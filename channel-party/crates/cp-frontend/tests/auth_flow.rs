//! End-to-end auth flow (`TODO.md` #17): login → me → logout over the real router via `oneshot`,
//! propagating the session cookie. A user is provisioned with a password up front (the shell path,
//! called directly), since there is no registration endpoint.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::response::Response;
use axum::Router;
use cp_core::{auth, Core, Registry};
use cp_frontend::{router, AppState};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

async fn json_body(res: Response) -> Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

async fn app() -> (tempfile::TempDir, Router) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder().build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());

    // Provision alice with a password (accounts are shell-provisioned; here we call the same store API).
    let store = core.store();
    auth::provision_user(store.pool(), "alice").await.unwrap();
    auth::set_password(store.pool(), "alice", "hunter2")
        .await
        .unwrap();

    let app = router(AppState {
        core,
        registry,
        web_dir: dir.path().to_path_buf(),
    });
    (dir, app)
}

fn login_req(handle: &str, password: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/api/auth/login")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({ "handle": handle, "password": password }).to_string(),
        ))
        .unwrap()
}

fn me_req(cookie: Option<&str>) -> Request<Body> {
    let mut b = Request::builder().method("GET").uri("/api/auth/me");
    if let Some(c) = cookie {
        b = b.header(header::COOKIE, c);
    }
    b.body(Body::empty()).unwrap()
}

fn logout_req(cookie: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/api/auth/logout")
        .header(header::COOKIE, cookie)
        .body(Body::empty())
        .unwrap()
}

/// The `cp_session=<token>` pair from a `Set-Cookie` header (dropping the attributes).
fn session_cookie(res: &Response) -> String {
    res.headers()
        .get(header::SET_COOKIE)
        .expect("login sets a cookie")
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn login_me_logout_flow() {
    let (_dir, app) = app().await;

    // Wrong password → 401, no cookie.
    let res = app
        .clone()
        .oneshot(login_req("alice", "wrong"))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
    assert!(res.headers().get(header::SET_COOKIE).is_none());

    // Correct → 200 + Set-Cookie + the user.
    let res = app
        .clone()
        .oneshot(login_req("alice", "hunter2"))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let cookie = session_cookie(&res);
    assert!(cookie.starts_with("cp_session="));
    assert_eq!(json_body(res).await["handle"], "alice");

    // /me without the cookie → 401.
    let res = app.clone().oneshot(me_req(None)).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // /me with the cookie → 200 alice.
    let res = app.clone().oneshot(me_req(Some(&cookie))).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(json_body(res).await["handle"], "alice");

    // Logout → 204.
    let res = app.clone().oneshot(logout_req(&cookie)).await.unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // The now-revoked cookie no longer authenticates.
    let res = app.oneshot(me_req(Some(&cookie))).await.unwrap();
    assert_eq!(
        res.status(),
        StatusCode::UNAUTHORIZED,
        "session was revoked on logout"
    );
}
