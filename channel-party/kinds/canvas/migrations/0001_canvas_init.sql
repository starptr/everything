-- Type-owned spatial index for the canvas slice (namespaced `canvas_*`). Core never learns its shape
-- (DESIGN §6). The kind's SpatialIndex RuntimeComponent (§7) maintains it off the change stream; the
-- canvas channel's viewport-bbox `contents` (§5) reads it. See `design/runtime.md`.
--
-- Two tables: a denormalized box projection keyed by the ULID item id (so `contents` reconstructs the
-- envelope without touching core's `items`), and an R-tree keyed by an integer rowid (R-trees key on
-- integers) mapped from that id via `canvas_box.rid`.
CREATE TABLE IF NOT EXISTS canvas_box (
    rid       INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id   TEXT NOT NULL UNIQUE,       -- the canvas-text-box item
    container TEXT NOT NULL,              -- the canvas channel this box lives in
    x    REAL NOT NULL,
    y    REAL NOT NULL,
    w    REAL NOT NULL,
    h    REAL NOT NULL,
    text TEXT
);

CREATE VIRTUAL TABLE IF NOT EXISTS canvas_box_rtree USING rtree(
    rid,                                  -- = canvas_box.rid
    minX, maxX,                           -- [x, x + w]
    minY, maxY                            -- [y, y + h]
);
