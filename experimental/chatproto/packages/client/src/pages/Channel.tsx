import Header from '#/components/Header'
import StatusForm, { STATUS_OPTIONS } from '#/components/StatusForm'
import StatusList from '#/components/StatusList'
import { useAuth } from '#/hooks/useAuth'
import { useParams, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import api from '#/services/api'
import { useEffect } from 'react'

const Channel = () => {
  const { channelNsid } = useParams();
  if (channelNsid === undefined) {
    return <div>
      <p>
        Channel component requires channelNsid router param.
      </p>
    </div>;
  }
  const [searchParams] = useSearchParams();
  const hintChannelOwner = searchParams.get('hintChannelOwner');
  const { user, loading, error } = useAuth()

  const { data, isPending, isError, error: queryError } = useQuery({
    queryKey: ['channel', channelNsid, hintChannelOwner],
    queryFn: async () => {
      const { data } = await api.getMessages({
        channelNsid,
        ...(hintChannelOwner !== null && { hintChannelOwner }), // Set field only if non-null
      });
      return data;
    },
    placeholderData: (previousData) => previousData, // Use previous data while refetching
    refetchInterval: 30e3, // Refresh every second
  });
  useEffect(() => {
    if (queryError) {
      console.error(queryError);
    }
  }, [queryError]);

  // Get a random emoji from the STATUS_OPTIONS array
  const randomEmoji =
    STATUS_OPTIONS[Math.floor(Math.random() * STATUS_OPTIONS.length)]

  if (loading || isPending) {
    return (
      <div className="flex justify-center items-center h-[80vh]">
        <div className="text-9xl animate-pulse">{randomEmoji}</div>
      </div>
    )
  }

  if (isError) {
    return (
      <div className="flex justify-center items-center py-16">
        <div className="text-center p-6 max-w-md">
          <h2 className="text-2xl font-semibold mb-2 text-gray-800 dark:text-gray-200">
            Error
          </h2>
          <p className="text-red-500 mb-4">{error}</p>
          <a
            href="/login"
            className="inline-block px-4 py-2 bg-blue-500 dark:bg-blue-600 text-white rounded-md hover:bg-blue-600 dark:hover:bg-blue-700 transition-colors"
          >
            Try logging in again
          </a>
        </div>
      </div>
    )
  }

  if (queryError) {
    return (
      <div>
        <Header />
        <p>
          Query failed. Try refreshing?
        </p>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-8 pb-12">
      <Header />

      {user && <StatusForm />}

      <div>
        <h2 className="text-xl font-semibold mb-4 text-gray-800 dark:text-gray-200">
          Messages
        </h2>
        {data.messages.map((messageData) => (
          <div key={messageData.tid}>
            <p>Author: {messageData.author.handle} ({messageData.author.did}) ({messageData.createdAt})</p>
            <p>{messageData.plaintext ?? ""}</p>
          </div>
        ))}
      </div>
    </div>
  )
}

export default Channel
