//! `silverwood-core` — the frontend-agnostic backend for code/agent workstreams.
//!
//! A [`Forest`] is one local instance of silverwood state (by default the
//! directory `~/.silverwood`). It owns a set of workstreams, each persisted as
//! its own document via a [`DocStore`]. This crate is the real API; frontends
//! (including the CLI) are thin layers over it. See `DESIGN.md`.
//!
//! Part 0 establishes the skeleton: identity types, the forest config, the
//! [`DocStore`] abstraction with a files-per-document backend, and
//! [`Forest::open`]. Workstream documents and provisioning arrive in Part 1.

mod config;
mod docstore;
mod error;
mod forest;
mod id;

pub use config::ForestConfig;
pub use docstore::{DocStore, FilesDocStore};
pub use error::{Error, Result};
pub use forest::Forest;
pub use id::{ForestId, WorkstreamId};
