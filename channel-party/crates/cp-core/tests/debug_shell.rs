//! Integration tests for the gated debug shell (`TODO.md` #6): the write-mode gate, direct-read
//! commands, envelope CRUD through the mutation API, and capability-gated membership. Uses throwaway
//! test kinds (one with membership, one without) rather than a concrete kind crate (DESIGN §12).

use async_trait::async_trait;
use cp_core::debug::DebugShell;
use cp_core::{Core, Registry};
use cp_model::{
    Channel, ChannelKind, Item, ItemKind, Json, Membership, Result, StoreCtx, TypeId, UserId,
    WriteCtx,
};

/// A channel that accepts users (membership via the generic edge substrate) and summarizes its name.
struct Room(TypeId);

#[async_trait]
impl ChannelKind for Room {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _q: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the debug-shell test")
    }
    fn debug_summary(&self, ch: &Channel) -> Option<String> {
        ch.payload
            .get("name")
            .and_then(|v| v.as_str())
            .map(|n| format!("#{n}"))
    }
    fn membership(&self) -> Option<&dyn Membership> {
        Some(self)
    }
}

#[async_trait]
impl Membership for Room {
    async fn add_user(&self, cx: &dyn WriteCtx, ch: &Channel, u: UserId) -> Result<()> {
        cx.add_member(ch.id, u).await
    }
    async fn remove_user(&self, cx: &dyn WriteCtx, ch: &Channel, u: UserId) -> Result<()> {
        cx.remove_member(ch.id, u).await
    }
    async fn members(&self, cx: &dyn WriteCtx, ch: &Channel) -> Result<Vec<UserId>> {
        cx.members(ch.id).await
    }
}

/// A channel that does not accept users (no membership capability).
struct Locked(TypeId);

#[async_trait]
impl ChannelKind for Locked {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _q: Json) -> Result<Json> {
        unreachable!("contents is not exercised by the debug-shell test")
    }
}

struct Msg(TypeId);

impl ItemKind for Msg {
    fn type_id(&self) -> &TypeId {
        &self.0
    }
    fn debug_summary(&self, item: &Item) -> Option<String> {
        item.payload
            .get("body")
            .and_then(|v| v.as_str())
            .map(str::to_owned)
    }
}

async fn shell() -> (tempfile::TempDir, DebugShell) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(Room(TypeId::new("room")))
        .channel(Locked(TypeId::new("locked")))
        .item(Msg(TypeId::new("msg")))
        .build();
    let core = Core::open(&url, registry.clone()).await.unwrap();
    // The shell holds an Arc<Store> (keeping the pool alive), so dropping `core` here is fine.
    (dir, DebugShell::new(registry, core.store()))
}

