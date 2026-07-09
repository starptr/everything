//! The envelope store: it persists envelopes (the single write path, implementing `cp_model::WriteCtx`)
//! and reads them back — point reads plus the kind-facing discovery primitives `cp_model::StoreCtx`
//! (`children`/`descendants`/`seek_time`, DESIGN §5). `search` is the one primitive still stubbed: it
//! needs the FTS index substrate (`TODO.md` #3). See `design/write-path.md` and `design/read-path.md`.
//!
//! Queries use runtime-checked `sqlx::query` / `QueryBuilder` (not the `query!` macros), so no `.sqlx`
//! offline cache is needed yet (`TODO.md` #21).

use async_trait::async_trait;
use cp_model::{
    Channel, ChannelId, Cursor, Error, Filter, Item, ItemId, Json, NewChannel, NewItem, Node,
    NodePage, Order, Page, Result, StoreCtx, SuperType, TypeId, Upsert, UserId, WriteCtx,
};
use sqlx::sqlite::SqliteRow;
use sqlx::{QueryBuilder, Row, Sqlite, SqlitePool};
use ulid::Ulid;

use crate::events::{ChangeEvent, ChangeOp, EnvelopeRef, EventBus};
use crate::index;
use crate::registry::Registry;

/// The sqlite-backed store. Holds the pool, the registry (for `validate`/`index` on write), and the
/// event bus (to emit after commit).
pub struct Store {
    pool: SqlitePool,
    registry: Registry,
    events: EventBus,
}

fn db(e: sqlx::Error) -> Error {
    Error::Other(e.to_string())
}

fn to_text(payload: &Json) -> Result<String> {
    serde_json::to_string(payload).map_err(|e| Error::Other(e.to_string()))
}

fn from_text(s: &str) -> Result<Json> {
    serde_json::from_str(s).map_err(|e| Error::Other(e.to_string()))
}

fn channel_id(s: &str) -> Result<ChannelId> {
    s.parse()
        .map_err(|_| Error::Other(format!("invalid channel id: {s}")))
}

fn item_id(s: &str) -> Result<ItemId> {
    s.parse()
        .map_err(|_| Error::Other(format!("invalid item id: {s}")))
}

fn user_id(s: &str) -> Result<UserId> {
    s.parse()
        .map_err(|_| Error::Other(format!("invalid user id: {s}")))
}

