use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::id::{ForestId, WorkstreamId};
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

/// How a workstream's code-change is materialized on disk, together with the data
/// that is only meaningful *for that strategy* — its seed (`initial_source`) and its
/// provisioning `state`. A future mode that adopts an existing local directory, for
/// instance, would carry no source and be instantly ready; folding these fields into
/// the variant keeps `Basic` honest. Open, internally-tagged enum: one mode today.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "checkout_mode", rename_all = "kebab-case")]
#[non_exhaustive]
pub enum CheckoutMode {
    /// A jj/git colocated clone (`jj git clone --colocate`) of `initial_source`.
    JjColocated {
        /// The HTTPS git url the checkout was cloned from.
        initial_source: String,
        /// Provisioning state of the clone (core-owned lifecycle).
        state: CheckoutState,
    },
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
    /// The stored `checkout_mode` discriminant for this variant (matches its serde tag).
    pub fn tag(&self) -> &'static str {
        match self {
            CheckoutMode::JjColocated { .. } => "jj-colocated",
        }
    }

    /// The provisioning state of this checkout.
    pub fn state(&self) -> CheckoutState {
        match self {
            CheckoutMode::JjColocated { state, .. } => *state,
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

/// Where a workstream's checkout physically lives: which forest materialized it,
/// and — polymorphic over forest kind — where inside that forest. A basic
/// workstream is materialized in a single forest, so this is one value, not a
/// per-forest map.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Location {
    /// The forest that materialized this checkout.
    pub forest_id: ForestId,
    /// The forest-kind-specific location within that forest.
    pub within: LocationWithinForest,
}

/// A checkout's location within a forest, polymorphic over *forest kind* (an axis
/// independent of [`CheckoutMode`]'s materialization-strategy axis). Open,
/// internally-tagged enum: one forest kind today.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "forest_kind", rename_all = "kebab-case")]
#[non_exhaustive]
pub enum LocationWithinForest {
    /// A basic forest: an absolute path to the checked-out working copy.
    BasicForest {
        /// Absolute path to the working copy.
        path: String,
    },
}

impl LocationWithinForest {
    /// The stored `forest_kind` discriminant for this variant (matches its serde tag).
    pub fn tag(&self) -> &'static str {
        match self {
            LocationWithinForest::BasicForest { .. } => "basic-forest",
        }
    }
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
    /// A materialized code-change: how it is checked out (mode, carrying its seed +
    /// provisioning state) and where it lives (location). Single-forest by design.
    Basic {
        /// How the code-change is materialized, plus its seed + provisioning state.
        mode: CheckoutMode,
        /// Where the checkout physically lives.
        location: Location,
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
    /// The checkout mode (with its seed + state), if this workstream's kind has one.
    pub fn mode(&self) -> Option<&CheckoutMode> {
        match &self.kind {
            WorkstreamKind::Basic { mode, .. } => Some(mode),
        }
    }

    /// The checkout location, if this workstream's kind has one.
    pub fn location(&self) -> Option<&Location> {
        match &self.kind {
            WorkstreamKind::Basic { location, .. } => Some(location),
        }
    }

    /// The provisioning state, if this workstream's kind has a checkout.
    pub fn state(&self) -> Option<CheckoutState> {
        self.mode().map(CheckoutMode::state)
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
    /// A basic workstream, materialized by a checkout mode.
    Basic {
        /// How to materialize the checkout (carries its seed; `state` is core-owned).
        mode: NewCheckoutMode,
    },
}

/// Creation-side counterpart to [`CheckoutMode`]: the caller supplies the
/// mode-specific seed, but never the provisioning `state` (core owns that
/// lifecycle — it mints `pending` then flips to `ready`/`failed`). Mirrors the
/// [`NewKind`]/[`WorkstreamKind`] split.
#[derive(Debug, Clone)]
pub enum NewCheckoutMode {
    /// A jj/git colocated clone from an HTTPS source.
    JjColocated {
        /// The HTTPS git url to clone.
        initial_source: HttpsGitUrl,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The hand-written `as_str`/`tag` forms must match the serde string forms,
    /// since the document is written via them and read back via serde.
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
        // Data-carrying enums: the internally-tagged discriminant must match tag().
        let mode = CheckoutMode::JjColocated {
            initial_source: "https://example.com/x.git".into(),
            state: CheckoutState::Ready,
        };
        assert_eq!(
            serde_json::to_value(&mode).unwrap()["checkout_mode"],
            serde_json::json!(mode.tag())
        );
        let within = LocationWithinForest::BasicForest {
            path: "/tmp/x".into(),
        };
        assert_eq!(
            serde_json::to_value(&within).unwrap()["forest_kind"],
            serde_json::json!(within.tag())
        );
    }

    /// `WorkstreamKind::tag()` must match the serde `kind` discriminant, since
    /// the document stores the tag via `tag()` and reads it back as the `kind`.
    #[test]
    fn kind_tag_matches_serde() {
        let kind = WorkstreamKind::Basic {
            mode: CheckoutMode::JjColocated {
                initial_source: "https://example.com/x.git".into(),
                state: CheckoutState::Pending,
            },
            location: Location {
                forest_id: ForestId::generate(),
                within: LocationWithinForest::BasicForest {
                    path: "/tmp/x".into(),
                },
            },
        };
        let json = serde_json::to_value(&kind).unwrap();
        assert_eq!(json["kind"], serde_json::json!(kind.tag()));
    }
}
