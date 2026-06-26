//! The Discord side: register the guild `/upload` command and, when invoked, mint a token and
//! reply (ephemerally) with the upload link.

use serenity::all::{
    CommandInteraction, Context, CreateCommand, CreateInteractionResponse,
    CreateInteractionResponseMessage, EventHandler, GuildId, Interaction, Ready,
};
use serenity::async_trait;

use crate::state::{AppState, AppStateKey};

pub struct Handler;

#[async_trait]
impl EventHandler for Handler {
    async fn ready(&self, ctx: Context, ready: Ready) {
        let state = app_state(&ctx).await;
        let guild = GuildId::new(state.cfg.discord_guild_id);
        // Guild-scoped commands register instantly (global ones take ~1h). set_commands replaces
        // the guild's command set with exactly ours, so re-deploys stay idempotent.
        let cmd = CreateCommand::new("upload").description("Get a link to upload a file to IPFS");
        match guild.set_commands(&ctx.http, vec![cmd]).await {
            Ok(_) => tracing::info!(
                "registered /upload in guild {} as {}",
                guild.get(),
                ready.user.name
            ),
            Err(e) => tracing::error!("failed to register /upload in guild {}: {e}", guild.get()),
        }
    }

    async fn interaction_create(&self, ctx: Context, interaction: Interaction) {
        let Interaction::Command(command) = interaction else {
            return;
        };
        if command.data.name != "upload" {
            return;
        }
        handle_upload(&ctx, &command).await;
    }
}

async fn handle_upload(ctx: &Context, command: &CommandInteraction) {
    let state = app_state(ctx).await;
    let token = state
        .store
        .issue(command.channel_id.get(), command.user.id.get());
    let link = format!(
        "{}/u/{}",
        state.cfg.app_base_url.trim_end_matches('/'),
        token
    );
    let msg = CreateInteractionResponseMessage::new()
        .ephemeral(true)
        .content(format!(
            "Upload a file here (single-use link, expires in 15 min):\n{link}"
        ));
    if let Err(e) = command
        .create_response(&ctx.http, CreateInteractionResponse::Message(msg))
        .await
    {
        tracing::error!("failed to reply to /upload: {e}");
    }
}

async fn app_state(ctx: &Context) -> AppState {
    ctx.data
        .read()
        .await
        .get::<AppStateKey>()
        .expect("AppState inserted into TypeMap at startup")
        .clone()
}
