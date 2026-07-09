//! `cp-core` — the fixed, small set of mechanisms. See DESIGN.md §13:
//!
//! > envelope store · two kind registries · `contents` dispatch · index substrates + inline
//! > projection · one `RuntimeComponent` supervisor · event bus · migrator · gated debug shell
//!
//! Depends only on `cp-model`; it has **no dependency on any concrete kind crate** — kinds are
//! wired in exactly one place, the composition root (`cp-bin`). Store primitives and several
//! mechanisms are stubbed in the scaffold; DESIGN §5/§6/§7/§8 fill them in.

pub mod auth;
pub mod authz;
pub mod contents;
pub mod debug;
pub mod events;
pub mod index;
pub mod links;
pub mod migrate;
pub mod registry;
pub mod runtime;
pub mod store;

use std::str::FromStr;
use std::sync::Arc;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::SqlitePool;

pub use cp_model::{Migration, Migrations};
pub use events::{ChangeEvent, ChangeOp, EnvelopeRef, EventBus};
pub use registry::{Registry, RegistryBuilder};
pub use store::Store;

/// The running core: the store handle, the registry, and the event bus. §10.
pub struct Core {
    pool: SqlitePool,
    registry: Registry,
    store: Arc<Store>,
    events: EventBus,
}

impl Core {
    /// Open the store at `db_url` (a sqlite URL, e.g. `sqlite:channel-party.db` or
    /// `sqlite::memory:`), run the core + kind migrations, and return a ready Core. §3/§10.
    pub async fn open(db_url: &str, registry: Registry) -> anyhow::Result<Self> {
        // `foreign_keys(true)` makes the `container` FK + `ON DELETE CASCADE` (and the
        // channel_members FKs) actually enforce — the write path relies on it. §3.
        let opts = SqliteConnectOptions::from_str(db_url)?
            .create_if_missing(true)
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new().connect_with(opts).await?;
        migrate::run(&pool, &registry).await?;
        let events = EventBus::new();
        let store = Arc::new(Store::new(pool.clone(), registry.clone(), events.clone()));
        Ok(Self {
            pool,
            registry,
            store,
            events,
        })
    }

    /// A cloneable handle to the envelope store (implements `cp_model::StoreCtx`).
    pub fn store(&self) -> Arc<Store> {
        self.store.clone()
    }

    pub fn registry(&self) -> &Registry {
        &self.registry
    }

    pub fn events(&self) -> &EventBus {
        &self.events
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    /// Supervise every registered `RuntimeComponent` (backfill-then-stream). Returns a handle that
    /// keeps the tasks alive — dropping it aborts them, so the caller must hold it. §7/§10.
    #[must_use]
    pub fn spawn_runtime(&self) -> runtime::RuntimeHandle {
        runtime::spawn(
            self.registry.clone(),
            self.store.clone(),
            self.events.clone(),
            self.pool.clone(),
        )
    }
}
