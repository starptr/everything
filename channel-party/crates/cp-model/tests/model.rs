//! Unit coverage for envelope serde and Kind trait defaults. See DESIGN §12.

use async_trait::async_trait;
use cp_model::{
    Channel, ChannelId, ChannelKind, IndexEntry, Item, ItemId, Json, Result, StoreCtx, TypeId,
};

#[test]
fn channel_envelope_round_trips() {
    let ch = Channel {
        id: ChannelId::generate(),
        type_id: TypeId::new("basic"),
        container: None,
        payload: serde_json::json!({ "name": "general" }),
    };
    let json = serde_json::to_string(&ch).unwrap();
    let back: Channel = serde_json::from_str(&json).unwrap();
    assert_eq!(back.id, ch.id);
    assert_eq!(back.type_id, ch.type_id);
    assert_eq!(back.payload, ch.payload);
}

#[test]
fn item_envelope_round_trips() {
    let item = Item {
        id: ItemId::generate(),
        type_id: TypeId::new("discord-compatible/cached-user"),
        container: None,
        external_key: Some("discord:12345".to_owned()),
        payload: serde_json::json!({ "username": "ferris" }),
    };
    let json = serde_json::to_string(&item).unwrap();
    let back: Item = serde_json::from_str(&json).unwrap();
    assert_eq!(back.external_key, item.external_key);
    assert_eq!(back.type_id.namespace(), "discord-compatible");
}

/// A minimal kind that overrides nothing but the two required methods, exercising the opt-in
/// defaults (`validate` -> Ok, `index` -> None).
struct TrivialChannel(TypeId);

#[async_trait]
impl ChannelKind for TrivialChannel {
    fn type_id(&self) -> &TypeId {
        &self.0
    }

    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _query: Json) -> Result<Json> {
        Ok(Json::Null)
    }
}

#[test]
fn trait_defaults_hold() {
    let kind = TrivialChannel(TypeId::new("basic"));
    assert!(kind.validate(&Json::Null).is_ok());
    assert!(kind.index(&Json::Null).is_none());
    assert!(kind.membership().is_none());
    assert!(kind.debug_commands().is_empty());
    // IndexEntry default is all-None.
    let entry = IndexEntry::default();
    assert!(entry.name.is_none() && entry.coord.is_none());
}
