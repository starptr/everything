import type {} from "@atcute/lexicons";
import * as v from "@atcute/lexicons/validations";
import type {} from "@atcute/lexicons/ambient";

const _mainSchema = /*#__PURE__*/ v.record(
	/*#__PURE__*/ v.tidString(),
	/*#__PURE__*/ v.object({
		$type: /*#__PURE__*/ v.literal("app.andref.chatproto3.message"),
		channel: /*#__PURE__*/ v.nsidString(),
		createdAt: /*#__PURE__*/ v.datetimeString(),
		/**
		 * @minLength 1
		 * @maxGraphemes 4000
		 */
		plaintext: /*#__PURE__*/ v.optional(
			/*#__PURE__*/ v.constrain(/*#__PURE__*/ v.string(), [
				/*#__PURE__*/ v.stringLength(1),
				/*#__PURE__*/ v.stringGraphemes(0, 4000),
			]),
		),
	}),
);

type main$schematype = typeof _mainSchema;

export interface mainSchema extends main$schematype {}

export const mainSchema = _mainSchema as mainSchema;

export interface Main extends v.InferInput<typeof mainSchema> {}

declare module "@atcute/lexicons/ambient" {
	interface Records {
		"app.andref.chatproto3.message": mainSchema;
	}
}
