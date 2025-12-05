import { RoleDefinition, GState, PlayerID } from "../types";
import { Ctx } from "boardgame.io";

const Robber: RoleDefinition = {
  id: "robber",
  name: "Robber",
  description: "You may swap your role with another player's and look at your new role.",
  team: "village",
  nightAction: {
    uiPrompt: {
      type: "choosePlayer",
      min: 0,
      max: 1,
      label: "Choose a player to rob (swap roles) or skip"
    },
    validator: (G: GState, ctx: Ctx, payload: any) => {
      if (payload.target === ctx.currentPlayer) {
        return false;
      }
      return true;
    },
    perform: (G: GState, ctx: Ctx, { actor, target }: { 
      actor: PlayerID; 
      target?: PlayerID 
    }) => {
      const actorState = G.players[actor];
      
      if (target) {
        const targetState = G.players[target];
        const actorRole = actorState.role;
        actorState.role = targetState.role;
        targetState.role = actorRole;
        
        actorState.privateLog.push(
          `You swapped roles with ${targetState.name}. Your new role: ${actorState.role}`
        );
      } else {
        actorState.privateLog.push("You chose not to rob anyone.");
      }
    }
  }
};

export default Robber;