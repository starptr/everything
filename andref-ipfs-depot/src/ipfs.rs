//! The one kubo RPC call we make: add a file (pinned) and turn its CID into a gateway URL.

use serde::Deserialize;

use crate::state::AppState;

/// kubo's `/api/v0/add` reply for a single file (one JSON object per added file).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct AddResponse {
    hash: String,
}

#[derive(Debug)]
pub enum IpfsError {
    Http(reqwest::Error),
    /// kubo returned a body we could not parse as an add result.
    BadResponse(String),
}

impl std::fmt::Display for IpfsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            IpfsError::Http(e) => write!(f, "kubo request failed: {e}"),
            IpfsError::BadResponse(e) => write!(f, "unexpected kubo response: {e}"),
        }
    }
}

impl std::error::Error for IpfsError {}

impl From<reqwest::Error> for IpfsError {
    fn from(e: reqwest::Error) -> Self {
        IpfsError::Http(e)
    }
}

/// Upload `bytes` to kubo, pinned, as a CIDv1 (base32 -- required so the CID is a DNS-safe
/// subdomain label). Returns the resulting CID.
pub async fn add(state: &AppState, filename: String, bytes: Vec<u8>) -> Result<String, IpfsError> {
    let part = reqwest::multipart::Part::bytes(bytes)
        .file_name(filename)
        .mime_str("application/octet-stream")?;
    let form = reqwest::multipart::Form::new().part("file", part);

    let url = format!(
        "{}/api/v0/add",
        state.cfg.kubo_rpc_base.trim_end_matches('/')
    );
    let body = state
        .kubo
        .post(url)
        // pin=true so this NoFetch, pinned-only node serves + announces it; cid-version=1 so the
        // CID is base32 and works as <cid>.ipfs.andref.app.
        .query(&[("pin", "true"), ("cid-version", "1")])
        .bearer_auth(&state.cfg.kubo_rpc_token)
        .multipart(form)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;

    // `add` streams newline-delimited JSON (one object per file, plus progress objects); the final
    // non-empty line carries the root file's result.
    let last = body
        .lines()
        .map(str::trim)
        .rfind(|l| !l.is_empty())
        .ok_or_else(|| IpfsError::BadResponse("empty body".to_string()))?;
    let parsed: AddResponse =
        serde_json::from_str(last).map_err(|e| IpfsError::BadResponse(e.to_string()))?;
    Ok(parsed.hash)
}

/// `https://<cid>.<gateway_base_domain>` -- the direct subdomain-gateway link to the file.
pub fn gateway_url(state: &AppState, cid: &str) -> String {
    format!("https://{}.{}", cid, state.cfg.gateway_base_domain)
}
