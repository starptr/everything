use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::id::WorkstreamId;
use crate::source::HttpsGitUrl;

/// The `kind` discriminant stored on a basic workstream.
pub(crate) const BASIC_KIND: &str = "basic";

/// The core-reserved KV namespace holding a workstream's agent sessions.
/// Sessions are a special case of namespaced KV (see `DESIGN.md` §5): frontends
/// must not write here directly — they go through the session API (`Forest::`
/// `create_session`/`rename_session`/`remove_session`, i.e. `silverwood session`).
pub(crate) const SESSION_NS: &str = "app.andref.silverwood.session";

/// KV namespaces beginning with this prefix are reserved for silverwood core;
/// the public `Forest::set_kv`/`unset_kv` reject writes to them so a frontend
/// cannot corrupt core-owned state (today: [`SESSION_NS`]).
pub(crate) const RESERVED_NS_PREFIX: &str = "app.andref.silverwood.";

/// Lifecycle status of a workstream. Deletion is the `Archived` tombstone —
/// documents are never removed, so archival merges under future sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Active,
    Archived,
}

/// How a code-change is materialized on disk. Open enum: one mode today.
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

/// Which agent an [`AgentSession`] belongs to. Open enum: one kind today.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum AgentKind {
    /// A Claude Code session.
    ClaudeCode,
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

/// A code-change's stored configuration: the source it clones and the mode it is
/// materialized in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodeChange {
    /// The HTTPS source the checkout is cloned from.
    pub source: String,
    /// The mode the checkout is materialized in.
    pub mode: CheckoutMode,
}

/// A per-forest materialization of a workstream's code-change. Keyed by forest
/// id in the document, so two forests provisioning the same workstream never
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

/// A generic agent session associated with a workstream kind that supports them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentSession {
    /// Which agent this session belongs to.
    pub kind: AgentKind,
    /// Human-friendly name for the session.
    pub name: String,
    /// When the association was created (RFC3339).
    pub created_at: String,
}

/// The kind of a workstream — an open, tagged enum. Today the only kind is
/// [`WorkstreamKind::Basic`]; future kinds may hold different data.
///
/// Agent sessions are **not** part of the kind: they are stored as namespaced KV
/// under the core-reserved `app.andref.silverwood.session` namespace and are
/// therefore kind-agnostic (see `DESIGN.md` §5). Read them with
/// [`WorkstreamBody::sessions`].
///
/// The kind is fixed at creation and never changes (see `doc.rs` for the
/// merge-safety invariant that relies on this). Serialize-only + internally
/// tagged: the `kind` discriminant and the variant's fields flatten to the top
/// level of the workstream's `--json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
#[non_exhaustive]
pub enum WorkstreamKind {
    /// A code-change and its per-forest checkouts.
    Basic {
        /// The code-change this workstream is built around.
        code_change: CodeChange,
        /// Per-forest checkout materializations, keyed by forest id.
        checkouts: BTreeMap<String, Checkout>,
    },
}

impl WorkstreamKind {
    /// The stored `kind` discriminant for this variant (matches its serde tag).
    pub fn tag(&self) -> &'static str {
        match self {
            WorkstreamKind::Basic { .. } => BASIC_KIND,
        }
    }
}

/// The stored body of a workstream document — everything but its id (the id is
/// the document's key in the [`crate::DocStore`], not stored inside it).
///
/// Serialize-only: hydration builds this by hand from the on-disk shape, and no
/// caller deserializes it directly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorkstreamBody {
    /// Human-friendly name.
    pub name: String,
    /// Lifecycle status.
    pub status: Status,
    /// Creation timestamp (RFC3339), minted by core.
    pub created_at: String,
    /// The workstream's kind and its kind-specific data.
    #[serde(flatten)]
    pub kind: WorkstreamKind,
    /// Open frontend state: namespace → key → JSON-encoded value. Kind-agnostic.
    pub kv: BTreeMap<String, BTreeMap<String, String>>,
}

impl WorkstreamBody {
    /// The code-change, if this workstream's kind has one.
    pub fn code_change(&self) -> Option<&CodeChange> {
        match &self.kind {
            WorkstreamKind::Basic { code_change, .. } => Some(code_change),
        }
    }

    /// The per-forest checkouts, if this workstream's kind has them.
    pub fn checkouts(&self) -> Option<&BTreeMap<String, Checkout>> {
        match &self.kind {
            WorkstreamKind::Basic { checkouts, .. } => Some(checkouts),
        }
    }

    /// The agent sessions associated with this workstream, decoded from the
    /// core-reserved `app.andref.silverwood.session` KV namespace (sessions are
    /// stored as KV; this is the typed read view). Kind-agnostic; undecodable
    /// entries are skipped.
    pub fn sessions(&self) -> BTreeMap<String, AgentSession> {
        self.kv
            .get(SESSION_NS)
            .map(|entries| {
                entries
                    .iter()
                    .filter_map(|(session_id, encoded)| {
                        serde_json::from_str::<AgentSession>(encoded)
                            .ok()
                            .map(|session| (session_id.clone(), session))
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// A workstream: its stable id plus its stored body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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
    /// The kind to build the workstream around.
    pub kind: NewKind,
}

/// The kind to build a new workstream around.
#[derive(Debug, Clone)]
pub enum NewKind {
    /// A basic workstream: a code-change cloned from an HTTPS source in a mode.
    Basic {
        source: HttpsGitUrl,
        mode: CheckoutMode,
    },
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

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

    /// `WorkstreamKind::tag()` must match the serde `kind` discriminant, since
    /// the document stores the tag via `tag()` and reads it back as the `kind`.
    #[test]
    fn kind_tag_matches_serde() {
        let kind = WorkstreamKind::Basic {
            code_change: CodeChange {
                source: "https://example.com/x.git".into(),
                mode: CheckoutMode::JjColocated,
            },
            checkouts: BTreeMap::new(),
        };
        let json = serde_json::to_value(&kind).unwrap();
        assert_eq!(json["kind"], serde_json::json!(kind.tag()));
    }
}
