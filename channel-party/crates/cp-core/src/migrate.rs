//! The migrator. Runs core's init schema, then every registered kind-owned migration. §6/§10.
//!
//! Under Nix/crane the `.sql` files must be kept in the build source (the flake's `src` filter
//! keeps `**/migrations/**`); a bare `cleanCargoSource` would strip them and `include_str!` would
//! fail to compile — the same asset-filter concern as `andref-ipfs-depot`.

use sqlx::SqlitePool;

use crate::registry::Registry;

/// Core's init schema (users / channels / items + the external-links edge). §3.
const CORE_INIT: &str = include_str!("../migrations/0001_init.sql");

/// Run core's init migration, then each registered kind migration in registration order. The SQL
/// is idempotent, so re-running on every boot is safe in the scaffold. §6/§10.
pub async fn run(pool: &SqlitePool, registry: &Registry) -> anyhow::Result<()> {
    sqlx::raw_sql(CORE_INIT).execute(pool).await?;
    for migration in registry.migrations() {
        sqlx::raw_sql(migration.sql).execute(pool).await?;
    }
    Ok(())
}
