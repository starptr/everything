-- Type-owned spatial index for the canvas slice (namespaced `canvas_*`). Populated by the
-- SpatialIndex RuntimeComponent (DESIGN §7); read by the canvas channel's viewport-bbox `contents`
-- (§5). Core never learns its shape (§6).
--
-- Placeholder: a flat coordinate table. A real deployment would use SQLite's R*Tree virtual table
-- (`CREATE VIRTUAL TABLE ... USING rtree`) for efficient bbox queries.
CREATE TABLE IF NOT EXISTS canvas_box_coords (
    item_id TEXT PRIMARY KEY,   -- references items(id) (a canvas-text-box)
    x       REAL NOT NULL,
    y       REAL NOT NULL
);