impl Store {
    pub fn new(pool: SqlitePool, registry: Registry, events: EventBus) -> Self {
        Self {
            pool,
            registry,
            events,
        }
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub fn registry(&self) -> &Registry {
        &self.registry
    }

    /// Point read of a channel envelope by id. Used by the generic API (§9) and internally by the
    /// write path; not part of the kind-facing `StoreCtx` discovery set.
    pub async fn get_channel(&self, id: ChannelId) -> Result<Option<Channel>> {
        let row = sqlx::query("SELECT type_id, container, payload FROM channels WHERE id = ?")
            .bind(id.to_string())
            .fetch_optional(&self.pool)
            .await
            .map_err(db)?;
        let Some(row) = row else {
            return Ok(None);
        };
        let container: Option<String> = row.try_get("container").map_err(db)?;
        Ok(Some(Channel {
            id,
            type_id: TypeId::new(row.try_get::<String, _>("type_id").map_err(db)?),
            container: container.as_deref().map(channel_id).transpose()?,
            payload: from_text(&row.try_get::<String, _>("payload").map_err(db)?)?,
        }))
    }

    /// Every channel + item of the given types, id-ordered. The backfill enumerator behind
    /// `RuntimeCtx::scan` (§7) — unscoped by container, unlike the discovery primitives. Empty
    /// `types` ⇒ empty result (a component with no interest types has nothing to backfill).
    pub async fn scan_by_types(&self, types: &[TypeId]) -> Result<Vec<Node>> {
        if types.is_empty() {
            return Ok(Vec::new());
        }
        let mut qb = QueryBuilder::<Sqlite>::new("");
        select_channels(&mut qb);
        qb.push(" WHERE 1 = 1");
        push_type_ids(&mut qb, Some(types));
        qb.push(" UNION ALL ");
        select_items(&mut qb);
        qb.push(" WHERE 1 = 1");
        push_type_ids(&mut qb, Some(types));
        qb.push(" ORDER BY id ASC");
        let rows = qb.build().fetch_all(&self.pool).await.map_err(db)?;
        rows.iter().map(row_to_node).collect()
    }

    /// Point read of an item envelope by id. §9.
    pub async fn get_item(&self, id: ItemId) -> Result<Option<Item>> {
        let row =
            sqlx::query("SELECT type_id, container, external_key, payload FROM items WHERE id = ?")
                .bind(id.to_string())
                .fetch_optional(&self.pool)
                .await
                .map_err(db)?;
        let Some(row) = row else {
            return Ok(None);
        };
        let container: Option<String> = row.try_get("container").map_err(db)?;
        Ok(Some(Item {
            id,
            type_id: TypeId::new(row.try_get::<String, _>("type_id").map_err(db)?),
            container: container.as_deref().map(channel_id).transpose()?,
            external_key: row.try_get("external_key").map_err(db)?,
            payload: from_text(&row.try_get::<String, _>("payload").map_err(db)?)?,
        }))
    }
}

// The write path. See `design/write-path.md`: validate -> tx -> persist -> index -> commit -> emit.
#[async_trait]
impl WriteCtx for Store {
    async fn create_channel(&self, spec: NewChannel) -> Result<ChannelId> {
        let entry = {
            let kind = self
                .registry
                .channel(&spec.type_id)
                .ok_or(Error::NotFound)?;
            kind.validate(&spec.payload)?;
            kind.index(&spec.payload)
        };
        let id = ChannelId::generate();

        let mut tx = self.pool.begin().await.map_err(db)?;
        sqlx::query("INSERT INTO channels (id, type_id, container, payload) VALUES (?, ?, ?, ?)")
            .bind(id.to_string())
            .bind(spec.type_id.as_str())
            .bind(spec.container.map(|c| c.to_string()))
            .bind(to_text(&spec.payload)?)
            .execute(&mut *tx)
            .await
            .map_err(db)?;
        if let Some(entry) = entry {
            index::upsert(&mut tx, EnvelopeRef::Channel(id), &entry).await?;
        }
        tx.commit().await.map_err(db)?;

        self.events.publish(ChangeEvent {
            op: ChangeOp::Created,
            target: EnvelopeRef::Channel(id),
            type_id: spec.type_id,
            container: spec.container,
        });
        Ok(id)
    }

    async fn create_item(&self, spec: NewItem) -> Result<ItemId> {
        let entry = {
            let kind = self.registry.item(&spec.type_id).ok_or(Error::NotFound)?;
            kind.validate(&spec.payload)?;
            kind.index(&spec.payload)
        };
        let id = ItemId::generate();

        let mut tx = self.pool.begin().await.map_err(db)?;
        sqlx::query(
            "INSERT INTO items (id, type_id, container, external_key, payload) VALUES (?, ?, ?, ?, ?)",
        )
        .bind(id.to_string())
        .bind(spec.type_id.as_str())
        .bind(spec.container.map(|c| c.to_string()))
        .bind(spec.external_key.as_deref())
        .bind(to_text(&spec.payload)?)
        .execute(&mut *tx)
        .await
        .map_err(db)?;
        if let Some(entry) = entry {
            index::upsert(&mut tx, EnvelopeRef::Item(id), &entry).await?;
        }
        tx.commit().await.map_err(db)?;

        self.events.publish(ChangeEvent {
            op: ChangeOp::Created,
            target: EnvelopeRef::Item(id),
            type_id: spec.type_id,
            container: spec.container,
        });
        Ok(id)
    }

