//! The gated debug shell: a thin read wrapper over the database by default, with an
//! explicitly-gated write surface that is off by default, per-session, and never persisted. Reads are
//! direct DB queries (an honest view of what is actually stored); writes route through core's mutation
//! API + the kind's `validate`, never raw SQL — the one exception is `create-user`, a bootstrap for the
//! fixed `users` substrate until auth (`TODO.md` #17). See DESIGN §8.

use std::sync::Arc;

use cp_model::{
    Channel, ChannelId, DebugAccess, Item, ItemId, Json, Membership, NewChannel, NewItem, TypeId,
    UserId, WriteCtx,
};
use sqlx::sqlite::SqliteRow;
use sqlx::Row;

use crate::registry::Registry;
use crate::store::Store;
use crate::Core;

/// The shell's per-session write mode. A fresh shell is always read-only. §8.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    ReadOnly,
    Write,
}

/// A read-only-by-default REPL over the store with a gated write surface. §8.
pub struct DebugShell {
    registry: Registry,
    store: Arc<Store>,
    mode: Mode,
}

impl DebugShell {
    pub fn new(registry: Registry, store: Arc<Store>) -> Self {
        Self {
            registry,
            store,
            mode: Mode::ReadOnly,
        }
    }

    /// The prompt reflecting the mode: `cp[ro]>` vs `cp[write]>`. §8.
    pub fn prompt(&self) -> &'static str {
        match self.mode {
            Mode::ReadOnly => "cp[ro]> ",
            Mode::Write => "cp[write]> ",
        }
    }

    pub fn enable_write_mode(&mut self) {
        self.mode = Mode::Write;
    }

    pub fn disable_write_mode(&mut self) {
        self.mode = Mode::ReadOnly;
    }

    /// Whether a command of the given access may run under the current mode. Every mutating command
    /// refuses until write mode is on. §8.
    pub fn permits(&self, access: DebugAccess) -> bool {
        matches!(
            (self.mode, access),
            (Mode::Write, _) | (Mode::ReadOnly, DebugAccess::Read)
        )
    }

    pub fn registry(&self) -> &Registry {
        &self.registry
    }

    /// Parse and run one input line, returning the text to print. Never panics on bad input; errors
    /// (including the write-mode gate) come back as a message.
    pub async fn eval(&mut self, line: &str) -> String {
        match self.run(line).await {
            Ok(out) => out,
            Err(msg) => msg,
        }
    }

    async fn run(&mut self, line: &str) -> Result<String, String> {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            return Ok(String::new());
        }
        let (cmd, rest) = split_first(line);
        match cmd {
            "help" => Ok(help_text()),
            "enable-write-mode" => {
                self.mode = Mode::Write;
                Ok("write mode ON — mutations enabled for this session".to_owned())
            }
            "disable-write-mode" => {
                self.mode = Mode::ReadOnly;
                Ok("write mode OFF".to_owned())
            }
            "show" => self.cmd_show(rest).await,
            "inspect" => self.cmd_inspect(rest.trim()).await,
            "members" => self.cmd_members(rest.trim()).await,
            "create-user" => {
                self.require_write()?;
                self.cmd_create_user(rest.trim()).await
            }
            "set-password" => {
                self.require_write()?;
                self.cmd_set_password(rest).await
            }
            "create-channel" => {
                self.require_write()?;
                self.cmd_create_channel(rest).await
            }
            "create-item" => {
                self.require_write()?;
                self.cmd_create_item(rest).await
            }
            "set-payload" => {
                self.require_write()?;
                self.cmd_set_payload(rest).await
            }
            "delete" => {
                self.require_write()?;
                self.cmd_delete(rest.trim()).await
            }
            "reparent" => {
                self.require_write()?;
                self.cmd_reparent(rest).await
            }
            "add-user-to-channel" => {
                self.require_write()?;
                self.cmd_add_user(rest, true).await
            }
            "remove-user-from-channel" => {
                self.require_write()?;
                self.cmd_add_user(rest, false).await
            }
            "link-user" => {
                self.require_write()?;
                self.cmd_link(rest, true).await
            }
            "unlink-user" => {
                self.require_write()?;
                self.cmd_link(rest, false).await
            }
            other => Err(format!("unknown command `{other}` — try `help`")),
        }
    }

    fn require_write(&self) -> Result<(), String> {
        if self.permits(DebugAccess::Write) {
            Ok(())
        } else {
            Err("read-only; run enable-write-mode first".to_owned())
        }
    }

    // --- reads (direct DB queries, §8) ------------------------------------------------------------

    async fn cmd_show(&self, rest: &str) -> Result<String, String> {
        let (sub, arg) = split_first(rest.trim());
        match sub {
            "channels" => self.show_channels().await,
            "items" => self.show_items(arg.trim()).await,
            "users" => self.show_users().await,
            "links" => self.show_links(arg.trim()).await,
            "" => Err(
                "usage: show <channels | items <channel-id> | users | links <handle>>".to_owned(),
            ),
            _ => Err(format!("unknown `show {sub}` — try `help`")),
        }
    }

    async fn show_channels(&self) -> Result<String, String> {
        let rows = sqlx::query("SELECT id, type_id, container, payload FROM channels ORDER BY id")
            .fetch_all(self.store.pool())
            .await
            .map_err(sql_err)?;
        if rows.is_empty() {
            return Ok("(no channels)".to_owned());
        }
        let mut out = Vec::new();
        for row in &rows {
            let ch = channel_from_row(row)?;
            let container = ch
                .container
                .map_or_else(|| "(root)".to_owned(), |c| c.to_string());
            let summary = self
                .registry
                .channel(&ch.type_id)
                .and_then(|k| k.debug_summary(&ch));
            let mut line = format!("{}  type={}  container={container}", ch.id, ch.type_id);
            if let Some(s) = summary {
                line.push_str(&format!("  — {s}"));
            }
            out.push(line);
        }
        Ok(out.join("\n"))
    }

    async fn show_items(&self, cid: &str) -> Result<String, String> {
        let container = parse_channel_id(cid)?;
        let rows = sqlx::query(
            "SELECT id, type_id, container, external_key, payload FROM items \
             WHERE container = ? ORDER BY id",
        )
        .bind(container.to_string())
        .fetch_all(self.store.pool())
        .await
        .map_err(sql_err)?;
        if rows.is_empty() {
            return Ok("(no items)".to_owned());
        }
        let mut out = Vec::new();
        for row in &rows {
            let item = item_from_row(row)?;
            let summary = self
                .registry
                .item(&item.type_id)
                .and_then(|k| k.debug_summary(&item));
            let mut line = format!("{}  type={}", item.id, item.type_id);
            if let Some(s) = summary {
                line.push_str(&format!("  — {s}"));
            }
            out.push(line);
        }
        Ok(out.join("\n"))
    }

    async fn show_users(&self) -> Result<String, String> {
        let rows = sqlx::query("SELECT id, handle FROM users ORDER BY id")
            .fetch_all(self.store.pool())
            .await
            .map_err(sql_err)?;
        if rows.is_empty() {
            return Ok("(no users)".to_owned());
        }
        rows.iter()
            .map(|r| Ok(format!("{}  @{}", str_col(r, "id")?, str_col(r, "handle")?)))
            .collect::<Result<Vec<_>, String>>()
            .map(|v| v.join("\n"))
    }

    async fn show_links(&self, handle: &str) -> Result<String, String> {
        if handle.is_empty() {
            return Err("usage: show links <handle>".to_owned());
        }
        let user = self.user_id_by_handle(handle).await?;
        let items = crate::links::linked_items(self.store.pool(), user)
            .await
            .map_err(core_err)?;
        if items.is_empty() {
            return Ok("(no links)".to_owned());
        }
        Ok(items
            .iter()
            .map(|i| format!("{}  type={}", i.id, i.type_id))
            .collect::<Vec<_>>()
            .join("\n"))
    }

    async fn cmd_inspect(&self, id: &str) -> Result<String, String> {
        if id.is_empty() {
            return Err("usage: inspect <id>".to_owned());
        }
        if let Ok(cid) = id.parse::<ChannelId>() {
            if let Some(ch) = self.store.get_channel(cid).await.map_err(core_err)? {
                let summary = self
                    .registry
                    .channel(&ch.type_id)
                    .and_then(|k| k.debug_summary(&ch));
                let container = ch
                    .container
                    .map_or_else(|| "(root)".to_owned(), |c| c.to_string());
                return Ok(format_envelope(
                    "channel",
                    &ch.id.to_string(),
                    &ch.type_id,
                    &container,
                    None,
                    summary,
                    &ch.payload,
                ));
            }
        }
        if let Ok(iid) = id.parse::<ItemId>() {
            if let Some(item) = self.store.get_item(iid).await.map_err(core_err)? {
                let summary = self
                    .registry
                    .item(&item.type_id)
                    .and_then(|k| k.debug_summary(&item));
                let container = item
                    .container
                    .map_or_else(|| "(none)".to_owned(), |c| c.to_string());
                return Ok(format_envelope(
                    "item",
                    &item.id.to_string(),
                    &item.type_id,
                    &container,
                    item.external_key.as_deref(),
                    summary,
                    &item.payload,
                ));
            }
        }
        Err(format!("no channel or item with id `{id}`"))
    }

    async fn cmd_members(&self, cid: &str) -> Result<String, String> {
        let (ch, membership) = self.resolve_membership(cid).await?;
        let users = membership
            .members(self.store.as_ref(), &ch)
            .await
            .map_err(core_err)?;
        if users.is_empty() {
            return Ok("(no members)".to_owned());
        }
        Ok(users
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n"))
    }

    // --- writes (through the mutation API, §8) ----------------------------------------------------

    async fn cmd_create_channel(&self, rest: &str) -> Result<String, String> {
        let (type_id, payload) = split_first(rest.trim());
        if type_id.is_empty() {
            return Err("usage: create-channel <type_id> <json-payload>".to_owned());
        }
        let id = self
            .store
            .create_channel(NewChannel {
                type_id: TypeId::new(type_id),
                container: None,
                payload: parse_json(payload)?,
            })
            .await
            .map_err(core_err)?;
        Ok(format!("created channel {id}"))
    }

    async fn cmd_create_item(&self, rest: &str) -> Result<String, String> {
        let (cid, tail) = split_first(rest.trim());
        let (type_id, payload) = split_first(tail);
        if cid.is_empty() || type_id.is_empty() {
            return Err("usage: create-item <channel-id> <type_id> <json-payload>".to_owned());
        }
        let id = self
            .store
            .create_item(NewItem {
                type_id: TypeId::new(type_id),
                container: Some(parse_channel_id(cid)?),
                external_key: None,
                payload: parse_json(payload)?,
            })
            .await
            .map_err(core_err)?;
        Ok(format!("created item {id}"))
    }

    async fn cmd_set_payload(&self, rest: &str) -> Result<String, String> {
        let (id, payload) = split_first(rest.trim());
        if id.is_empty() {
            return Err("usage: set-payload <id> <json-payload>".to_owned());
        }
        let payload = parse_json(payload)?;
        if let Ok(cid) = id.parse::<ChannelId>() {
            if self
                .store
                .get_channel(cid)
                .await
                .map_err(core_err)?
                .is_some()
            {
                self.store
                    .set_channel_payload(cid, payload)
                    .await
                    .map_err(core_err)?;
                return Ok(format!("updated channel {cid}"));
            }
        }
        if let Ok(iid) = id.parse::<ItemId>() {
            if self.store.get_item(iid).await.map_err(core_err)?.is_some() {
                self.store
                    .set_item_payload(iid, payload)
                    .await
                    .map_err(core_err)?;
                return Ok(format!("updated item {iid}"));
            }
        }
        Err(format!("no channel or item with id `{id}`"))
    }

    async fn cmd_delete(&self, id: &str) -> Result<String, String> {
        if let Ok(cid) = id.parse::<ChannelId>() {
            if self
                .store
                .get_channel(cid)
                .await
                .map_err(core_err)?
                .is_some()
            {
                self.store.delete_channel(cid).await.map_err(core_err)?;
                return Ok(format!("deleted channel {cid} (and its subtree)"));
            }
        }
        if let Ok(iid) = id.parse::<ItemId>() {
            if self.store.get_item(iid).await.map_err(core_err)?.is_some() {
                self.store.delete_item(iid).await.map_err(core_err)?;
                return Ok(format!("deleted item {iid}"));
            }
        }
        Err(format!("no channel or item with id `{id}`"))
    }

    async fn cmd_reparent(&self, rest: &str) -> Result<String, String> {
        // Move a channel/item under a new container (or `root` for none). The only way to build a
        // hierarchy interactively — e.g. put `basic` rooms inside a `space` so its search finds them.
        let (id, target) = split_first(rest.trim());
        if id.is_empty() || target.trim().is_empty() {
            return Err("usage: reparent <id> <container-id | root>".to_owned());
        }
        let container = match target.trim() {
            "root" => None,
            c => Some(parse_channel_id(c)?),
        };
        let dest = container.map_or_else(|| "(root)".to_owned(), |c| c.to_string());
        // A ULID parses as both id types, so confirm which table it is (get_* is a point read) before
        // choosing the mutation, exactly as `set-payload`/`delete` do.
        if let Ok(cid) = id.parse::<ChannelId>() {
            if self
                .store
                .get_channel(cid)
                .await
                .map_err(core_err)?
                .is_some()
            {
                self.store
                    .reparent_channel(cid, container)
                    .await
                    .map_err(core_err)?;
                return Ok(format!("reparented channel {cid} -> {dest}"));
            }
        }
        if let Ok(iid) = id.parse::<ItemId>() {
            if self.store.get_item(iid).await.map_err(core_err)?.is_some() {
                self.store
                    .reparent_item(iid, container)
                    .await
                    .map_err(core_err)?;
                return Ok(format!("reparented item {iid} -> {dest}"));
            }
        }
        Err(format!("no channel or item with id `{id}`"))
    }

    async fn cmd_set_password(&self, rest: &str) -> Result<String, String> {
        // Provision login for a native user (accounts are shell-provisioned; there is no public
        // registration — §17). The password is the remainder of the line.
        let (handle, password) = split_first(rest.trim());
        if handle.is_empty() || password.trim().is_empty() {
            return Err("usage: set-password <handle> <password>".to_owned());
        }
        crate::auth::set_password(self.store.pool(), handle, password.trim())
            .await
            .map_err(core_err)?;
        Ok(format!("password set for @{handle}"))
    }

    async fn cmd_create_user(&self, handle: &str) -> Result<String, String> {
        if handle.is_empty() || handle.contains(char::is_whitespace) {
            return Err("usage: create-user <handle>".to_owned());
        }
        // Bootstrap a native user (the fixed substrate, not an extensible envelope). Give it a login
        // with `set-password` (§2/§8/§17).
        let id = crate::auth::provision_user(self.store.pool(), handle)
            .await
            .map_err(core_err)?;
        Ok(format!("created user {id} (@{handle})"))
    }

    async fn cmd_add_user(&self, rest: &str, add: bool) -> Result<String, String> {
        let (cid, uid) = split_first(rest.trim());
        if cid.is_empty() || uid.trim().is_empty() {
            return Err(format!(
                "usage: {} <channel-id> <user-id>",
                if add {
                    "add-user-to-channel"
                } else {
                    "remove-user-from-channel"
                }
            ));
        }
        let user = parse_user_id(uid.trim())?;
        let (ch, membership) = self.resolve_membership(cid).await?;
        let cx: &dyn WriteCtx = self.store.as_ref();
        if add {
            membership.add_user(cx, &ch, user).await.map_err(core_err)?;
            Ok(format!("added user {user} to channel {}", ch.id))
        } else {
            membership
                .remove_user(cx, &ch, user)
                .await
                .map_err(core_err)?;
            Ok(format!("removed user {user} from channel {}", ch.id))
        }
    }

    async fn cmd_link(&self, rest: &str, add: bool) -> Result<String, String> {
        // Operator-provisioned `linked-users` (§2/§19): link a native user to an external cached-user
        // item. Pre-OAuth this is an operator-trusted assertion — there is no self-service HTTP write.
        let (handle, item) = split_first(rest.trim());
        if handle.is_empty() || item.trim().is_empty() {
            return Err(format!(
                "usage: {} <handle> <item-id>",
                if add { "link-user" } else { "unlink-user" }
            ));
        }
        let user = self.user_id_by_handle(handle).await?;
        let item_id = item
            .trim()
            .parse::<ItemId>()
            .map_err(|_| format!("invalid item id `{}`", item.trim()))?;
        if add {
            crate::links::link(self.store.pool(), user, item_id)
                .await
                .map_err(core_err)?;
            Ok(format!("linked @{handle} -> item {item_id}"))
        } else {
            crate::links::unlink(self.store.pool(), user, item_id)
                .await
                .map_err(core_err)?;
            Ok(format!("unlinked @{handle} -> item {item_id}"))
        }
    }

    /// Resolve a user handle to its id, or a "no user" refusal.
    async fn user_id_by_handle(&self, handle: &str) -> Result<UserId, String> {
        let row = sqlx::query("SELECT id FROM users WHERE handle = ?")
            .bind(handle)
            .fetch_optional(self.store.pool())
            .await
            .map_err(sql_err)?
            .ok_or_else(|| format!("no user with handle `{handle}`"))?;
        parse_user_id(&str_col(&row, "id")?)
    }

    /// Load a channel and its `Membership` capability, or the §8 "does not accept users" refusal.
    async fn resolve_membership(&self, cid: &str) -> Result<(Channel, &dyn Membership), String> {
        let channel_id = parse_channel_id(cid)?;
        let ch = self
            .store
            .get_channel(channel_id)
            .await
            .map_err(core_err)?
            .ok_or_else(|| format!("no channel with id `{cid}`"))?;
        let kind = self
            .registry
            .channel(&ch.type_id)
            .ok_or_else(|| format!("unregistered channel type `{}`", ch.type_id))?;
        match kind.membership() {
            Some(m) => Ok((ch, m)),
            None => Err(format!(
                "channel-type `{}` does not accept users",
                ch.type_id
            )),
        }
    }
}

