//! The core event bus. The write path emits a `ChangeEvent` after every committed mutation;
//! derived indexers and the frontend SSE consume the stream — independent tasks, so a slow
//! pipeline never blocks the write. The event *types* live in `cp-model` (so a kind's runtime
//! component can consume them without depending on `cp-core`); the bus is the mechanism. §7/§9.

use tokio::sync::broadcast;

// Re-exported so existing `cp_core::events::ChangeEvent` / `cp_core::ChangeEvent` paths keep working.
pub use cp_model::{ChangeEvent, ChangeOp, EnvelopeRef};

/// A multi-producer / multi-consumer change bus. §7/§9.
#[derive(Clone)]
pub struct EventBus {
    tx: broadcast::Sender<ChangeEvent>,
}

impl EventBus {
    pub fn new() -> Self {
        let (tx, _rx) = broadcast::channel(1024);
        Self { tx }
    }

    /// Emit a change event; dropped if there are no subscribers. §7.
    pub fn publish(&self, event: ChangeEvent) {
        let _ = self.tx.send(event);
    }

    /// Subscribe to the change stream (e.g. an indexer or an SSE connection). §7/§9.
    pub fn subscribe(&self) -> broadcast::Receiver<ChangeEvent> {
        self.tx.subscribe()
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}
