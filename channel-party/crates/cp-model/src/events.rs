//! Change events — the domain type the write path emits and runtime components + the SSE layer
//! consume. Lives here (not in `cp-core`) so a kind's `RuntimeComponent` can react to changes without
//! depending on `cp-core`. The broadcast bus that carries them is `cp-core`'s mechanism. See DESIGN §7.

use crate::ids::{ChannelId, ItemId, TypeId};

/// What happened to an envelope. §7.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChangeOp {
    Created,
    Updated,
    Deleted,
}

/// Which envelope changed. §7.
#[derive(Clone, Copy, Debug)]
pub enum EnvelopeRef {
    Channel(ChannelId),
    Item(ItemId),
}

/// A change event, emitted after a mutation commits. `container` is the scope SSE clients and runtime
/// component `interests` filter on. Carries no payload — a consumer that needs it does a point read. §7.
#[derive(Clone, Debug)]
pub struct ChangeEvent {
    pub op: ChangeOp,
    pub target: EnvelopeRef,
    pub type_id: TypeId,
    pub container: Option<ChannelId>,
}
