import React, { useState } from 'react';
import {
    CompositeHandleResolver,
	DohJsonHandleResolver,
	WellKnownHandleResolver,
    CompositeDidDocumentResolver,
    PlcDidDocumentResolver,
	WebDidDocumentResolver,
    LocalActorResolver,
} from '@atcute/identity-resolver';
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
    channelNsid: string;
}

export default function MessageDemo({
    hintChannelOwner,
    channelNsid,
}: MessageDemoProps) {
    if (!hintChannelOwner) {
        return <p>Please provide a hintChannelOwner.</p>
    }
    return <div>Placeholder</div>
}