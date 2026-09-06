const owoify = require("owoify-js").default;

let emojiRe = /<(?:a?:\w{2,}:\d+|@(?:!|&)\d+|#\d+)>/gm;

const parseStringWithCustomEmojisToOwo = str => {
	let emojis = str.match(emojiRe);
	if (emojis) {
		strTokens = str.split(emojiRe);
		strTokens = strTokens.map(partial => partial ? owoify(partial, "uwu") : "");
		if (str.startsWith(emojis[0])) {
			return emojis.reduce((acc, cur, index) => acc + cur + (index < strTokens.length ? strTokens[index] : ""), "");
		} else {
			return strTokens.reduce((acc, cur, index) => acc + cur + (index < emojis.length ? emojis[index] : ""), "");
		}
	} else {
		return owoify(str, "uwu");
	}
}

const owoifier = async message => {
	if (message.guild.me.hasPermission("MANAGE_WEBHOOKS")) {
		const webhooks = await message.guild.fetchWebhooks();
		const webhook = webhooks.find(hook => hook.name === "owoifier");
		const owoifiedText = parseStringWithCustomEmojisToOwo(message.content);

		try {
			await webhook.send(owoifiedText, {
				username: message.member.displayName,
				avatarURL: message.author.avatarURL({ dynamic: true }) || message.author.defaultAvatarURL,
			});
			message.delete();
		} catch (e) {
			console.error(e);
		}
	} else {
		message.channel.send("`Manage Webhooks` perm missing!");
	}

}

module.exports = owoifier;
