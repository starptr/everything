//! The one `RuntimeComponent` supervisor. Each component is a supervised, long-lived task that
//! backfills then reacts to the change stream. Components compose via the event bus. See DESIGN §7.

use cp_model::{RuntimeCtx, WriteScope};

use crate::registry::Registry;

/// The concrete context core hands a component: store (restricted per `writes()`), change-stream
/// subscription, scheduler, shutdown. A marker in the scaffold. §7.
pub struct CoreRuntimeCtx;

impl RuntimeCtx for CoreRuntimeCtx {}

/// Supervise every registered component. §7/§10. Stub: it logs each component and the write scope
/// core would confine it to; actual spawn + restart supervision + the change stream are deferred.
pub fn spawn(registry: Registry) {
    for component in registry.runtimes() {
        let scope = match component.writes() {
            WriteScope::Primary => "primary",
            WriteScope::Derived => "derived",
        };
        tracing::info!(
            name = component.name(),
            write_scope = scope,
            "runtime component registered (supervision stubbed — DESIGN §7)"
        );
    }
}