    async fn upsert_item(&self, spec: NewItem) -> Result<Upsert<ItemId>> {
        let key = spec
            .external_key
            .as_deref()
            .ok_or_else(|| Error::Other("upsert_item requires an external_key".to_owned()))?;
        let entry = {
            let kind = self.registry.item(&spec.type_id).ok_or(Error::NotFound)?;
            kind.validate(&spec.payload)?;
            kind.index(&spec.payload)
        };
        let fresh = ItemId::generate();

        let mut tx = self.pool.begin().await.map_err(db)?;
        // One atomic statement (no read-then-write race). On conflict the *existing* id is returned,
        // so it is stable across updates (§3). The partial unique index needs its WHERE echoed here.
        let row = sqlx::query(
            "INSERT INTO items (id, type_id, container, external_key, payload) VALUES (?, ?, ?, ?, ?)
             ON CONFLICT(external_key) WHERE external_key IS NOT NULL
             DO UPDATE SET payload = excluded.payload, container = excluded.container
             RETURNING id",
        )
        .bind(fresh.to_string())
        .bind(spec.type_id.as_str())
        .bind(spec.container.map(|c| c.to_string()))
        .bind(key)
        .bind(to_text(&spec.payload)?)
        .fetch_one(&mut *tx)
        .await
        .map_err(db)?;
        let id = item_id(&row.try_get::<String, _>("id").map_err(db)?)?;
        let inserted = id == fresh;
        if let Some(entry) = entry {
            index::upsert(&mut tx, EnvelopeRef::Item(id), &entry).await?;
        }
        tx.commit().await.map_err(db)?;

        self.events.publish(ChangeEvent {
            op: if inserted {
                ChangeOp::Created
            } else {
                ChangeOp::Updated
            },
            target: EnvelopeRef::Item(id),
            type_id: spec.type_id,
            container: spec.container,
        });
        Ok(if inserted {
            Upsert::Inserted(id)
        } else {
            Upsert::Updated(id)
        })
    }

    async fn set_channel_payload(&self, id: ChannelId, payload: Json) -> Result<()> {
        let ch = self.get_channel(id).await?.ok_or(Error::NotFound)?;
        let entry = {
            let kind = self.registry.channel(&ch.type_id).ok_or(Error::NotFound)?;
            kind.validate(&payload)?;
            kind.index(&payload)
        };

        let mut tx = self.pool.begin().await.map_err(db)?;
        sqlx::query("UPDATE channels SET payload = ? WHERE id = ?")
            .bind(to_text(&payload)?)
            .bind(id.to_string())
            .execute(&mut *tx)
            .await
            .map_err(db)?;
        if let Some(entry) = entry {
            index::upsert(&mut tx, EnvelopeRef::Channel(id), &entry).await?;
        }
        tx.commit().await.map_err(db)?;

        self.events.publish(ChangeEvent {
            op: ChangeOp::Updated,
            target: EnvelopeRef::Channel(id),
            type_id: ch.type_id,
            container: ch.container,
        });
        Ok(())
    }

    async fn set_item_payload(&self, id: ItemId, payload: Json) -> Result<()> {
        let item = self.get_item(id).await?.ok_or(Error::NotFound)?;
        let entry = {
            let kind = self.registry.item(&item.type_id).ok_or(Error::NotFound)?;
            kind.validate(&payload)?;
            kind.index(&payload)
        };

        let mut tx = self.pool.begin().await.map_err(db)?;
        sqlx::query("UPDATE items SET payload = ? WHERE id = ?")
            .bind(to_text(&payload)?)
            .bind(id.to_string())
            .execute(&mut *tx)
            .await
            .map_err(db)?;
        if let Some(entry) = entry {
            index::upsert(&mut tx, EnvelopeRef::Item(id), &entry).await?;
        }
        tx.commit().await.map_err(db)?;

        self.events.publish(ChangeEvent {
            op: ChangeOp::Updated,
            target: EnvelopeRef::Item(id),
            type_id: item.type_id,
            container: item.container,
        });
        Ok(())
    }

    async fn reparent_channel(&self, id: ChannelId, container: Option<ChannelId>) -> Result<()> {
        let ch = self.get_channel(id).await?.ok_or(Error::NotFound)?;
        // Container FK validates the new parent exists; payload/index unchanged (index is over payload).
        sqlx::query("UPDATE channels SET container = ? WHERE id = ?")
            .bind(container.map(|c| c.to_string()))
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(db)?;
        self.events.publish(ChangeEvent {
            op: ChangeOp::Updated,
            target: EnvelopeRef::Channel(id),
            type_id: ch.type_id,
            container,
        });
        Ok(())
    }

    async fn reparent_item(&self, id: ItemId, container: Option<ChannelId>) -> Result<()> {
        let item = self.get_item(id).await?.ok_or(Error::NotFound)?;
        sqlx::query("UPDATE items SET container = ? WHERE id = ?")
            .bind(container.map(|c| c.to_string()))
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(db)?;
        self.events.publish(ChangeEvent {
            op: ChangeOp::Updated,
            target: EnvelopeRef::Item(id),
            type_id: item.type_id,
            container,
        });
        Ok(())
    }

