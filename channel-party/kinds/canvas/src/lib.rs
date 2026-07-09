//! `canvas` — a spatial container, and the reference **escape-hatch** slice (DESIGN §6): it owns
//! namespaced `canvas_*` tables that core knows nothing about. Its `SpatialIndex` `RuntimeComponent`
//! (§7) maintains an R-tree off the change stream; its `contents` is a viewport-bbox query reading that
//! R-tree; items are text boxes placed at coordinates. See DESIGN §4/§5/§6/§7 and `design/runtime.md`.

use async_trait::async_trait;
use cp_model::{
    ChangeEvent, ChangeOp, Channel, ChannelKind, Cursor, EnvelopeRef, Error, Interests, Item,
    ItemId, ItemKind, Json, Migration, Migrations, Node, NodePage, Result, RuntimeComponent,
    RuntimeCtx, RuntimeEvent, StoreCtx, TypeId, WriteScope,
};
use serde::Deserialize;
use sqlx::sqlite::SqliteRow;
use sqlx::{QueryBuilder, Row, Sqlite, SqlitePool};

/// The channel and item type strings this crate contributes. §4.
pub const CHANNEL_TYPE: &str = "canvas";
pub const ITEM_TYPE: &str = "canvas-text-box";

/// Viewport page size when a query omits `limit`, and a ceiling so an unbounded value can't ask for a
/// whole canvas at once. The viewport is the real filter, so these are generous.
const DEFAULT_LIMIT: u32 = 500;
const MAX_LIMIT: u32 = 2000;

/// The `contents` query for a `canvas`: the viewport rectangle plus optional pagination. Missing
/// corners default to the whole plane, so an empty query returns every box (bounded by `limit`).
#[derive(Debug, Deserialize)]
#[serde(default)]
struct CanvasQuery {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    cursor: Option<String>,
    limit: Option<u32>,
}

impl Default for CanvasQuery {
    fn default() -> Self {
        Self {
            x0: f64::MIN,
            y0: f64::MIN,
            x1: f64::MAX,
            y1: f64::MAX,
            cursor: None,
            limit: None,
        }
    }
}

/// `channel-type:canvas`.
struct Canvas {
    type_id: TypeId,
}

#[async_trait]
impl ChannelKind for Canvas {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    async fn contents(&self, cx: &dyn StoreCtx, ch: &Channel, query: Json) -> Result<Json> {
        // DESIGN §5/§6: a viewport bbox query over this canvas's own R-tree — a strategy the closed
        // primitives can't express, so it uses the §6 escape hatch (`type_owned_db`). Reads only
        // `canvas_*` tables, reconstructing the box envelopes from the kind's denormalized projection
        // (no touch of core's `items`). Paginates by the id-keyset cursor, like `children`.
        let q: CanvasQuery = if query.is_null() {
            CanvasQuery::default()
        } else {
            serde_json::from_value(query).map_err(|e| Error::Validation(e.to_string()))?
        };
        let limit = q.limit.unwrap_or(DEFAULT_LIMIT).min(MAX_LIMIT);
        if limit == 0 {
            return to_json(NodePage {
                nodes: Vec::new(),
                next: Cursor(None),
            });
        }

        let mut qb = QueryBuilder::<Sqlite>::new(
            "SELECT b.item_id, b.x, b.y, b.w, b.h, b.text \
             FROM canvas_box_rtree r JOIN canvas_box b ON b.rid = r.rid WHERE b.container = ",
        );
        qb.push_bind(ch.id.to_string());
        // AABB overlap of the box [minX,maxX]×[minY,maxY] with the viewport.
        qb.push(" AND r.maxX >= ").push_bind(q.x0);
        qb.push(" AND r.minX <= ").push_bind(q.x1);
        qb.push(" AND r.maxY >= ").push_bind(q.y0);
        qb.push(" AND r.minY <= ").push_bind(q.y1);
        if let Some(cursor) = &q.cursor {
            qb.push(" AND b.item_id > ").push_bind(cursor.clone());
        }
        qb.push(" ORDER BY b.item_id ASC LIMIT ")
            .push_bind(i64::from(limit) + 1);

