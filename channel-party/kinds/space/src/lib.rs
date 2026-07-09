//! `space` — a container whose `contents` is a substring name-search over its descendant channels.
//! It is index-light and search-shaped: the island is a search UI. See DESIGN §4/§5 and
//! `design/index-search.md`.

use async_trait::async_trait;
use cp_model::{
    Channel, ChannelKind, Cursor, Error, Filter, Json, Page, Result, StoreCtx, SuperType, TypeId,
};
use serde::Deserialize;

/// Page size when a `space` query omits `limit`.
const DEFAULT_LIMIT: u32 = 50;

/// The `contents` query for a `space` — a search string plus optional pagination. Opaque to core; the
/// island and this kind agree on the shape (§5/§9). An empty/short `q` yields an empty page.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct SpaceQuery {
    q: String,
    cursor: Option<String>,
    limit: Option<u32>,
}

/// `channel-type:space`.
struct Space {
    type_id: TypeId,
}

#[async_trait]
impl ChannelKind for Space {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    async fn contents(&self, cx: &dyn StoreCtx, ch: &Channel, query: Json) -> Result<Json> {
        // DESIGN §5: search(scope = self, query.q, {Channel}, page) -> paginated channel matches over
        // the FTS projection (§6), then serialize the NodePage. Deviation from §5's `{Channel, [basic]}`:
        // we don't restrict to the `basic` type — hardcoding a peer kind's string would couple `space`
        // to `basic`; `super_type: Channel` already excludes messages, and a space may hold any channel
        // kind. `search` scopes to this space's subtree and short-circuits an empty/short `q`.
        let q: SpaceQuery = if query.is_null() {
            SpaceQuery::default()
        } else {
            serde_json::from_value(query).map_err(|e| Error::Validation(e.to_string()))?
        };

        let page = cx
            .search(
                ch.id,
                &q.q,
                Filter {
                    super_type: Some(SuperType::Channel),
                    type_ids: None,
                },
                Page {
                    cursor: Cursor(q.cursor),
                    limit: q.limit.unwrap_or(DEFAULT_LIMIT),
                },
            )
            .await?;
        serde_json::to_value(page).map_err(|e| Error::Other(e.to_string()))
    }
}

/// The `channel-type:space` kind, for the composition root. §10.
pub fn channel() -> impl ChannelKind {
    Space {
        type_id: TypeId::new("space"),
    }
}
