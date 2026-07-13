//! `silverwood-core` — the frontend-agnostic backend for code/agent workstreams.
//!
//! A [`Forest`] is one local instance of silverwood state (by default the
//! directory `~/.silverwood`). It owns a set of workstreams, each persisted as
//! its own document via a [`DocStore`]. This crate is the real API; frontends
//! (including the CLI) are thin layers over it. See `DESIGN.md`.
//!
//! Part 0 established the skeleton (identity, config, [`DocStore`],
//! [`Forest::open`]). Part 1 adds the workstream document — one Loro document
//! per workstream — and the basic workstream kind (a code-change with
//! jj-colocated provisioning, plus per-forest checkouts and agent sessions).

mod config;
mod doc;
mod docstore;
mod error;
mod forest;
mod id;
mod provider;
mod source;
mod workstream;

pub use config::ForestConfig;
pub use docstore::{DocStore, FilesDocStore};
pub use error::{Error, Result};
pub use forest::Forest;
pub use id::{ForestId, WorkstreamId};
pub use provider::{CheckoutProvider, JjColocated};
pub use source::HttpsGitUrl;
pub use workstream::{
    AgentKind, AgentSession, Checkout, CheckoutMode, CheckoutState, CodeChange, NewKind,
    NewWorkstream, Status, Workstream, WorkstreamBody, WorkstreamKind,
};