    async fn delete_channel(&self, id: ChannelId) -> Result<()> {
        // Fetch first so the event can carry type_id/container; also confirms existence.
        let ch = self.get_channel(id).await?.ok_or(Error::NotFound)?;
        let mut tx = self.pool.begin().await.map_err(db)?;
        // FK ON DELETE CASCADE removes child channels + items; their index rows are #3's concern.
        sqlx::query("DELETE FROM channels WHERE id = ?")
            .bind(id.to_string())
            .execute(&mut *tx)
            .await
            .map_err(db)?;
        index::delete(&mut tx, EnvelopeRef::Channel(id)).await?;
        tx.commit().await.map_err(db)?;

        self.events.publish(ChangeEvent {
            op: ChangeOp::Deleted,
            target: EnvelopeRef::Channel(id),
            type_id: ch.type_id,
            container: ch.container,
        });
        Ok(())
    }

    async fn delete_item(&self, id: ItemId) -> Result<()> {
        let item = self.get_item(id).await?.ok_or(Error::NotFound)?;
        let mut tx = self.pool.begin().await.map_err(db)?;
        sqlx::query("DELETE FROM items WHERE id = ?")
            .bind(id.to_string())
            .execute(&mut *tx)
            .await
            .map_err(db)?;
        index::delete(&mut tx, EnvelopeRef::Item(id)).await?;
        tx.commit().await.map_err(db)?;

        self.events.publish(ChangeEvent {
            op: ChangeOp::Deleted,
            target: EnvelopeRef::Item(id),
            type_id: item.type_id,
            container: item.container,
        });
        Ok(())
    }

    async fn add_member(&self, channel: ChannelId, user: UserId) -> Result<()> {
        // FKs enforce that both the channel and the (native) user exist. §2/§8.
        sqlx::query("INSERT OR IGNORE INTO channel_members (channel_id, user_id) VALUES (?, ?)")
            .bind(channel.to_string())
            .bind(user.to_string())
            .execute(&self.pool)
            .await
            .map_err(db)?;
        Ok(())
    }

    async fn remove_member(&self, channel: ChannelId, user: UserId) -> Result<()> {
        sqlx::query("DELETE FROM channel_members WHERE channel_id = ? AND user_id = ?")
            .bind(channel.to_string())
            .bind(user.to_string())
            .execute(&self.pool)
            .await
            .map_err(db)?;
        Ok(())
    }

    async fn members(&self, channel: ChannelId) -> Result<Vec<UserId>> {
        let rows = sqlx::query("SELECT user_id FROM channel_members WHERE channel_id = ?")
            .bind(channel.to_string())
            .fetch_all(&self.pool)
            .await
            .map_err(db)?;
        rows.iter()
            .map(|r| user_id(&r.try_get::<String, _>("user_id").map_err(db)?))
            .collect()
    }
}

// The read path / discovery primitives (`cp_model::StoreCtx`, DESIGN §5). A cursor is an opaque string
// wrapping a bare ULID keyset boundary; results resume *strictly beyond* it in the query's `Order`
// direction. Because ULIDs are time-ordered and their Crockford-base32 text sorts identically to the
// binary value, a plain `id <cmp> :cursor` gives time pagination for free, and `seek_time` is a pure
// timestamp→id computation. `search` alone is deferred (needs the FTS substrate, #3). See
// `design/read-path.md`.

/// Cap on one page, so an unbounded `limit` reaching these primitives from an HTTP query can't ask the
/// database to materialize everything at once. Callers keep paging via the returned cursor.
const MAX_LIMIT: u32 = 1000;

/// Keyset comparator for resuming after a cursor: `<` walks older ids (`TimeDesc`), `>` newer (`TimeAsc`).
fn cursor_cmp(order: Order) -> &'static str {
    match order {
        Order::TimeDesc => "<",
        Order::TimeAsc => ">",
    }
}

fn order_sql(order: Order) -> &'static str {
    match order {
        Order::TimeDesc => "DESC",
        Order::TimeAsc => "ASC",
    }
}

