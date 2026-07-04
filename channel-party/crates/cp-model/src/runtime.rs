//! `RuntimeComponent` — the one supervised-task abstraction. Ingesting workers and derived indexers
//! are the same machine: a long-lived task that does an initial batch pass, then reacts to a stream
//! ("backfill-then-stream"). There is no separate `Worker` and `Indexer`. See DESIGN §7.

use async_trait::async_trait;

use crate::ids::TypeId;
use crate::Result;

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

/// The handle a component receives: the store (restricted per `writes()`), the change-stream
/// subscription (filtered by `interests`), the scheduler, and shutdown. Concretely provided by
/// `cp-core`; a marker trait in the scaffold. §7.
pub trait RuntimeCtx: Send + Sync {}

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
