//! Integration tests for the FTS search substrate + `StoreCtx::search` (`TODO.md` #3) against a real
//! tempfile sqlite. Data is seeded through the write path, so `index()` actually populates `search_index`.
//! Uses throwaway test kinds (a name-indexing channel, a text-indexing item) rather than a concrete
//! kind crate (DESIGN §12) — which also proves search is generic over type, not tied to `basic`.

use async_trait::async_trait;
use cp_core::{Core, Registry};
use cp_model::{
    Channel, ChannelId, ChannelKind, Cursor, Filter, IndexEntry, ItemKind, Json, NewChannel,
    NewItem, Node, NodePage, Page, Result, StoreCtx, SuperType, TypeId, WriteCtx,
};
use serde_json::json;

/// A channel that projects `payload.name` into the FTS `name` column.
struct Room(TypeId);

#[async_trait]
impl ChannelKind for Room {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _q: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the search test")
    }
    fn index(&self, payload: &Json) -> Option<IndexEntry> {
        let name = payload.get("name")?.as_str()?;
        Some(IndexEntry {
            name: Some(name.to_owned()),
            ..Default::default()
        })
    }
}

/// An item that projects `payload.body` into the FTS `text` column.
struct Msg(TypeId);

impl ItemKind for Msg {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    fn index(&self, payload: &Json) -> Option<IndexEntry> {
        let body = payload.get("body")?.as_str()?;
        Some(IndexEntry {
            text: Some(body.to_owned()),
            ..Default::default()
        })
    }
}

async fn test_core() -> (tempfile::TempDir, Core) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    // One channel kind registered under two type strings (to test the type filter) + one item kind.
    let registry = Registry::builder()
        .channel(Room(TypeId::new("room")))
        .channel(Room(TypeId::new("board")))
        .item(Msg(TypeId::new("msg")))
        .build();
    let core = Core::open(&url, registry).await.unwrap();
    (dir, core)
}

fn ch(type_id: &str, name: &str, container: Option<ChannelId>) -> NewChannel {
    NewChannel {
        type_id: TypeId::new(type_id),
        container,
        payload: json!({ "name": name }),
    }
}
fn msg(body: &str, container: ChannelId) -> NewItem {
    NewItem {
        type_id: TypeId::new("msg"),
        container: Some(container),
        external_key: None,
        payload: json!({ "body": body }),
    }
}

fn channels(f: Option<SuperType>, type_ids: Option<Vec<TypeId>>) -> Filter {
    Filter {
        super_type: f,
        type_ids,
    }
}
fn page(limit: u32) -> Page {
    Page {
        cursor: Cursor(None),
        limit,
    }
}

/// The `name`/`body` payload field of each node, as a sorted set (order-independent assertions).
fn names(p: &NodePage) -> Vec<String> {
    let mut v: Vec<String> = p
        .nodes
        .iter()
        .filter_map(|n| {
            let payload = match n {
                Node::Channel(c) => &c.payload,
                Node::Item(i) => &i.payload,
            };
            payload
                .get("name")
                .or_else(|| payload.get("body"))
                .and_then(|v| v.as_str())
                .map(str::to_owned)
        })
        .collect();
    v.sort();
    v
}

#[tokio::test]
async fn channel_name_search_scopes_to_the_subtree_and_filters_by_type() {
    let (_dir, core) = test_core().await;
    let store = core.store();

    let root = store
        .create_channel(ch("room", "root", None))
        .await
        .unwrap();
    store
        .create_channel(ch("room", "general", Some(root)))
        .await
        .unwrap();
    store
        .create_channel(ch("room", "genesis", Some(root)))
        .await
        .unwrap();
    store
        .create_channel(ch("board", "genboard", Some(root)))
        .await
        .unwrap();
    // A sibling of `root`, sharing the "gen" substring but *outside* the searched subtree.
    store
        .create_channel(ch("room", "generosity", None))
        .await
        .unwrap();

    let hits = store
        .search(
            root,
            "gen",
            channels(Some(SuperType::Channel), None),
            page(100),
        )
        .await
        .unwrap();
    assert_eq!(
        names(&hits),
        vec!["genboard", "general", "genesis"],
        "every in-subtree name containing `gen`; the outside `generosity` is excluded"
    );

    // Narrow to the `room` type: the `board`-typed `genboard` drops out.
    let rooms_only = store
        .search(
            root,
            "gen",
            channels(Some(SuperType::Channel), Some(vec![TypeId::new("room")])),
            page(100),
        )
        .await
        .unwrap();
    assert_eq!(names(&rooms_only), vec!["general", "genesis"]);
}

