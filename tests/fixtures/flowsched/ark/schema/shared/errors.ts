export class ArkError<
> extends CastableBase<ArkErrorContextInput<code>> {
	constructor(
		{ prefixPath, relativePath, ...input }: ArkErrorContextInput,
		ctx: Traversal
	) {
		this.input = input as never
		this.ctx = ctx
		if (input.code === "union") {
			input.errors = input.errors.flatMap(innerError => {
				const flat =
					innerError.hasCode("union") ? innerError.errors : [innerError]
				return flat.map(e =>
						e =>
							({
					)
				)
			})
		}
		this.nodeConfig = ctx.config[this.code] as never
		this.path = new ReadonlyPath(...basePath)
	}
	transform(
		f: (input: ArkErrorContextInput<code>) => ArkErrorContextInput
	): ArkError {
		return new ArkError(
			f({
			}),
			this.ctx
		) as never
	}
	hasCode<code extends ArkErrorCode>(code: code): this is ArkError<code> {
	}
	get propString(): string {
	}
	get expected(): string {
	}
	get actual(): string {
	}
	get problem(): string {
	}
	get message(): string {
	}
	get flat(): ArkError[] {
		return this.hasCode("intersection") ? [...this.errors] : [this as never]
	}
	toJSON(): JsonObject {
		return {
		} as never
	}
	toString(): string {
	}
	throw(): never {
}
}
export class ArkErrors
{
	constructor(ctx: Traversal) {
		this.ctx = ctx
	}
	get flatByPath(): Record<string, ArkError[]> {
		return flatMorph(this.byPath, (k, v) => [k, v.flat])
	 * {@link byPath} flattened so that each value is an array of problem strings at that path.
	get flatProblemsByPath(): Record<string, string[]> {
	}
	private mutable: ArkError[] = this as never
	throw(): never {
	}
	toTraversalError(): TraversalError {
		return new TraversalError(this)
	}
	add(error: ArkError): void {
		const existing = this.byPath[error.propString]
		if (existing) {
			const errorIntersection =
				:	new ArkError(
						{
							errors:
								existing.hasCode("intersection") ?
									[...existing.errors, error]
								:	[existing, error]
					)
			this.mutable[existingIndex === -1 ? this.length : existingIndex] =
				errorIntersection
		}
	}
	transform(f: (e: ArkError) => ArkError): ArkErrors {
		const result = new ArkErrors(this.ctx)
		for (const e of this) result.add(f(e))
	}
	merge(errors: ArkErrors): void {
		for (const e of errors) {
			this.add(
				new ArkError(
					{ ...e, path: [...this.ctx.path, ...e.path] } as never,
					this.ctx
				)
			)
		}
	}
	affectsPath(path: ReadonlyPath): boolean {
	}
	get summary(): string {
	}
	get message(): string {
	}
	get issues(): this {
	}
	toJSON(): JsonArray {
		return [...this.map(e => e.toJSON())]
	}
	toString(): string {
	}
	private addAncestorPaths(error: ArkError): void {
}
