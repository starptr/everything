//! Authorization dispatch (`TODO.md` #18, `design/permissions.md`) against a real tempfile sqlite.
//! Throwaway kinds (DESIGN §12) exercise core's genericity: deny-by-default for a kind with no
//! `Permission`, an "allow" policy, and a membership-riding policy over the `channel_members` substrate.

use async_trait::async_trait;
use cp_core::{auth, authz, Core, Registry};
use cp_model::{
    Action, Channel, ChannelKind, Json, NewChannel, Permission, Result, StoreCtx, TypeId, UserId,
    WriteCtx,
};

/// Grants `Post` to anyone; denies everything else.
struct OpenChannel(TypeId);
#[async_trait]
impl ChannelKind for OpenChannel {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    async fn contents(&self, _: &dyn StoreCtx, _: &Channel, _: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the authz test")
    }
    fn permission(&self) -> Option<&dyn Permission> {
        Some(self)
    }
}
#[async_trait]
impl Permission for OpenChannel {
    async fn authorize(
        &self,
        _: &dyn StoreCtx,
        _: &Channel,
        _: UserId,
        action: Action,
    ) -> Result<bool> {
        Ok(action == Action::Post)
    }
}

/// Grants `Post` only to members of the channel — rides the generic `channel_members` substrate.
struct MembersChannel(TypeId);
#[async_trait]
impl ChannelKind for MembersChannel {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    async fn contents(&self, _: &dyn StoreCtx, _: &Channel, _: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the authz test")
    }
    fn permission(&self) -> Option<&dyn Permission> {
        Some(self)
    }
}
#[async_trait]
impl Permission for MembersChannel {
    async fn authorize(
        &self,
        cx: &dyn StoreCtx,
        ch: &Channel,
        user: UserId,
        action: Action,
    ) -> Result<bool> {
        match action {
            Action::Post => cx.is_member(ch.id, user).await,
            _ => Ok(false),
        }
    }
}

/// Declares no `Permission` — the deny-by-default case.
struct ClosedChannel(TypeId);
#[async_trait]
impl ChannelKind for ClosedChannel {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    async fn contents(&self, _: &dyn StoreCtx, _: &Channel, _: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the authz test")
    }
}

async fn test_core() -> (tempfile::TempDir, Core) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(OpenChannel(TypeId::new("open")))
        .channel(MembersChannel(TypeId::new("members")))
        .channel(ClosedChannel(TypeId::new("closed")))
        .build();
    let core = Core::open(&url, registry).await.unwrap();
    (dir, core)
}

async fn channel_of(core: &Core, type_id: &str) -> Channel {
    let store = core.store();
    let cid = store
        .create_channel(NewChannel {
            type_id: TypeId::new(type_id),
            container: None,
            payload: serde_json::json!({}),
        })
        .await
        .unwrap();
    store.get_channel(cid).await.unwrap().unwrap()
}

#[tokio::test]
async fn deny_by_default_and_allow() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let user = auth::provision_user(store.pool(), "alice").await.unwrap();

    // A kind with no Permission capability authorizes no one (deny-by-default).
    let closed = channel_of(&core, "closed").await;
    assert!(
        !authz::authorize(core.registry(), &*store, &closed, user, Action::Post)
            .await
            .unwrap()
    );

    // An "allow" policy grants the action it declares, and nothing else.
    let open = channel_of(&core, "open").await;
    assert!(
        authz::authorize(core.registry(), &*store, &open, user, Action::Post)
            .await
            .unwrap()
    );
    assert!(
        !authz::authorize(core.registry(), &*store, &open, user, Action::Manage)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn membership_gates_post() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let user = auth::provision_user(store.pool(), "bob").await.unwrap();
    let ch = channel_of(&core, "members").await;

    // Not a member yet → denied.
    assert!(
        !authz::authorize(core.registry(), &*store, &ch, user, Action::Post)
            .await
            .unwrap()
    );

    // After joining → allowed.
    store.add_member(ch.id, user).await.unwrap();
    assert!(
        authz::authorize(core.registry(), &*store, &ch, user, Action::Post)
            .await
            .unwrap()
    );

    // The grant is scoped to `Post`, not other actions.
    assert!(
        !authz::authorize(core.registry(), &*store, &ch, user, Action::View)
            .await
            .unwrap()
    );
}
