use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Separator between the scheme token and its value in a workstream id's canonical
/// string form (`uuidv7_<uuid>`). Underscore is safe in filenames and URL path
/// segments and never occurs in a UUID, so `split_once` is unambiguous.
const SCHEME_SEP: char = '_';

/// Stable identity of a [`crate::Forest`], used (via the derived Loro peer id)
/// to attribute edits. Local to a forest and never synced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ForestId(pub Uuid);

/// The UID scheme of a [`WorkstreamId`]. UUIDv7 is the only scheme today; other
/// universal UID schemes may be introduced alongside it later. A scheme-less id is
/// interpreted as the deprecated implicit UUIDv7.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum IdScheme {
    /// Time-ordered UUIDv7, rendered `uuidv7_<uuid>`.
    Uuidv7,
}

impl IdScheme {
    /// Scheme token used in the canonical `<scheme>_<value>` string form.
    const UUIDV7_TOKEN: &'static str = "uuidv7";

    fn token(self) -> &'static str {
        match self {
            IdScheme::Uuidv7 => Self::UUIDV7_TOKEN,
        }
    }
}

/// Stable identity of a workstream. Doubles as its document's name in a
/// [`crate::DocStore`]. A two-part id: a UID `scheme` plus that scheme's `value`.
/// Today the only scheme is [`IdScheme::Uuidv7`], whose value is a time-ordered
/// UUID, so ids within a scheme roughly sort by creation.
///
/// The canonical string form is **explicit** — `uuidv7_<uuid>`. A bare,
/// scheme-less UUID is a *deprecated implicit* uuidv7: accepted only when reading
/// pre-existing on-disk names (via the crate-internal `parse_storage_key`), never
/// on user/API input (see [`FromStr`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(into = "String", try_from = "String")]
pub struct WorkstreamId {
    scheme: IdScheme,
    value: Uuid,
}

impl ForestId {
    /// Mint a fresh, time-ordered forest id.
    pub fn generate() -> Self {
        Self(Uuid::now_v7())
    }
}

impl WorkstreamId {
    /// Mint a fresh, time-ordered (UUIDv7) workstream id.
    pub fn generate() -> Self {
        Self {
            scheme: IdScheme::Uuidv7,
            value: Uuid::now_v7(),
        }
    }

    /// This id's UID scheme.
    pub fn scheme(&self) -> IdScheme {
        self.scheme
    }

    /// The scheme's underlying UUID value (UUIDv7 is the only scheme today).
    pub fn uuid(&self) -> Uuid {
        self.value
    }

    /// The canonical explicit stem naming this id's on-disk artifacts (document
    /// file, checkout dir). Always scheme-prefixed — new workstreams are written
    /// under this; [`Self::parse_storage_key`] is the matching lenient reader.
    pub(crate) fn storage_key(&self) -> String {
        self.to_string()
    }

    /// Parse a storage-layer id stem (a filename stem or path component).
    /// **Lenient:** an explicit `<scheme>_<value>` stem parses by scheme, while a
    /// stem with no separator is assumed to be a deprecated implicit UUIDv7 — so
    /// pre-existing bare on-disk names keep resolving without a rename.
    pub(crate) fn parse_storage_key(stem: &str) -> Result<Self, ParseWorkstreamIdError> {
        match stem.split_once(SCHEME_SEP) {
            Some((token, value)) => Self::from_scheme_token(token, value),
            None => Ok(Self {
                scheme: IdScheme::Uuidv7,
                value: parse_uuid(stem)?,
            }),
        }
    }

    /// Build from an explicit scheme token + value string, shared by [`FromStr`]
    /// and [`Self::parse_storage_key`]. Rejects unrecognized scheme tokens.
    fn from_scheme_token(token: &str, value: &str) -> Result<Self, ParseWorkstreamIdError> {
        match token {
            IdScheme::UUIDV7_TOKEN => Ok(Self {
                scheme: IdScheme::Uuidv7,
                value: parse_uuid(value)?,
            }),
            other => Err(ParseWorkstreamIdError::UnknownScheme(other.to_string())),
        }
    }
}

fn parse_uuid(s: &str) -> Result<Uuid, ParseWorkstreamIdError> {
    Uuid::parse_str(s).map_err(ParseWorkstreamIdError::InvalidUuid)
}

impl fmt::Display for ForestId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl fmt::Display for WorkstreamId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}{}{}", self.scheme.token(), SCHEME_SEP, self.value)
    }
}

impl FromStr for WorkstreamId {
    type Err = ParseWorkstreamIdError;

    /// Parse a **canonical explicit** id (`uuidv7_<uuid>`). Strict: a bare,
    /// scheme-less UUID is rejected as the deprecated implicit form.
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.split_once(SCHEME_SEP) {
            Some((token, value)) => Self::from_scheme_token(token, value),
            None => Err(ParseWorkstreamIdError::MissingScheme),
        }
    }
}

