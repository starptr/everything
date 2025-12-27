import { useParams, useSearchParams } from 'react-router'

import { ComAtprotoRepoGetRecord } from '@atcute/atproto'
import { Client, simpleFetchHandler } from '@atcute/client';
import { isActorIdentifier } from '@atcute/lexicons/syntax';
import {
	CompositeHandleResolver,
	DohJsonHandleResolver,
	WellKnownHandleResolver,
	CompositeDidDocumentResolver,
	PlcDidDocumentResolver,
	WebDidDocumentResolver,
	LocalActorResolver,
} from '@atcute/identity-resolver'
import {
	getPdsEndpoint
} from '@atcute/identity'

import { useState, useEffect, useMemo } from 'react'

const handleResolver = new CompositeHandleResolver({
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

const Profile = () => {
	const { handle } = useParams()
	const [pds, setPds] = useState<string | null>(null);
	const [rpc, setRpc] = useState<Client>();
	const [mii, setMii] = useState(new ArrayBuffer())

	useEffect(() => {
		if (!handle || !isActorIdentifier(handle)) return;

		// Fetch profile data using the handle
		console.log('Fetching profile for handle:', handle)

		const fetchMii = async () => {
			// Fetch pds endpoint
			const { pds } = await actorResolver.resolve(handle);
			setPds(pds);

			const rpc = new Client({ handler: simpleFetchHandler({ service: pds }), });
			setRpc(rpc)

			const result = await rpc.get('com.atproto.repo.getRecord', {
				params: {
					repo: handle,
					collection: 'app.andref.atmii.mii',
					rkey: 'self',
				},
			});
			console.debug('Fetched Mii record:', result);
		};

		fetchMii();
	}, [handle])

	return <div>Profile Page</div>
}

export default Profile