/// Run the interactive REPL against a core, reading stdin until EOF. Prompts + banner go to stderr so
/// stdout carries only command output (scriptable: `printf '…' | channel-party shell`). §8.
pub async fn run(core: &Core) -> anyhow::Result<()> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let mut shell = DebugShell::new(core.registry().clone(), core.store());
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut err = tokio::io::stderr();
    err.write_all(b"channel-party debug shell. `help` for commands; Ctrl-D to exit.\n")
        .await?;
    err.write_all(shell.prompt().as_bytes()).await?;
    err.flush().await?;
    while let Some(line) = lines.next_line().await? {
        let out = shell.eval(&line).await;
        if !out.is_empty() {
            println!("{out}");
        }
        err.write_all(shell.prompt().as_bytes()).await?;
        err.flush().await?;
    }
    err.write_all(b"\n").await?;
    Ok(())
}

fn help_text() -> String {
    // Built-in commands only. Kind-contributed `debug_commands()` (§8) list/execute once a kind ships
    // one (e.g. canvas `move-box`, #11); that needs a registry enumerator + a kind execution hook,
    // deferred until then.
    [
        "reads (always available):",
        "  show channels                      list every channel",
        "  show items <channel-id>            list a channel's items",
        "  show users                         list native users",
        "  show links <handle>                list a user's linked external items (#19)",
        "  inspect <id>                       dump one envelope (channel or item)",
        "  members <channel-id>               list a channel's members",
        "mode:",
        "  enable-write-mode / disable-write-mode",
        "writes (require write mode):",
        "  create-channel <type_id> <json>",
        "  create-item <channel-id> <type_id> <json>",
        "  set-payload <id> <json>            replace a channel/item payload",
        "  delete <id>                        delete a channel (subtree) or item",
        "  reparent <id> <container-id|root>  move a channel/item under a new container",
        "  create-user <handle>               bootstrap a native user",
        "  set-password <handle> <password>   set a user's login password (#17)",
        "  add-user-to-channel <channel-id> <user-id>",
        "  remove-user-from-channel <channel-id> <user-id>",
        "  link-user <handle> <item-id>       link a user to an external cached-user item (#19)",
        "  unlink-user <handle> <item-id>     remove that link",
    ]
    .join("\n")
}

