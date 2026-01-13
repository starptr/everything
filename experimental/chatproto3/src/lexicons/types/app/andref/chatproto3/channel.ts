import type {} from "@atcute/lexicons";
import * as v from "@atcute/lexicons/validations";
import type {} from "@atcute/lexicons/ambient";
import * as AppAndrefChatproto3Writers from "./writers.js";

const _mainSchema = /*#__PURE__*/ v.record(
	/*#__PURE__*/ v.nsidString(),
	/*#__PURE__*/ v.object({
		$type: /*#__PURE__*/ v.literal("app.andref.chatproto3.channel"),
		/**
		 * @minLength 1
		 * @maxGraphemes 128
		 */
		name: /*#__PURE__*/ v.constrain(/*#__PURE__*/ v.string(), [
			/*#__PURE__*/ v.stringLength(1),
			/*#__PURE__*/ v.stringGraphemes(0, 128),
		]),
		get writers() {
			return /*#__PURE__*/ v.array(AppAndrefChatproto3Writers.mainSchema);
		},
	}),
);

type main$schematype = typeof _mainSchema;

export interface mainSchema extends main$schematype {}

export const mainSchema = _mainSchema as mainSchema;

export interface Main extends v.InferInput<typeof mainSchema> {}

declare module "@atcute/lexicons/ambient" {
	interface Records {
		"app.andref.chatproto3.channel": mainSchema;
	}
}
