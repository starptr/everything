//! `space` — a container whose `contents` is a substring name-search over its descendant channels.
//! It is index-light and search-shaped: the island is a search UI. See DESIGN §4/§5.

use async_trait::async_trait;
use cp_model::{Channel, ChannelKind, Json, Result, StoreCtx, TypeId};

/// `channel-type:space`.
struct Space {
    type_id: TypeId,
}

#[async_trait]
impl ChannelKind for Space {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _query: Json) -> Result<Json> {
        // DESIGN §5: search(descendants(id), query.q, {Channel, [basic]}, page) -> paginated name
        // matches over the `index()` projection (§6). Then serialize the NodePage to Json.
        todo!("space channel contents (DESIGN §5)")
    }
}

/// The `channel-type:space` kind, for the composition root. §10.
pub fn channel() -> impl ChannelKind {
    Space {
        type_id: TypeId::new("space"),
    }
}
