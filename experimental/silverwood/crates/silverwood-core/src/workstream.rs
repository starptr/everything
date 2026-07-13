use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::id::WorkstreamId;
use crate::source::HttpsGitUrl;

/// The `kind` stored on a code-checkout workstream.
pub(crate) const CODE_CHECKOUT_KIND: &str = "code-checkout";

/// Lifecycle status of a workstream. Deletion is the `Archived` tombstone —
/// documents are never removed, so archival merges under future sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Active,
    Archived,
}

/// How a code-checkout is materialized on disk. Open enum: one mode today.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum CheckoutMode {
    /// Clone into a jj/git colocated repository (`jj git clone --colocate`).
    JjColocated,
}

/// Provisioning state of a per-forest checkout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CheckoutState {
    /// The document exists; the working copy is not yet provisioned.
    Pending,
    /// The working copy has been provisioned successfully.
    Ready,
    /// Provisioning failed; the workstream is recoverable.
    Failed,
}

impl Status {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Status::Active => "active",
            Status::Archived => "archived",
        }
    }
}

impl CheckoutMode {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            CheckoutMode::JjColocated => "jj-colocated",
        }
    }
}

impl CheckoutState {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            CheckoutState::Pending => "pending",
            CheckoutState::Ready => "ready",
            CheckoutState::Failed => "failed",
        }
    }
}

/// The code-checkout primitive's stored configuration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckoutPrimitive {
    /// The HTTPS source the checkout is cloned from.
    pub source: String,
    /// The mode the checkout was created with.
    pub mode: CheckoutMode,
}

/// A per-forest materialization of a workstream's checkout. Keyed by forest id
/// in the document, so two forests provisioning the same workstream never
/// conflict.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Checkout {
    /// Absolute path to the working copy on the owning forest.
    pub location: String,
    /// Provisioning state.
    pub state: CheckoutState,
    /// The mode this checkout was provisioned with.
    pub mode: CheckoutMode,
}

/// A Claude Code session associated with a workstream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    /// Human-friendly name for the session.
    pub name: String,
    /// When the association was created (RFC3339).
    pub created_at: String,
}

/// The stored body of a workstream document — everything but its id (the id is
/// the document's key in the [`crate::DocStore`], not stored inside it).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkstreamBody {
    /// Human-friendly name.
    pub name: String,
    /// Lifecycle status.
    pub status: Status,
    /// Primitive kind (`"code-checkout"`).
    pub kind: String,
    /// Creation timestamp (RFC3339), minted by core.
    pub created_at: String,
    /// The code-checkout primitive configuration.
    pub primitive: CheckoutPrimitive,
    /// Per-forest checkout materializations, keyed by forest id.
    #[serde(default)]
    pub checkouts: BTreeMap<String, Checkout>,
    /// Associated Claude sessions, keyed by session id.
    #[serde(default)]
    pub sessions: BTreeMap<String, Session>,
    /// Open frontend state: namespace → key → JSON-encoded value.
    #[serde(default)]
    pub kv: BTreeMap<String, BTreeMap<String, String>>,
}

/// A workstream: its stable id plus its stored body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workstream {
    /// Stable id (also the document key).
    pub id: WorkstreamId,
    /// The stored document body.
    #[serde(flatten)]
    pub body: WorkstreamBody,
}

/// Parameters to create a workstream. Every field is explicit — core supplies
/// no defaults (see `DESIGN.md` §2.4).
#[derive(Debug, Clone)]
pub struct NewWorkstream {
    /// Human-friendly name.
    pub name: String,
    /// The primitive to build the workstream around.
    pub primitive: NewPrimitive,
}

/// The primitive to build a new workstream around.
#[derive(Debug, Clone)]
pub enum NewPrimitive {
    /// A code-checkout cloned from an HTTPS source in a given mode.
    CodeCheckout {
        source: HttpsGitUrl,
        mode: CheckoutMode,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The hand-written `as_str` forms must match the serde string forms, since
    /// the document is written via `as_str` and read back via serde.
    #[test]
    fn as_str_matches_serde() {
        assert_eq!(
            serde_json::to_value(Status::Active).unwrap(),
            serde_json::json!(Status::Active.as_str())
        );
        assert_eq!(
            serde_json::to_value(Status::Archived).unwrap(),
            serde_json::json!(Status::Archived.as_str())
        );
        assert_eq!(
            serde_json::to_value(CheckoutMode::JjColocated).unwrap(),
            serde_json::json!(CheckoutMode::JjColocated.as_str())
        );
        for state in [
            CheckoutState::Pending,
            CheckoutState::Ready,
            CheckoutState::Failed,
        ] {
            assert_eq!(
                serde_json::to_value(state).unwrap(),
                serde_json::json!(state.as_str())
            );
        }
    }
}
