import { IdResolver } from '@atproto/identity'
import { Firehose, MemoryRunner, type Event } from '@atproto/sync'
import {
  AppAndrefChatprotoChannel,
  AppAndrefChatprotoMessage,
  XyzStatusphereStatus,
} from '@statusphere/lexicon'
import pino from 'pino'

import type { Database } from '#/db'

export async function createFirehoseIngester(
  db: Database,
  idResolver: IdResolver,
) {
  const logger = pino({ name: 'firehose ingestion' })

  const cursor = await db
    .selectFrom('cursor')
    .where('id', '=', 1)
    .select('seq')
    .executeTakeFirst()

  logger.info(`start cursor: ${cursor?.seq}`)

  // For throttling cursor writes
  let lastCursorWrite = 0

  const runner = new MemoryRunner({
    startCursor: cursor?.seq || undefined,
    setCursor: async (seq) => {
      const now = Date.now()

      if (now - lastCursorWrite >= 10000) {
        lastCursorWrite = now
        await db
          .updateTable('cursor')
          .set({ seq })
          .where('id', '=', 1)
          .execute()
      }
    },
  })

  return new Firehose({
    idResolver,
    runner,
    handleEvent: async (evt: Event) => {
      // Watch for write events
      if (evt.event === 'create' || evt.event === 'update') {
        const now = new Date()
        const record = evt.record

        switch (evt.collection) {
          case 'xyz.statusphere.status': {
            if (!XyzStatusphereStatus.isRecord(record)) return
            const validatedRecord = XyzStatusphereStatus.validateRecord(record)
            if (!validatedRecord.success) return
            // Store the status in our SQLite
            await db
              .insertInto('status')
              .values({
                uri: evt.uri.toString(),
                authorDid: evt.did,
                status: validatedRecord.value.status,
                createdAt: validatedRecord.value.createdAt,
                indexedAt: now.toISOString(),
              })
              .onConflict((oc) =>
                oc.column('uri').doUpdateSet({
                  status: validatedRecord.value.status,
                  indexedAt: now.toISOString(),
                }),
              )
              .execute()
          }
          case 'app.andref.chatproto.message': {
            if (!AppAndrefChatprotoMessage.isRecord(record)) return
            const validatedRecord =
              AppAndrefChatprotoMessage.validateRecord(record)
            if (!validatedRecord.success) return
            // Plaintext is required for now, since it is the only content type we support
            if (validatedRecord.value.plaintext === undefined) return
            // Store the status in our SQLite
            await db
              .insertInto('message')
              .values({
                uri: evt.uri.toString(),
                authorDid: evt.did,
                plaintext: validatedRecord.value.plaintext,
                createdAt: validatedRecord.value.createdAt,
                channelUri: validatedRecord.value.channel,
                indexedAt: now.toISOString(),
              })
              .onConflict((oc) =>
                oc.column('uri').doUpdateSet({
                  plaintext: validatedRecord.value.plaintext,
                  indexedAt: now.toISOString(),
                }),
              )
              .execute()
          }
          case 'app.andref.chatproto.channel': {
            if (!AppAndrefChatprotoChannel.isRecord(record)) return
            const validatedRecord =
              AppAndrefChatprotoChannel.validateRecord(record)
            if (!validatedRecord.success) return

            // Channel is getting created or updated
          }
        }
      } else if (evt.event === 'delete') {
        switch (evt.collection) {
          case 'xyz.statusphere.status': {
            // Remove the status from our SQLite
            await db
              .deleteFrom('status')
              .where('uri', '=', evt.uri.toString())
              .execute()
          }
          case 'app.andref.chatproto.message': {
            // Remove the message from our SQLite
            await db
              .deleteFrom('message')
              .where('uri', '=', evt.uri.toString())
              .execute()
          }
          default: {
            // Ignore other deletions
          }
        }
      }
    },
    onError: (err: Error) => {
      logger.error({ err }, 'error on firehose ingestion')
    },
    filterCollections: [
      'xyz.statusphere.status',
      'app.andref.chatproto.message',
      'app.andref.chatproto.space',
      'app.andref.chatproto.channel',
    ],
    excludeIdentity: true,
    excludeAccount: true,
  })
}
