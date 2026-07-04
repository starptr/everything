//! Kind-owned migrations: namespaced SQL a kind ships (`discord_*`, `canvas_*`) and registers with
//! core's migrator, giving the slice a self-contained search stack — own table (schema) +
//! RuntimeComponent (writer) + `contents` (reader) — that core never learns the shape of. Part of
//! the plugin interface, so it lives here (kinds depend only on `cp-model`). See DESIGN §6.

/// One migration: a name and its SQL. Kinds typically build these with `include_str!`.
#[derive(Clone, Copy, Debug)]
pub struct Migration {
    pub name: &'static str,
    pub sql: &'static str,
}

/// A crate's set of migrations, contributed at the composition root via `.migrations(...)`. §6/§10.
#[derive(Clone, Copy, Debug)]
pub struct Migrations(pub &'static [Migration]);
