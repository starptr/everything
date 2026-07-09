//! The Kind abstraction. A Kind is a registry entry keyed by its type string; core calls into it
//! through this fixed set of capability traits and never `match`es on a concrete type. Capabilities
//! are opt-in default methods, so a trivial kind implements two lines and a rich one implements
//! many. See DESIGN §4.

use async_trait::async_trait;

use crate::debug::DebugCommand;
use crate::envelope::{Channel, Item, Json};
use crate::ids::{TypeId, UserId};
use crate::store::StoreCtx;
use crate::write::WriteCtx;
use crate::Result;

/// A kind-declared projection of searchable / sortable fields, applied transactionally on write
/// into core's built-in index substrates. A kind that needs no indexing returns `None`. §6.
#[derive(Clone, Debug, Default)]
pub struct IndexEntry {
    /// Name / body text for FTS (trigram substring search).
    pub name: Option<String>,
    pub text: Option<String>,
    /// A declared sort key (expression index).
    pub sort_key: Option<String>,
    /// A coordinate for the 2D / R-tree substrate (e.g. `canvas-text-box`).
    pub coord: Option<(f64, f64)>,
}

/// Behavior for one `channel-type:*`. §4.
#[async_trait]
pub trait ChannelKind: Send + Sync {
    fn type_id(&self) -> &TypeId;

    /// Reject invalid payloads before core commits them. §3.
    fn validate(&self, _payload: &Json) -> Result<()> {
        Ok(())
    }

    /// Discover this channel's contents. `query` and the returned value are type-defined and
    /// opaque to core; the kind composes its strategy from the `StoreCtx` primitives. §5.
    async fn contents(&self, cx: &dyn StoreCtx, ch: &Channel, query: Json) -> Result<Json>;

    /// Inline searchable / sortable projection. §6.
    fn index(&self, _payload: &Json) -> Option<IndexEntry> {
        None
    }

    /// Membership capability. `None` *is* the "does not accept users" answer. §8.
    fn membership(&self) -> Option<&dyn Membership> {
        None
    }

    /// Authorization capability. `None` = deny-by-default: the channel is not writable over HTTP
    /// until its kind grants an action. Opt-in like `membership`. §18.
    fn permission(&self) -> Option<&dyn Permission> {
        None
    }

    /// Extra HTTP routes, mounted under `/ext/<type>` (e.g. a webhook receiver). §4/§9.
    fn routes(&self) -> Option<axum::Router> {
        None
    }

    /// Debug-shell commands this kind contributes, each flagged read/write. §8.
    fn debug_commands(&self) -> Vec<DebugCommand> {
        Vec::new()
    }

    /// A one-line human summary for the debug shell. §8.
    fn debug_summary(&self, _ch: &Channel) -> Option<String> {
        None
    }
}

/// Behavior for one `item-type:*` — the same shape as [`ChannelKind`] minus `contents` and
/// `membership` (items are inert content, never containers or principals). All its methods are
/// synchronous, so it is a plain trait. §4.
pub trait ItemKind: Send + Sync {
    fn type_id(&self) -> &TypeId;

    fn validate(&self, _payload: &Json) -> Result<()> {
        Ok(())
    }

    fn index(&self, _payload: &Json) -> Option<IndexEntry> {
        None
    }

    /// Stamp server-known authorship into a new item's payload before it is persisted. The write
    /// endpoint calls this with the authenticated principal; a client-supplied `author` is overwritten
    /// — provenance is not client-trusted (§2). Default: unchanged (a kind with no notion of an author,
    /// e.g. a canvas box). §18.
    fn with_author(&self, payload: Json, _author: UserId) -> Json {
        payload
    }

    fn debug_summary(&self, _item: &Item) -> Option<String> {
        None
    }
}

/// Optional channel capability backing `add-user-to-channel`. It receives a [`WriteCtx`] because it
/// mutates: what "add a user" means is the kind's choice — a basic channel calls
/// `cx.add_member(...)` on the generic substrate; a Discord channel may reject or proxy an outbound
/// invite. §8.
#[async_trait]
pub trait Membership: Send + Sync {
    async fn add_user(&self, cx: &dyn WriteCtx, ch: &Channel, user: UserId) -> Result<()>;
    async fn remove_user(&self, cx: &dyn WriteCtx, ch: &Channel, user: UserId) -> Result<()>;
    async fn members(&self, cx: &dyn WriteCtx, ch: &Channel) -> Result<Vec<UserId>>;
}

/// A permission-checked action on a channel. A small, fixed, core-owned vocabulary (like
/// [`SuperType`](crate::store::SuperType)), distinct from the open-ended kind set. §18.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// Read a channel's contents. Defined for completeness; reads are not gated yet (§18 enforces writes).
    View,
    /// Create an item (post a message) in the channel.
    Post,
    /// Administer the channel: membership, structure, configuration.
    Manage,
}

/// Optional per-channel authorization (§18). Its absence (`ChannelKind::permission() -> None`) means
/// deny-by-default — the channel declines to authorize anyone. The policy is the kind's own: it may
/// consult the generic `channel_members` substrate ([`StoreCtx::is_member`]) or its own tables. It
/// takes a read `cx`, never [`WriteCtx`] — deciding never mutates.
#[async_trait]
pub trait Permission: Send + Sync {
    async fn authorize(
        &self,
        cx: &dyn StoreCtx,
        ch: &Channel,
        user: UserId,
        action: Action,
    ) -> Result<bool>;
}
