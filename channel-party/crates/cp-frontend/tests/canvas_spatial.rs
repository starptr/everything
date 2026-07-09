//! End-to-end slice for `canvas` (`TODO.md` #4 + #11): the reference escape-hatch kind. A real axum
//! request → `contents` → a viewport bbox query over the kind's *own* R-tree, which its `SpatialIndex`
//! `RuntimeComponent` maintains off the change stream. Proves the §6 type-owned-table escape hatch and
//! the §7 supervisor together: core knows nothing of `canvas_*`, yet backfill + live streaming + viewport
//! filtering + move/delete all work over HTTP. Boxes are seeded through the write path; the runtime is
//! actually spawned (in the test's tokio runtime), so the tests poll for its async convergence.

use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::http::Request;
use axum::response::Response;
use axum::Router;
use cp_core::{Core, Registry};
use cp_frontend::{router, AppState};
use cp_model::{ChannelId, ItemId, NewChannel, NewItem, TypeId, WriteCtx};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

async fn json_body(res: Response) -> Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// POST a viewport query to a canvas's `contents` and return the box nodes.
async fn view(app: &Router, canvas: ChannelId, viewport: Value) -> Vec<Value> {
    let req = Request::builder()
        .method("POST")
        .uri(format!("/api/channels/{canvas}/contents"))
        .header("content-type", "application/json")
        .body(Body::from(viewport.to_string()))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    json_body(res).await["nodes"].as_array().cloned().unwrap()
}

/// Poll a full-plane query until `pred` holds over the returned boxes (the R-tree is maintained
/// asynchronously by the `SpatialIndex`, so writes converge after a short delay).
async fn wait_for(app: &Router, canvas: ChannelId, pred: impl Fn(&[Value]) -> bool) -> Vec<Value> {
    for _ in 0..150 {
        let boxes = view(app, canvas, json!({})).await;
        if pred(&boxes) {
            return boxes;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!(
        "timed out; boxes = {:?}",
        view(app, canvas, json!({})).await
    );
}

fn box_x(node: &Value) -> f64 {
    node["payload"]["x"].as_f64().unwrap()
}

async fn add_box(
    store: &Arc<cp_core::Store>,
    canvas: ChannelId,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) -> ItemId {
    store
        .create_item(NewItem {
            type_id: TypeId::new("canvas-text-box"),
            container: Some(canvas),
            external_key: None,
            payload: json!({ "x": x, "y": y, "w": w, "h": h, "text": "box" }),
        })
        .await
        .unwrap()
}

/// A canvas, its wired app, the spawned runtime handle, and the shared store.
struct Fixture {
    _dir: tempfile::TempDir,
    app: Router,
    handle: cp_core::runtime::RuntimeHandle,
    store: Arc<cp_core::Store>,
    canvas: ChannelId,
}

async fn setup() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(cp_canvas::channel())
        .item(cp_canvas::text_box())
        .runtime(cp_canvas::spatial_index())
        .migrations(cp_canvas::MIGRATIONS)
        .build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());
    let store = core.store();
    let canvas = store
        .create_channel(NewChannel {
            type_id: TypeId::new("canvas"),
            container: None,
            payload: json!({ "name": "board" }),
        })
        .await
        .unwrap();
    let handle = core.spawn_runtime();
    let app = router(AppState {
        core,
        registry,
        web_dir: dir.path().to_path_buf(),
    });
    Fixture {
        _dir: dir,
        app,
        handle,
        store,
        canvas,
    }
}

#[tokio::test]
async fn backfill_stream_and_viewport_filtering() {
    // One box exists BEFORE the runtime starts → arrives via backfill; the rest are streamed.
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(cp_canvas::channel())
        .item(cp_canvas::text_box())
        .runtime(cp_canvas::spatial_index())
        .migrations(cp_canvas::MIGRATIONS)
        .build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());
    let store = core.store();
    let canvas = store
        .create_channel(NewChannel {
            type_id: TypeId::new("canvas"),
            container: None,
            payload: json!({ "name": "board" }),
        })
        .await
        .unwrap();
    let near = add_box(&store, canvas, 10.0, 10.0, 5.0, 5.0).await; // covers [10,15]²

    let handle = core.spawn_runtime();
    let app = router(AppState {
        core,
        registry,
        web_dir: dir.path().to_path_buf(),
    });

    // Backfill picks up the pre-existing box.
    wait_for(&app, canvas, |b| b.len() == 1).await;

    // Streamed boxes: one nearby, one far away.
    let far = add_box(&store, canvas, 1000.0, 1000.0, 10.0, 10.0).await;
    add_box(&store, canvas, 100.0, 100.0, 10.0, 10.0).await; // covers [100,110]²
    wait_for(&app, canvas, |b| b.len() == 3).await;

    // Viewport [0,0]-[50,50] sees only the near box (100² and 1000² boxes don't overlap it).
    let small = view(
        &app,
        canvas,
        json!({ "x0": 0, "y0": 0, "x1": 50, "y1": 50 }),
    )
    .await;
    assert_eq!(
        small.len(),
        1,
        "only the box at (10,10) overlaps: {small:?}"
    );
    assert_eq!(small[0]["id"], near.to_string());
    assert!((box_x(&small[0]) - 10.0).abs() < 0.01);
    assert!(small.iter().all(|n| n["super_type"] == "item"));

    // A viewport around (100,100) sees only that box, not the far one.
    let mid = view(
        &app,
        canvas,
        json!({ "x0": 90, "y0": 90, "x1": 120, "y1": 120 }),
    )
    .await;
    assert_eq!(mid.len(), 1, "only the (100,100) box: {mid:?}");
    assert!(!mid.iter().any(|n| n["id"] == far.to_string()));

    handle.shutdown().await;
}

#[tokio::test]
async fn reflects_move_and_delete() {
    let fx = setup().await;
    let a = add_box(&fx.store, fx.canvas, 10.0, 10.0, 5.0, 5.0).await;
    let b = add_box(&fx.store, fx.canvas, 20.0, 20.0, 5.0, 5.0).await;
    wait_for(&fx.app, fx.canvas, |boxes| boxes.len() == 2).await;

    // Move `a` far away: it leaves the [0,50] viewport and reappears at its new spot.
    fx.store
        .set_item_payload(
            a,
            json!({ "x": 900.0, "y": 900.0, "w": 5.0, "h": 5.0, "text": "moved" }),
        )
        .await
        .unwrap();
    wait_for(&fx.app, fx.canvas, |boxes| {
        boxes
            .iter()
            .any(|n| n["id"] == a.to_string() && box_x(n) > 800.0)
    })
    .await;
    let near = view(
        &fx.app,
        fx.canvas,
        json!({ "x0": 0, "y0": 0, "x1": 50, "y1": 50 }),
    )
    .await;
    assert!(
        near.iter().all(|n| n["id"] != a.to_string()),
        "moved box left the near viewport: {near:?}"
    );

    // Delete `b`: it disappears from the index.
    fx.store.delete_item(b).await.unwrap();
    wait_for(&fx.app, fx.canvas, |boxes| {
        boxes.iter().all(|n| n["id"] != b.to_string())
    })
    .await;

    fx.handle.shutdown().await;
}
