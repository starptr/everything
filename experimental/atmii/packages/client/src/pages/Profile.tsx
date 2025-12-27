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

import Mii from '@pretendonetwork/mii-js';

import { useState, useEffect, useMemo } from 'react'

function base64ToArrayBuffer(base64: string): ArrayBuffer {
  const binaryString = atob(base64);
  const len = binaryString.length;
  const bytes = new Uint8Array(len);

  for (let i = 0; i < len; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }

  return bytes.buffer;
}

function base64UrlToUint8Array(base64url: string): Uint8Array {
  let base64 = base64url
    .replace(/-/g, '+')
    .replace(/_/g, '/')

  // pad with '='
  const pad = base64.length % 4
  if (pad) {
    base64 += '='.repeat(4 - pad)
  }

  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes
}

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
	const [mii, setMii] = useState<Uint8Array>(new Uint8Array())
	const [renderUrl, setRenderUrl] = useState<string | null>(null);

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
			const data = blobResult.data as Uint8Array;
			console.log('data: ', data);
			setMii(data);
		};

		fetchMii();
	}, [handle])

	useEffect(() => {
		// Convert mii blob to image buffer
		const renderMii = async () => {
			if (!mii) return;
			console.log('mii: ', mii);
			const miiData = new Mii(mii.buffer.slice(mii.byteOffset, mii.byteOffset + mii.byteLength) as unknown as Buffer);

			//const miiData = new Mii(mii.buffer);

			//const exampleMiiStr = 'AwAAML1PTlt3fzJUk4gSiED0BxyEoQAAAEDEMOAwrjAAAAAAAAAAAAAAAAAAAEBAAAAhAQJoRBgmNEYUgRIXaA0AACkAUkhQAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBd';
			//const miiData = new Mii(base64ToArrayBuffer(exampleMiiStr))
			setRenderUrl(miiData.studioUrl());
		};
		renderMii();
	}, [mii])

	return <div>
		<h1>
			Profile Page
		</h1>
		{renderUrl && <img src={renderUrl} alt="mii render" />}
	</div>
}

export default Profile