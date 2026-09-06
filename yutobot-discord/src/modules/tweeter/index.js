const Twitter = require("twit");

const twitterConf = {
	consumer_key: process.env.TWITTER_API_KEY,
	consumer_secret: process.env.TWITTER_API_KEY_SECRET,
	access_token: process.env.TWITTER_ACCESS_TOKEN,
	access_token_secret: process.env.TWITTER_ACCESS_TOKEN_SECRET,
};

const isReply = tweet => {
	if (
		tweet.retweeted_status ||
		tweet.in_reply_to_status_id ||
		tweet.in_reply_to_status_id_str ||
		tweet.in_reply_to_user_id ||
		tweet.in_reply_to_user_id_str ||
		tweet.in_reply_to_screen_name
	)
		return true;
	else return false;
};

const tweeter = discordClient => {
	try {
		console.log("tweeter");
		const twitterClient = new Twitter(twitterConf);
		const stream = twitterClient.stream("statuses/filter", {
			follow: process.env.TWITTER_USERID,
		});
		stream.on("tweet", tweet => {
			if (!isReply(tweet)) {
				discordClient.channels.cache
					.get(process.env.DISCORD_CHANNELID_STREAM)
					.send(`https://twitter.com/${tweet.user.screen_name}/status/${tweet.id_str}`);
			}
			return false;
		});
	} catch (e) {
		console.error(e);
	}
};

module.exports = tweeter;
