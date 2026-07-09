//! The write path: `WriteCtx` — the single mutation surface. See `design/write-path.md` and
//! DESIGN §3/§8. Every mutation validates via the owning kind, writes the inline `index()`
//! projection (§6), and emits a change event — all transactionally. Implemented by `cp-core`'s
//! store; kinds receive it through the `Membership` capability. No other code writes envelope
//! tables.

use async_trait::async_trait;

use crate::envelope::Json;
use crate::ids::{ChannelId, ItemId, TypeId, UserId};
use crate::store::StoreCtx;
use crate::Result;

/// Fields for a new channel envelope. `id` is minted by core (a fresh ULID).
pub struct NewChannel {
    pub type_id: TypeId,
    pub container: Option<ChannelId>,
    pub payload: Json,
}

/// Fields for a new (or upserted) item envelope. The kind owns its `external_key` uniqueness grain
/// by constructing the key string (e.g. `"discord:user:456"`); core never parses it. §3.
pub struct NewItem {
    pub type_id: TypeId,
    pub container: Option<ChannelId>,
    pub external_key: Option<String>,
    pub payload: Json,
}

/// Outcome of `upsert_item`: whether the row was created or updated in place. The id is stable
/// across updates, so references (e.g. cached-messages pointing at a cached-user) never break. §3.
pub enum Upsert<Id> {
    Inserted(Id),
    Updated(Id),
}

impl<Id: Copy> Upsert<Id> {
    /// The id, whichever branch occurred.
    pub fn id(&self) -> Id {
        match self {
            Upsert::Inserted(id) | Upsert::Updated(id) => *id,
        }
    }
}

/// The single write path. A superset of [`StoreCtx`] (a mutation may read first — e.g. an update
/// looks up the target's immutable `type_id` to pick the right kind's `validate`). Every method
/// validates via the owning kind, writes the envelope + inline index in one transaction, and emits
/// a change event on commit. See DESIGN §3/§8 and `design/write-path.md`.
#[async_trait]
pub trait WriteCtx: StoreCtx {
    async fn create_channel(&self, spec: NewChannel) -> Result<ChannelId>;
    async fn create_item(&self, spec: NewItem) -> Result<ItemId>;

    /// Insert-or-update keyed on `external_key` (required). The id is stable across updates. §3.
    async fn upsert_item(&self, spec: NewItem) -> Result<Upsert<ItemId>>;

    async fn set_channel_payload(&self, id: ChannelId, payload: Json) -> Result<()>;
    async fn set_item_payload(&self, id: ItemId, payload: Json) -> Result<()>;

    async fn reparent_channel(&self, id: ChannelId, container: Option<ChannelId>) -> Result<()>;
    async fn reparent_item(&self, id: ItemId, container: Option<ChannelId>) -> Result<()>;

    async fn delete_channel(&self, id: ChannelId) -> Result<()>;
    async fn delete_item(&self, id: ItemId) -> Result<()>;

    /// The generic `channel_members` substrate, used by `ChannelKind::membership()` impls. The
    /// user must already exist (members are native principals — §2); user creation is auth's job. §8.
    async fn add_member(&self, channel: ChannelId, user: UserId) -> Result<()>;
    async fn remove_member(&self, channel: ChannelId, user: UserId) -> Result<()>;
    async fn members(&self, channel: ChannelId) -> Result<Vec<UserId>>;
}