/// The id printed after `created <kind> ` on a create line.
fn created_id(line: &str, kind: &str) -> String {
    line.strip_prefix(&format!("created {kind} "))
        .unwrap_or_else(|| panic!("unexpected create output: {line}"))
        .split_whitespace()
        .next()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn read_only_by_default_and_gates_writes() {
    let (_dir, mut sh) = shell().await;
    assert_eq!(sh.prompt(), "cp[ro]> ");
    assert_eq!(sh.eval("show channels").await, "(no channels)");

    let refused = sh.eval("create-channel room {\"name\":\"general\"}").await;
    assert_eq!(refused, "read-only; run enable-write-mode first");
    assert_eq!(
        sh.eval("show channels").await,
        "(no channels)",
        "nothing was written"
    );

    assert!(sh.eval("enable-write-mode").await.contains("write mode ON"));
    assert_eq!(sh.prompt(), "cp[write]> ");
    assert!(sh
        .eval("disable-write-mode")
        .await
        .contains("write mode OFF"));
    assert_eq!(sh.prompt(), "cp[ro]> ");
}

#[tokio::test]
async fn create_inspect_update_and_delete() {
    let (_dir, mut sh) = shell().await;
    sh.enable_write_mode();

    let cid = created_id(
        &sh.eval("create-channel room {\"name\":\"general\"}").await,
        "channel",
    );
    let channels = sh.eval("show channels").await;
    assert!(channels.contains(&cid), "{channels}");
    assert!(channels.contains("type=room"), "{channels}");
    assert!(
        channels.contains("#general"),
        "debug_summary shown: {channels}"
    );

    let iid = created_id(
        &sh.eval(&format!("create-item {cid} msg {{\"body\":\"hi\"}}"))
            .await,
        "item",
    );
    let items = sh.eval(&format!("show items {cid}")).await;
    assert!(items.contains(&iid) && items.contains("hi"), "{items}");

    let inspected = sh.eval(&format!("inspect {iid}")).await;
    assert!(inspected.contains("item"), "{inspected}");
    assert!(
        inspected.contains("\"body\": \"hi\""),
        "payload dumped: {inspected}"
    );

    assert!(sh
        .eval(&format!("set-payload {iid} {{\"body\":\"edited\"}}"))
        .await
        .contains("updated item"));
    assert!(sh.eval(&format!("inspect {iid}")).await.contains("edited"));

    assert!(sh
        .eval(&format!("delete {iid}"))
        .await
        .contains("deleted item"));
    assert_eq!(sh.eval(&format!("show items {cid}")).await, "(no items)");
}

#[tokio::test]
async fn membership_is_capability_gated() {
    let (_dir, mut sh) = shell().await;
    sh.enable_write_mode();

    let room = created_id(&sh.eval("create-channel room {}").await, "channel");
    let locked = created_id(&sh.eval("create-channel locked {}").await, "channel");
    let uid = created_id(&sh.eval("create-user alice").await, "user");

    let added = sh.eval(&format!("add-user-to-channel {room} {uid}")).await;
    assert!(added.contains("added user"), "{added}");
    assert!(sh.eval(&format!("members {room}")).await.contains(&uid));

    // A channel type with no `membership()` refuses with the §8 message — this *is* the "accepts
    // users" check (capability presence).
    let refused = sh
        .eval(&format!("add-user-to-channel {locked} {uid}"))
        .await;
    assert!(refused.contains("does not accept users"), "{refused}");

    assert!(sh
        .eval(&format!("remove-user-from-channel {room} {uid}"))
        .await
        .contains("removed user"));
    assert_eq!(sh.eval(&format!("members {room}")).await, "(no members)");
}

#[tokio::test]
async fn bad_input_is_a_clean_message_not_a_panic() {
    let (_dir, mut sh) = shell().await;
    sh.enable_write_mode();

    // Unregistered type -> the mutation API's NotFound, surfaced as text.
    assert!(sh
        .eval("create-channel nope {}")
        .await
        .contains("not found"));
    // Malformed JSON payload.
    assert!(sh
        .eval("create-channel room not-json")
        .await
        .contains("invalid JSON"));
    // Unknown command / id.
    assert!(sh.eval("frobnicate x").await.contains("unknown command"));
    assert!(sh.eval("inspect 0000").await.contains("no channel or item"));
    // help lists the gate.
    assert!(sh.eval("help").await.contains("enable-write-mode"));
}

#[tokio::test]
async fn reparent_moves_a_channel_under_a_container() {
    let (_dir, mut sh) = shell().await;
    sh.enable_write_mode();

    let parent = created_id(
        &sh.eval("create-channel room {\"name\":\"space\"}").await,
        "channel",
    );
    let child = created_id(
        &sh.eval("create-channel room {\"name\":\"room\"}").await,
        "channel",
    );
    // Both start at root — the only hierarchy the create commands can express on their own.
    assert!(sh.eval("show channels").await.contains("container=(root)"));

    let moved = sh.eval(&format!("reparent {child} {parent}")).await;
    assert!(
        moved.contains("reparented channel") && moved.contains(&parent),
        "{moved}"
    );
    assert!(
        sh.eval("show channels")
            .await
            .contains(&format!("container={parent}")),
        "child now nested under the parent"
    );

    // And back out to root.
    assert!(sh
        .eval(&format!("reparent {child} root"))
        .await
        .contains("(root)"));
}

#[tokio::test]
async fn set_password_is_gated_and_provisions_login() {
    let (_dir, mut sh) = shell().await;
    sh.enable_write_mode();

    assert!(sh.eval("create-user carol").await.contains("created user"));
    assert!(sh
        .eval("set-password carol s3cret")
        .await
        .contains("password set for @carol"));
    // Unknown handle → a clean NotFound message, not a panic.
    assert!(sh.eval("set-password nobody x").await.contains("not found"));

    // The write-mode gate applies.
    sh.disable_write_mode();
    assert!(sh
        .eval("set-password carol s3cret")
        .await
        .contains("read-only"));
}

#[tokio::test]
async fn link_user_provisions_and_lists_external_links() {
    let (_dir, mut sh) = shell().await;
    sh.enable_write_mode();

    let room = created_id(&sh.eval("create-channel room {}").await, "channel");
    let item = created_id(
        &sh.eval(&format!(
            "create-item {room} msg {{\"body\":\"cached-user\"}}"
        ))
        .await,
        "item",
    );
    sh.eval("create-user dave").await;
    assert_eq!(sh.eval("show links dave").await, "(no links)");

    // Provision a link, then it lists.
    assert!(sh
        .eval(&format!("link-user dave {item}"))
        .await
        .contains("linked @dave"));
    assert!(sh.eval("show links dave").await.contains(&item));

    // Unknown handle → a clean message, not a panic.
    assert!(sh
        .eval(&format!("link-user nobody {item}"))
        .await
        .contains("no user with handle"));

    // Unlink removes it; and the write-mode gate applies to link-user.
    assert!(sh
        .eval(&format!("unlink-user dave {item}"))
        .await
        .contains("unlinked @dave"));
    assert_eq!(sh.eval("show links dave").await, "(no links)");
    sh.disable_write_mode();
    assert!(sh
        .eval(&format!("link-user dave {item}"))
        .await
        .contains("read-only"));
}
