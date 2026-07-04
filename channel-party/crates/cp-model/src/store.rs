//! The closed set of store primitives a kind composes its `contents` strategy from. This set does
//! not grow as types are added — core gains nothing per type. `StoreCtx` is a trait (implemented by
//! `cp-core`) so kind crates depend only on `cp-model`. See DESIGN §5.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::envelope::{Channel, Item};
use crate::ids::{ChannelId, TypeId};
use crate::Result;

/// Which super-type a query targets. §2/§5.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SuperType {
    Channel,
    Item,
}

/// A filter over a children / descendants query. §5.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Filter {
    pub super_type: Option<SuperType>,
    pub type_ids: Option<Vec<TypeId>>,
}

/// Sort order for a page of children. ULID ids make time-ordering a plain id sort. §3/§5.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Order {
    TimeAsc,
    TimeDesc,
}

/// An opaque pagination cursor. §5.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Cursor(pub Option<String>);

/// A requested page: where to resume, and how many to return. §5.
#[derive(Clone, Debug)]
pub struct Page {
    pub cursor: Cursor,
    pub limit: u32,
}

/// One envelope in a discovery result — a child channel or item. Discovery is recursive: a
/// container yields child channel references, and opening one calls its own `contents`. §5.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "super_type", rename_all = "snake_case")]
pub enum Node {
    Channel(Channel),
    Item(Item),
}

/// A page of nodes plus the cursor to continue from. §5.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NodePage {
    pub nodes: Vec<Node>,
    pub next: Cursor,
}

/// The store primitives handed to a kind's `contents` / `membership`. §5.
#[async_trait]
pub trait StoreCtx: Send + Sync {
    /// One level of children (channels and/or items), cursor-paginated. §5.
    async fn children(
        &self,
        container: ChannelId,
        filter: Filter,
        page: Page,
        order: Order,
    ) -> Result<NodePage>;

    /// A whole subtree (fetch-all), optionally depth-limited. §5.
    async fn descendants(
        &self,
        root: ChannelId,
        filter: Filter,
        depth: Option<u32>,
    ) -> Result<Vec<Node>>;

    /// ULID time-jump: the cursor at `timestamp_ms` within a container. §3/§5.
    async fn seek_time(&self, container: ChannelId, timestamp_ms: u64) -> Result<Cursor>;

    /// FTS over the `index()` projection, scoped to a subtree. §5/§6.
    async fn search(
        &self,
        scope: ChannelId,
        text: &str,
        filter: Filter,
        page: Page,
    ) -> Result<NodePage>;
}
