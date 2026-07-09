//! Authorization dispatch (DESIGN §18, `design/permissions.md`). One generic resolver, mirroring
//! `contents::dispatch`: it resolves the channel's kind and asks its `Permission` capability. Core holds
//! no policy — the answer is the kind's. Deny-by-default: a kind with no `Permission` authorizes no one.

use cp_model::{Action, Channel, Result, StoreCtx, UserId};

use crate::registry::Registry;

/// May `user` perform `action` on `channel`? `Ok(false)` when the channel's kind is unknown or declares
/// no `Permission` capability (deny-by-default, §18); otherwise the kind's own decision.
pub async fn authorize(
    registry: &Registry,
    store: &dyn StoreCtx,
    channel: &Channel,
    user: UserId,
    action: Action,
) -> Result<bool> {
    match registry
        .channel(&channel.type_id)
        .and_then(|kind| kind.permission())
    {
        Some(policy) => policy.authorize(store, channel, user, action).await,
        None => Ok(false),
    }
}
