//! The envelope store: it persists envelopes and implements the closed `StoreCtx` primitive set
//! (DESIGN §5) over sqlite. The primitive bodies are stubbed in the scaffold — the schema
//! (`migrations/0001_init.sql`) and the registry wiring exist so kinds can be registered and
//! dispatched to; filling these in is §5/§6 slice work.

use async_trait::async_trait;
use cp_model::{ChannelId, Cursor, Filter, Node, NodePage, Order, Page, Result, StoreCtx};
use sqlx::SqlitePool;

use crate::registry::Registry;

/// The sqlite-backed store. Holds the pool and the registry (for `index()` on write). §5/§6.
pub struct Store {
    pool: SqlitePool,
    registry: Registry,
}

impl Store {
    pub fn new(pool: SqlitePool, registry: Registry) -> Self {
        Self { pool, registry }
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub fn registry(&self) -> &Registry {
        &self.registry
    }
}

#[async_trait]
impl StoreCtx for Store {
    async fn children(
        &self,
        _container: ChannelId,
        _filter: Filter,
        _page: Page,
        _order: Order,
    ) -> Result<NodePage> {
        todo!("cp-core store: children — one level, cursor-paginated (DESIGN §5)")
    }

    async fn descendants(
        &self,
        _root: ChannelId,
        _filter: Filter,
        _depth: Option<u32>,
    ) -> Result<Vec<Node>> {
        todo!("cp-core store: descendants — whole subtree (DESIGN §5)")
    }

    async fn seek_time(&self, _container: ChannelId, _timestamp_ms: u64) -> Result<Cursor> {
        todo!("cp-core store: seek_time — ULID time-jump to a cursor (DESIGN §3/§5)")
    }

    async fn search(
        &self,
        _scope: ChannelId,
        _text: &str,
        _filter: Filter,
        _page: Page,
    ) -> Result<NodePage> {
        todo!("cp-core store: search — FTS over the index() projection (DESIGN §5/§6)")
    }
}
