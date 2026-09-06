const Discord = require("discord.js");
//const sixLettersToWarn = require("../vcsyncwarn");
const owoifier = require("../owoifier");
//const tweeter = require("../tweeter");
const { commands, buildRegistry } = require("./commands");

const start = () => {
	const client = new Discord.Client({
		presence: {
			activity: {
				type: "LISTENING",
				name: `${process.env.DISCORD_COMMAND_PREFIX}help`,
			},
		},
	});

	// Command dispatch table (name/alias -> command) and mutable per-session state
	// shared between command handlers and the ambient owoifier below.
	const registry = buildRegistry(commands);
	const state = { owoifierEnabled: true };

	client.once("ready", () => {
		console.log("Ready!");
	});

	//Greet new members
	client.on("guildMemberAdd", member => {
		const guildChannelManagerCache = member.guild.channels.cache;
		const welcomeTextChannel = guildChannelManagerCache.get(process.env.DISCORD_CHANNELID_WELCOME);
		const vcSyncTextChannel = guildChannelManagerCache.get(process.env.DISCORD_CHANNELID_VC_SYNC);
		const commandsTextChannl = guildChannelManagerCache.get(process.env.DISCORD_CHANNELID_COMMANDS);
		const spawnTextChannel = guildChannelManagerCache.get(process.env.DISCORD_CHANNELID_SPAWN);
		const readmeTextChannel = guildChannelManagerCache.get(process.env.DISCORD_CHANNELID_README);

		welcomeTextChannel.send(
			`welcome ${member.user}, read ${readmeTextChannel}, ${vcSyncTextChannel} for text messages during voicechat, ${commandsTextChannl} and ${spawnTextChannel} for interacting with bots, enjoy`
		);
	});

	//Listen to commands in the commands channel (except help)
	client.on("message", async message => {
		const prefix = process.env.DISCORD_COMMAND_PREFIX;
		if (message.content.startsWith(prefix)) {
			//Tokenize command into words; args[0] is the command word
			const args = message.content.slice(prefix.length).trim().split(" ");
			const command = registry.get(args[0]);
			if (command) {
				await command.execute({ message, args, state, commands });
			} else {
				message.channel.send(`sry! idk what \`${args[0]}\` means ¯\\_(ツ)_/¯`);
			}
		}

		if (state.owoifierEnabled && message.channel.id === process.env.DISCORD_CHANNELID_GENERAL && !message.author.bot) {
			if (Math.random() < 0.01) {
				owoifier(message);
			}
		}
	});

	client.login(process.env.DISCORD_BOT_TOKEN);
};

module.exports = start;
