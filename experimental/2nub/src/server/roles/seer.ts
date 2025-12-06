import { RoleDefinition, GState, PlayerID } from "../types";
import { Ctx } from "boardgame.io";

const Seer: RoleDefinition = {
  id: "seer",
  name: "Seer",
  description: "Look at another player's card OR look at two center cards.",
  team: "village",
  nightAction: {
    uiPrompt: {
      type: "choosePlayer",
      min: 0,
      max: 1,
      label: "Choose a player to look at their card (or skip to look at center cards)",
      extraFields: {
        allowCenter: true,
        centerCount: 2
      }
    },
    validator: (G: GState, ctx: Ctx, payload: any) => {
      if (payload.target && payload.centerIndices) {
        return false;
      }
      if (payload.centerIndices && payload.centerIndices.length !== 2) {
        return false;
      }
      return true;
    },
    perform: (G: GState, ctx: Ctx, { actor, target, centerIndices }: { 
      actor: PlayerID; 
      target?: PlayerID; 
      centerIndices?: number[] 
    }) => {
      const actorState = G.players[actor];
      
      if (target) {
        const targetState = G.players[target];
        actorState.privateLog.push(
          `You looked at ${targetState.name}'s card: ${targetState.role}`
        );
      } else if (centerIndices) {
        const cards = centerIndices.map(i => G.center[i]);
        actorState.privateLog.push(
          `You looked at center cards ${centerIndices.map(i => i + 1).join(" and ")}: ${cards.join(", ")}`
        );
      }
    }
  }
};

export default Seer;