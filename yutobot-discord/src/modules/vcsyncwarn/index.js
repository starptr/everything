const fs = require("fs");
const path = require("path");

const amongUs = {
	regex: /^[a-z]+$/i,
	ignore: fs.readFileSync(path.resolve(__dirname, "wordlist.txt"), "utf-8").split("\n"),
};

const sixLettersToWarn = (client, message) => {
	//console.log(message.content);
	const msgStr = message.content;
	if (msgStr.match(amongUs.regex) && !amongUs.ignore.includes(msgStr)) {
		const vc_sync_channel = message.guild.channels.cache.get(process.env.DISCORD_CHANNELID_VC_SYNC);
		vc_sync_channel.send(`hey ${message.member.user}! please send Among Us room codes into ${vc_sync_channel} so that other channels like ${message.channel} don't get too cluttered (´• ω •\`) ♡
btw, the room code is \`${message.content}\`. have fun! ＼(≧▽≦)／`);
	}
};

module.exports = sixLettersToWarn;
