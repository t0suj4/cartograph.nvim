-- The LSP read surface: the pure handler table, tested transport-free. Build a
-- graph, ingest, call M.handlers[...](store, params), assert the LSP-shaped
-- result — the honesty contract especially (resolved -> Location, navigable
-- refusal -> candidate set, frontier -> empty + why-on-hover).

local store = require 'cartograph.store'
local lsp = require 'cartograph.lsp'

local function rng(sl, sc, el, ec)
    return { start = { line = sl, char = sc }, ['end'] = { line = el, char = ec } }
end
local function fn(file, name, r)
    return { id = file .. '::' .. name, name = name, kind = 'function',
        file = file, range = r, order = 0 }
end

-- a.lua: foo (lines 0-3) calls bar (line 1), a refused 'mystery' (line 2, one
-- candidate b.lua::baz), and a frontier 'extern' (line 3); foo reads var v.
local DATA = {
    root = '/x',
    nodes = {
        { id = 'a.lua', name = 'a.lua', kind = 'module', file = 'a.lua', range = rng(0, 0, 20, 0), order = 0 },
        fn('a.lua', 'foo', rng(0, 0, 3, 20)),
        fn('a.lua', 'bar', rng(5, 9, 6, 3)),
        { id = 'a.lua::v', name = 'v', kind = 'var', file = 'a.lua', range = rng(8, 6, 8, 7), order = 3 },
        { id = 'b.lua', name = 'b.lua', kind = 'module', file = 'b.lua', range = rng(0, 0, 5, 0), order = 0 },
        fn('b.lua', 'baz', rng(0, 9, 1, 3)),
    },
    edges = {
        { from = 'a.lua::foo', to = 'a.lua::bar', kind = 'ref', at = { rng(1, 4, 1, 7) } },
        { from = 'a.lua::foo', to = 'a.lua::v', kind = 'use', at = { rng(0, 10, 0, 11) }, rw = 1 },
    },
    calls = {
        { fn = 'a.lua::foo', callee = 'bar', file = 'a.lua', line = 1,
            to = 'a.lua::bar', at = rng(1, 4, 1, 7) },
        { fn = 'a.lua::foo', callee = 'mystery', file = 'a.lua', line = 2,
            at = rng(2, 4, 2, 11), refused = { rule = 'ambiguous', cands = { 'b.lua::baz' }, n = 1 } },
        { fn = 'a.lua::foo', callee = 'extern', file = 'a.lua', line = 3,
            at = rng(3, 4, 3, 10) },
    },
}

local function uri(f) return vim.uri_from_fname('/x/' .. f) end
local function at(file, line, character)
    return { textDocument = { uri = uri(file) }, position = { line = line, character = character } }
end
local function H(method, params) return lsp.handlers[method](store, params) end

