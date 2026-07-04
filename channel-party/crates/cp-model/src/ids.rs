//! Identifiers. Envelope ids are ULIDs (time-ordered), so a channel feed sorts by id with no
//! mandated `timestamp` field and "jump to timestamp T" is a seek to the ULID whose time prefix
//! is T. See DESIGN §3.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use ulid::Ulid;

/// A type discriminator, e.g. `"discord-compatible/channel"` or `"basic"`. Kinds are grouped by
/// namespace (the segment before the first `/`), not by leaf. §4.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TypeId(pub String);

impl TypeId {
    pub fn new(s: impl Into<String>) -> Self {
        Self(s.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The namespace segment before the first `/`, or the whole string if there is none.
    pub fn namespace(&self) -> &str {
        self.0.split('/').next().unwrap_or(&self.0)
    }
}

impl fmt::Display for TypeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<&str> for TypeId {
    fn from(s: &str) -> Self {
        Self(s.to_owned())
    }
}

/// Defines a ULID-backed id newtype with serde, `Display`, `FromStr`, and a `generate` constructor.
macro_rules! ulid_id {
    ($(#[$m:meta])* $name:ident) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
        pub struct $name(pub Ulid);

        impl $name {
            /// Mint a fresh time-ordered id.
            pub fn generate() -> Self {
                Self(Ulid::new())
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "{}", self.0)
            }
        }

        impl FromStr for $name {
            type Err = ulid::DecodeError;
            fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
                Ok(Self(Ulid::from_string(s)?))
            }
        }
    };
}

ulid_id!(
    /// Identifies a `channels` row. §3.
    ChannelId
);
ulid_id!(
    /// Identifies an `items` row. §3.
    ItemId
);
ulid_id!(
    /// Identifies a native `users` row — the only real principal. §2.
    UserId
);
