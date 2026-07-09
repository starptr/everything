//! `basic` — the generic channel/item slice. It rides core's generic path and implements almost
//! nothing: a `channel-type:basic` lists + paginates its items, and an `item-type:basic` is a plain
//! content object (the most common kind: a chat message). See DESIGN §2/§4/§5.

use async_trait::async_trait;
use cp_model::{
    Action, Channel, ChannelKind, Cursor, Error, Filter, IndexEntry, ItemKind, Json, Membership,
    Order, Page, Permission, Result, StoreCtx, SuperType, TypeId, UserId, WriteCtx,
};
use serde::Deserialize;

/// The type string shared by the `basic` channel and item kinds. Channels and items live in two
/// separate registries, so one string keys both without collision. §4.
pub const TYPE: &str = "basic";

/// Page size when a query omits `limit`.
const DEFAULT_LIMIT: u32 = 50;

/// The `contents` query for a `basic` channel — every field optional. Opaque to core; this kind and
/// its island agree on the shape (DESIGN §5/§9). `at` jumps to a UNIX-ms point in the feed before
/// paging; `cursor` resumes a prior page; `limit` caps the page.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct BasicQuery {
    at: Option<u64>,
    cursor: Option<String>,
    limit: Option<u32>,
}

/// `channel-type:basic`.
struct BasicChannel {
    type_id: TypeId,
}

#[async_trait]
impl ChannelKind for BasicChannel {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    async fn contents(&self, cx: &dyn StoreCtx, ch: &Channel, query: Json) -> Result<Json> {
        // DESIGN §5: children(id, {Item, [basic]}, page, TimeDesc); a `query.at` seeks via seek_time
        // first, so jump-to-timestamp is free. Because the feed is newest-first, `at` selects items
        // at/before that time (scroll back to a date). Then serialize the NodePage back to Json.
        let q: BasicQuery = if query.is_null() {
            BasicQuery::default()
        } else {
            serde_json::from_value(query).map_err(|e| Error::Validation(e.to_string()))?
        };

        let cursor = match q.at {
            Some(at) => cx.seek_time(ch.id, at).await?,
            None => Cursor(q.cursor),
        };
        let page = cx
            .children(
                ch.id,
                Filter {
                    super_type: Some(SuperType::Item),
                    type_ids: Some(vec![TypeId::new(TYPE)]),
                },
                Page {
                    cursor,
                    limit: q.limit.unwrap_or(DEFAULT_LIMIT),
                },
                Order::TimeDesc,
            )
            .await?;
        serde_json::to_value(page).map_err(|e| Error::Other(e.to_string()))
    }

    fn index(&self, payload: &Json) -> Option<IndexEntry> {
        // name -> FTS (DESIGN §6). This is what `space` searches over.
        let name = payload.get("name")?.as_str()?;
        Some(IndexEntry {
            name: Some(name.to_owned()),
            ..Default::default()
        })
    }

    fn membership(&self) -> Option<&dyn Membership> {
        // `basic` accepts native users, backed by core's generic `channel_members` substrate. §8.
        Some(self)
    }

    fn permission(&self) -> Option<&dyn Permission> {
        // `basic` authorizes posts by membership (see the `Permission` impl). §18.
        Some(self)
    }
}

/// `basic`'s authorization rides the same `channel_members` substrate as its membership: a member may
/// post, contents are public, and structural admin isn't exposed over HTTP. §18.
#[async_trait]
impl Permission for BasicChannel {
    async fn authorize(
        &self,
        cx: &dyn StoreCtx,
        ch: &Channel,
        user: UserId,
        action: Action,
    ) -> Result<bool> {
        Ok(match action {
            Action::View => true,
            Action::Post => cx.is_member(ch.id, user).await?,
            Action::Manage => false,
        })
    }
}

/// A `basic` channel's membership rides the generic edge table; "add a user" is a plain edge. §8.
#[async_trait]
impl Membership for BasicChannel {
    async fn add_user(&self, cx: &dyn WriteCtx, ch: &Channel, user: UserId) -> Result<()> {
        cx.add_member(ch.id, user).await
    }

    async fn remove_user(&self, cx: &dyn WriteCtx, ch: &Channel, user: UserId) -> Result<()> {
        cx.remove_member(ch.id, user).await
    }

    async fn members(&self, cx: &dyn WriteCtx, ch: &Channel) -> Result<Vec<UserId>> {
        cx.members(ch.id).await
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

    fn with_author(&self, mut payload: Json, author: UserId) -> Json {
        // A `basic` message's author is a native user id, stamped server-side (never client-trusted). §2/§18.
        if let Some(obj) = payload.as_object_mut() {
            obj.insert("author".to_owned(), Json::String(author.to_string()));
        }
        payload
    }
}

/// The `channel-type:basic` kind, for the composition root. §10.
pub fn channel() -> impl ChannelKind {
    BasicChannel {
        type_id: TypeId::new(TYPE),
    }
}

/// The `item-type:basic` kind, for the composition root. §10.
pub fn item() -> impl ItemKind {
    BasicItem {
        type_id: TypeId::new(TYPE),
    }
}