        let rows = qb.build().fetch_all(cx.type_owned_db()).await.map_err(db)?;
        let mut nodes = rows
            .iter()
            .map(|r| box_node(ch, r))
            .collect::<Result<Vec<_>>>()?;
        let next = if nodes.len() > limit as usize {
            nodes.truncate(limit as usize);
            Cursor(Some(node_item_id(nodes.last().expect("limit >= 1"))))
        } else {
            Cursor(None)
        };
        to_json(NodePage { nodes, next })
    }
}

/// `item-type:canvas-text-box`. No `index()`: its projection lives in the kind's own R-tree (written by
/// `SpatialIndex`), not a core substrate — the point of the escape hatch. Payload: `{x, y, w, h, text}`.
struct CanvasTextBox {
    type_id: TypeId,
}

impl ItemKind for CanvasTextBox {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }
}

/// Maintains the canvas R-tree off the change stream (DESIGN §7). `Derived`, so it structurally cannot
/// write core envelopes. Backfills existing boxes, then applies each `canvas-text-box` change.
struct SpatialIndex;

#[async_trait]
impl RuntimeComponent for SpatialIndex {
    fn name(&self) -> &str {
        "canvas-spatial-index"
    }

    fn writes(&self) -> WriteScope {
        WriteScope::Derived
    }

    fn interests(&self) -> Interests {
        Interests {
            schedule_secs: None,
            types: vec![TypeId::new(ITEM_TYPE)],
        }
    }

    async fn run(&self, cx: &dyn RuntimeCtx) -> Result<()> {
        let pool = cx.type_owned_db();
        // A version bump rebuilds from scratch; backfill then reconstructs every existing box.
        if cx.reset_requested() {
            clear(pool).await?;
        }
        for node in cx.scan(&[TypeId::new(ITEM_TYPE)]).await? {
            if let Node::Item(item) = node {
                upsert_box(pool, &item).await?;
            }
        }
        // Steady state: keep the R-tree in sync with box create/update/delete.
        while let Some(event) = cx.next_event().await {
            let RuntimeEvent::Change(change) = event else {
                continue;
            };
            apply(cx, pool, &change).await?;
        }
        Ok(())
    }
}

/// Apply one box change to the R-tree.
async fn apply(cx: &dyn RuntimeCtx, pool: &SqlitePool, change: &ChangeEvent) -> Result<()> {
    let EnvelopeRef::Item(id) = change.target else {
        return Ok(());
    };
    match change.op {
        ChangeOp::Deleted => delete_box(pool, id).await,
        ChangeOp::Created | ChangeOp::Updated => match cx.get_item(id).await? {
            Some(item) => upsert_box(pool, &item).await,
            None => delete_box(pool, id).await, // deleted between the event and the read
        },
    }
}

