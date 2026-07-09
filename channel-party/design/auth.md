# Design note: native user auth + sessions (`TODO.md` #17)

Status: **ratified & implemented (2026-07-11).** Password auth against the `users` substrate with
**provisioned accounts only** (no public registration) + server-side sessions. Folds into `DESIGN.md`
§2 (users are the one principal; "auth material lives here"). Scope: the identity/session *foundation* —
who is logged in — not authenticated write endpoints (those need the permissions model, #18) and not
open signup (a deliberate posture choice).

## Decisions

- **Provisioned accounts, no public signup.** A native `User` is created by the operator via the debug
  shell (`create-user <handle>` already exists) and given a password with a new gated `set-password
  <handle> <password>` command. The HTTP surface exposes **only** `login` / `logout` / `me` — there is
  no `/register` route. Suits a private instance; invite/self-signup can be layered on later without
  disturbing this.
- **Password hashing: argon2** (argon2id, the current best practice), via the `argon2` crate. The PHC
  string (`$argon2id$…`) is stored in a new `users.password_hash` column; a `NULL` hash means "no
  password set" → cannot log in (so a bare `create-user` account is inert until `set-password`).
- **Server-side sessions**, not JWT: a login mints a 256-bit random opaque token, returned to the
  browser in an **HttpOnly** cookie; the server stores only **`SHA-256(token)`** in a `sessions` table
  (a DB leak never exposes a live token). Revocation = delete the row (logout, or future admin kill).
  Chosen over stateless JWT because revocation is trivial and there's no signing-key/rotation footgun.
- **Where the code lives.** `cp-core::auth` owns the store logic (hashing, session CRUD — it touches
  core's `users`/`sessions` tables, core's data per §2). `cp-frontend` owns the HTTP/cookie layer
  (endpoints + a `CurrentUser` extractor) and calls `cp-core::auth`. Auth is *not* a kind capability
  (§13 is unchanged) — it resolves against `users`, exactly as §2 mandates.

## Schema (added to core's `0001_init.sql`)

```sql
ALTER-equivalent: users gains  password_hash TEXT   -- PHC string; NULL = no password (can't log in)

CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY,                       -- SHA-256 hex of the opaque cookie token
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at TEXT NOT NULL                           -- datetime('now','+30 days'); string-comparable
);
```

Note: `password_hash` is added *inside* the `CREATE TABLE users` (fresh DBs get it). A real
column-add on a populated table needs the versioned migrator (#7, still open); the scaffold's DBs are
throwaway, so this is consistent with "idempotent CREATE-IF-NOT-EXISTS, re-run every boot" for now.
Sessions store `expires_at` via sqlite `datetime()`, so expiry is a plain string comparison in SQL — no
Rust clock handling.

## `cp-core::auth` API (free fns over `&SqlitePool`, used by both the shell and the frontend)

```
set_password(pool, handle, password) -> Result<()>          // argon2 hash → users.password_hash; NotFound if no such handle
authenticate(pool, handle, password) -> Result<Option<User>> // verify; None on bad handle / bad pw / no pw set
create_session(pool, user_id) -> Result<String>             // returns the plaintext token (the cookie value)
resolve_session(pool, token) -> Result<Option<User>>        // hash → join sessions⋈users, WHERE not expired
delete_session(pool, token) -> Result<()>                   // logout
```

Token: 32 bytes from the OS CSPRNG (`argon2`'s re-exported `rand_core::OsRng`), hex-encoded for the
cookie; the DB row keys on its SHA-256 hex. `authenticate` runs argon2 verification, which is constant-
time within the hash; a missing user still returns `None` (a tiny timing asymmetry from skipping the
hash is acceptable for a private instance).

## HTTP surface (`cp-frontend`)

```
POST /api/auth/login   {handle, password}  -> 200 {id, handle} + Set-Cookie: cp_session=<token> (HttpOnly, SameSite=Lax, Path=/)
                                              | 401 on bad credentials
POST /api/auth/logout                       -> 204, clears the cookie + deletes the session row
GET  /api/auth/me                           -> 200 {id, handle} | 401 (drives the frontend's login state)
```

- **`CurrentUser` extractor** (`FromRequestParts<AppState>`): reads the `cp_session` cookie, calls
  `resolve_session`, yields the `User` or rejects `401`. `/me` uses it directly; future protected
  routes (writes, #18) reuse it. Cookies via `axum-extra`'s `CookieJar`.
- **Cookie flags:** `HttpOnly` + `SameSite=Lax` + `Path=/` always; `Secure` is gated on
  `CP_SECURE_COOKIES=1` (off for local http dev, on behind TLS) so the cookie isn't dropped over plain
  http during testing.

## Frontend (shell, not a kind island)

The type-agnostic shell (`index.astro`) gains a header auth widget: on load it `GET`s `/api/auth/me`;
`401` → a **login form** (handle + password → `POST /login`); `200` → "signed in as *handle*" + a
logout button. No register form (provisioned accounts). Login/logout re-render the widget.

## What this unblocks / defers

- **Unblocks #18 (permissions):** every request can now resolve a principal; a permission capability
  reads `CurrentUser`.
- **Deferred:** authenticated *write* endpoints (posting as a user) — they need #18 + a generic write
  API, out of scope here. Open self-signup, password reset, and Discord-OAuth linking (#19) are all
  additive and don't disturb this session model.

## What this touches

- **`cp-core`:** new `auth.rs` (argon2 + `sha2` deps); `users.password_hash` + a `sessions` table in
  `0001_init.sql`; `debug.rs` gains `set-password`. New `crates/cp-core/tests/auth.rs`.
- **`cp-frontend`:** new `auth.rs` (endpoints + `CurrentUser`), wired into the router; `axum-extra`
  (cookie) dep. New `crates/cp-frontend/tests/auth_flow.rs`.
- **`web/`:** the shell's auth widget.
- **Not touched:** kinds, the store's envelope path, the runtime.
