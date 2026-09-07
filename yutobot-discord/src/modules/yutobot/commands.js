// The single source of truth for every command the bot understands.
//
// A command is a plain object:
//   { name, aliases?, description?, hideFromList?, execute(ctx) }
//     - name:         canonical trigger word (without the command prefix)
//     - aliases:      extra trigger words for the same command
//     - description:  short one-liner; commands with one are documented by `.list`
//     - hideFromList: when true, `.list` omits the command entirely
//     - execute(ctx): the command's logic. `ctx` is { message, args, state, commands }
//                     where `args` is the whitespace-split message (args[0] is the
//                     command word), `state` is per-session mutable bot state, and
//                     `commands` is this full registry (so reflection commands like
//                     `.list` can enumerate their peers).
//
// Because everything — logic commands and canned call/response commands alike —
// lives in one array, `.list` can reflect over it and new commands only need to
// be appended here.

const owoifier = require("../owoifier");
const wiimenu = require("../wiimenu");
const pkgInfo = require("../../../package.json");
const simpleCallResponse = require("./simple_call_response.json");

// Render the `.list` output: every non-hidden command, showing its trigger(s)
// and — only when it has one — its description.
const renderCommandList = commands => {
	const prefix = process.env.DISCORD_COMMAND_PREFIX;
	const lines = commands
		.filter(command => !command.hideFromList)
		.map(command => {
			const triggers = [command.name, ...(command.aliases || [])].map(name => `\`${prefix}${name}\``).join(", ");
			return command.description ? `${triggers} — ${command.description}` : triggers;
		});
	return ["**Commands:**", ...lines].join("\n");
};

// Commands with real logic. Anything that inspects permissions, holds state, or
// computes its reply lives here (and generally carries a description).
const logicCommands = [
	{
		name: "version",
		aliases: ["v"],
		description: "Show the running YutoBot version",
		execute: ({ message }) => message.channel.send(`Running YutoBot v${pkgInfo.version}`),
	},
	{
		name: "foocheck",
		description: "List members who don't have the `foo` role (needs Manage Roles)",
		execute: async ({ message }) => {
			if (!message.member.hasPermission("MANAGE_ROLES")) {
				message.channel.send("you need the perm `Manage Roles` to run this command :(");
				return;
			}
			try {
				const allMembers = (await message.guild.members.fetch()).array().filter(member => !member.user.bot);
				const allMembersWithoutFoo = allMembers.filter(member => !member.roles.cache.array().some(role => role.name === "foo"));
				message.channel.send(
					`No foos: \`${allMembersWithoutFoo.map(member => member.nickname || member.user.username).join("`, `")}\``
				);
			} catch (err) {
				console.error("foocheck failed.");
				console.error(err);
				message.channel.send("sry, foocheck broke ¯\\_(ツ)_/¯");
			}
		},
	},
	{
		name: "owoifier",
		description: "Toggle the random owoifier (needs Administrator)",
		execute: ({ message, state }) => {
			if (!message.member.hasPermission("ADMINISTRATOR")) {
				message.channel.send("you need the perm `Administrator` to run this command :(");
				return;
			}
			state.owoifierEnabled = !state.owoifierEnabled;
			message.channel.send(state.owoifierEnabled ? "1" : "0");
		},
	},
	{
		// Wii menu card — an easter egg reached from the `power` response
		// ("Press Ⓐ to continue"), so keep it out of `.list`.
		name: "Ⓐ",
		hideFromList: true,
		execute: ({ message }) => wiimenu(message),
	},
	{
		name: "list",
		description: "List every command",
		execute: ({ message, commands }) => message.channel.send(renderCommandList(commands)),
	},
];

// Canned call/response commands, derived from simple_call_response.json so they
// share the registry with everything else. They carry no description on purpose:
// there is nothing to explain beyond the reply itself.
const simpleCommands = Object.entries(simpleCallResponse).map(([name, response]) => ({
	name,
	execute: ({ message }) => message.channel.send(response),
}));

const commands = [...logicCommands, ...simpleCommands];

// Map every name and alias to its command for O(1) dispatch.
const buildRegistry = commands => {
	const registry = new Map();
	for (const command of commands) {
		for (const trigger of [command.name, ...(command.aliases || [])]) {
			registry.set(trigger, command);
		}
	}
	return registry;
};

module.exports = { commands, buildRegistry, renderCommandList };
