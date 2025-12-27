import { useParams, useSearchParams } from 'react-router'

import { ComAtprotoRepoGetRecord } from '@atcute/atproto'
import { Client, simpleFetchHandler } from '@atcute/client';
import { isActorIdentifier } from '@atcute/lexicons/syntax';

import { useState, useEffect, useMemo } from 'react'

const Profile = () => {
	const { handle } = useParams()

	const rpc = useMemo(() => {
		return new Client({ handler: simpleFetchHandler({ service: 'https://public.api.bsky.app' }), });
	}, []);

	useEffect(() => {
		if (!handle || !isActorIdentifier(handle)) return;

		// Fetch profile data using the handle
		console.log('Fetching profile for handle:', handle)

		const fetchMii = async () => {
			const result = rpc.get('com.atproto.repo.getRecord', {
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