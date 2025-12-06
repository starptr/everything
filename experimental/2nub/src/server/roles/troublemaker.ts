import { RoleDefinition, GState, PlayerID } from "../types";
import { Ctx } from "boardgame.io";

const Troublemaker: RoleDefinition = {
  id: "troublemaker",
  name: "Troublemaker", 
  description: "You may swap the roles of two other players.",
  team: "village",
  nightAction: {
    uiPrompt: {
      type: "choosePlayers",
      min: 0,
      max: 2,
      label: "Choose two players to swap their roles (or skip)"
    },
    validator: (G: GState, ctx: Ctx, payload: any) => {
      if (payload.targets) {
        if (payload.targets.length !== 0 && payload.targets.length !== 2) {
          return false;
        }
        if (payload.targets.includes(ctx.currentPlayer)) {
          return false;
        }
        if (payload.targets.length === 2 && payload.targets[0] === payload.targets[1]) {
          return false;
        }
      }
      return true;
    },
    perform: (G: GState, ctx: Ctx, { actor, targets }: { 
      actor: PlayerID; 
      targets?: PlayerID[] 
    }) => {
      const actorState = G.players[actor];
      
      if (targets && targets.length === 2) {
        const player1 = G.players[targets[0]];
        const player2 = G.players[targets[1]];
        
        const temp = player1.role;
        player1.role = player2.role;
        player2.role = temp;
        
        actorState.privateLog.push(
          `You swapped the roles of ${player1.name} and ${player2.name}.`
        );
      } else {
        actorState.privateLog.push("You chose not to swap anyone.");
      }
    }
  }
};

export default Troublemaker;