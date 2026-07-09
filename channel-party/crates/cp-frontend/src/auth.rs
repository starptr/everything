//! HTTP auth: login / logout / me + the `CurrentUser` extractor (DESIGN §2, `design/auth.md`, #17).
//! The store logic (hashing, sessions) is `cp_core::auth`; this is the cookie + endpoint layer. Accounts
//! are shell-provisioned — there is no registration route.

use axum::extract::{FromRequestParts, State};
use axum::http::request::Parts;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use cp_model::User;
use serde::Deserialize;
use serde_json::json;

use crate::AppState;

/// The session cookie name.
const COOKIE: &str = "cp_session";

#[derive(Deserialize)]
pub struct LoginBody {
    handle: String,
    password: String,
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(json!({ "error": "unauthenticated" })),
    )
        .into_response()
}

fn internal_error(e: cp_model::Error) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({ "error": e.to_string() })),
    )
        .into_response()
}

/// Build the session cookie. `HttpOnly` + `SameSite=Lax` + `Path=/` always; `Secure` only when
/// `CP_SECURE_COOKIES=1` (so it isn't dropped over plain http in local dev, but is set behind TLS).
fn session_cookie(token: String) -> Cookie<'static> {
    let mut cookie = Cookie::new(COOKIE, token);
    cookie.set_http_only(true);
    cookie.set_same_site(SameSite::Lax);
    cookie.set_path("/");
    if std::env::var("CP_SECURE_COOKIES").as_deref() == Ok("1") {
        cookie.set_secure(true);
    }
    cookie
}

/// `POST /api/auth/login {handle, password}` → 200 + `Set-Cookie` on success, 401 on bad credentials.
pub async fn login(
    State(state): State<AppState>,
    jar: CookieJar,
    Json(body): Json<LoginBody>,
) -> Response {
    let pool = state.core.store();
    let pool = pool.pool();
    match cp_core::auth::authenticate(pool, &body.handle, &body.password).await {
        Ok(Some(user)) => match cp_core::auth::create_session(pool, user.id).await {
            Ok(token) => (jar.add(session_cookie(token)), Json(user)).into_response(),
            Err(e) => internal_error(e),
        },
        Ok(None) => unauthorized(),
        Err(e) => internal_error(e),
    }
}

/// `POST /api/auth/logout` → revokes the session (if any) and clears the cookie. Always 204.
pub async fn logout(State(state): State<AppState>, jar: CookieJar) -> Response {
    if let Some(cookie) = jar.get(COOKIE) {
        let store = state.core.store();
        let _ = cp_core::auth::delete_session(store.pool(), cookie.value()).await;
    }
    let mut removal = Cookie::new(COOKIE, "");
    removal.set_path("/");
    removal.make_removal();
    (jar.add(removal), StatusCode::NO_CONTENT).into_response()
}

/// `GET /api/auth/me` → the current user, or 401 (the extractor rejects an absent/expired session).
pub async fn me(CurrentUser(user): CurrentUser) -> Response {
    Json(user).into_response()
}

/// The authenticated principal, resolved from the session cookie. Rejects `401` when there is no valid
/// session. Reuse this on any future protected route (writes, permissions #18). §2/§17.
pub struct CurrentUser(pub User);

impl FromRequestParts<AppState> for CurrentUser {
    type Rejection = Response;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let jar = CookieJar::from_headers(&parts.headers);
        let Some(token) = jar.get(COOKIE).map(|c| c.value().to_owned()) else {
            return Err(unauthorized());
        };
        let store = state.core.store();
        match cp_core::auth::resolve_session(store.pool(), &token).await {
            Ok(Some(user)) => Ok(CurrentUser(user)),
            Ok(None) => Err(unauthorized()),
            Err(e) => Err(internal_error(e)),
        }
    }
}