impl From<WorkstreamId> for String {
    fn from(id: WorkstreamId) -> String {
        id.to_string()
    }
}

impl TryFrom<String> for WorkstreamId {
    type Error = ParseWorkstreamIdError;

    fn try_from(s: String) -> Result<Self, Self::Error> {
        s.parse()
    }
}

/// Failure parsing a [`WorkstreamId`] from its string form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseWorkstreamIdError {
    /// A bare, scheme-less id was supplied where an explicit one is required. The
    /// implicit form is deprecated; ids must carry a scheme, e.g. `uuidv7_<uuid>`.
    MissingScheme,
    /// The scheme token is not a recognized UID scheme.
    UnknownScheme(String),
    /// The scheme's value was not a valid UUID.
    InvalidUuid(uuid::Error),
}

impl fmt::Display for ParseWorkstreamIdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingScheme => write!(
                f,
                "missing id scheme (bare ids are deprecated); prefix with `{}{}`",
                IdScheme::UUIDV7_TOKEN,
                SCHEME_SEP
            ),
            Self::UnknownScheme(token) => write!(f, "unknown id scheme {token:?}"),
            Self::InvalidUuid(e) => write!(f, "invalid uuid: {e}"),
        }
    }
}

impl std::error::Error for ParseWorkstreamIdError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::InvalidUuid(e) => Some(e),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_uuid() -> Uuid {
        Uuid::parse_str("01999999-0000-7000-8000-000000000000").unwrap()
    }

    #[test]
    fn display_is_canonical_explicit() {
        let id = WorkstreamId {
            scheme: IdScheme::Uuidv7,
            value: sample_uuid(),
        };
        assert_eq!(
            id.to_string(),
            "uuidv7_01999999-0000-7000-8000-000000000000"
        );
    }

    #[test]
    fn from_str_round_trips_explicit() {
        let s = "uuidv7_01999999-0000-7000-8000-000000000000";
        let id: WorkstreamId = s.parse().unwrap();
        assert_eq!(id.scheme(), IdScheme::Uuidv7);
        assert_eq!(id.uuid(), sample_uuid());
        assert_eq!(id.to_string(), s);
    }

    #[test]
    fn from_str_rejects_bare_uuid() {
        let err = "01999999-0000-7000-8000-000000000000"
            .parse::<WorkstreamId>()
            .unwrap_err();
        assert_eq!(err, ParseWorkstreamIdError::MissingScheme);
    }

    #[test]
    fn from_str_rejects_unknown_scheme() {
        let err = "ulid_01999999-0000-7000-8000-000000000000"
            .parse::<WorkstreamId>()
            .unwrap_err();
        assert!(matches!(err, ParseWorkstreamIdError::UnknownScheme(s) if s == "ulid"));
    }

    #[test]
    fn from_str_rejects_bad_uuid() {
        let err = "uuidv7_not-a-uuid".parse::<WorkstreamId>().unwrap_err();
        assert!(matches!(err, ParseWorkstreamIdError::InvalidUuid(_)));
    }

    #[test]
    fn storage_key_is_explicit_and_round_trips() {
        let id = WorkstreamId::generate();
        let key = id.storage_key();
        assert!(key.starts_with("uuidv7_"));
        assert_eq!(WorkstreamId::parse_storage_key(&key).unwrap(), id);
    }

    #[test]
    fn parse_storage_key_assumes_uuidv7_for_bare_stem() {
        let bare = "01999999-0000-7000-8000-000000000000";
        let id = WorkstreamId::parse_storage_key(bare).unwrap();
        assert_eq!(id.scheme(), IdScheme::Uuidv7);
        assert_eq!(id.uuid(), sample_uuid());
    }

    #[test]
    fn ord_follows_uuid_value_order() {
        // Within a scheme, `Ord` sorts by the UUID value; UUIDv7's leading
        // timestamp bytes make that a creation-time order. Use two fixed uuids
        // differing only in the low bytes for a deterministic check.
        let earlier = WorkstreamId {
            scheme: IdScheme::Uuidv7,
            value: Uuid::parse_str("01999999-0000-7000-8000-000000000001").unwrap(),
        };
        let later = WorkstreamId {
            scheme: IdScheme::Uuidv7,
            value: Uuid::parse_str("01999999-0000-7000-8000-000000000002").unwrap(),
        };
        assert!(later > earlier);
    }

    #[test]
    fn serde_uses_canonical_string() {
        let id = WorkstreamId {
            scheme: IdScheme::Uuidv7,
            value: sample_uuid(),
        };
        let json = serde_json::to_string(&id).unwrap();
        assert_eq!(json, "\"uuidv7_01999999-0000-7000-8000-000000000000\"");
        let back: WorkstreamId = serde_json::from_str(&json).unwrap();
        assert_eq!(back, id);
    }
}
