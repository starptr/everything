//! Integration tests for the core write path (`TODO.md` #1) against a real tempfile sqlite. Uses a
//! throwaway test kind so core's genericity is exercised, not a concrete kind crate (DESIGN §12).

use async_trait::async_trait;
use cp_core::{ChangeOp, Core, EnvelopeRef, Registry};
use cp_model::{
    Channel, ChannelKind, Error, IndexEntry, ItemKind, Json, NewChannel, NewItem, Result, StoreCtx,
    TypeId, Upsert, UserId, WriteCtx,
};

struct TestChannel(TypeId);

#[async_trait]
impl ChannelKind for TestChannel {
    fn type_id(&self) -> &TypeId {
        &self.0
    }

    fn validate(&self, payload: &Json) -> Result<()> {
        require_object(payload)
    }

    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _query: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the write-path test")
    }

    fn index(&self, payload: &Json) -> Option<IndexEntry> {
        payload
            .get("name")
            .and_then(|v| v.as_str())
            .map(|name| IndexEntry {
                name: Some(name.to_owned()),
                ..Default::default()
            })
    }
}

struct TestItem(TypeId);

impl ItemKind for TestItem {
    fn type_id(&self) -> &TypeId {
        &self.0
    }

    fn validate(&self, payload: &Json) -> Result<()> {
        require_object(payload)
    }
}

fn require_object(payload: &Json) -> Result<()> {
    if payload.is_object() {
        Ok(())
    } else {
        Err(Error::Validation("expected a JSON object".to_owned()))
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

fn new_channel(payload: Json) -> NewChannel {
    NewChannel {
        type_id: TypeId::new("test"),
        container: None,
        payload,
    }
}

#[tokio::test]
async fn create_read_update_delete() {
    let (_dir, core) = test_core().await;
    let store = core.store();

    let cid = store
        .create_channel(new_channel(serde_json::json!({ "name": "general" })))
        .await
        .unwrap();
    let ch = store.get_channel(cid).await.unwrap().unwrap();
    assert_eq!(ch.type_id.as_str(), "test");
    assert_eq!(ch.payload["name"], "general");

    let iid = store
        .create_item(NewItem {
            type_id: TypeId::new("test"),
            container: Some(cid),
            external_key: None,
            payload: serde_json::json!({ "body": "hi" }),
        })
        .await
        .unwrap();
    assert!(store.get_item(iid).await.unwrap().is_some());

    store
        .set_item_payload(iid, serde_json::json!({ "body": "edited" }))
        .await
        .unwrap();
    assert_eq!(
        store.get_item(iid).await.unwrap().unwrap().payload["body"],
        "edited"
    );

    store.delete_item(iid).await.unwrap();
    assert!(store.get_item(iid).await.unwrap().is_none());
}

#[tokio::test]
async fn upsert_is_idempotent_with_stable_id() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let cid = store
        .create_channel(new_channel(serde_json::json!({})))
        .await
        .unwrap();

    let mirror = |seen: i32| NewItem {
        type_id: TypeId::new("test"),
        container: Some(cid),
        external_key: Some("discord:user:42".to_owned()),
        payload: serde_json::json!({ "seen": seen }),
    };

    let first = store.upsert_item(mirror(1)).await.unwrap();
    let second = store.upsert_item(mirror(2)).await.unwrap();
    assert!(matches!(first, Upsert::Inserted(_)));
    assert!(matches!(second, Upsert::Updated(_)));
    assert_eq!(
        first.id(),
        second.id(),
        "one item per external_key; the id is stable across updates"
    );
    assert_eq!(
        store.get_item(second.id()).await.unwrap().unwrap().payload["seen"],
        2
    );
}

#[tokio::test]
async fn validation_and_unregistered_type_are_rejected() {
    let (_dir, core) = test_core().await;
    let store = core.store();

    let invalid = store
        .create_channel(new_channel(serde_json::json!("not an object")))
        .await;
    assert!(matches!(invalid, Err(Error::Validation(_))));

    let unregistered = store
        .create_channel(NewChannel {
            type_id: TypeId::new("nope"),
            container: None,
            payload: serde_json::json!({}),
        })
        .await;
    assert!(matches!(unregistered, Err(Error::NotFound)));
}

#[tokio::test]
async fn mutations_emit_change_events() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let mut rx = core.events().subscribe();

    let cid = store
        .create_channel(new_channel(serde_json::json!({ "name": "x" })))
        .await
        .unwrap();

    let event = rx.try_recv().unwrap();
    assert!(matches!(event.op, ChangeOp::Created));
    assert!(matches!(event.target, EnvelopeRef::Channel(id) if id == cid));
}

#[tokio::test]
async fn membership_substrate() {
    let (_dir, core) = test_core().await;
    let store = core.store();
    let cid = store
        .create_channel(new_channel(serde_json::json!({})))
        .await
        .unwrap();

    // Users come from auth (TODO #17); insert one directly to satisfy the channel_members FK.
    let uid = UserId::generate();
    sqlx::query("INSERT INTO users (id, handle) VALUES (?, ?)")
        .bind(uid.to_string())
        .bind("alice")
        .execute(core.pool())
        .await
        .unwrap();

    store.add_member(cid, uid).await.unwrap();
    assert_eq!(store.members(cid).await.unwrap(), vec![uid]);
    store.remove_member(cid, uid).await.unwrap();
    assert!(store.members(cid).await.unwrap().is_empty());
}
