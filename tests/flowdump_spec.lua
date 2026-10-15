-- cartograph.flowdump — flowtype's program in the flowpath core IR with its solution (CART-1710), and
-- cartograph.flowcheck — the Lean checker's constraints transcribed (Core/Andersen.lean `Constraint`, Core/Errors.lean
-- `EConstraint`, Lua instance): a dump of a route fixture is CLOSED except where an instruction carries a named
-- divergence, every variable that holds something is written by an instruction, and the route's opcode is there.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local flowtype = require 'cartograph.flowtype'
local flowcheck = require 'cartograph.flowcheck'

local function tree(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        vim.fn.mkdir((root .. '/' .. rel):match('^(.*)/[^/]+$'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    return root
end

local CLASSES = table.concat({
    'local A, B = {}, {}',
    'function A.m(self) return "A" end',
    'function B.m(self) return "B" end',
    'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
    'local function use(p) return p:m() end',
    'use(a)' }, '\n') .. '\n'

local function dump(src)
    local root = tree({ ['m.lua'] = CLASSES .. src })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    return vim.json.decode(R.dump), R
end
local function opcodes(D)
    local ops = {}
    for _, F in ipairs(D.functions) do for _, i in ipairs(F.body) do ops[i[1]] = (ops[i[1]] or 0) + 1 end end
    return ops
end

-- (each route: the opcode its translation must produce, and the divergence its check may name)
local ROUTES = {
    { 'errorval', 'local ok, e = pcall(function () error(b) end)\nprint(use(e))\n', { 'pcall', 'error' } },
    { 'callmeta', 'local function h(self, p) return p:m() end\nh(nil, a)\nlocal c = setmetatable({}, { __call = h })\nprint(c(b))\n', { 'call', 'setmeta' } },
    { 'opmeta', 'local function add(x, p) return p:m() end\nadd(nil, a)\nlocal box = setmetatable({}, { __add = add })\nprint(box + b)\n', { 'op' } },
    { 'indexfn', 'local lazy = setmetatable({}, { __index = function (t, k) return b end })\nprint(use(lazy.anything))\n', { 'load', 'setmeta' } },
    { 'dynamic', 'local t = {}\nlocal k = ("q"):upper()\nt[k] = b\nprint(use(t[k]))\n', { 'storeDyn', 'loadDyn' } },
    { 'coroutine', 'local function f(p) return p:m() end\nlocal co = coroutine.create(f)\nprint(coroutine.resume(co, b))\n', { 'cocreate', 'resume' }, 'divergence:coroutine' },
    { 'yield', 'local co = coroutine.create(function () coroutine.yield(b) end)\nlocal ok, v = coroutine.resume(co)\nprint(use(v))\n', { 'yield', 'resume' }, 'divergence:coroutine' },
    { 'varargs', 'local function f(...) return use(...) end\nprint(f(b))\n', { 'call' } },
    { 'globals', '_G.q = b\nprint(use(q))\n', { 'store', 'load' } },
    -- (a KEYED COPY `t[k] = S[k]` has no core opcode: field-wise, it is a gap, and its pairing writes nothing — CART-1726)
    { 'keyed-copy', 'local t = {}\nlocal S = { x = b }\nfor _, k in ipairs({ "x" }) do t[k] = S[k] end\nprint(use(t.x))\n', { 'load' } },
    -- (a function has no metatable of its own: a shared setmetatable helper that also receives a function must not give
    -- it one — the core would run __call when the function is called, which Lua never does)
    { 'fn-meta', 'local function h(self, p) return p:m() end\nh(nil, a)\nlocal function sm(x) return setmetatable(x, { __call = h }) end\nsm({})\nlocal function g() end\npcall(sm, g)\ng(b)\n', { 'setmeta', 'call' } },
    { 'fn-meta-direct', 'local function h(self, p) return p:m() end\nh(nil, a)\nlocal function g() end\npcall(function () setmetatable(g, { __call = h }) end)\ng(b)\n', { 'setmeta', 'call' } },
}
for _, r in ipairs(ROUTES) do
    test(('flowdump: %s — the dump is closed (but for a named divergence), complete, and holds %s'):format(r[1], table.concat(r[3], ', ')), function ()
        if not parser_available('lua') then skip 'no lua parser' end
        local D = dump(r[2])
        local c = flowcheck.check(D, 5)
        for k, n in pairs(c.counts) do
            -- (a `(model)` class is a place the Lean model is coarser than Lua — a finding for FLOW, not a hole in the solve)
            ok((r[4] and k:find(r[4], 1, true) == 1) or k:find('(model)', 1, true),
                ('%s: %d unexplained failure(s) %s: %s'):format(r[1], n, k, table.concat(c.fails, ' | ')))
        end
        eq(0, c.unwritten, r[1] .. ': a variable that holds something no instruction writes: ' .. vim.inspect(c.unwritten_ex))
        local ops = opcodes(D)
        for _, op in ipairs(r[3]) do ok(ops[op], r[1] .. ': no ' .. op .. ' instruction: ' .. vim.inspect(ops)) end
    end)
end

test('flowdump: the format — the Lua instance\'s field ids, host sites, per-function error ports, tags, contracts', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local ok, e = pcall(function () error(b) end)\nprint(use(e))\nlocal t = { x = a }\nfor k in pairs(t) do print(k) end\n')
    eq(1, D.format)
    -- (the PRODUCER's commit is cartograph's, wherever the caller stands; a corpus that is no repository has none — CART-1721)
    eq(vim.fn.systemlist({ 'git', '-C', vim.fn.fnamemodify(debug.getinfo(require('cartograph.flowtype').solve, 'S').source:sub(2), ':h'), 'rev-parse', 'HEAD' })[1], D.cartograph)
    eq(vim.NIL, D.corpus.sha, 'a temp tree is no repository')
    eq('<meta>', D.names.fields[101], 'the metatable slot is field 100')
    eq('__index', D.names.fields[102], '__index is field 101')
    eq(vim.NIL, D.names.fields[105], '104 (evStoreLook) is no field')
    local kinds = {}
    for _, s in ipairs(D.sites) do kinds[s.kind] = true end
    ok(kinds['function'] and kinds.table and kinds.type and kinds.globals, vim.inspect(kinds))
    -- a function's error port: the pcall'd callback raises b
    local any = false
    for _, e in ipairs(D.solution.err.fn) do if D.names.functions[e[1] + 1]:find('pcall') then any = #e[2] > 0 end end
    ok(any, 'the callback\'s port holds what it raises: ' .. vim.inspect(D.solution.err))
    local tags = {}
    for _, F in ipairs(D.functions) do for _, t in ipairs(F.tags) do tags[t[2]] = true end end
    ok(tags['contract:strict-global'], 'a global read carries its contract: ' .. vim.inspect(tags))
    ok(D.contracts.clauses['hidden-fields'] and D.contracts.globals_site, vim.inspect(D.contracts))
    -- the key set `pairs` yields is no field: hkeys, and its load a gap
    ok(#D.solution.hkeys > 0, 'the key set is hkeys')
    local gap = false
    for _, g in ipairs(D.gaps) do if g.kind == 'table-keys' then gap = true end end
    ok(gap, 'a load of the key set is a gap: ' .. vim.inspect(D.gaps))
    for _, e in ipairs(D.solution.h) do ok(D.names.fields[e[2] + 1] ~= '{k}', 'no {k} field in h') end
end)

test('flowdump: no dump, no recording — and the dump\'s solve is the instance-free one', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES .. 'print(use(b))\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    eq(nil, R.dump)
    local Rd = flowtype.solve(store, { open = false, dump = true })
    eq(0, Rd.stats.instances or 0, 'no per-site instance in a dump')
    vim.fn.delete(root, 'rf')
end)

-- (the check BOTH SIDES: a solution with a hole is caught — a check that passes everything would pass every route above)
test('flowcheck: a solution with a hole is caught — a site dropped from a copied variable, an error dropped from a port', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local ok, e = pcall(function () error(b) end)\nlocal c = b\nprint(use(c), use(e))\n')
    eq(0, flowcheck.check(D).failed, 'the dump itself is closed')
    -- drop the copy's destination sites
    local V = {}
    for i, e in ipairs(D.solution.v) do V[e[1]] = i end
    local hit
    for _, F in ipairs(D.functions) do
        for _, ins in ipairs(F.body) do
            if not hit and ins[1] == 'copy' and V[ins[2]] and V[ins[3]] and #D.solution.v[V[ins[3]]][2] > 0 then hit = ins[2] end
        end
    end
    ok(hit, 'a copy to break')
    local saved = D.solution.v[V[hit]][2]
    D.solution.v[V[hit]][2] = {}
    local c = flowcheck.check(D)
    ok(c.failed > 0 and next(c.counts):find('copy', 1, true), 'the hole is named: ' .. vim.inspect(c.counts))
    D.solution.v[V[hit]][2] = saved
    -- empty every error port: the callback's error(b) has nowhere to go
    for _, e in ipairs(D.solution.err.fn) do e[2] = {} end
    c = flowcheck.check(D)
    ok(c.counts['untagged error:error'], 'an error missing from its port is caught: ' .. vim.inspect(c.counts))
end)

-- (closedness cannot see a MISSING instruction — fewer constraints pass more easily: the instructions a route needs are
-- pinned here one by one)
test('flowdump: a plain global assignment is a store into the globals site, and every function returns through `ret`', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('q = b\nprint(use(q))\n')
    local qf
    for i, nm in ipairs(D.names.fields) do if nm == 'q' then qf = i - 1 end end
    local store_q, rets, fns = false, 0, 0
    for _, F in ipairs(D.functions) do
        local name = D.names.functions[F.id + 1]
        local has_ret = false
        for _, ins in ipairs(F.body) do
            if ins[1] == 'store' and ins[3] == qf then store_q = true end
            if ins[1] == 'ret' then has_ret = true end
        end
        if not name:find('^chunk:') and name ~= 'init' then fns = fns + 1; if has_ret then rets = rets + 1 end end
    end
    ok(store_q, '`q = b` is a store of field q')
    ok(fns > 0 and rets == fns, ('every function returns through ret: %d of %d'):format(rets, fns))
end)
