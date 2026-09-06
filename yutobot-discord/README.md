# yutobot-discord
My online presence automator.

## Develop
1. [Create a discord bot](https://discord.com/developers/applications) and add it to a test Discord server with Admin permissions
2. Do the same steps as deploy (below), except for the last step
3. Run `yarn develop`

## Deploy
1. `touch .env` at the project root and define these:
```
DISCORD_BOT_TOKEN=
DISCORD_CHANNELID_WELCOME=
DISCORD_CHANNELID_VC_SYNC=
DISCORD_CHANNELID_COMMANDS=
DISCORD_CHANNELID_SPAWN=
DISCORD_CHANNELID_README=
DISCORD_CHANNELID_GENERAL=
DISCORD_COMMAND_PREFIX=
```
2. Add a webhook named "owoifier" to the server.
3. Run:
```
yarn install
yarn build
yarn deploy
```

## Contributors
Feel free to add yourself :)
- [nug-nug](https://github.com/nug-nug)
- [kale](https://github.com/kayleyseow)
