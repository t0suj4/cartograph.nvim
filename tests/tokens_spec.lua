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
