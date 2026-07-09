//! End-to-end vertical slice (`TODO.md` #8 + #12): a real axum request → generic handler → `contents`
//! dispatch → `basic`'s `StoreCtx` composition → JSON. Data is seeded through the write path against a
//! tempfile sqlite; requests hit the actual `Router` via `oneshot` (no socket). This is the first test
//! that wires a concrete kind, core, and the HTTP layer together — the proof the seams compose.

use std::collections::HashSet;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::response::Response;
use axum::Router;
use cp_core::{Core, Registry};
use cp_frontend::{router, AppState};
use cp_model::{ChannelId, NewChannel, NewItem, TypeId, WriteCtx};
use http_body_util::BodyExt;
use tower::ServiceExt;

async fn json_body(res: Response) -> serde_json::Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn get(uri: String) -> Request<Body> {
    Request::builder().uri(uri).body(Body::empty()).unwrap()
}

fn post_json(uri: String, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

/// Seed a `basic` channel with three message items and return the wired app + the seeded ids.
async fn seeded() -> (tempfile::TempDir, Router, ChannelId, Vec<cp_model::ItemId>) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(cp_basic::channel())
        .item(cp_basic::item())
        .build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());

    let store = core.store();
    let cid = store
        .create_channel(NewChannel {
            type_id: TypeId::new("basic"),
            container: None,
            payload: serde_json::json!({ "name": "general" }),
        })
        .await
        .unwrap();
    let mut items = Vec::new();
    for body in ["first", "second", "third"] {
        items.push(
            store
                .create_item(NewItem {
                    type_id: TypeId::new("basic"),
                    container: Some(cid),
                    external_key: None,
                    payload: serde_json::json!({ "body": body }),
                })
                .await
                .unwrap(),
        );
    }

    let app = router(AppState {
        core,
        registry,
        web_dir: dir.path().to_path_buf(),
    });
    (dir, app, cid, items)
}

#[tokio::test]
async fn get_channel_returns_the_envelope() {
    let (_dir, app, cid, _items) = seeded().await;
    let res = app
        .oneshot(get(format!("/api/channels/{cid}")))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = json_body(res).await;
    assert_eq!(body["id"], cid.to_string());
    assert_eq!(
        body["type_id"], "basic",
        "the shell mounts the island off this"
    );
    assert_eq!(body["payload"]["name"], "general");
}

#[tokio::test]
async fn channel_contents_paginate_newest_first() {
    let (_dir, app, cid, _items) = seeded().await;

    // Page 1 (limit 2): a NodePage of items with a continuation cursor.
    let res = app
        .clone()
        .oneshot(post_json(
            format!("/api/channels/{cid}/contents"),
            serde_json::json!({ "limit": 2 }),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let p1 = json_body(res).await;
    let p1_nodes = p1["nodes"].as_array().unwrap();
    assert_eq!(p1_nodes.len(), 2, "limit honored");
    assert!(p1_nodes.iter().all(|n| n["super_type"] == "item"));
    assert!(p1["next"].is_string(), "a further page exists");

    // Page 2 via the cursor: the remaining item, then end-of-feed.
    let res = app
        .oneshot(post_json(
            format!("/api/channels/{cid}/contents"),
            serde_json::json!({ "cursor": p1["next"], "limit": 2 }),
        ))
        .await
        .unwrap();
    let p2 = json_body(res).await;
    let p2_nodes = p2["nodes"].as_array().unwrap();
    assert_eq!(p2_nodes.len(), 1, "one item left");
    assert!(p2["next"].is_null(), "end of feed");

    // The two pages together are exactly the three seeded items, in strictly descending id order
    // (TimeDesc). Assert on id order, not insertion order: same-ms ULIDs tie on the time prefix.
    let all: Vec<&serde_json::Value> = p1_nodes.iter().chain(p2_nodes).collect();
    let bodies: HashSet<&str> = all
        .iter()
        .map(|n| n["payload"]["body"].as_str().unwrap())
        .collect();
    assert_eq!(bodies, HashSet::from(["first", "second", "third"]));
    let ids: Vec<&str> = all.iter().map(|n| n["id"].as_str().unwrap()).collect();
    assert!(
        ids.windows(2).all(|w| w[0] > w[1]),
        "strictly descending id across pages"
    );
}

#[tokio::test]
async fn contents_at_timestamp_seeks_the_feed() {
    let (_dir, app, cid, _items) = seeded().await;
    // `basic` reads newest-first (TimeDesc), so `query.at` selects items *at/before* T (scroll back to
    // a date). Two bracketing timestamps prove seek_time is wired through the handler, in the right
    // direction: nothing exists before the epoch; everything exists before the far future.
    let count_before = |at: u64| {
        let app = app.clone();
        async move {
            let res = app
                .oneshot(post_json(
                    format!("/api/channels/{cid}/contents"),
                    serde_json::json!({ "at": at }),
                ))
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            json_body(res).await["nodes"].as_array().unwrap().len()
        }
    };
    assert_eq!(count_before(0).await, 0, "no items before the epoch");
    assert_eq!(
        count_before(32_503_680_000_000).await, // ~year 3000
        3,
        "all items are before the far future"
    );
}

#[tokio::test]
async fn get_item_returns_the_envelope() {
    let (_dir, app, _cid, items) = seeded().await;
    let iid = items[0];
    let res = app.oneshot(get(format!("/api/items/{iid}"))).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(json_body(res).await["payload"]["body"], "first");
}

#[tokio::test]
async fn absent_and_malformed_ids_are_clean_errors() {
    let (_dir, app, _cid, _items) = seeded().await;

    // A well-formed but absent id → 404 (not 501, not a panic).
    let res = app
        .clone()
        .oneshot(get(format!("/api/channels/{}", ChannelId::generate())))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);

    // A garbage id → 400.
    let res = app
        .oneshot(get("/api/items/not-a-ulid".to_owned()))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}
