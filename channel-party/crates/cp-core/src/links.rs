//! The `linked-users` edge + authorship resolution (DESIGN §2/§3, `design/linked-users.md`, `TODO.md`
//! #19). A native `User` links to the external `cached-user` items that represent it; authorship on a
//! `cached-message` resolves *up* such a link to the native user. Core is type-agnostic here — it links a
//! user to *an item*, never checking the item is a "cached-user" (that is the caller's semantics, §13).
//! Links are operator-provisioned (the debug shell); this module is the store logic it and the read
//! endpoints call. Sibling to `auth`.

use cp_model::{Error, Item, ItemId, Result, TypeId, User, UserId};
use sqlx::sqlite::SqliteRow;
use sqlx::{Row, SqlitePool};

fn db(e: sqlx::Error) -> Error {
    Error::Other(e.to_string())
}

fn item_from_row(row: &SqliteRow) -> Result<Item> {
    let container: Option<String> = row.try_get("container").map_err(db)?;
    Ok(Item {
        id: row
            .try_get::<String, _>("id")
            .map_err(db)?
            .parse::<ItemId>()
            .map_err(|_| Error::Other("invalid item id".to_owned()))?,
        type_id: TypeId::new(row.try_get::<String, _>("type_id").map_err(db)?),
        container: container
            .map(|c| c.parse())
            .transpose()
            .map_err(|_| Error::Other("invalid container id".to_owned()))?,
        external_key: row.try_get("external_key").map_err(db)?,
        payload: serde_json::from_str(&row.try_get::<String, _>("payload").map_err(db)?)
            .map_err(|e| Error::Other(e.to_string()))?,
    })
}

fn user_from_row(row: &SqliteRow) -> Result<User> {
    Ok(User {
        id: row
            .try_get::<String, _>("id")
            .map_err(db)?
            .parse::<UserId>()
            .map_err(|_| Error::Other("invalid user id".to_owned()))?,
        handle: row.try_get("handle").map_err(db)?,
    })
}

/// Link a native user to an external item. `NotFound` if the item does not exist. Idempotent for the
/// *same* user; a `Validation` conflict if the item is already linked to a *different* user (an external
/// identity resolves up to at most one native user — §2). Never silently ignores that conflict.
pub async fn link(pool: &SqlitePool, user: UserId, item: ItemId) -> Result<()> {
    if !item_exists(pool, item).await? {
        return Err(Error::NotFound);
    }
    if let Some(existing) = user_for_item(pool, item).await? {
        if existing.id == user {
            return Ok(()); // already linked to this user — idempotent
        }
        return Err(Error::Validation(format!(
            "item {item} is already linked to @{}",
            existing.handle
        )));
    }
    sqlx::query("INSERT INTO user_external_links (user_id, item_id) VALUES (?, ?)")
        .bind(user.to_string())
        .bind(item.to_string())
        .execute(pool)
        .await
        .map_err(db)?;
    Ok(())
}

/// Remove a link. A no-op if it does not exist.
pub async fn unlink(pool: &SqlitePool, user: UserId, item: ItemId) -> Result<()> {
    sqlx::query("DELETE FROM user_external_links WHERE user_id = ? AND item_id = ?")
        .bind(user.to_string())
        .bind(item.to_string())
        .execute(pool)
        .await
        .map_err(db)?;
    Ok(())
}

/// Forward: the external items a native user is linked to (its `linked-users`). §2.
pub async fn linked_items(pool: &SqlitePool, user: UserId) -> Result<Vec<Item>> {
    let rows = sqlx::query(
        "SELECT i.id, i.type_id, i.container, i.external_key, i.payload \
         FROM user_external_links l JOIN items i ON i.id = l.item_id \
         WHERE l.user_id = ? ORDER BY i.id",
    )
    .bind(user.to_string())
    .fetch_all(pool)
    .await
    .map_err(db)?;
    rows.iter().map(item_from_row).collect()
}

/// Reverse: the native user an external item is linked to, if any — authorship resolution *up* the link
/// (§2). `None` when the item is unlinked (or does not exist).
pub async fn user_for_item(pool: &SqlitePool, item: ItemId) -> Result<Option<User>> {
    let row = sqlx::query(
        "SELECT u.id, u.handle FROM user_external_links l JOIN users u ON u.id = l.user_id \
         WHERE l.item_id = ?",
    )
    .bind(item.to_string())
    .fetch_optional(pool)
    .await
    .map_err(db)?;
    row.as_ref().map(user_from_row).transpose()
}

async fn item_exists(pool: &SqlitePool, item: ItemId) -> Result<bool> {
    let row = sqlx::query("SELECT 1 FROM items WHERE id = ?")
        .bind(item.to_string())
        .fetch_optional(pool)
        .await
        .map_err(db)?;
    Ok(row.is_some())
}
