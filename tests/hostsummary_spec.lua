-- cartograph.hostsummary — ONE summary of a runtime's own Lua, read by flowtype and by effects (CART-1786). Needs the
-- nvim runtime the nvim profile was distilled from (its sig_source): skipped where it is not here.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local HS = require 'cartograph.hostsummary'

local function runtime_here()
    local pr = require('cartograph.spec.profile').load('nvim')
    return pr and pr.sig_source and vim.uv.fs_stat(pr.sig_source .. '/lua/vim/_core/shared.lua') and true or false
end

local function tree(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        vim.fn.mkdir((root .. '/' .. rel):match('^(.*)/[^/]+$'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'wb')); fd:write(src); fd:close()
    end
    return root
end

-- (S1: the record, read off a placeholder solve of shared.lua alone — what each function returns, stores into its
-- parameters' paths, calls through them; stamped by the runtime's version and the file's hash)
test('hostsummary: shared.lua summarized from its source — results, stores, calls over parameter paths', function ()
    if not runtime_here() then skip 'the nvim runtime is not here' end
    local hs = HS.of('nvim')
    ok(hs and hs.stamp:find('lua/vim/_core/shared.lua=', 1, true), 'stamped by the source hash: ' .. tostring(hs and hs.stamp))
    local m = hs.fns['vim#tbl_map']
    eq(1, #m.calls, 'tbl_map calls one thing')
    eq('param', m.calls[1].callee[1]); eq(1, m.calls[1].callee[2]); eq('', m.calls[1].callee[3])
    ok(vim.inspect(m.calls[1].args[1]):find('"param", 2, "%[%]"'), 'with its second argument\'s elements: ' .. vim.inspect(m.calls[1].args))
    local r = m.results[1][1]
    eq('new', r[1], 'and returns a NEW table')
    ok(vim.inspect(r.fields['[]']):find('"call", 1, 1', 1, true), 'holding what the call returned: ' .. vim.inspect(r.fields['[]']))
    local rl = hs.fns['vim#tbl_add_reverse_lookup']
    ok(#rl.stores > 0 and rl.stores[1].at[1] == 'param' and rl.stores[1].at[2] == 1, 'tbl_add_reverse_lookup WRITES its argument')
    eq('param', rl.results[1][1][1], 'and returns it')
    -- (the projection: tbl_map CALLS its argument; vim.split's `s:find()` is the argument's own METHOD, no call of it)
    ok(HS.effects_sig(m).calls[1], 'tbl_map calls its argument')
    ok(not HS.effects_sig(hs.fns['vim#split']).calls[1], 'split does not call its argument: ' .. vim.inspect(HS.effects_sig(hs.fns['vim#split'])))
    ok(not HS.effects_sig(hs.fns['vim#trim']).calls[1], 'nor trim, whose `s:match()` runs in its own body: ' .. vim.inspect(hs.fns['vim#trim'].calls))
    -- (a depth-capped path is no store — the cap's unknown fill is not a value put there)
    eq(0, #hs.fns['vim#deep_equal'].stores, 'deep_equal stores nothing')
end)

-- (S2: effects' signature is the summary's PROJECTION, ahead of the hand table — the hand `vim.tbl_` prefix said pure,
-- and vim.tbl_add_reverse_lookup writes its argument)
test('hostsummary: effects reads the projection — a function handing its parameter to tbl_add_reverse_lookup writes it', function ()
    if not runtime_here() then skip 'the nvim runtime is not here' end
    local root = tree({ ['lua/p/init.lua'] = 'local M = {}\nfunction M.rev(t) vim.tbl_add_reverse_lookup(t) end\nfunction M.keys(t) return vim.tbl_keys(t) end\nreturn M\n' })
    store.ingest(ts.extract(root))
    store.data.profile = 'nvim'
    local fx = require 'cartograph.effects'
    local ids = {}
    for _, n in ipairs(store.data.nodes) do if n.name == 'M.rev' or n.name == 'M.keys' then ids[n.name] = n.id end end
    store._fx = nil
    local S = fx.summaries(store)
    ok(S[ids['M.rev']].pwx and S[ids['M.rev']].pwx[1], 'derived: M.rev writes its parameter: ' .. vim.inspect(S[ids['M.rev']]))
    ok(not S[ids['M.keys']].pwx, 'tbl_keys writes nothing')
    fx.NODERIVED = true
    store._fx = nil; store.generation = store.generation + 1
    local H = fx.summaries(store)
    fx.NODERIVED = nil
    ok(not H[ids['M.rev']].pwx, 'the hand table alone (`vim.tbl_` = pure) said it writes nothing')
    store._fx = nil; store.generation = store.generation + 1
    vim.fn.delete(root, 'rf')
end)

-- (S3, applied as edges: a METHOD call on the argument is the argument's type's method — `s:upper()` on a string is a
-- string; an UNKNOWN source — a closure it returns, a path past its depth — is tainted, never ext (ext reaches the
-- unknown-code channel, which calls every function it is handed). A summary of a function no signature types)
test('hostsummary: a summary applied as edges — a method on the argument is typed, an unknown source is partial', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local flowtype = require 'cartograph.flowtype'
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
        'local _ = setmetatable({}, { __index = B }):m()',
        'local F1, F2 = {}, {}', 'function F1.find(self) end', 'function F2.find(self) end', -- (s:find is ambiguous: a verdict)
        'local s = host.up("x")', 's:find("x")',
        'local u = host.mystery()', 'u:m()',
        'local cb = function (q) return q end', 'host.each(cb)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local at = {}
    for _, c in ipairs(store.data.calls) do local k = callrec.full(c); if k then at[k] = c end end
    local SUM = {
        ['host#up'] = { nparams = 1, results = { { { 'call', 1, 1, '' } } }, stores = {}, calls = { { callee = { 'param', 1, '.upper' }, args = { { { 'param', 1, '' } } }, now = true, method = true } } },
        ['host#mystery'] = { nparams = 0, results = { { { 'unknown', 'ext' } } }, stores = {}, calls = {} },
        ['host#each'] = { nparams = 1, results = {}, stores = {}, calls = {} },
    }
    local R = flowtype.solve(store, { open = false, hostsummary = SUM, explain = true, exp = 'expose' })
    local v = R.verdict(at['s:find'])
    ok(v and v.kind == 'string' and not v.partial, 'the method result of a string argument is a string: ' .. vim.inspect(v))
    -- (u's receiver: tainted by the summary, holding no ext)
    local I, recv = R.internals, nil
    for _, pr in ipairs(I.probes) do if pr.c == at['u:m'] then recv = pr.recv end end
    assert(recv, 'u:m is a probe')
    local ext = false
    for o in I.each(recv) do if tostring(I.obinfo[o]) == 'external' then ext = true end end
    ok(not ext, 'no ext reaches it')
    ok(I.tainted[recv], 'it is tainted')
    ok(table.concat(R.taint_path(recv), ' | '):find("host summary's unknown source", 1, true), 'by the summary\'s unknown source: ' .. table.concat(R.taint_path(recv), ' | '))
    vim.fn.delete(root, 'rf')
end)
