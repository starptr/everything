//! SSE live-update slice (`TODO.md` #13): subscribe to `GET /api/events?scope=…`, then a committed
//! write on the same core must surface as a `change` event on the stream. Drives the real Router +
//! broadcast bus, bounded by timeouts so a wiring regression fails fast instead of hanging.

use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::http::header::CONTENT_TYPE;
use axum::http::{Request, StatusCode};
use cp_core::{Core, Registry};
use cp_frontend::{router, AppState};
use cp_model::{NewChannel, NewItem, TypeId, WriteCtx};
use tokio::time::timeout;
use tokio_stream::StreamExt;
use tower::ServiceExt;

#[tokio::test]
async fn write_surfaces_as_scoped_sse_change_event() {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(cp_basic::channel())
        .item(cp_basic::item())
        .build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());
    let cid = core
        .store()
        .create_channel(NewChannel {
            type_id: TypeId::new("basic"),
            container: None,
            payload: serde_json::json!({}),
        })
        .await
        .unwrap();

    let app = router(AppState {
        core: core.clone(),
        registry,
        web_dir: dir.path().to_path_buf(),
    });

    // Open the stream scoped to the channel. The handler subscribes to the bus before returning, so a
    // write issued after this await is guaranteed to be buffered for us.
    let res = timeout(
        Duration::from_secs(5),
        app.oneshot(
            Request::builder()
                .uri(format!("/api/events?scope={cid}"))
                .body(Body::empty())
                .unwrap(),
        ),
    )
    .await
    .expect("handler responded")
    .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res.headers().get(CONTENT_TYPE).unwrap().to_str().unwrap();
    assert!(ct.starts_with("text/event-stream"), "got content-type {ct}");

    // Commit a write on the same core -> emits a ChangeEvent whose container is this channel.
    let iid = core
        .store()
        .create_item(NewItem {
            type_id: TypeId::new("basic"),
            container: Some(cid),
            external_key: None,
            payload: serde_json::json!({ "body": "hello" }),
        })
        .await
        .unwrap();

    // Read frames until the change event for our item arrives (its id appears only in that frame).
    let mut stream = res.into_body().into_data_stream();
    let mut buf = String::new();
    let found = timeout(Duration::from_secs(5), async {
        while let Some(chunk) = stream.next().await {
            buf.push_str(&String::from_utf8_lossy(&chunk.unwrap()));
            if buf.contains(&iid.to_string()) {
                return true;
            }
        }
        false
    })
    .await
    .expect("event arrived before timeout");

    assert!(found, "the committed item surfaced on the SSE stream");
    assert!(buf.contains("\"op\":\"created\""), "frame: {buf}");
    assert!(buf.contains("\"super_type\":\"item\""), "frame: {buf}");
}

#[tokio::test]
async fn scope_filters_out_other_channels() {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(cp_basic::channel())
        .item(cp_basic::item())
        .build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());
    let watched = core
        .store()
        .create_channel(NewChannel {
            type_id: TypeId::new("basic"),
            container: None,
            payload: serde_json::json!({}),
        })
        .await
        .unwrap();
    let other = core
        .store()
        .create_channel(NewChannel {
            type_id: TypeId::new("basic"),
            container: None,
            payload: serde_json::json!({}),
        })
        .await
        .unwrap();

    let app = router(AppState {
        core: core.clone(),
        registry,
        web_dir: dir.path().to_path_buf(),
    });
    let res = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/events?scope={watched}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // A write into a *different* channel, then one into the watched channel. The first must not appear;
    // seeing the second's id first proves the earlier out-of-scope event was filtered, not merely late.
    let noise = core
        .store()
        .create_item(NewItem {
            type_id: TypeId::new("basic"),
            container: Some(other),
            external_key: None,
            payload: serde_json::json!({}),
        })
        .await
        .unwrap();
    let wanted = core
        .store()
        .create_item(NewItem {
            type_id: TypeId::new("basic"),
            container: Some(watched),
            external_key: None,
            payload: serde_json::json!({}),
        })
        .await
        .unwrap();

    let mut stream = res.into_body().into_data_stream();
    let mut buf = String::new();
    timeout(Duration::from_secs(5), async {
        while let Some(chunk) = stream.next().await {
            buf.push_str(&String::from_utf8_lossy(&chunk.unwrap()));
            if buf.contains(&wanted.to_string()) {
                return;
            }
        }
    })
    .await
    .expect("scoped event arrived");
    assert!(
        !buf.contains(&noise.to_string()),
        "out-of-scope channel's event leaked through: {buf}"
    );
}
