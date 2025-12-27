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
	ResolvedActor,
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
	const [resolvedActor, setResolvedActor] = useState<ResolvedActor | null>(null);
	const [rpc, setRpc] = useState<Client>();
	const [miiCid, setMiiCid] = useState<string | null>(null);
	const [mii, setMii] = useState(new Uint8Array())

	useEffect(() => {
		if (!handle || !isActorIdentifier(handle)) return;

		// Fetch profile data using the handle
		console.log('Fetching profile for handle:', handle)

		const fetchMii = async () => {
			// Fetch pds endpoint
			const resolvedActor = await actorResolver.resolve(handle);
			setResolvedActor(resolvedActor)

			const rpc = new Client({ handler: simpleFetchHandler({ service: resolvedActor.pds }), });
			setRpc(rpc)

			const result = await rpc.get('com.atproto.repo.getRecord', {
				params: {
					repo: handle,
					collection: 'app.andref.atmii.mii',
					rkey: 'self',
				},
			});
			console.debug('Fetched Mii record:', result);

			if (!('value' in result.data)) {
				console.log('result.data.value does not exist');
				return;
			}

			// TODO: add type safety
			const cid = (result.data.value.mii as any).ref["$link"] as string;
			setMiiCid(cid);

			// Get blob
			const blobResult = await rpc.get('com.atproto.sync.getBlob', {
				params: {
					did: resolvedActor.did,
					cid: cid,
				},
				as: 'bytes',
			});
			console.debug('Fetched mii blob: ', blobResult)
			if (!blobResult.ok) {
				console.log('blobResult is not ok');
				return;
			}
			const miiData = new Uint8Array(blobResult.data);
			setMii(miiData);
		};

		fetchMii();
	}, [handle])

	return <div>Profile Page</div>
}

export default Profile