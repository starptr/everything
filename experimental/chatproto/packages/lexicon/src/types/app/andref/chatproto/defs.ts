/**
 * GENERATED CODE - DO NOT MODIFY
 */
import { BlobRef, ValidationResult } from '@atproto/lexicon'
import { CID } from 'multiformats/cid'

import { validate as _validate } from '../../../../lexicons'
import { is$typed as _is$typed, $Typed, OmitKey } from '../../../../util'

const is$typed = _is$typed,
  validate = _validate
const id = 'app.andref.chatproto.defs'

export interface SpaceView {
  $type?: 'app.andref.chatproto.defs#spaceView'
  uri: string
  name: string
}

const hashSpaceView = 'spaceView'

export function isSpaceView<V>(v: V) {
  return is$typed(v, id, hashSpaceView)
}

export function validateSpaceView<V>(v: V) {
  return validate<SpaceView & V>(v, id, hashSpaceView)
}

export interface ChannelView {
  $type?: 'app.andref.chatproto.defs#channelView'
  uri: string
  name: string
}

const hashChannelView = 'channelView'

export function isChannelView<V>(v: V) {
  return is$typed(v, id, hashChannelView)
}

export function validateChannelView<V>(v: V) {
  return validate<ChannelView & V>(v, id, hashChannelView)
}

export interface ProfileView {
  $type?: 'app.andref.chatproto.defs#profileView'
  did: string
  handle: string
}

const hashProfileView = 'profileView'

export function isProfileView<V>(v: V) {
  return is$typed(v, id, hashProfileView)
}

export function validateProfileView<V>(v: V) {
  return validate<ProfileView & V>(v, id, hashProfileView)
}
