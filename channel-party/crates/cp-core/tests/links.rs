//! The `linked-users` edge + authorship resolution (`TODO.md` #19, `design/linked-users.md`) against a
//! real tempfile sqlite. Throwaway kinds (DESIGN §12) prove core links a user to *any* item, not a
//! hardcoded "cached-user" type: link both directions, idempotency, the one-user-per-item conflict, the
//! missing-item error, unlink, and FK cascade on item delete.

use async_trait::async_trait;
use cp_core::{auth, links, Core, Registry};
use cp_model::{
    Channel, ChannelKind, Error, ItemKind, Json, NewChannel, NewItem, Result, StoreCtx, TypeId,
    WriteCtx,
};

struct TestChannel(TypeId);
#[async_trait]
impl ChannelKind for TestChannel {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    async fn contents(&self, _: &dyn StoreCtx, _: &Channel, _: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the links test")
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
    let registry = Registry::builder()
        .channel(TestChannel(TypeId::new("test")))
        .item(TestItem(TypeId::new("test")))
        .build();
    let core = Core::open(&url, registry).await.unwrap();
    (dir, core)
}

/// Create a root channel and an item inside it; return the item id (stands in for a `cached-user`).
async fn an_item(core: &Core) -> cp_model::ItemId {
    let store = core.store();
    let cid = store
        .create_channel(NewChannel {
            type_id: TypeId::new("test"),
            container: None,
            payload: serde_json::json!({}),
        })
        .await
        .unwrap();
    store
        .create_item(NewItem {
            type_id: TypeId::new("test"),
            container: Some(cid),
            external_key: None,
            payload: serde_json::json!({ "external": "discord:user:42" }),
        })
        .await
        .unwrap()
}

#[tokio::test]
async fn link_resolves_both_directions_and_is_idempotent() {
    let (_dir, core) = test_core().await;
    let pool = core.pool();
    let alice = auth::provision_user(pool, "alice").await.unwrap();
    let item = an_item(&core).await;

    links::link(pool, alice, item).await.unwrap();
    links::link(pool, alice, item).await.unwrap(); // idempotent for the same user

    // Forward: alice's linked items include it (exactly once).
    let items = links::linked_items(pool, alice).await.unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, item);

    // Reverse: the item resolves up to alice (authorship resolution).
    let resolved = links::user_for_item(pool, item).await.unwrap().unwrap();
    assert_eq!(resolved.id, alice);
    assert_eq!(resolved.handle, "alice");
}

#[tokio::test]
async fn one_native_user_per_item_and_missing_item() {
    let (_dir, core) = test_core().await;
    let pool = core.pool();
    let alice = auth::provision_user(pool, "alice").await.unwrap();
    let bob = auth::provision_user(pool, "bob").await.unwrap();
    let item = an_item(&core).await;

    links::link(pool, alice, item).await.unwrap();

    // A second user claiming the same external item is a conflict, not a silent second row.
    let conflict = links::link(pool, bob, item).await;
    assert!(matches!(conflict, Err(Error::Validation(_))));
    assert_eq!(links::linked_items(pool, bob).await.unwrap().len(), 0);

    // Linking a nonexistent item is NotFound.
    let ghost = cp_model::ItemId::generate();
    assert!(matches!(
        links::link(pool, alice, ghost).await,
        Err(Error::NotFound)
    ));
}

#[tokio::test]
async fn unlink_and_cascade_on_item_delete() {
    let (_dir, core) = test_core().await;
    let pool = core.pool();
    let store = core.store();
    let alice = auth::provision_user(pool, "alice").await.unwrap();

    // unlink removes the edge.
    let item = an_item(&core).await;
    links::link(pool, alice, item).await.unwrap();
    links::unlink(pool, alice, item).await.unwrap();
    assert!(links::user_for_item(pool, item).await.unwrap().is_none());

    // Deleting the item cascades the link away (FK ON DELETE CASCADE).
    let item2 = an_item(&core).await;
    links::link(pool, alice, item2).await.unwrap();
    store.delete_item(item2).await.unwrap();
    assert!(links::user_for_item(pool, item2).await.unwrap().is_none());
    assert_eq!(links::linked_items(pool, alice).await.unwrap().len(), 0);
}
