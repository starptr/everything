//! The envelope types. Storage is schemaless: core stores envelopes and never interprets a
//! `payload`. The only truly universal fields are `id` and `type_id`; even `container` is
//! optional. See DESIGN §1/§3.

use serde::{Deserialize, Serialize};

use crate::ids::{ChannelId, ItemId, TypeId, UserId};

/// An opaque per-kind payload. Core never looks inside one. §1.
pub type Json = serde_json::Value;

/// A container envelope. A channel's children = everything (channels or items) whose `container`
/// is this channel; `container` is null for a root channel. §3.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Channel {
    pub id: ChannelId,
    pub type_id: TypeId,
    pub container: Option<ChannelId>,
    pub payload: Json,
}

/// A content envelope — everything that lives in a container. `external_key` is the dedup/upsert
/// handle for mirrored external objects (e.g. one `cached-user` per Discord user). §2/§3.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Item {
    pub id: ItemId,
    pub type_id: TypeId,
    pub container: Option<ChannelId>,
    pub external_key: Option<String>,
    pub payload: Json,
}

/// The one native principal. Not a super-type because it is not extensible: there is exactly one
/// native user representation, and it is the only thing that authenticates, owns, or holds
/// permissions. Auth material and `created_at` live here; elided in the scaffold. §2.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct User {
    pub id: UserId,
    pub handle: String,
}

/// The `linked-users` edge: a native user's reference to a `cached-user` item that represents it
/// on an external platform. Bidirectional. §2/§3.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UserExternalLink {
    pub user_id: UserId,
    pub item_id: ItemId,
}
