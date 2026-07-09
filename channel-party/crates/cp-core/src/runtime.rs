//! The one `RuntimeComponent` supervisor. Each component is a supervised, long-lived task that
//! backfills then reacts to the change stream ("backfill-then-stream"). This module provides the
//! concrete `RuntimeCtx` core hands each component and the supervisor that keeps it alive (restart +
//! backoff), confines its writes by `WriteScope`, and drives `version()`-triggered resets. See DESIGN
//! §7 and `design/runtime.md`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use cp_model::{
    ChangeEvent, Channel, ChannelId, Interests, Item, ItemId, Node, Result, RuntimeComponent,
    RuntimeCtx, RuntimeEvent, TypeId, WriteCtx, WriteScope,
};
use sqlx::SqlitePool;
use tokio::sync::{broadcast, watch, Mutex};
use tokio::task::JoinSet;
use tokio::time::{interval, Interval};

use crate::events::EventBus;
use crate::registry::Registry;
use crate::store::Store;

/// Backoff floor + ceiling for restarting a failed component.
const BACKOFF_MIN: Duration = Duration::from_millis(200);
const BACKOFF_MAX: Duration = Duration::from_secs(30);
/// A run that lasted at least this long is treated as healthy: its next failure restarts from the floor.
const HEALTHY_RUN: Duration = Duration::from_secs(30);

/// The concrete context core hands a component: the interests-filtered change stream + scheduler, point
/// reads, the `WriteScope`-confined write surface, the type-owned DB handle, and the reset flag. §7.
pub struct CoreRuntimeCtx {
    types: Vec<TypeId>,
    writes: WriteScope,
    store: Arc<Store>,
    changes: Mutex<broadcast::Receiver<ChangeEvent>>,
    interval: Option<Mutex<Interval>>,
    pool: SqlitePool,
    shutdown: watch::Receiver<bool>,
    reset: bool,
}

impl CoreRuntimeCtx {
    fn new(
        interests: Interests,
        writes: WriteScope,
        store: Arc<Store>,
        changes: broadcast::Receiver<ChangeEvent>,
        pool: SqlitePool,
        shutdown: watch::Receiver<bool>,
        reset: bool,
    ) -> Self {
        // `interval` must be built inside the runtime (it is: the supervisor task).
        let interval = interests
            .schedule_secs
            .map(|s| Mutex::new(interval(Duration::from_secs(s.max(1)))));
        Self {
            types: interests.types,
            writes,
            store,
            changes: Mutex::new(changes),
            interval,
            pool,
            shutdown,
            reset,
        }
    }

    fn interested(&self, ev: &ChangeEvent) -> bool {
        // Empty `types` ⇒ reacts to no change events (a schedule-only or pure-backfill component).
        self.types.contains(&ev.type_id)
    }
}

#[async_trait::async_trait]
impl RuntimeCtx for CoreRuntimeCtx {
    async fn next_event(&self) -> Option<RuntimeEvent> {
        let mut shutdown = self.shutdown.clone();
        loop {
            if *shutdown.borrow() {
                return None;
            }
            let mut rx = self.changes.lock().await;
            tokio::select! {
                biased;
                () = wait_flag(&mut shutdown) => return None,
                () = tick(self.interval.as_ref()) => return Some(RuntimeEvent::Tick),
                recv = rx.recv() => match recv {
                    Ok(ev) if self.interested(&ev) => return Some(RuntimeEvent::Change(ev)),
                    Ok(_) => {}                                        // not of interest → keep waiting
                    Err(broadcast::error::RecvError::Lagged(_)) => {}  // fell behind → skip, re-sync
                    Err(broadcast::error::RecvError::Closed) => return None,
                },
            }
        }
    }

    async fn get_item(&self, id: ItemId) -> Result<Option<Item>> {
        self.store.get_item(id).await
    }

    async fn get_channel(&self, id: ChannelId) -> Result<Option<Channel>> {
        self.store.get_channel(id).await
    }

    async fn scan(&self, types: &[TypeId]) -> Result<Vec<Node>> {
        self.store.scan_by_types(types).await
    }

    fn writer(&self) -> Option<&dyn WriteCtx> {
        // Structural §7 confinement: a Derived component cannot obtain the envelope mutation API.
        match self.writes {
            WriteScope::Primary => Some(self.store.as_ref()),
            WriteScope::Derived => None,
        }
    }

