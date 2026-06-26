//! Shared application state, cloned into both the Discord event handler and the axum router.

use std::sync::Arc;

use serenity::http::Http;

use crate::config::Config;
use crate::tokens::TokenStore;

/// Cheap to clone: every field is an `Arc` (or `reqwest::Client`, which is itself `Arc`-backed).
#[derive(Clone)]
pub struct AppState {
    pub cfg: Arc<Config>,
    /// HTTP client for the kubo RPC.
    pub kubo: reqwest::Client,
    /// serenity's Discord HTTP client, so the upload handler can post the result to the channel.
    pub discord: Arc<Http>,
    pub store: Arc<TokenStore>,
}

/// serenity stores per-client data in a typed map; this key hands the handler its `AppState`.
pub struct AppStateKey;

impl serenity::prelude::TypeMapKey for AppStateKey {
    type Value = AppState;
}
