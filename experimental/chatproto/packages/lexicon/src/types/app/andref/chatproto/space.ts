/**
 * GENERATED CODE - DO NOT MODIFY
 */
import { BlobRef, ValidationResult } from '@atproto/lexicon'
import { CID } from 'multiformats/cid'

import { validate as _validate } from '../../../../lexicons'
import { is$typed as _is$typed, $Typed, OmitKey } from '../../../../util'
import type * as AppAndrefChatprotoWriters from './writers.js'

const is$typed = _is$typed,
  validate = _validate
const id = 'app.andref.chatproto.space'

export interface Record {
  $type: 'app.andref.chatproto.space'
  name: string
  writers?: AppAndrefChatprotoWriters.Main
  channels: string[]
  [k: string]: unknown
}

const hashRecord = 'main'

export function isRecord<V>(v: V) {
  return is$typed(v, id, hashRecord)
}

export function validateRecord<V>(v: V) {
  return validate<Record & V>(v, id, hashRecord, true)
}
