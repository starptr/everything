//! The core event bus. The sync component writes envelopes and emits change events; derived
//! indexers and the frontend SSE consume them — independent tasks, so a slow pipeline never blocks
//! ingestion. See DESIGN §7/§9.

use cp_model::{ChannelId, TypeId};
use tokio::sync::broadcast;

/// A change event: which envelope type changed, and the channel scope it belongs to (if any). §7.
#[derive(Clone, Debug)]
pub struct ChangeEvent {
    pub type_id: TypeId,
    pub scope: Option<ChannelId>,
}

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
