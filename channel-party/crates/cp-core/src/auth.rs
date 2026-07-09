//! Native-user authentication + server-side sessions (DESIGN §2, `design/auth.md`, `TODO.md` #17).
//! Auth resolves exclusively against the `users` substrate — the one principal (§2). Passwords are
//! argon2id PHC strings in `users.password_hash`; a login mints an opaque random token handed to the
//! browser in a cookie, of which only the SHA-256 is stored (a DB leak exposes no live token). The
//! HTTP/cookie layer lives in `cp-frontend`; this module is the store logic both it and the debug
//! shell call. Accounts are *provisioned* (shell `set-password`) — there is no public registration.

use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use cp_model::{Error, Result, User, UserId};
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};
use sqlx::sqlite::SqliteRow;
use sqlx::{Row, SqlitePool};

fn db(e: sqlx::Error) -> Error {
    Error::Other(e.to_string())
}

fn hash_password(password: &str) -> Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| Error::Other(format!("password hashing failed: {e}")))
}

/// Verify a password against a stored PHC string; any parse/verify failure is a plain non-match.
fn verify_password(password: &str, phc: &str) -> bool {
    PasswordHash::new(phc)
        .and_then(|parsed| Argon2::default().verify_password(password.as_bytes(), &parsed))
        .is_ok()
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex(&hasher.finalize())
}

/// A fresh 256-bit opaque token (hex), from the OS CSPRNG. This is the cookie value; the DB keys on its
/// hash, never this.
fn random_token() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    hex(&bytes)
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

/// Insert a native user (no password yet — inert until `set_password`). The provisioning primitive
/// behind the shell's `create-user`; users are the fixed substrate, minted here rather than through the
/// envelope API (§2/§8). Errors (e.g. a duplicate handle) surface as `Other`.
pub async fn provision_user(pool: &SqlitePool, handle: &str) -> Result<UserId> {
    let id = UserId::generate();
    sqlx::query("INSERT INTO users (id, handle) VALUES (?, ?)")
        .bind(id.to_string())
        .bind(handle)
        .execute(pool)
        .await
        .map_err(db)?;
    Ok(id)
}

/// Set (or replace) a user's password. `NotFound` if no user has that handle. The provisioning path
/// (debug shell `set-password`) — there is no public registration. §17.
pub async fn set_password(pool: &SqlitePool, handle: &str, password: &str) -> Result<()> {
    let hash = hash_password(password)?;
    let affected = sqlx::query("UPDATE users SET password_hash = ? WHERE handle = ?")
        .bind(hash)
        .bind(handle)
        .execute(pool)
        .await
        .map_err(db)?
        .rows_affected();
    if affected == 0 {
        return Err(Error::NotFound);
    }
    Ok(())
}

/// Verify credentials, returning the `User` on success. `None` for an unknown handle, a wrong password,
/// or a user with no password set (a bare `create-user` account is inert until `set-password`).
pub async fn authenticate(pool: &SqlitePool, handle: &str, password: &str) -> Result<Option<User>> {
    let row = sqlx::query("SELECT id, handle, password_hash FROM users WHERE handle = ?")
        .bind(handle)
        .fetch_optional(pool)
        .await
        .map_err(db)?;
    let Some(row) = row else {
        return Ok(None);
    };
    let hash: Option<String> = row.try_get("password_hash").map_err(db)?;
    let Some(hash) = hash else {
        return Ok(None);
    };
    if verify_password(password, &hash) {
        Ok(Some(user_from_row(&row)?))
    } else {
        Ok(None)
    }
}

/// Mint a session for a user, returning the plaintext token to set as the cookie. §17.
pub async fn create_session(pool: &SqlitePool, user_id: UserId) -> Result<String> {
    let token = random_token();
    sqlx::query(
        "INSERT INTO sessions (token_hash, user_id, expires_at) \
         VALUES (?, ?, datetime('now', '+30 days'))",
    )
    .bind(sha256_hex(token.as_bytes()))
    .bind(user_id.to_string())
    .execute(pool)
    .await
    .map_err(db)?;
    Ok(token)
}

/// Resolve a cookie token to its user, or `None` if the session is unknown or expired. §17.
pub async fn resolve_session(pool: &SqlitePool, token: &str) -> Result<Option<User>> {
    let row = sqlx::query(
        "SELECT u.id, u.handle FROM sessions s JOIN users u ON u.id = s.user_id \
         WHERE s.token_hash = ? AND s.expires_at > datetime('now')",
    )
    .bind(sha256_hex(token.as_bytes()))
    .fetch_optional(pool)
    .await
    .map_err(db)?;
    row.as_ref().map(user_from_row).transpose()
}

/// Revoke a session (logout). A no-op if the token is unknown. §17.
pub async fn delete_session(pool: &SqlitePool, token: &str) -> Result<()> {
    sqlx::query("DELETE FROM sessions WHERE token_hash = ?")
        .bind(sha256_hex(token.as_bytes()))
        .execute(pool)
        .await
        .map_err(db)?;
    Ok(())
}
