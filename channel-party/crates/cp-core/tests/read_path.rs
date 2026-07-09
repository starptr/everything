//! Integration tests for the read/discovery primitives (`StoreCtx`, `TODO.md` #2) against a real
//! tempfile sqlite. Data is seeded through the write path, so these exercise reads and writes together.
//! Uses throwaway test kinds rather than a concrete kind crate (DESIGN §12).

use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use cp_core::{Core, Registry};
use cp_model::{
    Channel, ChannelId, ChannelKind, Cursor, Filter, ItemKind, Json, NewChannel, NewItem, Node,
    NodePage, Order, Page, Result, StoreCtx, SuperType, TypeId, WriteCtx,
};

struct TestChannel(TypeId);

#[async_trait]
impl ChannelKind for TestChannel {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _query: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the read-path test")
    }
}

struct TestItem(TypeId);

impl ItemKind for TestItem {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
}

async fn test_core() -> (tempfile::TempDir, Core) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    // Two channel types (to test type filtering) and one item type.
    let registry = Registry::builder()
        .channel(TestChannel(room()))
        .channel(TestChannel(space()))
        .item(TestItem(msg()))
        .build();
    let core = Core::open(&url, registry).await.unwrap();
    (dir, core)
}

fn room() -> TypeId {
    TypeId::new("room")
}
fn space() -> TypeId {
    TypeId::new("space")
}
fn msg() -> TypeId {
    TypeId::new("msg")
}

fn ch(type_id: TypeId, container: Option<ChannelId>) -> NewChannel {
    NewChannel {
        type_id,
        container,
        payload: serde_json::json!({}),
    }
}
fn item(container: ChannelId) -> NewItem {
    NewItem {
        type_id: msg(),
        container: Some(container),
        external_key: None,
        payload: serde_json::json!({}),
    }
}

fn page(limit: u32) -> Page {
    Page {
        cursor: Cursor(None),
        limit,
    }
}

fn node_id(node: &Node) -> String {
    match node {
        Node::Channel(c) => c.id.to_string(),
        Node::Item(i) => i.id.to_string(),
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// Walk every page of `children` and return the node ids in feed order.
async fn collect_all(
    store: &impl StoreCtx,
    container: ChannelId,
    filter: Filter,
    order: Order,
    limit: u32,
) -> Vec<String> {
    let mut ids = Vec::new();
    let mut cursor = Cursor(None);
    loop {
        let p: NodePage = store
            .children(
                container,
                filter.clone(),
                Page {
                    cursor: cursor.clone(),
                    limit,
                },
                order,
            )
            .await
            .unwrap();
        ids.extend(p.nodes.iter().map(node_id));
        if p.next.0.is_none() {
            break;
        }
        cursor = p.next;
    }
    ids
}

#[tokio::test]
async fn children_are_time_ordered_and_paginate() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let room_id = store.create_channel(ch(room(), None)).await.unwrap();

    // Seed items. Ids are time-ordered ULIDs, but two minted in the same millisecond tie on the time
    // prefix and order by their random bits — so assert on id order, never on insertion order.
    let mut created = Vec::new();
    for _ in 0..5 {
        created.push(store.create_item(item(room_id)).await.unwrap().to_string());
    }

    let items = Filter {
        super_type: Some(SuperType::Item),
        type_ids: None,
    };
    // Page size 2 forces multiple pages over 5 items.
    let desc = collect_all(&*store, room_id, items.clone(), Order::TimeDesc, 2).await;
    assert_eq!(desc.len(), 5, "every item recovered across pages");
    assert!(
        desc.windows(2).all(|w| w[0] > w[1]),
        "strictly descending id order, no dups"
    );
    let mut got = desc.clone();
    got.sort();
    let mut want = created.clone();
    want.sort();
    assert_eq!(got, want, "exactly the created set — no gaps, no dups");

    let asc = collect_all(&*store, room_id, items, Order::TimeAsc, 3).await;
    assert!(asc.windows(2).all(|w| w[0] < w[1]), "strictly ascending");
    let desc_rev: Vec<String> = desc.iter().rev().cloned().collect();
    assert_eq!(asc, desc_rev, "ascending is descending reversed");
}

#[tokio::test]
async fn children_filter_by_super_type_and_type() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let parent = store.create_channel(ch(room(), None)).await.unwrap();

    let sub_room = store
        .create_channel(ch(room(), Some(parent)))
        .await
        .unwrap();
    let sub_space = store
        .create_channel(ch(space(), Some(parent)))
        .await
        .unwrap();
    store.create_item(item(parent)).await.unwrap();
    store.create_item(item(parent)).await.unwrap();

    let all = store
        .children(parent, Filter::default(), page(100), Order::TimeAsc)
        .await
        .unwrap();
    assert_eq!(all.nodes.len(), 4, "2 sub-channels + 2 items, mixed freely");

    let channels = store
        .children(
            parent,
            Filter {
                super_type: Some(SuperType::Channel),
                type_ids: None,
            },
            page(100),
            Order::TimeAsc,
        )
        .await
        .unwrap();
    assert_eq!(channels.nodes.len(), 2);
    assert!(channels.nodes.iter().all(|n| matches!(n, Node::Channel(_))));
    let channel_ids: Vec<String> = channels.nodes.iter().map(node_id).collect();
    assert!(channel_ids.contains(&sub_room.to_string()));
    assert!(channel_ids.contains(&sub_space.to_string()));

    let items = store
        .children(
            parent,
            Filter {
                super_type: Some(SuperType::Item),
                type_ids: None,
            },
            page(100),
            Order::TimeAsc,
        )
        .await
        .unwrap();
    assert_eq!(items.nodes.len(), 2);
    assert!(items.nodes.iter().all(|n| matches!(n, Node::Item(_))));

    let spaces = store
        .children(
            parent,
            Filter {
                super_type: Some(SuperType::Channel),
                type_ids: Some(vec![space()]),
            },
            page(100),
            Order::TimeAsc,
        )
        .await
        .unwrap();
    assert_eq!(spaces.nodes.len(), 1, "narrowed to the one `space` channel");
    assert_eq!(node_id(&spaces.nodes[0]), sub_space.to_string());
}

