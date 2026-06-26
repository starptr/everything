//! Process configuration, read once from the environment at startup.

/// All runtime configuration. Every field is required; `from_env` fails fast naming the missing
/// variable rather than letting the app start half-configured.
#[derive(Clone, Debug)]
pub struct Config {
    /// Discord bot token (gateway + HTTP credential).
    pub discord_bot_token: String,
    /// The single guild the `/upload` command is registered in.
    pub discord_guild_id: u64,
    /// Base URL of the kubo RPC API, e.g. `http://kubo.default.svc.cluster.local:5001`.
    pub kubo_rpc_base: String,
    /// Bearer token, scoped in kubo's `API.Authorizations` to `/api/v0/add`.
    pub kubo_rpc_token: String,
    /// Subdomain-gateway base, e.g. `ipfs.andref.app`; links are `https://<cid>.<this>`.
    pub gateway_base_domain: String,
    /// Public base URL of this app, e.g. `https://depot.andref.app`; the upload link is `<this>/u/<token>`.
    pub app_base_url: String,
    /// `host:port` the HTTP server binds, e.g. `0.0.0.0:8080`.
    pub bind_addr: String,
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        Ok(Self {
            discord_bot_token: req("DISCORD_BOT_TOKEN")?,
            discord_guild_id: req("DISCORD_GUILD_ID")?
                .parse()
                .map_err(|_| "DISCORD_GUILD_ID must be a u64".to_string())?,
            kubo_rpc_base: req("KUBO_RPC_BASE")?,
            kubo_rpc_token: req("KUBO_RPC_TOKEN")?,
            gateway_base_domain: req("GATEWAY_BASE_DOMAIN")?,
            app_base_url: req("APP_BASE_URL")?,
            bind_addr: req("BIND_ADDR")?,
        })
    }
}

fn req(key: &str) -> Result<String, String> {
    std::env::var(key).map_err(|_| format!("missing required env var {key}"))
}
