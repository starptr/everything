//! `canvas` — a spatial container. Its `contents` is a viewport-bbox query; items are text boxes
//! placed at coordinates, projected into a spatial (R-tree) index. Frontend- and index-heavy: the
//! island is a pan/zoom canvas that delegates drawing each box to the `canvas-text-box` item
//! island. See DESIGN §4/§5/§6.

use async_trait::async_trait;
use cp_model::{
    Channel, ChannelKind, IndexEntry, Interests, ItemKind, Json, Migration, Migrations, Result,
    RuntimeComponent, RuntimeCtx, StoreCtx, TypeId, WriteScope,
};

/// `channel-type:canvas`.
struct Canvas {
    type_id: TypeId,
}

#[async_trait]
impl ChannelKind for Canvas {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    // §4 capability table: canvas validates its payloads.
    fn validate(&self, _payload: &Json) -> Result<()> {
        Ok(())
    }

    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _query: Json) -> Result<Json> {
        // DESIGN §5: a viewport bbox query over the spatial index (§6), returning the boxes in view.
        todo!("canvas channel contents (DESIGN §5)")
    }
}

/// `item-type:canvas-text-box`.
struct CanvasTextBox {
    type_id: TypeId,
}

impl ItemKind for CanvasTextBox {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    fn index(&self, payload: &Json) -> Option<IndexEntry> {
        // coord -> spatial index. §6.
        let x = payload.get("x")?.as_f64()?;
        let y = payload.get("y")?.as_f64()?;
        Some(IndexEntry {
            coord: Some((x, y)),
            ..Default::default()
        })
    }
}

/// Maintains the spatial index off the change stream. Confined to `Derived` tables. §7.
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
            types: vec![TypeId::new("canvas-text-box")],
        }
    }

    async fn run(&self, _cx: &dyn RuntimeCtx) -> Result<()> {
        todo!("canvas spatial index: backfill, then react to box moves (DESIGN §7)")
    }
}

/// The `channel-type:canvas` kind, for the composition root. §10.
pub fn channel() -> impl ChannelKind {
    Canvas {
        type_id: TypeId::new("canvas"),
    }
}

/// The `item-type:canvas-text-box` kind, for the composition root. §10.
pub fn text_box() -> impl ItemKind {
    CanvasTextBox {
        type_id: TypeId::new("canvas-text-box"),
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
