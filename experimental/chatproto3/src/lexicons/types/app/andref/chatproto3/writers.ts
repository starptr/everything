import type {} from "@atcute/lexicons";
import * as v from "@atcute/lexicons/validations";

const _mainSchema = /*#__PURE__*/ v.object({
	$type: /*#__PURE__*/ v.optional(/*#__PURE__*/ v.literal("app.andref.chatproto3.writers")),
	identifiers: /*#__PURE__*/ v.optional(
		/*#__PURE__*/ v.array(/*#__PURE__*/ v.actorIdentifierString()),
	),
	since: /*#__PURE__*/ v.datetimeString(),
});

type main$schematype = typeof _mainSchema;

export interface mainSchema extends main$schematype {}

export const mainSchema = _mainSchema as mainSchema;

export interface Main extends v.InferInput<typeof mainSchema> {}
