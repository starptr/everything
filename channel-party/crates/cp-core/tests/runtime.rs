//! Integration tests for the `RuntimeComponent` supervisor + `RuntimeCtx` (`TODO.md` #4) against a real
//! tempfile sqlite. Uses throwaway components that record what the ctx hands them into a shared log
//! (DESIGN §12) — so these assert the supervisor's behavior generically, without a concrete kind:
//! backfill-then-stream, `interests` filtering, `WriteScope` confinement, `version()` reset, shutdown.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use cp_core::{Core, Registry};
use cp_model::{
    ChangeOp, EnvelopeRef, Interests, ItemKind, NewItem, Node, Result, RuntimeComponent,
    RuntimeCtx, RuntimeEvent, TypeId, WriteCtx, WriteScope,
};
use tokio::sync::Mutex;

const ITEM: &str = "test-item";
const OTHER: &str = "other-item";

/// An item kind with no behavior — just something to create + enumerate.
struct TestItem(TypeId);
impl ItemKind for TestItem {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
}

/// A `Derived` component that records everything the ctx gives it (writer scope, reset, backfill, each
/// streamed change) into a shared log, filtered to `ITEM`.
struct Recorder {
    log: Arc<Mutex<Vec<String>>>,
    version: u32,
}

impl Recorder {
    async fn push(&self, s: String) {
        self.log.lock().await.push(s);
    }
}

#[async_trait]
impl RuntimeComponent for Recorder {
    fn name(&self) -> &str {
        "recorder"
    }
    fn writes(&self) -> WriteScope {
        WriteScope::Derived
    }
    fn version(&self) -> u32 {
        self.version
    }
    fn interests(&self) -> Interests {
        Interests {
            schedule_secs: None,
            types: vec![TypeId::new(ITEM)],
        }
    }
    async fn run(&self, cx: &dyn RuntimeCtx) -> Result<()> {
        // A Derived component must NOT get the envelope write API (§7 confinement).
        self.push(format!(
            "writer:{}",
            if cx.writer().is_some() {
                "some"
            } else {
                "none"
            }
        ))
        .await;
        if cx.reset_requested() {
            self.push("reset".to_owned()).await;
        }
        // Backfill: everything of interest that already exists.
        for node in cx.scan(&[TypeId::new(ITEM)]).await? {
            if let Node::Item(item) = node {
                self.push(format!("backfill:{}", item.id)).await;
            }
        }
        // Stream: react to changes (already filtered to `interests.types`).
        while let Some(event) = cx.next_event().await {
            match event {
                RuntimeEvent::Change(c) => {
                    let EnvelopeRef::Item(id) = c.target else {
                        continue;
                    };
                    let op = match c.op {
                        ChangeOp::Created => "created",
                        ChangeOp::Updated => "updated",
                        ChangeOp::Deleted => "deleted",
                    };
                    self.push(format!("change:{op}:{id}")).await;
                }
                RuntimeEvent::Tick => self.push("tick".to_owned()).await,
            }
        }
        Ok(())
    }
}

/// A `Primary` component: records that it *does* get the write API, then idles until shutdown.
struct PrimaryProbe {
    log: Arc<Mutex<Vec<String>>>,
}
#[async_trait]
impl RuntimeComponent for PrimaryProbe {
    fn name(&self) -> &str {
        "primary-probe"
    }
    fn writes(&self) -> WriteScope {
        WriteScope::Primary
    }
    async fn run(&self, cx: &dyn RuntimeCtx) -> Result<()> {
        let scope = if cx.writer().is_some() {
            "some"
        } else {
            "none"
        };
        self.log
            .lock()
            .await
            .push(format!("primary-writer:{scope}"));
        while cx.next_event().await.is_some() {}
        Ok(())
    }
}

fn item(type_id: &str) -> NewItem {
    NewItem {
        type_id: TypeId::new(type_id),
        container: None,
        external_key: None,
        payload: serde_json::json!({}),
    }
}

/// Poll the log until `pred` holds (or time out), returning a snapshot.
async fn wait_until(
    log: &Arc<Mutex<Vec<String>>>,
    pred: impl Fn(&[String]) -> bool,
) -> Vec<String> {
    for _ in 0..150 {
        {
            let l = log.lock().await;
            if pred(&l) {
                return l.clone();
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out waiting; log = {:?}", log.lock().await);
}

async fn open(url: &str, log: Arc<Mutex<Vec<String>>>, version: u32) -> Core {
    let registry = Registry::builder()
        .item(TestItem(TypeId::new(ITEM)))
        .item(TestItem(TypeId::new(OTHER)))
        .runtime(Recorder {
            log: log.clone(),
            version,
        })
        .runtime(PrimaryProbe { log })
        .build();
    Core::open(url, registry).await.unwrap()
}

#[tokio::test]
async fn supervisor_backfills_streams_filters_and_confines() {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let log = Arc::new(Mutex::new(Vec::new()));
    let core = open(&url, log.clone(), 0).await;
    let store = core.store();

    // One item exists BEFORE the runtime starts → it must arrive via backfill (there were no
    // subscribers when it was created, so it can't have come from the stream).
    let before = store.create_item(item(ITEM)).await.unwrap();

    let handle = core.spawn_runtime();

    // Wait until BOTH components have started (they are independent tasks with no ordering between
    // them): the Recorder has run its backfill, and the Primary probe has reported its writer scope.
    // Once the Recorder's backfill has run it has already subscribed (subscription precedes backfill),
    // so a change created after this cannot be missed.
    let snap = wait_until(&log, |l| {
        l.iter().any(|s| s == &format!("backfill:{before}"))
            && l.contains(&"primary-writer:some".to_owned())
    })
    .await;
    assert!(
        snap.contains(&"writer:none".to_owned()),
        "Derived component is denied the write API: {snap:?}"
    );
    assert!(
        snap.contains(&"primary-writer:some".to_owned()),
        "Primary component gets the write API: {snap:?}"
    );
    assert!(
        !snap.contains(&"reset".to_owned()),
        "first boot is not a reset"
    );

    // A streamed change of interest is delivered...
    let after = store.create_item(item(ITEM)).await.unwrap();
    // ...while a change of a non-interesting type is filtered out.
    let ignored = store.create_item(item(OTHER)).await.unwrap();

    let snap = wait_until(&log, |l| {
        l.iter().any(|s| s == &format!("change:created:{after}"))
    })
    .await;
    assert!(
        !snap.iter().any(|s| s.contains(&ignored.to_string())),
        "the `other-item` change was filtered by interests: {snap:?}"
    );

    handle.shutdown().await;
}

#[tokio::test]
async fn version_bump_requests_reset() {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());

    // First boot at version 0: records the version, no reset (nothing prior to reset).
    let log1 = Arc::new(Mutex::new(Vec::new()));
    let core = open(&url, log1.clone(), 0).await;
    let h = core.spawn_runtime();
    let snap = wait_until(&log1, |l| l.iter().any(|s| s.starts_with("writer:"))).await;
    assert!(
        !snap.contains(&"reset".to_owned()),
        "v0 first boot: {snap:?}"
    );
    h.shutdown().await;

    // Second boot at version 1 against the same DB: the bump requests a reset.
    let log2 = Arc::new(Mutex::new(Vec::new()));
    let core = open(&url, log2.clone(), 1).await;
    let h = core.spawn_runtime();
    wait_until(&log2, |l| l.contains(&"reset".to_owned())).await;
    h.shutdown().await;
}