test('lsp: definition on a resolved call -> the target Location', function ()
    store.ingest(DATA)
    local r = H('textDocument/definition', at('a.lua', 1, 5))
    eq(1, #r)
    eq(uri('a.lua'), r[1].uri)
    eq(5, r[1].range.start.line) -- bar's def line
end)

test('lsp: definition on a navigable refusal -> the candidate set', function ()
    store.ingest(DATA)
    local r = H('textDocument/definition', at('a.lua', 2, 6))
    eq(1, #r)
    eq(uri('b.lua'), r[1].uri) -- the candidate baz, in b.lua
    eq(0, r[1].range.start.line)
end)

test('lsp: definition on a frontier -> EMPTY (never a fabricated guess)', function ()
    store.ingest(DATA)
    eq({}, H('textDocument/definition', at('a.lua', 3, 6)))
end)

test('lsp: definition on a def name -> the def itself', function ()
    store.ingest(DATA)
    local r = H('textDocument/definition', at('a.lua', 5, 10)) -- on bar's def
    eq(1, #r)
    eq(5, r[1].range.start.line)
end)

test('lsp: documentSymbol -> the file\'s navigable nodes with kinds', function ()
    store.ingest(DATA)
    local syms = H('textDocument/documentSymbol', { textDocument = { uri = uri('a.lua') } })
    local by = {}
    for _, s in ipairs(syms) do by[s.name] = s.kind end
    eq(12, by.foo); eq(12, by.bar); eq(13, by.v) -- Function/Function/Variable
    eq(nil, by['a.lua'], 'the module node is not a document symbol')
end)

test('lsp: hover on a resolved call surfaces the tier (the honesty face)', function ()
    store.ingest(DATA)
    local h = H('textDocument/hover', at('a.lua', 1, 5))
    ok(h.contents.value:find('bar'), h.contents.value)
    ok(h.contents.value:find('tier: `matched`'), h.contents.value)
end)

test('lsp: hover on a refusal surfaces the rule + candidate count', function ()
    store.ingest(DATA)
    local h = H('textDocument/hover', at('a.lua', 2, 6))
    ok(h.contents.value:find('unresolved'), h.contents.value)
    ok(h.contents.value:find('ambiguous'), h.contents.value)
    ok(h.contents.value:find('1 candidate'), h.contents.value)
end)

test('lsp: hover on a frontier says external, not a guess', function ()
    store.ingest(DATA)
    local h = H('textDocument/hover', at('a.lua', 3, 6))
    ok(h.contents.value:find('external frontier'), h.contents.value)
end)

test('lsp: references gathers caller sites, +decl when asked', function ()
    store.ingest(DATA)
    local base = at('a.lua', 1, 5) -- on the call to bar -> target is bar
    base.context = { includeDeclaration = false }
    local refs = H('textDocument/references', base)
    eq(1, #refs) -- the one call site inside foo
    eq(1, refs[1].range.start.line)
    base.context = { includeDeclaration = true }
    eq(2, #H('textDocument/references', base)) -- + bar's declaration
end)

test('lsp: references on a variable gathers its use sites', function ()
    store.ingest(DATA)
    -- cursor on v's def; references = the use inside foo
    local refs = H('textDocument/references', at('a.lua', 8, 6))
    eq(1, #refs)
    eq(0, refs[1].range.start.line) -- foo's read of v at line 0
end)

test('lsp: workspace/symbol matches exact + tail + substring', function ()
    store.ingest(DATA)
    local function names(q)
        local out = {}
        for _, s in ipairs(H('workspace/symbol', { query = q })) do out[s.name] = true end
        return out
    end
    ok(names('bar').bar, 'exact')
    ok(names('ba').bar and names('ba').baz, 'substring hits both')
    eq(nil, names('bar')['a.lua'], 'modules are not workspace symbols')
end)

test('lsp: initialize advertises only the served capabilities', function ()
    local c = H('initialize', {}).capabilities
    eq(true, c.definitionProvider); eq(true, c.referencesProvider)
    eq(true, c.documentSymbolProvider); eq(true, c.hoverProvider)
    eq(true, c.workspaceSymbolProvider)
    eq('utf-8', c.positionEncoding)
    eq(nil, c.completionProvider, 'no completion in the read MVP')
end)

test('lsp: handle() dispatches and rejects unknown methods', function ()
    store.ingest(DATA)
    local r = lsp.handle(store, 'textDocument/documentSymbol', { textDocument = { uri = uri('a.lua') } })
    eq(3, #r)
    local _, err = lsp.handle(store, 'textDocument/completion', {})
    ok(err and err:find('method not found'), err)
end)

test('lsp: prepareCallHierarchy names the symbol under the cursor', function ()
    store.ingest(DATA)
    local r = H('textDocument/prepareCallHierarchy', at('a.lua', 1, 5)) -- on the bar call
    eq(1, #r); eq('bar', r[1].name); eq('a.lua::bar', r[1].data.id)
    local d = H('textDocument/prepareCallHierarchy', at('a.lua', 5, 10)) -- on bar's def
    eq('a.lua::bar', d[1].data.id)
end)

test('lsp: callHierarchy incoming/outgoing walk the call graph', function ()
    store.ingest(DATA)
    local inc = H('callHierarchy/incomingCalls', { item = { data = { id = 'a.lua::bar' } } })
    eq(1, #inc); eq('foo', inc[1].from.name)
    eq(1, inc[1].fromRanges[1].start.line) -- the call site inside foo, line 1
    local out = H('callHierarchy/outgoingCalls', { item = { data = { id = 'a.lua::foo' } } })
    eq(1, #out); eq('bar', out[1].to.name) -- foo -> bar (the use edge foo->v is not a call)
end)

test('lsp: cartograph/why is the honesty record, programmatic', function ()
    store.ingest(DATA)
    local resolved = H('cartograph/why', at('a.lua', 1, 5))
    eq('resolved', resolved.status); eq('a.lua::bar', resolved.target); eq('matched', resolved.tier)
    local refused = H('cartograph/why', at('a.lua', 2, 6))
    eq('refused', refused.status); eq('ambiguous', refused.rule); eq(1, refused.candidates)
    eq('frontier', H('cartograph/why', at('a.lua', 3, 6)).status)
    local def = H('cartograph/why', at('a.lua', 5, 10))
    eq('def', def.kind); eq('bar', def.name)
end)

test('lsp: cartograph/graphInfo carries the provenance header', function ()
    store.ingest(DATA)
    local g = H('cartograph/graphInfo', {})
    eq('/x', g.root); eq(6, g.counts.nodes); eq(3, g.counts.calls)
    ok(g.cacheVersion, 'cache version stamped')
end)

test('lsp: diagnostics maps the graph-aware lint per file (T2 push)', function ()
    store.ingest(DATA)
    -- foo has no callers, is not exported -> the dead-function lint fires on it
    local diags = lsp.diagnostics(store, uri('a.lua'))
    local dead
    for _, d in ipairs(diags) do if d.code == 'dead-function' then dead = d end end
    ok(dead, 'dead-function diagnostic present for foo')
    eq('cartograph', dead.source)
    eq(2, dead.severity) -- warn
    eq(0, dead.range.start.line) -- foo's def line
end)

-- a Java-flavored graph: interface Api{label}, Impl implements Api, make():Api
local JDATA = {
    root = '/j',
    nodes = {
        { id = 'Api.java', name = 'Api.java', kind = 'module', file = 'Api.java', range = rng(0, 0, 10, 0), order = 0 },
        { id = 'Api.java::Api', name = 'Api', kind = 'function', file = 'Api.java', range = rng(0, 0, 2, 1), order = 0 },
        { id = 'Api.java::Api::label', name = 'Api::label', kind = 'method', file = 'Api.java', range = rng(1, 4, 1, 20), order = 1 },
        { id = 'Api.java::make', name = 'make', kind = 'function', file = 'Api.java', range = rng(4, 0, 6, 1), order = 2, ret = 'Api' },
        { id = 'Impl.java', name = 'Impl.java', kind = 'module', file = 'Impl.java', range = rng(0, 0, 10, 0), order = 0 },
        { id = 'Impl.java::Impl', name = 'Impl', kind = 'function', file = 'Impl.java', range = rng(0, 0, 5, 1), order = 0 },
        { id = 'Impl.java::Impl::label', name = 'Impl::label', kind = 'method', file = 'Impl.java', range = rng(2, 4, 3, 5), order = 1 },
    },
    edges = {}, calls = {},
    implements = { { iface = 'Api', child = 'Impl', file = 'Impl.java' } },
}
local function jat(f, l, ch) return { textDocument = { uri = vim.uri_from_fname('/j/' .. f) }, position = { line = l, character = ch } } end

test('lsp: typeDefinition resolves the value\'s type node (n.ret)', function ()
    store.ingest(JDATA)
    local r = lsp.handlers['textDocument/typeDefinition'](store, jat('Api.java', 4, 2)) -- on make():Api
    eq(1, #r)
    eq(vim.uri_from_fname('/j/Api.java'), r[1].uri)
    eq(0, r[1].range.start.line) -- the Api interface node
end)

test('lsp: implementation lists interface impls (class + method)', function ()
    store.ingest(JDATA)
    -- on the interface CLASS Api -> the Impl class
    local cls = lsp.handlers['textDocument/implementation'](store, jat('Api.java', 0, 1))
    eq(1, #cls); eq(vim.uri_from_fname('/j/Impl.java'), cls[1].uri)
    -- on the interface METHOD Api::label -> Impl::label
    local m = lsp.handlers['textDocument/implementation'](store, jat('Api.java', 1, 10))
    eq(1, #m); eq(2, m[1].range.start.line) -- Impl::label's def line
end)

test('lsp: implementation is empty where there is no implements data', function ()
    store.ingest(DATA) -- no data.implements
    eq({}, lsp.handlers['textDocument/implementation'](store, at('a.lua', 5, 10)))
end)

test('lsp: semanticTokens tint resolved calls by their tier (delta-encoded)', function ()
    store.ingest(DATA)
    local r = lsp.handlers['textDocument/semanticTokens/full'](store,
        { textDocument = { uri = uri('a.lua') } })
    -- only the resolved foo->bar call (line 1, char 4-7); matched = last rung
    local matched_bit = 2 ^ (#require('cartograph.tier').LADDER - 1)
    eq({ 1, 4, 3, 0, matched_bit }, r.data)
end)

test('lsp: the T1 in-process server wrapper dispatches via callback', function ()
    store.ingest(DATA)
    local srv = lsp.make_server(store)(nil) -- cmd(dispatchers) -> server object
    local got
    srv.request('textDocument/definition', at('a.lua', 1, 5),
        function (e, res) got = { e = e, res = res } end)
    eq(nil, got.e); eq(1, #got.res)
    local err
    srv.request('textDocument/nope', {}, function (e) err = e end)
    eq(-32601, err.code) -- unknown method -> LSP error via callback, no throw
    ok(not srv.is_closing())
    srv.notify('exit')
    ok(srv.is_closing())
end)
