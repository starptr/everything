//! Integration tests for native-user auth + sessions (`TODO.md` #17): password provisioning +
//! verification and the session lifecycle, against a real tempfile sqlite.

use cp_core::{auth, Core, Registry};

async fn core() -> (tempfile::TempDir, Core) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let core = Core::open(&url, Registry::builder().build()).await.unwrap();
    (dir, core)
}

#[tokio::test]
async fn provision_set_password_and_authenticate() {
    let (_dir, core) = core().await;
    let store = core.store();
    let pool = store.pool();

    let uid = auth::provision_user(pool, "alice").await.unwrap();

    // Provisioned but no password yet ⇒ inert (can't authenticate).
    assert!(auth::authenticate(pool, "alice", "hunter2")
        .await
        .unwrap()
        .is_none());

    auth::set_password(pool, "alice", "hunter2").await.unwrap();
    let user = auth::authenticate(pool, "alice", "hunter2").await.unwrap();
    assert_eq!(user.expect("correct password authenticates").id, uid);

    // Wrong password / unknown handle ⇒ no user.
    assert!(auth::authenticate(pool, "alice", "wrong")
        .await
        .unwrap()
        .is_none());
    assert!(auth::authenticate(pool, "nobody", "hunter2")
        .await
        .unwrap()
        .is_none());

    // set-password on an unknown handle is NotFound (no silent create).
    assert!(auth::set_password(pool, "nobody", "x").await.is_err());
}

#[tokio::test]
async fn sessions_resolve_and_revoke() {
    let (_dir, core) = core().await;
    let store = core.store();
    let pool = store.pool();

    let uid = auth::provision_user(pool, "bob").await.unwrap();
    auth::set_password(pool, "bob", "pw").await.unwrap();

    let token = auth::create_session(pool, uid).await.unwrap();
    assert_eq!(
        auth::resolve_session(pool, &token)
            .await
            .unwrap()
            .expect("live session resolves")
            .handle,
        "bob"
    );

    // A bogus token resolves to nothing.
    assert!(auth::resolve_session(pool, "deadbeef")
        .await
        .unwrap()
        .is_none());

    // After logout the token is dead.
    auth::delete_session(pool, &token).await.unwrap();
    assert!(auth::resolve_session(pool, &token).await.unwrap().is_none());
}
