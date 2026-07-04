//! `contents` dispatch: one generic route, one trait method. `POST /api/channels/:id/contents`
//! resolves the channel's kind from the registry and calls its `contents`; `query` and the
//! response are opaque to core. See DESIGN §5.

use cp_model::{Channel, Error, Json, Result, StoreCtx};

use crate::registry::Registry;

/// Dispatch a contents query to the channel's kind. §5.
pub async fn dispatch(
    registry: &Registry,
    store: &dyn StoreCtx,
    channel: &Channel,
    query: Json,
) -> Result<Json> {
    let kind = registry.channel(&channel.type_id).ok_or(Error::NotFound)?;
    kind.contents(store, channel, query).await
}
