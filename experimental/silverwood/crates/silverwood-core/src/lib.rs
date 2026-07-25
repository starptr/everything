//! `silverwood-core` — the frontend-agnostic backend for code/agent workstreams.
//!
//! A [`Forest`] is one local instance of silverwood state (by default the
//! directory `~/.silverwood`). It owns a set of workstreams, each persisted as
//! its own document via a [`DocStore`]. This crate is the real API; frontends
//! (including the CLI) are thin layers over it. See `DESIGN.md`.
//!
//! Part 0 established the skeleton (identity, config, [`DocStore`],
//! [`Forest::open`]). Part 1 adds the workstream document — one Loro document
//! per workstream — and the basic workstream kind (a checkout mode with
//! jj-colocated provisioning + a single-forest location, plus agent sessions).

mod apfs;
mod claude;
mod config;
mod doc;
mod docstore;
mod error;
mod forest;
mod id;
mod migrate;
mod provider;
mod source;
mod spawn;
mod workstream;

#[cfg(test)]
mod tests;

pub use claude::claude_conversation_exists;
pub use config::ForestConfig;
pub use docstore::{DocStore, FilesDocStore};
pub use error::{Error, Result};
pub use forest::{Forest, UpgradeReport};
pub use id::{ForestId, WorkstreamId};
pub use migrate::DOC_SCHEMA_VERSION;
pub use provider::{CheckoutProvider, JjColocated};
pub use source::{AbsolutePath, HttpsGitUrl};
pub use spawn::{agent_shell_plan, base_shell_plan, ShellPlan, SpawnSeed};
pub use workstream::{
    AgentKind, AgentSession, CheckoutMode, CheckoutState, DoctorReport, Location,
    LocationWithinForest, NewCheckoutMode, NewKind, NewWorkstream, SessionLock, Status, Workstream,
    WorkstreamBody, WorkstreamKind,
};
