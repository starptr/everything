//! In-memory, single-use, time-limited upload tokens.
//!
//! A token is minted by the Discord bot when a member runs `/upload`, embedded in the link the
//! member opens, and consumed exactly once by the upload handler. Consuming removes it (single
//! use) and checks the TTL. Expiry is lazy -- there is no reaper task; a stale token just lives in
//! the map until something tries to consume it (then it is removed). For a per-member upload tool
//! the leftover-entry memory is negligible, and the whole store is disposable across restarts (a
//! member simply re-runs `/upload`).

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use uuid::Uuid;

/// How long a minted link stays valid.
const TTL: Duration = Duration::from_secs(15 * 60);

/// What a token authorizes: an upload whose result is announced back to the channel + member it
/// originated from.
#[derive(Clone, Copy, Debug)]
pub struct Pending {
    pub channel_id: u64,
    pub user_id: u64,
    expiry: Instant,
}

#[derive(Default)]
pub struct TokenStore {
    inner: Mutex<HashMap<String, Pending>>,
}

impl TokenStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Mint a single-use token bound to the originating channel + member.
    pub fn issue(&self, channel_id: u64, user_id: u64) -> String {
        let token = Uuid::new_v4().simple().to_string();
        let pending = Pending {
            channel_id,
            user_id,
            expiry: Instant::now() + TTL,
        };
        self.inner.lock().unwrap().insert(token.clone(), pending);
        token
    }

    /// Consume a token: remove it (single use) and return its binding iff it had not expired. A
    /// stale token is removed and reported invalid, so even a failed attempt burns it.
    pub fn consume(&self, token: &str) -> Option<Pending> {
        let pending = self.inner.lock().unwrap().remove(token)?;
        (Instant::now() < pending.expiry).then_some(pending)
    }

    /// Check whether a token is currently usable (present and unexpired) WITHOUT consuming it --
    /// used to gate serving the upload page so a guessed/expired/already-used link shows an error
    /// instead of the form. A token found expired is removed (lazy cleanup). The single-use
    /// guarantee still rests on `consume`: a page served here is only spent when its upload POSTs.
    pub fn is_valid(&self, token: &str) -> bool {
        let mut map = self.inner.lock().unwrap();
        match map.get(token) {
            Some(p) if Instant::now() < p.expiry => true,
            Some(_) => {
                map.remove(token);
                false
            }
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn issued_token_validates_then_is_single_use() {
        let store = TokenStore::new();
        let token = store.issue(111, 222);

        // is_valid must NOT consume: a live link can be opened/refreshed repeatedly before upload.
        assert!(store.is_valid(&token));
        assert!(store.is_valid(&token));

        // First consume returns the binding it was issued with...
        let pending = store
            .consume(&token)
            .expect("a freshly issued token must consume");
        assert_eq!(pending.channel_id, 111);
        assert_eq!(pending.user_id, 222);

        // ...and the token is now spent: not valid, not consumable again (no reuse).
        assert!(!store.is_valid(&token));
        assert!(store.consume(&token).is_none());
    }

    #[test]
    fn guessed_token_is_rejected() {
        let store = TokenStore::new();
        // A token that was never issued (a guessed link) is never valid or consumable.
        assert!(!store.is_valid("hello"));
        assert!(store.consume("hello").is_none());
    }

    #[test]
    fn expired_token_is_rejected_and_swept() {
        let store = TokenStore::new();
        let token = "already-expired".to_string();
        let already_expired = Pending {
            channel_id: 1,
            user_id: 2,
            expiry: Instant::now(), // a later now() is strictly greater -> treated as expired
        };
        store
            .inner
            .lock()
            .unwrap()
            .insert(token.clone(), already_expired);

        // is_valid rejects an expired token AND lazily sweeps it from the map.
        assert!(!store.is_valid(&token));
        assert!(!store.inner.lock().unwrap().contains_key(&token));

        // consume also rejects an expired token rather than handing back its binding.
        store
            .inner
            .lock()
            .unwrap()
            .insert(token.clone(), already_expired);
        assert!(store.consume(&token).is_none());
    }
}