#[tokio::test]
async fn descendants_span_the_subtree_and_respect_depth() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let root = store.create_channel(ch(room(), None)).await.unwrap();
    let child = store.create_channel(ch(room(), Some(root))).await.unwrap();
    let grand = store.create_channel(ch(room(), Some(child))).await.unwrap();
    store.create_item(item(root)).await.unwrap();
    store.create_item(item(child)).await.unwrap();
    store.create_item(item(grand)).await.unwrap();

    let all = store
        .descendants(root, Filter::default(), None)
        .await
        .unwrap();
    assert_eq!(
        all.len(),
        5,
        "2 descendant channels + 3 items (root excluded, its items included)"
    );

    let channels = store
        .descendants(
            root,
            Filter {
                super_type: Some(SuperType::Channel),
                type_ids: None,
            },
            None,
        )
        .await
        .unwrap();
    assert_eq!(channels.len(), 2);
    let ids: Vec<String> = channels.iter().map(node_id).collect();
    assert!(ids.contains(&child.to_string()) && ids.contains(&grand.to_string()));
    assert!(
        !ids.contains(&root.to_string()),
        "root is not its own descendant"
    );

    let depth1 = store
        .descendants(root, Filter::default(), Some(1))
        .await
        .unwrap();
    assert_eq!(
        depth1.len(),
        2,
        "one hop: the direct child channel + root's direct item"
    );
    let d1: Vec<String> = depth1.iter().map(node_id).collect();
    assert!(d1.contains(&child.to_string()));
    assert!(
        !d1.contains(&grand.to_string()),
        "grandchild is two hops down"
    );

    let none = store
        .descendants(root, Filter::default(), Some(0))
        .await
        .unwrap();
    assert!(none.is_empty(), "depth 0 = nothing below root");
}

#[tokio::test]
async fn seek_time_bounds_the_feed_by_timestamp() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let room_id = store.create_channel(ch(room(), None)).await.unwrap();

    let before = now_ms();
    for _ in 0..3 {
        store.create_item(item(room_id)).await.unwrap();
    }

    let items = Filter {
        super_type: Some(SuperType::Item),
        type_ids: None,
    };
    // A boundary at the pre-seed timestamp includes everything created since.
    let cur = store.seek_time(room_id, before).await.unwrap();
    let since = store
        .children(
            room_id,
            items.clone(),
            Page {
                cursor: cur,
                limit: 100,
            },
            Order::TimeAsc,
        )
        .await
        .unwrap();
    assert_eq!(
        since.nodes.len(),
        3,
        "all three items are at/after `before`"
    );

    // A boundary far in the future is past every id, so the forward feed is empty.
    let future = store.seek_time(room_id, now_ms() + 60_000).await.unwrap();
    let none = store
        .children(
            room_id,
            items,
            Page {
                cursor: future,
                limit: 100,
            },
            Order::TimeAsc,
        )
        .await
        .unwrap();
    assert!(
        none.nodes.is_empty(),
        "nothing was created after a future timestamp"
    );
}
