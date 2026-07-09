//! `RuntimeComponent` — the one supervised-task abstraction. Ingesting workers and derived indexers
//! are the same machine: a long-lived task that does an initial batch pass, then reacts to a stream
//! ("backfill-then-stream"). There is no separate `Worker` and `Indexer`. See DESIGN §7 and
//! `design/runtime.md`.

use async_trait::async_trait;

use crate::events::ChangeEvent;
use crate::ids::{ChannelId, ItemId, TypeId};
use crate::{Channel, Item, Node, Result, WriteCtx};

/// What a component reacts to: a schedule, and/or the change stream filtered by envelope type. §7.
#[derive(Clone, Debug, Default)]
pub struct Interests {
    /// A fixed-interval schedule, in seconds, if any.
    pub schedule_secs: Option<u64>,
    /// Envelope types whose change events this component consumes.
    pub types: Vec<TypeId>,
}

impl Interests {
    /// Reacts to nothing (the default): a pure one-shot backfill.
    pub fn none() -> Self {
        Self::default()
    }
}

/// Write confinement for the store handle core hands a component. A `Derived` indexer is confined
/// to derived tables, so a bug can't corrupt the `Primary` source of truth. §7.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteScope {
    Primary,
    Derived,
}

/// One thing a component's loop reacts to, from [`RuntimeCtx::next_event`]. §7.
pub enum RuntimeEvent {
    /// An interests-filtered change committed to the store.
    Change(ChangeEvent),
    /// The `interests.schedule_secs` interval fired.
    Tick,
}

/// The handle a component receives (concretely provided by `cp-core`): the interests-filtered change
/// stream + scheduler, point reads, a `WriteScope`-confined write surface, the type-owned DB escape
/// hatch, and the reset signal. See `design/runtime.md`. §7.
#[async_trait]
pub trait RuntimeCtx: Send + Sync {
    /// Await the next change (pre-filtered to `interests.types`) or scheduler tick; `None` once the
    /// supervisor shuts the component down (a clean loop exit). Broadcast lag is skipped silently.
    async fn next_event(&self) -> Option<RuntimeEvent>;

    /// Point-read an item — a `ChangeEvent` carries no payload, so a `Derived` indexer fetches the
    /// changed envelope to project it.
    async fn get_item(&self, id: ItemId) -> Result<Option<Item>>;
    async fn get_channel(&self, id: ChannelId) -> Result<Option<Channel>>;

    /// Every existing envelope of the given types, id-ordered — the backfill enumerator. The change
    /// stream carries only *new* changes, so a component reconstructs prior state through this. §7.
    async fn scan(&self, types: &[TypeId]) -> Result<Vec<Node>>;

    /// The `Primary` write surface (envelope mutations), or `None` for a `Derived` component — which
    /// therefore *cannot* write core envelopes. This is the §7 confinement, enforced structurally.
    fn writer(&self) -> Option<&dyn WriteCtx>;

    /// A handle to the kind's own namespaced tables (the §6 escape hatch). Used to read/write a
    /// type-owned index; not for touching core's `channels`/`items`.
    fn type_owned_db(&self) -> &sqlx::SqlitePool;

    /// Whether `version()` was bumped since the last boot — the component resets (idempotently). §7.
    fn reset_requested(&self) -> bool;
}

/// A supervised, long-lived component: backfill then steady-state, all in one loop. Components are
/// crate-contributed singletons (one Discord component manages all bridged guilds), not
/// one-per-channel-instance. §7.
#[async_trait]
pub trait RuntimeComponent: Send + Sync {
    fn name(&self) -> &str;

    /// A schedule and/or the change stream this component reacts to. §7.
    fn interests(&self) -> Interests {
        Interests::none()
    }

    /// Bump to trigger a reset; the component decides what reset means. §7.
    fn version(&self) -> u32 {
        0
    }

    /// Whether the component writes `Primary` (source of truth) or `Derived` (indexes). §7.
    fn writes(&self) -> WriteScope {
        WriteScope::Derived
    }

    /// Backfill + steady-state, in one loop. §7.
    async fn run(&self, cx: &dyn RuntimeCtx) -> Result<()>;
}
