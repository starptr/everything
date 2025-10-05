import SqliteDb from 'better-sqlite3'
import {
  Kysely,
  Migration,
  MigrationProvider,
  Migrator,
  SqliteDialect,
} from 'kysely'

// Types

export type DatabaseSchema = {
  status: Status
  message: Message
  space: Space
  channel: Channel
  writers: Writers
  auth_session: AuthSession
  auth_state: AuthState
  cursor: Cursor
}

export type Status = {
  uri: string
  authorDid: string
  status: string
  createdAt: string
  indexedAt: string
}

export type Message = {
  uri: string
  authorDid: string
  plaintext: string
  createdAt: string
  indexedAt: string
  channelUri: string
}

export type Space = {
  uri: string
  name: string
}

export type Channel = {
  uri: string
  name: string
  useSpaceWriters: boolean
  spaceUri: string
}

export type Writers = {
  writableUri: string
  writer: string
}

export type AuthSession = {
  key: string
  session: AuthSessionJson
}

export type AuthState = {
  key: string
  state: AuthStateJson
}

export type Cursor = {
  id: number
  seq: number
}

type AuthStateJson = string

type AuthSessionJson = string

// Migrations

const migrations: Record<string, Migration> = {}

const migrationProvider: MigrationProvider = {
  async getMigrations() {
    return migrations
  },
}

migrations['003'] = {
  async up(db: Kysely<unknown>) {},
  async down(_db: Kysely<unknown>) {},
}

migrations['002'] = {
  async up(db: Kysely<unknown>) {
    await db.schema
      .createTable('cursor')
      .addColumn('id', 'integer', (col) => col.primaryKey())
      .addColumn('seq', 'integer', (col) => col.notNull())
      .execute()

    // Insert initial cursor values:
    // id=1 is for firehose, id=2 is for jetstream
    await db
      .insertInto('cursor' as never)
      .values([
        { id: 1, seq: 0 },
        { id: 2, seq: 0 },
      ])
      .execute()
  },
  async down(db: Kysely<unknown>) {
    await db.schema.dropTable('cursor').execute()
  },
}

migrations['001'] = {
  async up(db: Kysely<unknown>) {
    await db.schema
      .createTable('status')
      .addColumn('uri', 'varchar', (col) => col.primaryKey())
      .addColumn('authorDid', 'varchar', (col) => col.notNull())
      .addColumn('status', 'varchar', (col) => col.notNull())
      .addColumn('createdAt', 'varchar', (col) => col.notNull())
      .addColumn('indexedAt', 'varchar', (col) => col.notNull())
      .execute()
    await db.schema
      .createTable('message')
      .addColumn('uri', 'varchar', (col) => col.primaryKey())
      .addColumn('authorDid', 'varchar', (col) => col.notNull())
      .addColumn('plaintext', 'varchar', (col) => col.notNull())
      .addColumn('createdAt', 'varchar', (col) => col.notNull())
      .addColumn('indexedAt', 'varchar', (col) => col.notNull())
      .addColumn('channelUri', 'varchar', (col) => col.notNull())
      .execute()
    await db.schema
      .createTable('space')
      .addColumn('uri', 'varchar', (col) => col.primaryKey())
      .addColumn('name', 'varchar', (col) => col.notNull())
      .execute()
    await db.schema
      .createTable('channel')
      .addColumn('uri', 'varchar', (col) => col.primaryKey())
      .addColumn('name', 'varchar', (col) => col.notNull())
      .addColumn('useSpaceWriters', 'boolean', (col) => col.notNull().defaultTo(true))
      .addColumn('spaceUri', 'varchar', (col) => col.notNull())
      .addForeignKeyConstraint(
        'spaceUri_fkey',
        ['spaceUri'],
        'space',
        ['uri'],
        (cb) => cb.onDelete('cascade'),
      )
      .execute()
    await db.schema
      .createTable('writers')
      .addColumn('writableUri', 'varchar', (col) => col.notNull())
      .addColumn('writer', 'varchar', (col) => col.notNull())
      .addForeignKeyConstraint(
        'writableUri_fkey',
        ['writableUri'],
        'space',
        ['uri'],
        (cb) => cb.onDelete('cascade'),
      )
      .execute()
    await db.schema
      .createTable('auth_session')
      .addColumn('key', 'varchar', (col) => col.primaryKey())
      .addColumn('session', 'varchar', (col) => col.notNull())
      .execute()
    await db.schema
      .createTable('auth_state')
      .addColumn('key', 'varchar', (col) => col.primaryKey())
      .addColumn('state', 'varchar', (col) => col.notNull())
      .execute()
  },
  async down(db: Kysely<unknown>) {
    await db.schema.dropTable('auth_state').execute()
    await db.schema.dropTable('auth_session').execute()
    await db.schema.dropTable('writers').execute()
    await db.schema.dropTable('channel').execute()
    await db.schema.dropTable('space').execute()
    await db.schema.dropTable('message').execute()
    await db.schema.dropTable('status').execute()
  },
}

// APIs

export const createDb = (location: string): Database => {
  return new Kysely<DatabaseSchema>({
    dialect: new SqliteDialect({
      database: new SqliteDb(location),
    }),
  })
}

export const migrateToLatest = async (db: Database) => {
  const migrator = new Migrator({ db, provider: migrationProvider })
  const { error } = await migrator.migrateToLatest()
  if (error) throw error
}

export type Database = Kysely<DatabaseSchema>
