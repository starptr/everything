//! `basic` — the generic channel/item slice. It rides core's generic path and implements almost
//! nothing: a `channel-type:basic` lists + paginates its items, and an `item-type:basic` is a plain
//! content object (the most common kind: a chat message). See DESIGN §2/§4/§5.

use async_trait::async_trait;
use cp_model::{Channel, ChannelKind, IndexEntry, ItemKind, Json, Result, StoreCtx, TypeId};

/// `channel-type:basic`.
struct BasicChannel {
    type_id: TypeId,
}

#[async_trait]
impl ChannelKind for BasicChannel {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _query: Json) -> Result<Json> {
        // DESIGN §5: children(id, {Item, [basic]}, page, TimeDesc); a `query.at` seeks via
        // seek_time first, so jump-to-timestamp is free. Then serialize the NodePage to Json.
        todo!("basic channel contents (DESIGN §5)")
    }

    fn index(&self, payload: &Json) -> Option<IndexEntry> {
        // name -> FTS (DESIGN §6). This is what `space` searches over.
        let name = payload.get("name")?.as_str()?;
        Some(IndexEntry {
            name: Some(name.to_owned()),
            ..Default::default()
        })
    }
}

/// `item-type:basic`.
struct BasicItem {
    type_id: TypeId,
}

impl ItemKind for BasicItem {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    fn index(&self, payload: &Json) -> Option<IndexEntry> {
        // body text -> FTS. §6.
        let body = payload.get("body")?.as_str()?;
        Some(IndexEntry {
            text: Some(body.to_owned()),
            ..Default::default()
        })
    }
}

/// The `channel-type:basic` kind, for the composition root. §10.
pub fn channel() -> impl ChannelKind {
    BasicChannel {
        type_id: TypeId::new("basic"),
    }
}

/// The `item-type:basic` kind, for the composition root. §10.
pub fn item() -> impl ItemKind {
    BasicItem {
        type_id: TypeId::new("basic"),
    }
}
