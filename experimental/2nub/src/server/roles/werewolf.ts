import { RoleDefinition, GState, PlayerID } from "../types";
import { Ctx } from "boardgame.io";

const Werewolf: RoleDefinition = {
  id: "werewolf",
  name: "Werewolf",
  description: "Look for other werewolves. If you are the only werewolf, you may look at a center card.",
  team: "werewolf",
  nightAction: {
    uiPrompt: {
      type: "noPrompt",
      label: "Look for other werewolves..."
    },
    perform: (G: GState, ctx: Ctx, { actor }: { actor: PlayerID }) => {
      const actorState = G.players[actor];
      
      const otherWerewolves = Object.values(G.players)
        .filter(p => p.id !== actor && p.originalRole === "werewolf")
        .map(p => `Player ${p.seat} (${p.name})`);

      if (otherWerewolves.length > 0) {
        actorState.privateLog.push(
          `You see the other werewolves: ${otherWerewolves.join(", ")}`
        );
      } else {
        const centerCard = G.center[0];
        actorState.privateLog.push(
          `You are the lone werewolf. You looked at center card 1: ${centerCard}`
        );
      }
    }
  },
  scoring: (G: GState, ctx: Ctx) => {
    const werewolves = Object.values(G.players)
      .filter(p => p.role === "werewolf")
      .map(p => p.id);

    if (!G.revealed) return;

    const eliminatedWerewolves = G.revealed.endSummary.eliminatedPlayers
      .filter(id => G.players[id].role === "werewolf");

    if (eliminatedWerewolves.length === 0 && werewolves.length > 0) {
      G.revealed.winners = werewolves;
      G.revealed.endSummary.winCondition = "Werewolves win! No werewolves were eliminated.";
    }
  }
};

export default Werewolf;