    fn type_owned_db(&self) -> &SqlitePool {
        &self.pool
    }

    fn reset_requested(&self) -> bool {
        self.reset
    }
}

/// Await until the watch flag is `true` (or the sender is dropped). Used as the shutdown arm.
async fn wait_flag(rx: &mut watch::Receiver<bool>) {
    loop {
        if *rx.borrow() {
            return;
        }
        if rx.changed().await.is_err() {
            return; // sender dropped ⇒ treat as shutdown
        }
    }
}

/// The scheduler arm: fire on the interval, or never (pending) when unscheduled.
async fn tick(interval: Option<&Mutex<Interval>>) {
    match interval {
        Some(m) => {
            m.lock().await.tick().await;
        }
        None => std::future::pending::<()>().await,
    }
}

/// A handle to the running components: shut them down (graceful) or drop it (aborts them). §7.
pub struct RuntimeHandle {
    shutdown: watch::Sender<bool>,
    tasks: JoinSet<()>,
}

impl RuntimeHandle {
    /// Signal shutdown and wait for every component to exit its loop.
    pub async fn shutdown(mut self) {
        let _ = self.shutdown.send(true);
        while self.tasks.join_next().await.is_some() {}
    }
}

/// Supervise every registered component: one task each, restarted with capped backoff on failure. §7/§10.
pub fn spawn(
    registry: Registry,
    store: Arc<Store>,
    events: EventBus,
    pool: SqlitePool,
) -> RuntimeHandle {
    let (sd_tx, sd_rx) = watch::channel(false);
    let mut tasks = JoinSet::new();
    for component in registry.runtimes() {
        let component = component.clone();
        let store = store.clone();
        let events = events.clone();
        let pool = pool.clone();
        let sd_rx = sd_rx.clone();
        tasks.spawn(supervise(component, store, events, pool, sd_rx));
    }
    RuntimeHandle {
        shutdown: sd_tx,
        tasks,
    }
}

async fn supervise(
    component: Arc<dyn RuntimeComponent>,
    store: Arc<Store>,
    events: EventBus,
    pool: SqlitePool,
    mut shutdown: watch::Receiver<bool>,
) {
    let name = component.name().to_owned();
    // A version bump since last boot means reset; persist the new version either way.
    let reset = match reconcile_version(&pool, &name, component.version()).await {
        Ok(reset) => reset,
        Err(e) => {
            tracing::error!(component = name, error = %e, "runtime: version reconcile failed");
            false
        }
    };

    let mut backoff = BACKOFF_MIN;
    loop {
        if *shutdown.borrow() {
            break;
        }
        let cx = CoreRuntimeCtx::new(
            component.interests(),
            component.writes(),
            store.clone(),
            events.subscribe(),
            pool.clone(),
            shutdown.clone(),
            reset,
        );
        let started = Instant::now();
        match component.run(&cx).await {
            Ok(()) => break, // clean exit (driven by shutdown via next_event → None)
            Err(e) => {
                tracing::error!(component = name, error = %e, "runtime component failed; restarting")
            }
        }
        if *shutdown.borrow() {
            break;
        }
        // A long, healthy run resets the backoff; a fast-failing one keeps escalating.
        if started.elapsed() >= HEALTHY_RUN {
            backoff = BACKOFF_MIN;
        }
        tokio::select! {
            () = tokio::time::sleep(backoff) => {}
            () = wait_flag(&mut shutdown) => break,
        }
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

/// Compare the component's `version()` to the stored one and persist the new value. Returns whether a
/// reset is due — true only when a *different* prior version was recorded (a first-ever boot has nothing
/// to reset). §7.
async fn reconcile_version(pool: &SqlitePool, name: &str, version: u32) -> Result<bool> {
    let db = |e: sqlx::Error| cp_model::Error::Other(e.to_string());
    let stored: Option<i64> =
        sqlx::query_scalar("SELECT version FROM runtime_component_state WHERE name = ?")
            .bind(name)
            .fetch_optional(pool)
            .await
            .map_err(db)?;
    let reset = matches!(stored, Some(v) if v as u32 != version);
    sqlx::query(
        "INSERT INTO runtime_component_state (name, version) VALUES (?, ?) \
         ON CONFLICT(name) DO UPDATE SET version = excluded.version",
    )
    .bind(name)
    .bind(i64::from(version))
    .execute(pool)
    .await
    .map_err(db)?;
    Ok(reset)
}
