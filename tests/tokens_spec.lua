-- The token provider: stack languages (Forth, PostScript) into the
-- neutral schema without tree-sitter. Fixtures cover the definer tables,
-- Forth's nearest-preceding redefinition binding, tick/writer forms,
-- comment discipline (\, \G, multi-line parens), imports, cross-file
-- candidate-set refusals, PostScript proc attribution + local
-- suppression, and the volume discipline (at-cap with counted truth).

local tok = require 'cartograph.providers.tokens'

local function fixture(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for f, t in pairs(files) do
        local dir = f:match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(root .. '/' .. dir, 'p') end
        local fd = assert(io.open(root .. '/' .. f, 'w'))
        fd:write(t)
        fd:close()
    end
    local data = tok.extract(root)
    vim.fn.delete(root, 'rf')
    local byid, edges = {}, {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    for _, e in ipairs(data.edges) do
        edges[e.from .. '>' .. e.to .. '[' .. e.kind .. ']'] = e
    end
    return data, byid, edges
end

test('tokens: forth defs, redefinition binds nearest-preceding', function ()
    local _, byid, edges = fixture({
        ['a.fs'] = table.concat({
            ': greet ( -- ) 1 ;',
            ': hail greet ;',      -- binds greet@0
            ': greet ( -- ) 2 ;',  -- redefinition (an [IF] branch shape)
            ': shout greet ;',     -- binds greet@2, Forth semantics
        }, '\n'),
    })
    ok(byid['a.fs::greet@0'] and byid['a.fs::greet@2'], 'both defs exist')
    ok(edges['a.fs::hail@1>a.fs::greet@0[ref]'], 'earlier use binds earlier def')
    ok(edges['a.fs::shout@3>a.fs::greet@2[ref]'], 'later use binds the redefinition')
end)

test('tokens: forth tick/writer/variable and comment discipline', function ()
    local data, byid, edges = fixture({
        ['b.fs'] = table.concat({
            'variable counter',
            '\\ counter mentioned in a comment must not count',
            '\\G doc comment: counter counter counter',
            '( multi-line comment opens here',
            '  counter counter still commented )',
            ': bump 1 counter +! ;',
            ": vec ['] bump ;",
            'code raw end-code',
            '5 constant limit',
        }, '\n'),
    })
    ok(byid['b.fs::counter@0'] and byid['b.fs::counter@0'].kind == 'var', 'variable def')
    ok(byid['b.fs::raw@7'] and byid['b.fs::limit@8'], 'code and constant defs')
    local e = edges['b.fs::bump@5>b.fs::counter@0[use]']
    ok(e, 'use edge from bump to counter')
    eq(1, e.atn, 'comment mentions do not count')
    ok(edges['b.fs::vec@6>b.fs::bump@5[ref]'], "['] bump is a reference")
    for _, c in ipairs(data.calls) do
        ok(c.callee ~= 'multi-line' and c.callee ~= 'doc', 'no comment words leak')
    end
end)

test('tokens: forth include edge + cross-file candidate-set refusal', function ()
    local data, _, edges = fixture({
        ['lib/util.fs'] = ': helper 1 ;\n: shared 1 ;\n',
        ['app.fs'] = table.concat({
            'require lib/util.fs',
            ': shared 2 ;',      -- second FILE defining shared
            ': go helper ;',     -- unique elsewhere: ~ inferred',
        }, '\n'),
        ['other.fs'] = ': test shared ;\n', -- two defining files -> refuse
    })
    ok(edges['app.fs>lib/util.fs[import]'], 'require resolves the import edge')
    local e = edges['app.fs::go@2>lib/util.fs::helper@0[ref]']
    ok(e and e.inferred, 'cross-file unique match is ~')
    local refused
    for _, c in ipairs(data.calls) do
        if c.refused and c.callee == 'shared' and c.file == 'other.fs' then
            refused = c
        end
    end
    ok(refused, 'two defining files refuse')
    eq('ambiguous', refused.refused.rule)
    eq(2, #refused.refused.cands - (#refused.refused.cands - 2), 'candidates carried')
end)

test('tokens: postscript procs, locals suppressed, top-level reg', function ()
    local data, byid, edges = fixture({
        ['draw.ps'] = table.concat({
            '/helper { 1 add } def',
            '/size 10 def',
            '/main { /x exch def x helper size } bind def',
            'main',
            '% helper mentioned in a comment',
            '(helper in a (nested) string)',
        }, '\n'),
    })
    ok(byid['draw.ps::helper@0'] and byid['draw.ps::helper@0'].kind == 'function',
        'proc def')
    ok(byid['draw.ps::size@1'] and byid['draw.ps::size@1'].kind == 'var', 'var def')
    local e = edges['draw.ps::main@2>draw.ps::helper@0[ref]']
    ok(e, 'proc -> proc ref')
    eq(1, e.atn, 'comment and string mentions do not count')
    ok(edges['draw.ps::main@2>draw.ps::size@1[use]'], 'proc -> var use')
    ok(edges['draw.ps>draw.ps::main@2[reg]'], 'top-level invocation is a reg edge')
    for _, c in ipairs(data.calls) do
        ok(c.callee ~= 'x', 'proc-local /x is suppressed, not unresolved')
    end
end)

test('tokens: at-cap keeps counted truth (no silent caps)', function ()
    local uses = {}
    for _ = 1, 12 do uses[#uses + 1] = 'helper' end
    local _, _, edges = fixture({
        ['n.fs'] = ': helper 1 ;\n: caller ' .. table.concat(uses, ' ') .. ' ;\n',
    })
    local e = edges['n.fs::caller@1>n.fs::helper@0[ref]']
    ok(e, 'edge exists')
    eq(12, e.atn, 'full occurrence count kept')
    eq(8, #e.at, 'at list capped at MAX_AT')
end)

test('tokens: declared stack effects — parsed, raw-only, multi-line', function ()
    local _, byid = fixture({
        ['e.fs'] = table.concat({
            ': square ( n -- n^2 ) dup * ;',
            ': noop ( -- ) ;',
            ': weird ( compilation: x -- ; run-time: -- y ) ;',
            ': multi ( a b', '  -- c ) + ;',
            ': bare 1 ;',
            'variable ptr ( -- addr )',
        }, '\n'),
    })
    eq({ 'n' }, byid['e.fs::square@0'].params, 'ins ride params')
    eq({ 'n^2' }, byid['e.fs::square@0'].effect.outs)
    eq({}, byid['e.fs::noop@1'].params, 'declared-zero is {} not nil')
    local w = byid['e.fs::weird@2']
    ok(w.effect and w.effect.raw and not w.effect.ins,
        'double effect stays raw-only, never guessed')
    eq({ 'a', 'b' }, byid['e.fs::multi@3'].params, 'multi-line effect assembles')
    ok(byid['e.fs::bare@5'].effect == nil and byid['e.fs::bare@5'].params == nil,
        'no comment, no fields')
    local p = byid['e.fs::ptr@6']
    ok(p.effect and p.effect.outs[1] == 'addr' and p.params == nil,
        'var effect attaches without params')
end)

test('tokens: the positional checker — derive, grade, bail with reasons', function ()
    local _, byid = fixture({
        ['c.fs'] = table.concat({
            ': sq ( n -- n2 ) dup * ;',
            ': bad ( a b -- c ) drop ;',
            ': pick1 ( f a b -- x ) rot if drop else nip then ;',
            ': odd if dup then ;',
            ': looper ( -- ) begin dup until ;',
            ': juggler ( a -- a ) >r r> ;',
            ': plus2 2 + ;',
            ': chain sq sq ;',
            'variable v',
            ': getv ( -- n ) v @ ;',
            ': dyn ( xt -- ) execute ;',
        }, '\n'),
    })
    local function chk(id, verdict, ins, outs)
        local n = byid[id]
        eq(verdict, n.echeck, id)
        if ins then
            eq(ins, n.derived.ins, id .. ' ins')
            eq(outs, n.derived.outs, id .. ' outs')
        else
            ok(n.derived == nil, id .. ' underivable')
        end
    end
    chk('c.fs::sq@0', 'ok', 1, 1)
    chk('c.fs::bad@1', 'mismatch', 1, 0)
    chk('c.fs::pick1@2', 'ok', 3, 1)          -- IF/ELSE/THEN arms join
    chk('c.fs::odd@3', 'if-join')             -- unbalanced arm: honest bail
    chk('c.fs::looper@4', 'loop')
    chk('c.fs::juggler@5', 'rstack')
    chk('c.fs::plus2@6', 'undeclared', 1, 1)  -- derived fills missing docs
    chk('c.fs::chain@7', 'undeclared', 1, 1)  -- composes via sq's DECLARED
    chk('c.fs::getv@9', 'ok', 0, 1)           -- var mention pushes addr
    chk('c.fs::dyn@10', 'execute')            -- quotations stay honest
end)

test('tokens: load-order walk — shadowing, islands, checker callees', function ()
    local data, _, edges = fixture({
        ['boot.fs'] = 'include early.fs\ninclude late.fs\ninclude user.fs\n',
        ['early.fs'] = ': shared ( -- n ) 1 ;\n',
        ['late.fs'] = ': shared ( -- n ) 2 ;\n',
        ['user.fs'] = ': go ( -- n ) shared ;\n',
        ['island.fs'] = ': lost shared ;\n', -- no root reaches it
    })
    local e = edges['user.fs::go@0>late.fs::shared@0[ref]']
    ok(e and e.inferred, 'walk binds the LATEST def in load order, as ~')
    ok(not edges['user.fs::go@0>early.fs::shared@0[ref]'],
        'the shadowed def is not bound')
    local refused
    for _, c in ipairs(data.calls) do
        if c.refused and c.file == 'island.fs' then refused = c end
    end
    ok(refused, 'unreached files keep the honest refusal')
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    eq('ok', byid['user.fs::go@0'].echeck,
        'checker resolves callees through the walk')
end)

-- ── WIRING: the token provider is reachable from an :Cartograph open ───────
-- It produced correct graphs for a long while with nothing routing to it, so
-- these cover the seam rather than the tokenizer: one file walk classifies both
-- providers' files, and a token graph survives store.ingest.

local ts = require 'cartograph.providers.treesitter'

local function tree(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]+$')
        vim.fn.mkdir(dir, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    return root
end

test('list_files: stack-language files come back separately from ts files', function ()
    local root = tree {
        ['core.fs']     = ': double dup + ;\n',
        ['sub/main.fs'] = ': main double ;\n',
        ['art.ps']      = '/box { 4 2 rectfill } def\n',
        ['build.lua']   = 'local M = {}\nreturn M\n',
    }
    local tsf, _, tok = ts.list_files(root)
    eq({ 'build.lua' }, tsf, 'tree-sitter claims only what it has a grammar for')
    eq({ 'art.ps', 'core.fs', 'sub/main.fs' }, tok, 'the dialects come back third, sorted')
    vim.fn.delete(root, 'rf')
end)

test('list_files: the token list inherits the walk\'s exclusions', function ()
    local root = tree {
        ['core.fs'] = ': double dup + ;\n',
        ['node_modules/vendored.fs'] = ': junk ;\n',
        ['vendor/also.fs'] = ': junk2 ;\n',
    }
    local _, _, tok = ts.list_files(root)
    eq({ 'core.fs' }, tok, 'vendored dirs are skipped for dialects too, not just for ts')
    vim.fn.delete(root, 'rf')
end)

test('a token graph ingests, and declares that its calls are aggregated', function ()
    local root = tree { ['core.fs'] = ': double dup + ;\n: quad double double ;\n' }
    local data = tok.extract(root, { files = { 'core.fs' } })
    eq('tokens', data.provider, 'the graph carries its own provider identity')
    eq('aggregated', (data.capabilities or {}).calls,
        'and says calls are aggregated — the reason this is not merged into a ts graph')
    local store = require 'cartograph.store'
    store.ingest(data)
    local words = {}
    for _, n in pairs(store.by_id) do
        if n.kind == 'function' then words[#words + 1] = n.name end
    end
    table.sort(words)
    eq({ 'double', 'quad' }, words, 'words are browsable nodes after ingest')
    vim.fn.delete(root, 'rf')
end)