fn format_envelope(
    kind: &str,
    id: &str,
    type_id: &TypeId,
    container: &str,
    external_key: Option<&str>,
    summary: Option<String>,
    payload: &Json,
) -> String {
    let mut out = format!("{kind} {id}\n  type_id:   {type_id}\n  container: {container}");
    if let Some(key) = external_key {
        out.push_str(&format!("\n  ext_key:   {key}"));
    }
    if let Some(s) = summary {
        out.push_str(&format!("\n  summary:   {s}"));
    }
    let json = serde_json::to_string_pretty(payload).unwrap_or_else(|_| payload.to_string());
    out.push_str(&format!("\n  payload:   {json}"));
    out
}

/// Split a line into its first whitespace-delimited word and the trimmed remainder (which may itself
/// contain whitespace, e.g. a JSON payload).
fn split_first(s: &str) -> (&str, &str) {
    let s = s.trim_start();
    match s.find(char::is_whitespace) {
        Some(i) => (&s[..i], s[i..].trim_start()),
        None => (s, ""),
    }
}

fn sql_err(e: sqlx::Error) -> String {
    e.to_string()
}

fn core_err(e: cp_model::Error) -> String {
    e.to_string()
}

fn parse_json(s: &str) -> Result<Json, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("missing JSON payload".to_owned());
    }
    serde_json::from_str(s).map_err(|e| format!("invalid JSON: {e}"))
}