/// The shared discovery `SELECT` list for one super-type, tagged so both UNION arms round-trip through
/// [`row_to_node`]. Channels have no `external_key`, so it is a literal `NULL` there. Caller appends the
/// `WHERE`/filters.
fn select_channels(qb: &mut QueryBuilder<'_, Sqlite>) {
    qb.push(
        "SELECT 'channel' AS super_type, id, type_id, container, NULL AS external_key, payload \
         FROM channels",
    );
}
fn select_items(qb: &mut QueryBuilder<'_, Sqlite>) {
    qb.push(
        "SELECT 'item' AS super_type, id, type_id, container, external_key, payload FROM items",
    );
}

/// `AND type_id IN (...)` for a non-empty type filter; a no-op otherwise (`None`/empty ⇒ unfiltered).
fn push_type_ids(qb: &mut QueryBuilder<'_, Sqlite>, type_ids: Option<&[TypeId]>) {
    let Some(ids) = type_ids.filter(|v| !v.is_empty()) else {
        return;
    };
    qb.push(" AND type_id IN (");
    for (i, t) in ids.iter().enumerate() {
        if i > 0 {
            qb.push(", ");
        }
        qb.push_bind(t.as_str().to_owned());
    }
    qb.push(")");
}

/// The keyset predicate, when resuming from a cursor.
fn push_cursor(qb: &mut QueryBuilder<'_, Sqlite>, cursor: &Cursor, order: Order) {
    if let Some(id) = &cursor.0 {
        qb.push(" AND id ")
            .push(cursor_cmp(order))
            .push(" ")
            .push_bind(id.clone());
    }
}

/// Rebuild a [`Node`] from a discovery row (either UNION arm), keyed on the tagged `super_type`.
fn row_to_node(row: &SqliteRow) -> Result<Node> {
    let id: String = row.try_get("id").map_err(db)?;
    let type_id = TypeId::new(row.try_get::<String, _>("type_id").map_err(db)?);
    let container: Option<String> = row.try_get("container").map_err(db)?;
    let container = container.as_deref().map(channel_id).transpose()?;
    let payload = from_text(&row.try_get::<String, _>("payload").map_err(db)?)?;
    match row.try_get::<String, _>("super_type").map_err(db)?.as_str() {
        "channel" => Ok(Node::Channel(Channel {
            id: channel_id(&id)?,
            type_id,
            container,
            payload,
        })),
        "item" => Ok(Node::Item(Item {
            id: item_id(&id)?,
            type_id,
            container,
            external_key: row.try_get("external_key").map_err(db)?,
            payload,
        })),
        other => Err(Error::Other(format!("unknown super_type in row: {other}"))),
    }
}

fn node_id(node: &Node) -> String {
    match node {
        Node::Channel(c) => c.id.to_string(),
        Node::Item(i) => i.id.to_string(),
    }
}

#[async_trait]
impl StoreCtx for Store {
    async fn children(
        &self,
        container: ChannelId,
        filter: Filter,
        page: Page,
        order: Order,
    ) -> Result<NodePage> {
        if page.limit == 0 {
            return Ok(NodePage {
                nodes: Vec::new(),
                next: Cursor(None),
            });
        }
        let limit = page.limit.min(MAX_LIMIT);
        let want_channels = filter.super_type != Some(SuperType::Item);
        let want_items = filter.super_type != Some(SuperType::Channel);
        let type_ids = filter.type_ids.as_deref();

        // One UNION arm per wanted super-type; the trailing ORDER BY/LIMIT applies to the whole
        // compound. Fetch limit+1 to learn whether a further page exists without a second query.
        let mut qb = QueryBuilder::<Sqlite>::new("");
        if want_channels {
            select_channels(&mut qb);
            qb.push(" WHERE container = ");
            qb.push_bind(container.to_string());
            push_type_ids(&mut qb, type_ids);
            push_cursor(&mut qb, &page.cursor, order);
        }
        if want_channels && want_items {
            qb.push(" UNION ALL ");
        }
        if want_items {
            select_items(&mut qb);
            qb.push(" WHERE container = ");
            qb.push_bind(container.to_string());
            push_type_ids(&mut qb, type_ids);
            push_cursor(&mut qb, &page.cursor, order);
        }
        qb.push(" ORDER BY id ")
            .push(order_sql(order))
            .push(" LIMIT ")
            .push_bind(i64::from(limit) + 1);

        let rows = qb.build().fetch_all(&self.pool).await.map_err(db)?;
        let mut nodes = rows.iter().map(row_to_node).collect::<Result<Vec<_>>>()?;
        let next = if nodes.len() > limit as usize {
            nodes.truncate(limit as usize);
            Cursor(Some(node_id(nodes.last().expect("limit >= 1"))))
        } else {
            Cursor(None)
        };
        Ok(NodePage { nodes, next })
    }

