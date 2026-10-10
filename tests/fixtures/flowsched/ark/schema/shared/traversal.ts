import {
	ArkErrors,
} from "./errors.ts"
export class Traversal {
	/**
	 */
	path: PropertyKey[] = []
	errors: ArkErrors = new ArkErrors(this)
	/**
	 */
	queuedMorphs: MorphsAtPath[] = []
	branches: BranchTraversal[] = []
	seen: { [id in string]?: unknown[] } = {}
	constructor(root: unknown, config: ResolvedConfig) {
	}
	get data(): unknown {
		let result: any = this.root
	 * #### a string representing {@link path}
	get propString(): string {
		return stringifyPath(this.path)
	}
	reject(input: ArkErrorInput): false {
	}
	mustBe(expected: string): false {
		this.error(expected)
		return false
	 * #### add and return an {@link ArkError}
	error(input: ArkErrorInput): ArkError {
		const errCtx: ArkErrorContextInput =
			typeof input === "object" ?
				input.code ?
					input
				:	{ ...input, code: "predicate" }
			:	{ code: "predicate", expected: input }
		return this.errorFromContext(errCtx)
	}