#[tokio::test]
async fn item_body_search_uses_the_second_arm_and_scopes() {
    let (_dir, core) = test_core().await;
    let store = core.store();

    let root = store
        .create_channel(ch("room", "root", None))
        .await
        .unwrap();
    let chat = store
        .create_channel(ch("room", "chat", Some(root)))
        .await
        .unwrap();
    store.create_item(msg("hello world", chat)).await.unwrap();
    store.create_item(msg("goodbye now", chat)).await.unwrap();
    store.create_item(msg("hello again", chat)).await.unwrap();
    // An item under a channel outside `root`'s subtree.
    let elsewhere = store
        .create_channel(ch("room", "elsewhere", None))
        .await
        .unwrap();
    store
        .create_item(msg("hello outsider", elsewhere))
        .await
        .unwrap();

    let hits = store
        .search(
            root,
            "hello",
            channels(Some(SuperType::Item), None),
            page(100),
        )
        .await
        .unwrap();
    assert_eq!(
        names(&hits),
        vec!["hello again", "hello world"],
        "both in-subtree bodies match; the outside item is excluded"
    );
}

#[tokio::test]
async fn search_paginates_by_offset_cursor() {
    let (_dir, core) = test_core().await;
    let store = core.store();

    let root = store
        .create_channel(ch("room", "root", None))
        .await
        .unwrap();
    for name in ["match-a", "match-b", "match-c"] {
        store
            .create_channel(ch("room", name, Some(root)))
            .await
            .unwrap();
    }

    // Page size 2 over 3 matches → two pages, then exhausted.
    let mut seen = Vec::new();
    let mut cursor = Cursor(None);
    let mut pages = 0;
    loop {
        let p = store
            .search(
                root,
                "match",
                channels(Some(SuperType::Channel), None),
                Page {
                    cursor: cursor.clone(),
                    limit: 2,
                },
            )
            .await
            .unwrap();
        pages += 1;
        seen.extend(names(&p));
        match p.next.0 {
            Some(_) => cursor = p.next,
            None => break,
        }
    }
    assert_eq!(pages, 2, "3 matches at page size 2 = two pages");
    seen.sort();
    assert_eq!(
        seen,
        vec!["match-a", "match-b", "match-c"],
        "no gaps or dups"
    );
}

#[tokio::test]
async fn short_query_no_match_and_bad_cursor() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let root = store
        .create_channel(ch("room", "root", None))
        .await
        .unwrap();
    store
        .create_channel(ch("room", "general", Some(root)))
        .await
        .unwrap();

    // Under the trigram floor (3 code points) ⇒ empty page, not an FTS error.
    let short = store
        .search(
            root,
            "ge",
            channels(Some(SuperType::Channel), None),
            page(100),
        )
        .await
        .unwrap();
    assert!(short.nodes.is_empty() && short.next.0.is_none());

    // A well-formed query that matches nothing ⇒ empty page.
    let miss = store
        .search(
            root,
            "zzzzz",
            channels(Some(SuperType::Channel), None),
            page(100),
        )
        .await
        .unwrap();
    assert!(miss.nodes.is_empty());

    // A non-numeric cursor is a clean Validation error, not a silent reset.
    let bad = store
        .search(
            root,
            "gen",
            channels(Some(SuperType::Channel), None),
            Page {
                cursor: Cursor(Some("not-a-number".to_owned())),
                limit: 10,
            },
        )
        .await;
    assert!(bad.is_err());
}

#[tokio::test]
async fn update_and_delete_reindex() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let root = store
        .create_channel(ch("room", "root", None))
        .await
        .unwrap();
    let c = store
        .create_channel(ch("room", "alpha", Some(root)))
        .await
        .unwrap();

    let found = |needle: &'static str| {
        let store = store.clone();
        async move {
            store
                .search(
                    root,
                    needle,
                    channels(Some(SuperType::Channel), None),
                    page(100),
                )
                .await
                .unwrap()
                .nodes
                .len()
        }
    };

    assert_eq!(found("alpha").await, 1);

    // Renaming re-projects: the old name stops matching, the new one starts.
    store
        .set_channel_payload(c, json!({ "name": "omega" }))
        .await
        .unwrap();
    assert_eq!(found("alpha").await, 0, "old name purged from the index");
    assert_eq!(found("omega").await, 1, "new name indexed");

    // Deleting purges the index row.
    store.delete_channel(c).await.unwrap();
    assert_eq!(found("omega").await, 0);
}