    async fn descendants(
        &self,
        root: ChannelId,
        filter: Filter,
        depth: Option<u32>,
    ) -> Result<Vec<Node>> {
        let want_channels = filter.super_type != Some(SuperType::Item);
        let want_items = filter.super_type != Some(SuperType::Channel);
        let type_ids = filter.type_ids.as_deref();

        // Walk the channel containment edge from `root` (depth 0) with a recursive CTE, an optional
        // `depth` capping the hops. A node's depth = its container's depth + 1, so descendant channels
        // are the subtree minus root (depth >= 1) and an item qualifies when its container sits within
        // `depth - 1` hops. Fetch-all (no pagination): the primitive is "whole subtree" by contract.
        let mut qb = QueryBuilder::<Sqlite>::new(
            "WITH RECURSIVE subtree(id, depth) AS (SELECT id, 0 FROM channels WHERE id = ",
        );
        qb.push_bind(root.to_string());
        qb.push(
            " UNION ALL SELECT c.id, s.depth + 1 FROM channels c \
             JOIN subtree s ON c.container = s.id",
        );
        if let Some(max) = depth {
            qb.push(" WHERE s.depth + 1 <= ");
            qb.push_bind(i64::from(max));
        }
        qb.push(") ");

        if want_channels {
            select_channels(&mut qb);
            qb.push(" WHERE id IN (SELECT id FROM subtree WHERE depth >= 1)");
            push_type_ids(&mut qb, type_ids);
        }
        if want_channels && want_items {
            qb.push(" UNION ALL ");
        }
        if want_items {
            select_items(&mut qb);
            qb.push(" WHERE container IN (SELECT id FROM subtree");
            if let Some(max) = depth {
                qb.push(" WHERE depth <= ");
                qb.push_bind(i64::from(max) - 1);
            }
            qb.push(")");
            push_type_ids(&mut qb, type_ids);
        }
        qb.push(" ORDER BY id ASC");

        let rows = qb.build().fetch_all(&self.pool).await.map_err(db)?;
        rows.iter().map(row_to_node).collect()
    }

    async fn seek_time(&self, _container: ChannelId, timestamp_ms: u64) -> Result<Cursor> {
        // ULIDs carry a 48-bit millisecond time prefix, so the earliest id possible at time T is
        // `from_parts(T, 0)`. Return the id one below it: with `children`'s exclusive-beyond cursor, a
        // following `children(.., TimeAsc)` then yields exactly the rows created at/after T (and
        // `TimeDesc` those strictly before T). Pure — no query, no need to read the container. §3/§5.
        let floor = Ulid::from_parts(timestamp_ms, 0).0;
        let boundary = Ulid(floor.saturating_sub(1));
        Ok(Cursor(Some(boundary.to_string())))
    }

