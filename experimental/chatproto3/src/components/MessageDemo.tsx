import React, { useState, useEffect } from 'react';
import {
    CompositeHandleResolver,
	DohJsonHandleResolver,
	WellKnownHandleResolver,
    CompositeDidDocumentResolver,
    PlcDidDocumentResolver,
	WebDidDocumentResolver,
    LocalActorResolver,
} from '@atcute/identity-resolver';
import { Client, simpleFetchHandler } from '@atcute/client';
import type { ActorIdentifier } from '@atcute/lexicons';
import { isActorIdentifier } from '@atcute/lexicons/syntax';
import type {} from '@atcute/atproto'; // Augments XRPCQueries with com.atproto.* methods
import { safeParse } from '@atcute/lexicons';
import {
    AppAndrefChatproto3Channel,
    AppAndrefChatproto3Message,
    AppAndrefChatproto3Writers,
} from '../lexicons';

const handleResolver = new CompositeHandleResolver({
	strategy: 'race', // default - first successful response wins
	methods: {
        dns: new DohJsonHandleResolver({ dohUrl: 'https://mozilla.cloudflare-dns.com/dns-query' }),
        http: new WellKnownHandleResolver(),
    },
});
const didResolver = new CompositeDidDocumentResolver({
	methods: {
		plc: new PlcDidDocumentResolver(),
		web: new WebDidDocumentResolver(),
	},
});
const actorResolver = new LocalActorResolver({
    handleResolver,
    didDocumentResolver: didResolver,
});

interface MessageDemoProps {
    hintChannelOwner?: string;
    channelNsid?: string;
}

export default function MessageDemo() {
    const [queryParams, setQueryParams] = useState<{
        hintChannelOwner?: string;
        channelNsid?: string;
    }>({});
    useEffect(() => {
        // Using URLSearchParams (modern approach)
        const params = new URLSearchParams(window.location.search);
    
        // Convert to a plain object
        const paramsObj = {} as any;
        for (const [key, value] of params.entries()) {
            paramsObj[key] = value;
        }
    
        setQueryParams({...paramsObj});
        console.log('Query Params:', paramsObj);
    }, []);
    console.log('Current Query Params:', queryParams);

    const [messages, setMessages] = useState<{
        displayName: string;
        message: AppAndrefChatproto3Message.Main;
    }[]>([]);
    const [channelName, setChannelName] = useState<string>('');
    const [channelWriters, setChannelWriters] = useState<AppAndrefChatproto3Writers.Main[]>([]);

    useEffect(() => {
        async function fetchMessages() {
            if (queryParams.hintChannelOwner === undefined || queryParams.channelNsid === undefined || !isActorIdentifier(queryParams.hintChannelOwner)) return;

            let actor = null;
            try {
                actor = await actorResolver.resolve(queryParams.hintChannelOwner);
            } catch (error) {
                console.log('Failed to resolve actor:', error);
            }
            if (actor === null) return;

            const channelOwnerRpc = new Client({
                handler: simpleFetchHandler({ service: actor.pds }),
            });
            const channel = await channelOwnerRpc.get('com.atproto.repo.getRecord', {
                params: {
                    repo: actor.handle,
                    collection: 'app.andref.chatproto3.channel',
                    rkey: queryParams.channelNsid,
                },
            });
            if (!channel.ok) {
                console.log('Failed to fetch channel record:', channel);
                return;
            }
            const channelData = safeParse(AppAndrefChatproto3Channel.mainSchema, channel.data.value);
            if (!channelData.ok) {
                console.log('Failed to parse channel record:', channelData.issues);
                console.log('Raw data:', channel.data);
                return;
            }
            console.log('Channel data:', channelData);
            setChannelName(channelData.value.name);
            
            const writers = channelData.value.writers || [];
            setChannelWriters(writers);

            // TODO: Handle `since` and multiple writers changing over time
            // Fetch messages
            const rule = writers[0];
            if (!Array.isArray(rule.identifiers)) {
                return;
            }
            const messagesByUser = await Promise.all(rule.identifiers.map(async (identifier) => {
                const actor = await actorResolver.resolve(identifier);
                if (actor === null) return null;

                const writerRpc = new Client({
                    handler: simpleFetchHandler({ service: actor.pds }),
                });
                const messages = await writerRpc.get('com.atproto.repo.listRecords', {
                    params: {
                        repo: actor.handle,
                        collection: 'app.andref.chatproto3.message',
                        reverse: true,
                        limit: 100,
                    },
                });
                if (!messages.ok) {
                    console.log('Failed to fetch messages:', messages);
                    return null;
                }
                // TODO: handle pagination properly
                const allMessageDataFromCurrentUser = messages.data.records.map((record) => {
                    const parsed = safeParse(AppAndrefChatproto3Message.mainSchema, record.value);
                    if (!parsed.ok) {
                        console.log('Failed to parse message record:', parsed.issues);
                        console.log('Raw message data:', record);
                        return null;
                    }
                    return parsed.value;
                });
                const relevantMessages = allMessageDataFromCurrentUser.filter((message) => {
                    return message !== null;
                }).filter((message) => {
                    return message.channel === queryParams.channelNsid;
                });
                return {
                    displayName: actor.handle,
                    messages: relevantMessages,
                };
            })).then((results) => results.filter((res) => res !== null));

            const allMessages = messagesByUser.flatMap((userMessages) => {
                return userMessages.messages.map((message) => ({
                    displayName: userMessages.displayName,
                    message,
                }));
            }).sort((a, b) => {
                return new Date(a.message.createdAt) < new Date(b.message.createdAt) ? 1 : -1
            });

            setMessages(allMessages);
        }
        fetchMessages();
    }, [queryParams]);

    if (!queryParams.hintChannelOwner) {
        return <p>Please provide a hintChannelOwner.</p>
    }
    return messages.map(({ displayName, message }) => <div>
        <h3>{displayName}</h3>
        <p>{new Date(message.createdAt).toISOString()}</p>
        {/* TODO: handle null plaintext properly */}
        <p>{message.plaintext}</p>
    </div>).toReversed();
}