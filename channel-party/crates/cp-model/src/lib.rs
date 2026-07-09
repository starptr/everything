//! `cp-model` — the channel-party interface crate. See DESIGN.md §4/§5/§7/§8.
//!
//! Defines the envelope types, ULID ids, the two Kind traits and their opt-in capabilities, the
//! closed `StoreCtx` primitive set, and the `RuntimeComponent` abstraction. `cp-core` implements
//! these mechanisms; kind crates under `kinds/` depend on this crate only, never on `cp-core`.
//!
//! TODO(ts-rs): the payload / query / response structs each kind defines should derive `ts-rs::TS`
//! so a kind can emit its TS types into `web/` (DESIGN §9). Deferred; not wired in the scaffold.

pub mod debug;
pub mod envelope;
pub mod events;
pub mod ids;
pub mod kind;
pub mod migration;
pub mod runtime;
pub mod store;
pub mod write;

pub use debug::{DebugAccess, DebugCommand};
pub use envelope::{Channel, Item, Json, User, UserExternalLink};
pub use events::{ChangeEvent, ChangeOp, EnvelopeRef};
pub use ids::{ChannelId, ItemId, TypeId, UserId};
pub use kind::{Action, ChannelKind, IndexEntry, ItemKind, Membership, Permission};
pub use migration::{Migration, Migrations};
pub use runtime::{Interests, RuntimeComponent, RuntimeCtx, RuntimeEvent, WriteScope};
pub use store::{Cursor, Filter, Node, NodePage, Order, Page, StoreCtx, SuperType};
pub use write::{NewChannel, NewItem, Upsert, WriteCtx};

/// Crate-wide result type. Kind capabilities and store primitives return this.
pub type Result<T> = std::result::Result<T, Error>;

/// Errors surfaced across the plugin boundary between core and a kind.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A payload failed a kind's `validate`. §3.
    #[error("invalid payload: {0}")]
    Validation(String),
    /// A referenced envelope does not exist.
    #[error("not found")]
    NotFound,
    /// Anything else, kept opaque to core.
    #[error("{0}")]
    Other(String),
}
