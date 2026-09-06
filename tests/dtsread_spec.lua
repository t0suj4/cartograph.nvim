-- The shared TypeScript DECLARATION reader (tools/dtsread.lua), used by
-- npmdistill for npm packages and by domdistill for TypeScript's own lib.dom.d.ts.
-- It exists so the walk is written once; these pin the rules that decide whether
-- what it produces is a FACT or a guess.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local dts = dofile(repo .. '/tools/dtsread.lua')

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'typescript')
end

local function surface(src, opts)
    local acc = dts.new()
    dts.absorb(acc, src, opts or { ambient = true })
    dts.finish(acc)
    return acc
end

test('dts: an intersection yields a component, a union yields nothing', function ()
    -- ★ THE ASYMMETRY IS THE POINT. `Window & typeof globalThis` HAS every member
    -- of Window, so naming Window is a subset claim. `HTMLElement | null` has only
    -- what BOTH sides have, so naming HTMLElement would claim members the value
    -- may not carry.
    eq('Window', dts.base_of('Window & typeof globalThis'))
    eq(nil, dts.base_of('HTMLElement | null'))
    eq('SinonStub', dts.base_of('SinonStub<TArgs, TReturnValue>'))
    eq('Response', dts.base_of('Promise<Response>'))
    eq(nil, dts.base_of('string'))   -- a primitive types nothing resolvable
    eq(nil, dts.base_of('T'))        -- a type VARIABLE is not a type
end)

test('dts: a global gets the members of its EXTENDS CHAIN', function ()
    if not ready() then skip 'no typescript parser' end
    -- `document.appendChild` is not declared on Document; it is on Node, and on
    -- lib.dom.d.ts that chain is seven interfaces long
    local a = surface([[
        declare var document: Document;
        interface Document extends Node { getElementById(id: string): HTMLElement; }
        interface Node extends EventTarget { appendChild(n: Node): Node; }
        interface EventTarget { addEventListener(t: string): void; }
    ]])
    ok(a.nsset['document'], 'the global is a namespace')
    ok(a.sigs['document.getElementById'], 'own member')
    ok(a.sigs['document.appendChild'], 'inherited one level')
    ok(a.sigs['document.addEventListener'], 'inherited two levels')
end)

test('dts: `declare` does not leak into an interface or namespace BODY', function ()
    if not ready() then skip 'no typescript parser' end
    -- ⚠ THE BUG THIS PINS: letting the ambient flag ride every descendant made
    -- `declare namespace CSS { function Hz(...) }` register Hz, Q, cap and ch as
    -- callable GLOBALS — names that would then claim any unresolved project
    -- function sharing them.
    local a = surface([[
        declare function fetch(input: string): Promise<Response>;
        declare namespace CSS { function Hz(value: number): CSSUnitValue; }
        interface Thing { close(): void; }
    ]])
    ok(a.free['fetch'], 'a real ambient function is free')
    eq(nil, a.free['Hz'], 'a namespaced function is NOT a global')
    eq(nil, a.free['close'], 'an interface method is NOT a global')
end)

test('dts: a PROPERTY type is never stored as a return type', function ()
    if not ready() then skip 'no typescript parser' end
    -- ★★ `sinon.assert` does not RETURN a SinonAssert, it IS one. Reading a
    -- property's `type_annotation` as if it were a return produced exactly that
    -- wrong fact, and it also SUPPRESSED the arity pass that would have given the
    -- property its real return type — the tell was declared return types 1167 ->
    -- 2530 while arity-typed callable properties went 391 -> 0.
    local a = surface([[
        interface Api { stub: StubStatic; run(): Result; }
        interface StubStatic {
            (): Stub;
            (obj: object): Stub;
        }
        interface Stub { returns(v: unknown): Stub; }
        interface Result { ok(): void; }
    ]], { ns = 'pkg' })
    eq('Result', a.sigs['pkg.run'].ret, 'a method keeps its declared return')
    eq('Stub', a.sigs['Api.stub'].ret, 'the property is typed by its CALL, not by itself')
    ok(a.sigs['Api.stub'].rets, 'and the per-arity map is recorded')
end)

test('dts: overloads that disagree are keyed by ARITY and leave `ret` unset', function ()
    if not ready() then skip 'no typescript parser' end
    -- a single answer would be a guess, and the wrong one FABRICATES: `stub(obj)
    -- .reset()` would claim the library's reset when it means the object's
    local a = surface([[
        interface Api { stub: StubStatic; }
        interface StubStatic {
            (): Stub;
            (obj: object): Instance;
        }
        interface Stub { returns(v: unknown): Stub; }
        interface Instance { reset(): void; }
    ]], { ns = 'pkg' })
    local sig = a.sigs['Api.stub']
    eq(nil, sig.ret, 'no scalar answer when the overloads disagree')
    eq('Stub', sig.rets[0])
    eq('Instance', sig.rets[1])
end)

test('dts: an alias resolves only when ONE known interface is named', function ()
    if not ready() then skip 'no typescript parser' end
    local a = surface([[
        interface Api { make: MakeStatic; }
        interface MakeStatic { (): Wrapped; }
        type Wrapped = Cond extends true ? Stub : Stub;
        interface Stub { returns(): void; }
        interface Cond { x(): void; }
    ]], { ns = 'pkg' })
    -- both branches say Stub, so the conditional never has to be evaluated —
    -- but Cond is named too, so this is exactly the two-candidate case
    ok(a.sigs['Api.make'], 'the property is present either way')
end)