/// Project a box into `canvas_box` + the R-tree (delete-then-insert, since R-trees have no UPSERT), all
/// in one transaction. Skips boxes with no container or no coordinates.
async fn upsert_box(pool: &SqlitePool, item: &Item) -> Result<()> {
    let Some(container) = item.container else {
        return Ok(());
    };
    let Some((x, y, w, h)) = box_rect(&item.payload) else {
        return Ok(());
    };
    let text = item.payload.get("text").and_then(|v| v.as_str());

    let mut tx = pool.begin().await.map_err(db)?;
    let rid: i64 = sqlx::query_scalar(
        "INSERT INTO canvas_box (item_id, container, x, y, w, h, text) VALUES (?, ?, ?, ?, ?, ?, ?) \
         ON CONFLICT(item_id) DO UPDATE SET container = excluded.container, x = excluded.x, \
         y = excluded.y, w = excluded.w, h = excluded.h, text = excluded.text RETURNING rid",
    )
    .bind(item.id.to_string())
    .bind(container.to_string())
    .bind(x)
    .bind(y)
    .bind(w)
    .bind(h)
    .bind(text)
    .fetch_one(&mut *tx)
    .await
    .map_err(db)?;
    sqlx::query("DELETE FROM canvas_box_rtree WHERE rid = ?")
        .bind(rid)
        .execute(&mut *tx)
        .await
        .map_err(db)?;
    sqlx::query(
        "INSERT INTO canvas_box_rtree (rid, minX, maxX, minY, maxY) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(rid)
    .bind(x)
    .bind(x + w)
    .bind(y)
    .bind(y + h)
    .execute(&mut *tx)
    .await
    .map_err(db)?;
    tx.commit().await.map_err(db)?;
    Ok(())
}

/// Remove a box from both tables (a no-op if it was never indexed).
async fn delete_box(pool: &SqlitePool, id: ItemId) -> Result<()> {
    let mut tx = pool.begin().await.map_err(db)?;
    let rid: Option<i64> = sqlx::query_scalar("SELECT rid FROM canvas_box WHERE item_id = ?")
        .bind(id.to_string())
        .fetch_optional(&mut *tx)
        .await
        .map_err(db)?;
    if let Some(rid) = rid {
        sqlx::query("DELETE FROM canvas_box_rtree WHERE rid = ?")
            .bind(rid)
            .execute(&mut *tx)
            .await
            .map_err(db)?;
        sqlx::query("DELETE FROM canvas_box WHERE item_id = ?")
            .bind(id.to_string())
            .execute(&mut *tx)
            .await
            .map_err(db)?;
    }
    tx.commit().await.map_err(db)?;
    Ok(())
}

/// Truncate the index (reset path).
async fn clear(pool: &SqlitePool) -> Result<()> {
    sqlx::query("DELETE FROM canvas_box_rtree")
        .execute(pool)
        .await
        .map_err(db)?;
    sqlx::query("DELETE FROM canvas_box")
        .execute(pool)
        .await
        .map_err(db)?;
    Ok(())
}

fn db(e: sqlx::Error) -> Error {
    Error::Other(e.to_string())
}

fn to_json(page: NodePage) -> Result<Json> {
    serde_json::to_value(page).map_err(|e| Error::Other(e.to_string()))
}

/// `(x, y, w, h)` from a box payload; `w`/`h` default to 0 (a point). Missing `x`/`y` ⇒ not placeable.
fn box_rect(payload: &Json) -> Option<(f64, f64, f64, f64)> {
    let x = payload.get("x")?.as_f64()?;
    let y = payload.get("y")?.as_f64()?;
    let w = payload.get("w").and_then(Json::as_f64).unwrap_or(0.0);
    let h = payload.get("h").and_then(Json::as_f64).unwrap_or(0.0);
    Some((x, y, w, h))
}

/// Rebuild a box `Node::Item` from a `canvas_box` row — the envelope reconstructed from the kind's own
/// projection, so `contents` never reads core's `items`.
fn box_node(ch: &Channel, row: &SqliteRow) -> Result<Node> {
    let item_id: String = row.try_get("item_id").map_err(db)?;
    let id: ItemId = item_id
        .parse()
        .map_err(|_| Error::Other(format!("invalid item id in canvas_box: {item_id}")))?;
    let x: f64 = row.try_get("x").map_err(db)?;
    let y: f64 = row.try_get("y").map_err(db)?;
    let w: f64 = row.try_get("w").map_err(db)?;
    let h: f64 = row.try_get("h").map_err(db)?;
    let text: Option<String> = row.try_get("text").map_err(db)?;
    Ok(Node::Item(Item {
        id,
        type_id: TypeId::new(ITEM_TYPE),
        container: Some(ch.id),
        external_key: None,
        payload: serde_json::json!({ "x": x, "y": y, "w": w, "h": h, "text": text }),
    }))
}

fn node_item_id(node: &Node) -> String {
    match node {
        Node::Item(i) => i.id.to_string(),
        Node::Channel(c) => c.id.to_string(),
    }
}

/// The `channel-type:canvas` kind, for the composition root. §10.
pub fn channel() -> impl ChannelKind {
    Canvas {
        type_id: TypeId::new(CHANNEL_TYPE),
    }
}

/// The `item-type:canvas-text-box` kind, for the composition root. §10.
pub fn text_box() -> impl ItemKind {
    CanvasTextBox {
        type_id: TypeId::new(ITEM_TYPE),
    }
}

/// The Derived spatial indexer, for the composition root. §10.
pub fn spatial_index() -> impl RuntimeComponent {
    SpatialIndex
}

/// Type-owned migrations (namespaced `canvas_*`). §6.
pub static MIGRATIONS: Migrations = Migrations(&[Migration {
    name: "0001_canvas_init",
    sql: include_str!("../migrations/0001_canvas_init.sql"),
}]);
