//! End-to-end slice for `space` (`TODO.md` #3/#9): a real axum request → `contents` dispatch →
//! `space`'s `search` composition → FTS → JSON. A `space` holds `basic` channels; the search finds them
//! by name *without `space` knowing the `basic` type* — the vertical-slice + genericity proof (DESIGN
//! §5/§12). Data is seeded through the write path against a tempfile sqlite; requests hit the `Router`
//! via `oneshot`.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::response::Response;
use axum::Router;
use cp_core::{Core, Registry};
use cp_frontend::{router, AppState};
use cp_model::{ChannelId, NewChannel, TypeId, WriteCtx};
use http_body_util::BodyExt;
use tower::ServiceExt;

async fn json_body(res: Response) -> serde_json::Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn search(space: ChannelId, query: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/api/channels/{space}/contents"))
        .header("content-type", "application/json")
        .body(Body::from(query.to_string()))
        .unwrap()
}

/// A `space` containing five named `basic` rooms, plus a same-named room *outside* it. Returns the app
/// and the space id.
async fn seeded() -> (tempfile::TempDir, Router, ChannelId) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(cp_space::channel())
        .channel(cp_basic::channel())
        .build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());

    let store = core.store();
    let mk = |name: &'static str, container: Option<ChannelId>| {
        let store = store.clone();
        async move {
            store
                .create_channel(NewChannel {
                    type_id: TypeId::new("basic"),
                    container,
                    payload: serde_json::json!({ "name": name }),
                })
                .await
                .unwrap()
        }
    };

    let space = store
        .create_channel(NewChannel {
            type_id: TypeId::new("space"),
            container: None,
            payload: serde_json::json!({ "name": "server" }),
        })
        .await
        .unwrap();
    for name in ["general", "genesis", "random", "gardening"] {
        mk(name, Some(space)).await;
    }
    // Outside the space: shares the "gen" substring but must not be found.
    mk("generosity", None).await;

    let app = router(AppState {
        core,
        registry,
        web_dir: dir.path().to_path_buf(),
    });
    (dir, app, space)
}

fn names(page: &serde_json::Value) -> Vec<String> {
    let mut v: Vec<String> = page["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["payload"]["name"].as_str().unwrap().to_owned())
        .collect();
    v.sort();
    v
}

#[tokio::test]
async fn space_search_finds_descendant_channels_by_name() {
    let (_dir, app, space) = seeded().await;
    let res = app
        .oneshot(search(space, serde_json::json!({ "q": "gen" })))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let page = json_body(res).await;
    assert_eq!(
        names(&page),
        vec!["general", "genesis"],
        "in-space `gen` channels; `gardening`/`random` don't contain it, `generosity` is outside"
    );
    assert!(
        page["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .all(|n| n["super_type"] == "channel"),
        "results are channel references the island mounts"
    );
}

#[tokio::test]
async fn space_search_paginates_and_empty_query_is_empty() {
    let (_dir, app, space) = seeded().await;

    // Empty query → empty page (the <3-char guard), not an error: a freshly opened search box.
    let res = app
        .clone()
        .oneshot(search(space, serde_json::json!({ "q": "" })))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert!(json_body(res).await["nodes"].as_array().unwrap().is_empty());

    // "gen" matches two rooms; page size 1 walks them across two pages via the offset cursor.
    let p1 = json_body(
        app.clone()
            .oneshot(search(space, serde_json::json!({ "q": "gen", "limit": 1 })))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(p1["nodes"].as_array().unwrap().len(), 1);
    assert!(p1["next"].is_string(), "a further page exists");

    let p2 = json_body(
        app.oneshot(search(
            space,
            serde_json::json!({ "q": "gen", "limit": 1, "cursor": p1["next"] }),
        ))
        .await
        .unwrap(),
    )
    .await;
    assert_eq!(p2["nodes"].as_array().unwrap().len(), 1);
    assert!(p2["next"].is_null(), "two matches exhausted");

    let mut both = vec![
        p1["nodes"][0]["payload"]["name"].as_str().unwrap(),
        p2["nodes"][0]["payload"]["name"].as_str().unwrap(),
    ];
    both.sort();
    assert_eq!(
        both,
        vec!["general", "genesis"],
        "no gaps or dups across pages"
    );
}