    async fn search(
        &self,
        scope: ChannelId,
        text: &str,
        filter: Filter,
        page: Page,
    ) -> Result<NodePage> {
        // FTS over the `index()` projection (`search_index`), scoped to `scope`'s subtree. See
        // `design/index-search.md`. Trigram needs >= 3 code points; a shorter needle forms no trigram,
        // so there is nothing to match — an empty page, not an FTS error.
        let needle = text.trim();
        if page.limit == 0 || needle.chars().count() < 3 {
            return Ok(NodePage {
                nodes: Vec::new(),
                next: Cursor(None),
            });
        }
        let limit = page.limit.min(MAX_LIMIT);
        let offset = decode_search_cursor(&page.cursor)?;
        // Match the needle as a literal FTS5 phrase: wrap in quotes, double any embedded quote. This
        // treats user input verbatim — its `AND`/`OR`/`NEAR`/`*`/column-filter operators are text, not
        // FTS query syntax (no injection).
        let match_expr = format!("\"{}\"", needle.replace('"', "\"\""));

        let want_channels = filter.super_type != Some(SuperType::Item);
        let want_items = filter.super_type != Some(SuperType::Channel);
        let type_ids = filter.type_ids.as_deref();

        // The subtree CTE is the *same* recursion as `descendants(scope)`, so search scoping and listing
        // scoping share one mental model. Each arm MATCHes the FTS row then INNER JOINs its envelope
        // table (rebuilding the Node and dropping orphaned index rows). `search_index.rank` is bm25 (more
        // negative ⇒ more relevant); `id` breaks ties into a total order for stable offset paging. The
        // FTS table is referenced unaliased: FTS5's table-level `MATCH` needs the real table name.
        let mut qb = QueryBuilder::<Sqlite>::new(
            "WITH RECURSIVE subtree(id, depth) AS (SELECT id, 0 FROM channels WHERE id = ",
        );
        qb.push_bind(scope.to_string());
        qb.push(
            " UNION ALL SELECT c.id, s.depth + 1 FROM channels c \
             JOIN subtree s ON c.container = s.id) ",
        );

        if want_channels {
            qb.push(
                "SELECT 'channel' AS super_type, c.id, c.type_id, c.container, NULL AS external_key, \
                 c.payload, search_index.rank AS score \
                 FROM search_index JOIN channels c ON c.id = search_index.envelope_id \
                 WHERE search_index.super_type = 'channel' AND search_index MATCH ",
            );
            qb.push_bind(match_expr.clone());
            qb.push(" AND c.id IN (SELECT id FROM subtree WHERE depth >= 1)");
            push_type_ids(&mut qb, type_ids);
        }
        if want_channels && want_items {
            qb.push(" UNION ALL ");
        }
        if want_items {
            qb.push(
                "SELECT 'item' AS super_type, i.id, i.type_id, i.container, i.external_key, i.payload, \
                 search_index.rank AS score \
                 FROM search_index JOIN items i ON i.id = search_index.envelope_id \
                 WHERE search_index.super_type = 'item' AND search_index MATCH ",
            );
            qb.push_bind(match_expr.clone());
            qb.push(" AND i.container IN (SELECT id FROM subtree)");
            push_type_ids(&mut qb, type_ids);
        }
        qb.push(" ORDER BY score ASC, id ASC LIMIT ")
            .push_bind(i64::from(limit) + 1)
            .push(" OFFSET ")
            .push_bind(i64::from(offset));

        let rows = qb.build().fetch_all(&self.pool).await.map_err(db)?;
        let mut nodes = rows.iter().map(row_to_node).collect::<Result<Vec<_>>>()?;
        let next = if nodes.len() > limit as usize {
            nodes.truncate(limit as usize);
            Cursor(Some((offset + limit).to_string()))
        } else {
            Cursor(None)
        };
        Ok(NodePage { nodes, next })
    }

    async fn is_member(&self, channel: ChannelId, user: UserId) -> Result<bool> {
        // The read side of the `channel_members` substrate (§8), consulted by `Permission` policies. §18.
        let row = sqlx::query("SELECT 1 FROM channel_members WHERE channel_id = ? AND user_id = ?")
            .bind(channel.to_string())
            .bind(user.to_string())
            .fetch_optional(&self.pool)
            .await
            .map_err(db)?;
        Ok(row.is_some())
    }

    fn type_owned_db(&self) -> &SqlitePool {
        // The §6 escape hatch: an escape-hatch kind's `contents` reads its own namespaced tables
        // through this (e.g. `canvas` its R-tree). It is the same pool; kinds are trusted to touch only
        // their `<kind>_*` tables, never core's `channels`/`items`. See `design/runtime.md`.
        &self.pool
    }
}

/// Decode a search cursor: a bare decimal **offset** (`None` ⇒ 0). Distinct from the id-keyset cursor
/// `children` mints — search ranks by relevance, not id, so it pages by offset (`design/index-search.md`).
fn decode_search_cursor(cursor: &Cursor) -> Result<u32> {
    match &cursor.0 {
        None => Ok(0),
        Some(s) => s
            .parse::<u32>()
            .map_err(|_| Error::Validation(format!("invalid search cursor: {s}"))),
    }
}
