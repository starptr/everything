import { RoleDefinition, GState } from "../types";
import { Ctx } from "boardgame.io";

const Villager: RoleDefinition = {
  id: "villager",
  name: "Villager",
  description: "You have no special ability. Try to find the werewolves!",
  team: "village"
};

export default Villager;