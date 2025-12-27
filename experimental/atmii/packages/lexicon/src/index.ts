/**
 * GENERATED CODE - DO NOT MODIFY
 */
import { FetchHandler, FetchHandlerOptions, XrpcClient } from '@atproto/xrpc'
import { CID } from 'multiformats/cid'

import { schemas } from './lexicons.js'
import * as AppAndrefAtmiiMii from './types/app/andref/atmii/mii.js'
import { OmitKey, Un$Typed } from './util.js'

export * as AppAndrefAtmiiMii from './types/app/andref/atmii/mii.js'

export class AtpBaseClient extends XrpcClient {
  app: AppNS

  constructor(options: FetchHandler | FetchHandlerOptions) {
    super(options, schemas)
    this.app = new AppNS(this)
  }

  /** @deprecated use `this` instead */
  get xrpc(): XrpcClient {
    return this
  }
}

export class AppNS {
  _client: XrpcClient
  andref: AppAndrefNS

  constructor(client: XrpcClient) {
    this._client = client
    this.andref = new AppAndrefNS(client)
  }
}

export class AppAndrefNS {
  _client: XrpcClient
  atmii: AppAndrefAtmiiNS

  constructor(client: XrpcClient) {
    this._client = client
    this.atmii = new AppAndrefAtmiiNS(client)
  }
}

export class AppAndrefAtmiiNS {
  _client: XrpcClient
  mii: MiiRecord

  constructor(client: XrpcClient) {
    this._client = client
    this.mii = new MiiRecord(client)
  }
}

export class MiiRecord {
  _client: XrpcClient

  constructor(client: XrpcClient) {
    this._client = client
  }

  async list(
    params: OmitKey<ComAtprotoRepoListRecords.QueryParams, 'collection'>,
  ): Promise<{
    cursor?: string
    records: { uri: string; value: AppAndrefAtmiiMii.Record }[]
  }> {
    const res = await this._client.call('com.atproto.repo.listRecords', {
      collection: 'app.andref.atmii.mii',
      ...params,
    })
    return res.data
  }

  async get(
    params: OmitKey<ComAtprotoRepoGetRecord.QueryParams, 'collection'>,
  ): Promise<{ uri: string; cid: string; value: AppAndrefAtmiiMii.Record }> {
    const res = await this._client.call('com.atproto.repo.getRecord', {
      collection: 'app.andref.atmii.mii',
      ...params,
    })
    return res.data
  }

  async create(
    params: OmitKey<
      ComAtprotoRepoCreateRecord.InputSchema,
      'collection' | 'record'
    >,
    record: Un$Typed<AppAndrefAtmiiMii.Record>,
    headers?: Record<string, string>,
  ): Promise<{ uri: string; cid: string }> {
    const collection = 'app.andref.atmii.mii'
    const res = await this._client.call(
      'com.atproto.repo.createRecord',
      undefined,
      { collection, ...params, record: { ...record, $type: collection } },
      { encoding: 'application/json', headers },
    )
    return res.data
  }

  async delete(
    params: OmitKey<ComAtprotoRepoDeleteRecord.InputSchema, 'collection'>,
    headers?: Record<string, string>,
  ): Promise<void> {
    await this._client.call(
      'com.atproto.repo.deleteRecord',
      undefined,
      { collection: 'app.andref.atmii.mii', ...params },
      { headers },
    )
  }
}