fn parse_channel_id(s: &str) -> Result<ChannelId, String> {
    s.parse().map_err(|_| format!("invalid channel id `{s}`"))
}

fn parse_user_id(s: &str) -> Result<UserId, String> {
    s.parse().map_err(|_| format!("invalid user id `{s}`"))
}

fn str_col(row: &SqliteRow, col: &str) -> Result<String, String> {
    row.try_get::<String, _>(col).map_err(sql_err)
}

fn channel_from_row(row: &SqliteRow) -> Result<Channel, String> {
    let container: Option<String> = row.try_get("container").map_err(sql_err)?;
    Ok(Channel {
        id: parse_channel_id(&str_col(row, "id")?)?,
        type_id: TypeId::new(str_col(row, "type_id")?),
        container: container.as_deref().map(parse_channel_id).transpose()?,
        payload: parse_json(&str_col(row, "payload")?)?,
    })
}

fn item_from_row(row: &SqliteRow) -> Result<Item, String> {
    let container: Option<String> = row.try_get("container").map_err(sql_err)?;
    Ok(Item {
        id: str_col(row, "id")?
            .parse()
            .map_err(|_| "invalid item id".to_owned())?,
        type_id: TypeId::new(str_col(row, "type_id")?),
        container: container.as_deref().map(parse_channel_id).transpose()?,
        external_key: row.try_get("external_key").map_err(sql_err)?,
        payload: parse_json(&str_col(row, "payload")?)?,
    })
}
