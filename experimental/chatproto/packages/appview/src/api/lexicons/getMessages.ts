import { AppContext } from '#/context'
import { Server } from '#/lexicons'
import { statusToStatusView } from '#/lib/hydrate'
import { AtUri, isValidHandle } from '@atproto/syntax';

import { getSessionAgent } from '#/session'
import { AppAndrefChatprotoChannel, AppAndrefChatprotoMessage, AppAndrefChatprotoSpace } from '@statusphere/lexicon'
import { isValidDidDoc } from '@atproto/common';
import { DidResolver, HandleResolver } from '@atproto/identity';

export default function (server: Server, ctx: AppContext) {
  server.app.andref.chatproto.getMessages({
    handler: async ({ params, req, res }) => {
      // TODO: handle pagination
      if (params.before !== undefined) {
        ctx.logger.error("Pagination is not supported yet");
        throw new Error('Pagination is not supported yet');
      }

      // TODO: use cached data stored in DB
      if (params.hintChannelOwner === undefined) {
        ctx.logger.error("hintChannelOwner is required for now");
        throw new Error('hintChannelOwner is required for now');
      }

      const agent = await getSessionAgent(req, res, ctx);
      if (!agent) {
        // TODO: is auth required?
        ctx.logger.error("Authentication required");
        throw new Error('Authentication required');
      }

      const channel = await agent.com.atproto.repo.getRecord({
        repo: params.hintChannelOwner,
        collection: 'app.andref.chatproto.channel',
        rkey: params.channelNsid,
      }).catch(() => {
        ctx.logger.error("Channel not found");
        throw new Error('Channel not found');
      });
      if (!channel.success) {
        ctx.logger.error(`Getting channel record failed:\nHeaders:\n${channel.headers}\nData:\n${channel.data}`);
        throw new Error(`Getting channel record failed:\nHeaders:\n${channel.headers}\nData:\n${channel.data}`);
      }

      // TODO: think about whether it makes sense to require the channel's belonging space to be owned by the same hintChannelOwner
      const validatedChannel = AppAndrefChatprotoChannel.validateRecord(channel.data);
      if (!validatedChannel.success) {
        ctx.logger.error(`Channel record validation failed:\n${validatedChannel.error}`);
        throw new Error(`Channel record validation failed:\n${validatedChannel.error}`);
      }
      const parts = params.channelNsid.split('.');
      parts.pop();
      const spaceNsid = parts.join('.');
      const space = await agent.com.atproto.repo.getRecord({
        repo: params.hintChannelOwner,
        collection: 'app.andref.chatproto.space',
        rkey: spaceNsid,
      }).catch(() => {
        ctx.logger.error("Space not found");
        throw new Error('Space not found');
      });
      if (!space.success) {
        ctx.logger.error(`Getting space record failed:\nHeaders:\n${space.headers}\nData:\n${space.data}`);
        throw new Error(`Getting space record failed:\nHeaders:\n${space.headers}\nData:\n${space.data}`);
      }
      const validatedSpace = AppAndrefChatprotoSpace.validateRecord(space.data);
      if (!validatedSpace.success) {
        ctx.logger.error(`Space record validation failed:\n${validatedSpace.error}`);
        throw new Error(`Space record validation failed:\n${validatedSpace.error}`);
      }
      const writers = validatedSpace.value.writers ?? [];
      const messagesByWriter = await Promise.all(writers.map(async (writer) => {
        const messagesFromWriter = await agent.com.atproto.repo.listRecords({
          repo: writer,
          collection: 'app.andref.chatproto.message',
          limit: 50,
          reverse: true,
        });
        if (!messagesFromWriter.success) {
          ctx.logger.error(`Listing messages from ${writer} failed:\nHeaders:\n${messagesFromWriter.headers}\nData:\n${messagesFromWriter.data}`);
          throw new Error(`Listing messages from ${writer} failed:\nHeaders:\n${messagesFromWriter.headers}\nData:\n${messagesFromWriter.data}`);
        }
        const validatedMessageRkeyPairs = messagesFromWriter.data.records.map((entry) => {
          const uri = new AtUri(entry.uri);
          const rkey = uri.rkey;
          const validatedMessage = AppAndrefChatprotoMessage.validateRecord(entry.value);
          if (!validatedMessage.success) {
            ctx.logger.error(`Message record validation failed:\n${validatedMessage.error}`);
            throw new Error(`Message record validation failed:\n${validatedMessage.error}`);
          }
          return {
            message: validatedMessage.value,
            rkey,
          };
        });
        return {
          writer,
          messages: validatedMessageRkeyPairs,
        };
      }));
      const messages = messagesByWriter.flatMap(({ writer, messages }) => {
        return messages.map(({ message, rkey }) => ({
          writer,
          message,
          rkey,
        }));
      }).sort((a, b) => {
        if (a.message.createdAt > b.message.createdAt) return -1;
        else if (a.message.createdAt < b.message.createdAt) return 1;
        else return 0;
      });

      // Convert writer to did and handle
      const messagesWithAuthorViews = await Promise.all(messages.map(async ({ writer, message, rkey }) => {
        if (!isValidDidDoc(writer) && !isValidHandle(writer)) {
          ctx.logger.error(`Invalid at-identifier: ${writer}`);
          throw new Error(`Invalid at-identifier: ${writer}`);
        }
        let did: string;
        let handle: string | null;
        if (!isValidDidDoc(writer)) {
          handle = writer;
          // Convert handle to did
          const handleResolver = new HandleResolver({});
          const resolved = await handleResolver.resolve(writer);
          if (resolved === undefined) {
            ctx.logger.error(`Failed to resolve handle: ${writer}`);
            throw new Error(`Failed to resolve handle: ${writer}`);
          }
          did = resolved;
        } else {
          did = writer;
          // Convert did to handle (not required to be successful)
          const didResolver = new DidResolver({});
          const userData = await didResolver.resolveAtprotoData(did);
          handle = userData.handle;
        }
        return {
          did,
          handle,
          message,
          rkey,
        };
      }));

      const messagesToReturn = messagesWithAuthorViews.map(({ did, handle, message, rkey }) => ({
        tid: rkey,
        plainText: message.plaintext,
        createdAt: message.createdAt,
        channel: validatedChannel.value.uri,
        author: {
          did,
          handle,
        },
      }));

      return {
        encoding: 'application/json',
        body: {
          messages: messagesToReturn.slice(0, 50), // limit to 50 messages
        },
      };
    },
  })
}
