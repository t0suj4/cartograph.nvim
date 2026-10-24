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

local function dump(src, exp)
    local root = tree({ ['m.lua'] = CLASSES .. src })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true, exp = exp })
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
    -- (CART-1739: the key set pairs yields is a `keys` instruction, no longer a gap; dynamic accesses carry their key)
    local keys, gap = 0, false
    for _, F in ipairs(D.functions) do for _, i in ipairs(F.body) do if i[1] == 'keys' then keys = keys + 1 end end end
    for _, g in ipairs(D.gaps) do if g.kind == 'table-keys' then gap = true end end
    ok(keys > 0 and not gap, 'pairs reads the key set by a keys instruction: ' .. keys)
    eq(true, D.contracts.dyn_keys, 'the dynamic accesses carry their key operand')
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

-- (CART-1725, flowpath C.4: each answer names the CALL instruction it is about — `ins = [fn, index]`, the index into that
-- function's DUMPED body — so the checker reads the answer against that instruction's callee in the solution)
test('flowdump: an answer names its call instruction — a call in the function that makes it, whose callee holds the answer', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local function two(q) return q:m(), q:m() end\nprint(two(a))\n')
    local byid = {}
    for _, F in ipairs(D.functions) do byid[F.id] = F end
    local V = {}
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    local seen, n = {}, 0
    for _, a in ipairs(D.answers) do
        if a.kind == 'exact' then
            n = n + 1
            ok(type(a.ins) == 'table', 'linked: ' .. vim.inspect(a))
            local F = byid[a.ins[1]]
            local ins = F and F.body[a.ins[2] + 1]
            ok(ins and ins[1] == 'call', 'a call instruction: ' .. vim.inspect(ins))
            ok(D.names.functions[a.ins[1] + 1]:find('use') or D.names.functions[a.ins[1] + 1]:find('two'), 'in the calling function: ' .. D.names.functions[a.ins[1] + 1])
            -- the callee variable holds the answered function's site
            local held = {}
            for _, s in ipairs(V[ins[3]] or {}) do held[s] = true end
            local site
            for _, s in ipairs(D.sites) do if s.kind == 'function' and s.fn == a.targets[1] then site = s.id end end
            ok(site ~= nil and held[site], 'the callee holds the target: ' .. vim.inspect({ callee = ins[3], held = V[ins[3]], site = site }))
            local key = a.ins[1] .. ':' .. a.ins[2]
            ok(not seen[key], 'two calls, two instructions: ' .. key)
            seen[key] = true
        end
    end
    ok(n >= 3, 'use\'s p:m() and two\'s q:m() twice are answered: ' .. n)
end)

-- (CART-1735: the dump is JSON text, so UTF-8 — a byte string that is not, a WoW addon's Latin-1 "N\xfake", is read as
-- Latin-1: each byte >= 0x80 the code point U+00XX, lossless; valid UTF-8 and ASCII pass unchanged)
test('flowdump: a string that is not UTF-8 is written as Latin-1, so the dump stays valid JSON', function ()
    local jstr = require('cartograph.flowdump')._jstr
    eq('N\195\186ke', vim.json.decode(jstr('N\250ke')), 'Latin-1 ú -> U+00FA')
    eq('já', vim.json.decode(jstr('já')), 'valid UTF-8 unchanged')
    eq('"plain"', jstr('plain'))
    eq('12', jstr(12), 'a non-string value is encoded as before')
end)

-- (CART-1736: a store / setmeta through a SATURATED base reaches every object the base may hold by the escape rule —
-- but _G, which never escapes: the dump names that contract on the instruction)
test('flowdump: a store through a saturated base carries contract:globals-never-escape', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local sinks = {}
    for k = 1, 70 do sinks[k] = 'sink({})' end
    local D = dump('local function sink(t) t.f = b; setmetatable(t, {}) end\n' .. table.concat(sinks, '\n') .. '\n')
    local tagged = {}
    for _, F in ipairs(D.functions) do
        local name = D.names.functions[F.id + 1]
        for _, t in ipairs(F.tags) do
            if t[2] == 'contract:globals-never-escape' then tagged[#tagged + 1] = F.body[t[1] + 1][1] .. '@' .. name end
        end
    end
    table.sort(tagged)
    ok(#tagged >= 2, 'the store and the setmeta in sink are tagged: ' .. vim.inspect(tagged))
    for _, x in ipairs(tagged) do ok(x:find('sink', 1, true), 'only sink\'s instructions: ' .. x) end
end)

-- (CART-1723: `weak` names every site a store that may set __mode reaches — a named __mode store, or a dynamic-key
-- store, whose key may be "__mode")
test('flowdump: weak names the sites a __mode store may reach — named or by a dynamic key — and no other', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local wm = { __mode = "k" }\nlocal w = setmetatable({}, wm)\nlocal t = {}\nlocal k = ("x"):upper()\nt[k] = a\nlocal plain = { n = 1 }\nreturn w, t, plain\n')
    local label = {}
    for _, s in ipairs(D.sites) do label[s.id] = s.label end
    local weak = {}
    for _, o in ipairs(D.solution.weak) do weak[tostring(label[o])] = true end
    local function has(pat) for l in pairs(weak) do if l:find(pat) then return true end end return false end
    ok(has('m.lua:6:'), 'the __mode table wm is weak: ' .. vim.inspect(weak))
    ok(has('m.lua:8:'), 'the dynamic-key store target t is weak: ' .. vim.inspect(weak))
    ok(not has('m.lua:11:'), 'plain is not: ' .. vim.inspect(weak))
end)

-- (CART-1739: `storeDyn x k y` and `loadDyn x y k` carry the key's variable, `keys x y` reads the key set — and the
-- check holds them: a dynamic store's key is in the target's key set, the key loop variable holds them)
test('flowdump: dynamic accesses carry their key; keys reads the key set; the dump stays closed', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local t = {}\nlocal k = ("q"):upper()\nt[k] = b\nprint(use(t[k]))\nfor key in pairs(t) do print(key) end\n')
    local sd, ld, ks
    for _, F in ipairs(D.functions) do
        for _, i in ipairs(F.body) do
            if i[1] == 'storeDyn' then sd = i elseif i[1] == 'loadDyn' and i[4] ~= vim.NIL then ld = i elseif i[1] == 'keys' then ks = i end
        end
    end
    ok(sd and #sd == 4 and sd[3] ~= vim.NIL, 'storeDyn x k y: ' .. vim.inspect(sd))
    ok(ld and #ld == 4, 't[k]: loadDyn x y k (a builtin\'s own dynamic load, pairs\' values, has a null key): ' .. vim.inspect(ld))
    ok(ks and #ks == 3, 'keys x y: ' .. vim.inspect(ks))
    local c = flowcheck.check(D, 5)
    for k, n in pairs(c.counts) do ok(k:find('(model)', 1, true), ('%d × %s: %s'):format(n, k, table.concat(c.fails, ' | '))) end
    eq(0, c.unwritten, 'every variable written: ' .. vim.inspect(c.unwritten_ex))
end)

-- (CART-1744: a store of `.f` through a tainted base taints field f of EVERY escaped object — the cells no port holds too.
-- htaint lists ports, and a cell nothing reads has none: vimruntime's 2,770 cells written through a `__newindex` table
-- looked untainted. The dump states the rule — taint.escaped and taint.fields_hit — and the checker applies it)
test('flowdump: taint.escaped and taint.fields_hit state the store rule; the checker excuses a portless hit cell', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, '\nlocal a, b, c = {}, {}, {}\nlocal x = (#arg == 1 and a) or (#arg == 2 and b) or c\nx.f = 1\n')
    flowtype.CAP = cap
    assert(ok_, D)
    local fidx
    for i, nm in ipairs(D.names.fields) do if nm == 'f' then fidx = i - 1 end end
    local T = D.solution.taint
    ok(fidx and vim.tbl_contains(T.fields_hit, fidx), 'f is hit: ' .. vim.inspect(T.fields_hit))
    -- (an escaped table — a, b or c — that a variable holds alone, and whose f no port holds)
    local esc, held = {}, {}
    for _, o in ipairs(T.escaped) do esc[o] = true end
    for _, e in ipairs(D.solution.v) do if #e[2] == 1 and esc[e[2][1]] then held[e[2][1]] = held[e[2][1]] or e[1] end end
    local ported = {}
    for _, e in ipairs(D.solution.h) do if e[2] == fidx then ported[e[1]] = true end end
    local asite, avar
    for _, s in ipairs(D.sites) do
        if s.kind == 'table' and s.label:find('m.lua', 1, true) and held[s.id] and not ported[s.id] and not asite then asite, avar = s.id, held[s.id] end
    end
    ok(asite, 'an escaped table with no f port: ' .. vim.inspect(T.escaped))
    local V = { avar }
    local chunk = D.functions[#D.functions]
    chunk.body[#chunk.body + 1] = { 'store', V[1], fidx, V[1] } -- (a.f = a: a cell with no port)
    eq(0, flowcheck.check(D).failed, 'the hit cell of an escaped object is tainted')
    T.fields_hit = {}
    ok(flowcheck.check(D).failed > 0, 'without the rule the same store fails')
end)

-- (the dump is compared BYTE for byte across processes; pairs order over string keys varies by process, so what it writes
-- from a hash — the contract clauses, the hit fields' interning — goes out sorted)
test('flowdump: the contract clauses are written in name order', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = 'local t = {}\nreturn t\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local cl = R.dump:match('"clauses":(%b{})')
    ok(cl, 'the clauses')
    local ks = {}
    for k in cl:gmatch('"([^"]+)":"') do ks[#ks + 1] = k end
    local sorted = vim.deepcopy(ks)
    table.sort(sorted)
    ok(#ks > 3, 'clauses: ' .. #ks)
    eq(sorted, ks, 'in name order')
end)

-- (CART-1752: a TAINTED key set — a dynamic store whose key is lost but not saturated — may hold any key under the
-- taint reading, as a saturated one may: hkeystop lists it. Dumped closed, the checker failed 182 vimruntime stores)
test('flowdump: hkeystop lists a TAINTED key set, not only a saturated one', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    -- (k saturates past CAP 2; k2 is fed by it, tainted but not saturated; t's key set is written from k2)
    local ok_, D = pcall(dump, '\nlocal x, y, z = {}, {}, {}\nlocal k = (#arg == 1 and x) or (#arg == 2 and y) or z\nlocal k2 = k\nlocal t = {}\nt[k2] = 1\nreturn t\n')
    flowtype.CAP = cap
    assert(ok_, D)
    local lab = {}
    for _, s in ipairs(D.sites) do lab[s.id] = s.label end
    local tl
    for _, id in ipairs(D.solution.hkeystop) do if tostring(lab[id]):match('^tbl:m%.lua:') then tl = lab[id] end end
    ok(tl ~= nil, 'a table key set is listed: ' .. vim.inspect(D.solution.hkeystop))
end)

-- (CART-1739's residue, 29 vimruntime failures: a constructor's COMPUTED key `{ [e] = v }` and rawset(t, k, v) were
-- dumped as storeDyn with no key, and the constructor's key set held a string for every key)
test('flowdump: a constructor\'s computed key and rawset\'s key are named by their storeRawDyn (CART-1771)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (keys read from a FIELD, as vimruntime's `[watch.FileChangeType.Created] = …`: neither a constant nor an index)
    local D = dump('\nlocal K = { x = tostring(#arg) }\nlocal t = { [K.x] = 1 }\nlocal u = {}\nrawset(u, K.x, 2)\nreturn t, u\n')
    local dyn, named = 0, 0
    for _, F in ipairs(D.functions) do
        for _, i in ipairs(F.body) do
            if i[1] == 'storeRawDyn' then dyn = dyn + 1; if i[3] ~= vim.NIL then named = named + 1 end end
        end
    end
    eq(2, dyn, 'two RAW dynamic stores: the constructor field and rawset')
    eq(2, named, 'both name their key')
end)

-- (CART-1756 / 1757 / 1758: what the dump said of a TAINTED cell or channel, and rawget's key. k2 is fed by k, which
-- saturates past CAP 2: tainted and EMPTY, the case a site list cannot carry)
test('flowdump: a tainted [] cell is weak, a tainted resume channel is rin_top, rawget names its key', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, table.concat({ '',
        'local x, y, z = {}, {}, {}',
        'local k = (#arg == 1 and x) or (#arg == 2 and y) or z',
        'local k2 = k',
        'local K = { f = tostring(#arg) }',
        'local t = {}', 't[K.f] = k2',
        'local co = coroutine.create(function (v) return v end)', 'coroutine.resume(co, k2)',
        'local u = {}', 'local w = rawget(u, K.f)',
        'return t, w' }, '\n') .. '\n')
    flowtype.CAP = cap
    assert(ok_, D)
    local S, lab = D.solution, {}
    for _, s in ipairs(D.sites) do lab[s.id] = s.label end
    local tw = false
    for _, id in ipairs(S.weak) do if tostring(lab[id]):match('^tbl:m%.lua:%d+:10$') then tw = true end end
    ok(tw, 't (its [] cell tainted, empty) is weak: ' .. vim.inspect(S.weak))
    eq(1, S.rin_top, 'the resume channel is tainted: rin_top')
    local named = false
    for _, F in ipairs(D.functions) do for _, i in ipairs(F.body) do if i[1] == 'loadRaw' and i[4] ~= vim.NIL then named = true end end end
    ok(named, 'rawget(u, K.f) is a loadRaw that names its key (FLOW-0090)')
end)

-- (FLOW-0090 / CART-1759: raw accesses — a constructor's named field is storeRaw, pairs' value and rawget(t, k) with a
-- variable key are loadRaw, the latter with its key; and the dump is still closed under flowcheck)
test('flowdump: a constructor field is storeRaw; pairs\' value and rawget(t, k) are loadRaw', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('\nlocal K = { f = tostring(#arg) }\nlocal t = { x = 1 }\nfor _, v in pairs(t) do print(v) end\nlocal w = rawget(t, K.f)\nreturn w\n')
    local sraw, lraw, lrawk = 0, 0, 0
    for _, F in ipairs(D.functions) do
        for _, i in ipairs(F.body) do
            if i[1] == 'storeRaw' then sraw = sraw + 1 end
            if i[1] == 'loadRaw' then lraw = lraw + 1; if i[4] ~= vim.NIL then lrawk = lrawk + 1 end end
        end
    end
    ok(sraw >= 2, 'the constructors\' named fields are storeRaw: ' .. sraw)
    eq(2, lraw, 'pairs\' value and rawget are loadRaw')
    eq(1, lrawk, 'rawget names its key, pairs does not')
    eq(0, flowcheck.check(D).failed, 'the dump is closed under the raw rules')
end)

-- (CART-1760: init calls UNKNOWN CODE, which may raise anything: its error port is tainted)
test('flowdump: init\'s error port is tainted when it calls unknown code', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('\nlocal m = require("not_in_the_tree")\nreturn m.f(a)\n')
    local initid
    for i, nm in ipairs(D.names.functions) do if nm == 'init' then initid = i - 1 end end
    ok(initid ~= nil, 'init is named: ' .. vim.inspect(D.names.functions))
    local has = false
    for _, id in ipairs(D.solution.err.taint) do if tonumber(id) == initid then has = true end end
    ok(has, 'init is in err.taint: ' .. vim.inspect(D.solution.err.taint))
end)

-- (CART-1761: a host site carries its kind from the profile — the certificate's supplied premise)
test('flowdump: a host site carries its kind: string prim, io.open\'s file members', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('\nlocal s = tostring(#arg)\nlocal fh = io.open(s)\nreturn fh\n')
    local kinds = {}
    for _, s in ipairs(D.sites) do if s.kind == 'type' then kinds[s.label] = s.host end end
    eq('prim', kinds['type:string'], 'string is prim: ' .. vim.inspect(kinds))
    eq('members', kinds['type:file'], 'file is members')
end)

-- (CART-1763: a dynamic store may write the target's KEY SET and, its key unknown, its __mode. Through a TAINTED target,
-- every escaped table may be written: weak when the key may be the string "__mode", hkeystop when it may be an object.
-- On a LISTED target, an unknown key makes it weak whatever the value — __mode's own value is a string)
test('flowdump: a dynamic store through a tainted target makes escaped tables weak and key-open; a listed one weak', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, table.concat({ '',
        'local x, y, z = {}, {}, {}',
        'local T = (#arg == 1 and x) or (#arg == 2 and y) or z',          -- saturates past CAP 2: x, y, z escape
        'local NM = { f = tostring(#arg) }',
        'T[NM.f] = 1',                                                    -- through T, a string key: may be "__mode"
        'local K = {}', 'T[K] = 2',                                       -- through T, an object key
        'local L = {}', 'local function put(v) L[NM.f] = v end',          -- a listed target, an unknown key, an EMPTY value
        'return T, L' }, '\n') .. '\n')
    flowtype.CAP = cap
    assert(ok_, D)
    local S, lab = D.solution, {}
    for _, s in ipairs(D.sites) do lab[s.id] = s.label end
    local function count(list, pat) local n = 0; for _, id in ipairs(list) do if tostring(lab[id]):match(pat) then n = n + 1 end end; return n end
    eq(3, count(S.weak, '^tbl:m%.lua:7:'), 'x, y, z (escaped) are weak')
    eq(3, count(S.hkeystop, '^tbl:m%.lua:7:'), 'x, y, z are key-open')
    eq(1, count(S.weak, '^tbl:m%.lua:13:'), 'L (listed, an unknown key, a value that holds nothing) is weak')
end)

-- (CART-1762: a load through a LOST base may run an escaped __index handler, which may raise: the loading function's
-- error port is tainted once such a handler is possible)
test('flowdump: a load through a tainted base taints the loading function\'s error port when __index is possible', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, table.concat({ '',
        'local x, y, z = {}, {}, {}',
        'local T = (#arg == 1 and x) or (#arg == 2 and y) or z',
        'local P = setmetatable({}, { __index = function () error("no") end })',
        'local function rd() return T.f end',
        'return rd(), P' }, '\n') .. '\n')
    flowtype.CAP = cap
    assert(ok_, D)
    local rdid
    for i, nm in ipairs(D.names.functions) do if tostring(nm):match('::rd@') then rdid = i - 1 end end
    ok(rdid ~= nil, 'rd is named')
    local has = false
    for _, id in ipairs(D.solution.err.taint) do if tonumber(id) == rdid then has = true end end
    ok(has, 'rd\'s error port is tainted: ' .. vim.inspect(D.solution.err.taint))
end)

-- (CART-1768: an ESCAPED function may be called with anything — its parameters are tainted though no call through a
-- lost callee is seen. CART-1764: a dynamic load through an escaped base may run an escaped __index handler with its
-- key — the key's objects escape)
test('flowdump: an escaped method\'s parameter is tainted; a dynamic load\'s key escapes through an escaped base', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, table.concat({ '',
        'local function lose(x) return x end',
        'lose({})', 'lose({})', 'lose({})',
        'local v = lose(a)',                                                -- a escapes, and A.m with it
        'local P = setmetatable({}, { __index = function (_, k) return k end })',
        'local K = {}',
        'local w = v[K]',                                                   -- v may hold the escaped a: K escapes
        'return P, w' }, '\n') .. '\n')
    flowtype.CAP = cap
    assert(ok_, D)
    local T = D.solution.taint
    local tp = {}
    for _, p in ipairs(T.ports) do tp[p] = true end
    local mid
    for i, nm in ipairs(D.names.functions) do if tostring(nm):match('::A%.m@') then mid = i - 1 end end
    local par
    for _, F in ipairs(D.functions) do if F.id == mid then par = F.params[1] end end
    ok(par and tp[par], 'A.m (escaped) has a tainted parameter: ' .. tostring(par))
    local lab = {}
    for _, s in ipairs(D.sites) do lab[s.id] = s.label end
    local kesc = false
    for _, o in ipairs(T.escaped) do if tostring(lab[o]):match('^tbl:m%.lua:13:') then kesc = true end end
    ok(kesc, 'K (the key of a load through an escaped base) escaped: ' .. vim.inspect(T.escaped))
end)

-- (CART-1769: a base that LISTS an escaped table — not itself tainted — meets the same handlers as a lost one: a load's
-- and a STORE's error port are tainted once their handler is possible)
test('flowdump: a load and a store through a listed escaped table taint their error ports', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, table.concat({ '',
        'local function lose(q) return q end',
        'local x = {}',
        'lose(x)', 'lose({})', 'lose({})',                                   -- x escapes through the saturated q
        'local P = setmetatable({}, { __index = function () error("i") end, __newindex = function () error("n") end })',
        'local function rd() return x.f end',                                -- x is LISTED here, not tainted
        'local function wr() x.g = 1 end',
        'return rd(), wr(), P' }, '\n') .. '\n')
    flowtype.CAP = cap
    assert(ok_, D)
    local ids = {}
    for i, nm in ipairs(D.names.functions) do
        local short = tostring(nm):match('::(%w+)@')
        if short then ids[short] = i - 1 end
    end
    local tset = {}
    for _, id in ipairs(D.solution.err.taint) do tset[tonumber(id)] = true end
    ok(ids.rd and tset[ids.rd], 'rd (a load through listed escaped x) has a tainted error port')
    ok(ids.wr and tset[ids.wr], 'wr (a store through listed escaped x) has a tainted error port')
end)

-- (CART-1772: coroutine.wrap and xpcall's handler are IR over existing instructions, no gap. wrap: `cocreate` of f, and
-- w's body `resume [ok, r…] co params; error r1`. xpcall: the pcall, `call [hr] h [r1]`, `copy r1 hr`)
test('flowdump: coroutine.wrap and xpcall\'s handler are IR, not gaps', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump(table.concat({ '',
        'local w = coroutine.wrap(function (x) return x end)', 'local r = w(a)',
        'local ok, v = xpcall(function () error(b) end, function (e) return e end)',
        'return r, v' }, '\n') .. '\n')
    local gaps = {}
    for _, g in ipairs(D.gaps) do gaps[g.kind] = true end
    ok(not gaps['coroutine.wrap'], 'no coroutine.wrap gap')
    ok(not gaps['xpcall-handler'], 'no xpcall-handler gap')
    local wbody
    for _, F in ipairs(D.functions) do if tostring(D.names.functions[F.id + 1]):match('^ts:wrap:') then wbody = F.body end end
    local ops = {}
    for _, i in ipairs(wbody or {}) do ops[#ops + 1] = i[1] end
    eq('resume error ret', table.concat(ops, ' '), 'the wrap function resumes, re-raises, returns')
    -- (the handler call: `call [hr] h [r1]` followed by `copy r1 hr`)
    local handled = false
    for _, F in ipairs(D.functions) do
        for i, ins in ipairs(F.body) do
            local nx = F.body[i + 1]
            if ins[1] == 'call' and nx and nx[1] == 'copy' and nx[3] == ins[2][1] and nx[2] == ins[4][1] then handled = true end
        end
    end
    ok(handled, 'xpcall\'s handler is called with r1, and its result copied back')
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- (CART-1772, the core's coroutine CHANNELS: a coroutine's function returns into `rout` and raises into `cerr` even
-- when nothing resumes it, and every resume's error result takes `cerr`)
test('flowdump: a coroutine nobody resumes still returns into rout and raises into cerr; a resume sees cerr', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump(table.concat({ '',
        'local co1 = coroutine.create(function () if #arg > 0 then error(b) end; return a end)', -- never resumed
        'local co2 = coroutine.create(function () end)',
        'local ok, e = coroutine.resume(co2)',
        'return e' }, '\n') .. '\n')
    local S, V = D.solution, {}
    for _, xv in ipairs(S.v) do V[xv[1]] = xv[2] end
    local function has(list, o) for _, x in ipairs(list or {}) do if x == o then return true end end end
    local siteof = {}
    for _, st in ipairs(D.sites) do siteof[st.label] = st.id end
    local asite, bsite = siteof['tbl:m.lua:3:26'], siteof['tbl:m.lua:3:61'] -- (a's and b's tables; labels are 0-based)
    ok(asite and has(S.rout, asite), 'co1 returns a into rout though never resumed: ' .. vim.inspect(S.rout))
    ok(bsite and has(S.err.cerr, bsite), 'co1 raises b into cerr: ' .. vim.inspect(S.err.cerr))
    local e
    for _, F in ipairs(D.functions) do for _, ins in ipairs(F.body) do if ins[1] == 'resume' then e = ins[2][2] end end end
    ok(e and has(V[e], bsite), 'the resume of co2 sees b in its error result: ' .. vim.inspect(V[e]))
end)

-- (CART-1773 / 1774: getmetatable is the core's getmeta (with __metatable's field), a keyed copy its copyKeyed — no
-- hidden-load or keyed-copy gap is left)
test('flowdump: getmetatable is getmeta and a keyed copy copyKeyed, not gaps', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump(table.concat({ '',
        'local t = setmetatable({}, { __metatable = b })', 'local m = getmetatable(t)',
        'local S, T = { x = a }, {}', 'for k in pairs(S) do T[k] = S[k] end',
        'return m, T' }, '\n') .. '\n')
    local gaps, ops = {}, {}
    for _, g in ipairs(D.gaps) do gaps[g.kind] = true end
    for _, F in ipairs(D.functions) do for _, i in ipairs(F.body) do ops[i[1]] = true end end
    ok(not gaps['hidden-load'] and not gaps['keyed-copy'], 'no hidden-load / keyed-copy gap: ' .. vim.inspect(D.gaps))
    ok(ops.getmeta and ops.copyKeyed, 'getmeta and copyKeyed are emitted')
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- (CART-1775, fixed environments: a tree that never calls setfenv has every environment _G — getfenv leaves no gap and
-- the dump states `fixed-env`; one that does keeps the gap and claims nothing)
test('flowdump: getfenv is no gap under fixed environments, and stays one when a setfenv may target a tree function (CART-1775, CART-1813)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function kinds(D) local g = {}; for _, x in ipairs(D.gaps) do g[x.kind] = true end; return g end
    local D = dump('\nlocal G = getfenv(0)\nreturn G\n')
    ok(not kinds(D).getfenv, 'no getfenv gap without setfenv')
    ok(D.contracts.clauses['fixed-env'] ~= nil, 'the fixed-env clause is stated')
    D = dump('\nlocal G = getfenv(0)\nsetfenv(1, {})\nreturn G\n')
    ok(kinds(D).getfenv, 'with a setfenv the getfenv gap stays')
    ok(D.contracts.clauses['fixed-env'] == nil, 'and the fixed-env clause is not stated')
    -- (by the walk's SCOPE resolution, not the text, CART-1785: a comment or a string naming it, or a LOCAL called
    -- setfenv, is no reference to the builtin; an alias, debug.setfenv, `_G["setfenv"]` are)
    for _, src in ipairs {
        '\n-- setfenv is not called here\nlocal s = "setfenv"\nlocal G = getfenv(0)\nreturn G, s\n',
        '\nlocal setfenv = function () end\nsetfenv(1, {})\nlocal G = getfenv(0)\nreturn G\n' } do
        ok(dump(src).contracts.clauses['fixed-env'] ~= nil, 'fixed: ' .. src)
    end
    -- (CART-1813: from the SOLUTION, not from a reference — a call that may set a TREE function's environment, by name or
    -- by value, withholds the claim; an alias never called, or a call on loaded code, does not)
    for _, src in ipairs {
        '\nlocal function f() return x end\nsetfenv(f, {})\nlocal G = getfenv(0)\nreturn G\n',
        '\nlocal sf = setfenv\nlocal function f() return x end\nsf(f, {})\nlocal G = getfenv(0)\nreturn G\n',
        '\nlocal function f() return x end\ndebug.setfenv(f, {})\nlocal G = getfenv(0)\nreturn G\n',
        '\nlocal sf = debug.setfenv\nlocal function f() return x end\nsf(f, {})\nlocal G = getfenv(0)\nreturn G\n' } do
        local D2 = dump(src)
        -- (by value the call has no walk position: the claim is withheld and the getfenv gap stays)
        ok(D2.contracts.clauses['fixed-env'] == nil and (kinds(D2).setfenv or kinds(D2).getfenv), 'not fixed, a gap: ' .. src)
    end
    for _, src in ipairs {
        '\nlocal sf = setfenv\nlocal G = getfenv(0)\nreturn G, sf\n',
        '\nlocal g = loadstring(tostring(1))\nsetfenv(g, {})\nlocal G = getfenv(0)\nreturn G\n' } do
        local D2 = dump(src)
        ok(D2.contracts.clauses['fixed-env'] ~= nil and not kinds(D2).setfenv and not kinds(D2).getfenv, 'fixed, no gap: ' .. src)
    end
end)

-- (CART-1776, the world: the OUTSIDE writes into what escaped, data fields included — `[]` is hit once anything escapes,
-- not only when tree code stores dynamically through a lost base)
test('flowdump: once anything escapes, `[]` is hit — though no tree store goes through a lost base', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, '\nlocal function lose(q) return q end\nlose({})\nlose({})\nlose({})\nreturn lose\n')
    flowtype.CAP = cap
    assert(ok_, D)
    ok(#D.solution.taint.escaped > 0, 'something escaped')
    local hit = false
    for _, f in ipairs(D.solution.taint.fields_hit) do if f == vim.NIL then hit = true end end
    ok(hit, '[] is in fields_hit: ' .. vim.inspect(D.solution.taint.fields_hit))
end)

-- (CART-1782: which escaped objects outside code can REACH and which the solve only LOST past CAP, and which tainted
-- ports trace back to an outside seed)
test('flowdump: escaped_root tells outside-reachable from saturated, and outside lists the ports an outside seed taints', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local function root(D)
        local by = {}
        for _, e in ipairs(D.solution.taint.escaped_root) do by[e[2]] = (by[e[2]] or 0) + 1 end
        return by
    end
    -- saturation only
    local ok1, D1 = pcall(dump, '\nlocal function lose(q) return q end\nlose({})\nlose({})\nlose({})\nreturn lose\n')
    -- handed to unknown code, and a lost call's argument
    local ok2, D2 = pcall(dump, table.concat({ '',
        'local t = { x = {} }', 'local f = load(("return ..."):lower())', 'f(t)',
        'local function lose(q) return q end', 'lose(function () end)', 'lose(function () end)', 'lose(function () end)',
        'local g = lose(print)', 'local u = {}', 'g(u)',
        'local y = t.x',                                                   -- a read of what unknown code may have written
        'return t, u, y' }, '\n') .. '\n')
    flowtype.CAP = cap
    assert(ok1, D1); assert(ok2, D2)
    local r1 = root(D1)
    ok(r1.saturated and not r1['unknown-code'] and not r1.export, 'saturation only: ' .. vim.inspect(r1))
    eq(0, #D1.solution.taint.outside, 'and no tainted port runs back to an outside seed')
    local r2 = root(D2)
    ok(r2['unknown-code'], 'what load\'s code was handed is rooted outside: ' .. vim.inspect(r2))
    ok(r2['escmore:lost-call-argument'], 'a lost call\'s argument names its rule: ' .. vim.inspect(r2))
    ok(#D2.solution.taint.outside > 0, 'some tainted port runs back to the unknown-code seed')
end)

-- (CART-1783: the CART-1776 rule also for what escapes LATE — in the taint phase, past the rule's first check. Closed
-- mode hits `[]`, and an escaped table's KEY set is ⊤: the outside may key it by any escaped object)
test('flowdump: closed — a value escaping in the taint phase hits `[]`, and its key set is open (CART-1783)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local t = { cb = function () end }',
        'local f = load(("return ..."):lower())',
        'f(t)',                                     -- (unknown code may replace t.cb)
        'local h = t.cb',
        'local u = { z = 1 }',
        'h(u)',                                     -- (u escapes LATE: a lost call's argument)
        'local n = 0',
        'for k in pairs(u) do n = n + 1 end',
        'return u.z, n' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local T = D.solution.taint
    local u
    for _, s in ipairs(D.sites) do if s.label == 'tbl:m.lua:4:10' then u = s.id end end
    assert(u, 'u has a site')
    local late = false
    for _, e in ipairs(T.escaped_root) do if e[1] == u and e[2] == 'escmore:lost-call-argument' then late = true end end
    ok(late, 'u escapes late: ' .. vim.inspect(T.escaped_root))
    ok(vim.tbl_contains(T.fields_hit, vim.NIL), '[] is hit: ' .. vim.inspect(T.fields_hit))
    ok(vim.tbl_contains(D.solution.hkeystop, u), 'u\'s key set is open: ' .. vim.inspect(D.solution.hkeystop))
    eq(0, #T.outside_written, 'closed mode states no per-object outside writes')
end)

-- (CART-1783, OPEN mode under C1: what outside code holds — the exports' reach, and what escapes later — is written
-- per object: its data fields, what a DYNAMIC load reads of it, its key set. Not the `[]` cell a named load of a
-- function member reads: C1)
test('flowdump: open — the outside writes the exports\' new keys and key sets, stated per object, `[]` not hit (CART-1783)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['lua/m/init.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.m(self) return "A" end',
        'function B.m(self) return "B" end',
        'local M = {}',
        'function M.mk_a() return setmetatable({}, { __index = A }) end',
        'function M.mk_b() return setmetatable({}, { __index = B }) end',
        'M.one = M.mk_a()',
        'function M.run() return M[("oth"):lower() .. "er"]:m() end', -- (the outside may have set M.other = M.mk_b())
        'function M.count() local n = 0; for k in pairs(M) do n = n + 1 end; return n end',
        'return M' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = true, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local T = D.solution.taint
    local M, str
    for _, s in ipairs(D.sites) do
        if s.label == 'tbl:lua/m/init.lua:3:10' then M = s.id end
        if s.label == 'type:string' then str = s.id end
    end
    assert(M, 'M has a site')
    ok(vim.tbl_contains(T.outside_written, M), 'M is written by the outside: ' .. vim.inspect(T.outside_written))
    ok(vim.tbl_contains(D.solution.hkeystop, M), 'M\'s key set is open: ' .. vim.inspect(D.solution.hkeystop))
    ok(not vim.tbl_contains(T.fields_hit, vim.NIL), 'the `[]` cell is not hit (C1): ' .. vim.inspect(T.fields_hit))
    ok(not str or not vim.tbl_contains(T.outside_written, str), 'a string escaping late has no fields the outside writes (C2)')
    local callrec = require 'cartograph.callrec'
    local seen = 0
    for _, c in ipairs(store.data.calls) do
        if (callrec.full(c) or ""):find('"er"]:m', 1, true) then
            seen = seen + 1
            local v = R.verdict(c)
            ok(v and v.partial, 'the dynamic read through M is partial: ' .. vim.inspect(v))
        end
    end
    eq(1, seen, 'the dynamic call is found')
end)

-- (CART-1783, open mode: a table escaping LATE — handed to `M.hook:m`, whose `m` the outside may supply (O2) — is
-- outside-written too. Its only named field `h` is a function member by its prototype (C1: not written), but under a
-- NEW key the outside may store anything: the DYNAMIC load `cfg[k]` is tainted in the dump. It had been stated closed)
test('flowdump: open — a late-escaping table is outside-written; a dynamic load of it is tainted (CART-1783)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['lua/m/init.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.m(self) return "A" end',
        'function B.m(self) return "B" end',
        'local P = {}',
        'function P.h() end',
        'local cfg = setmetatable({}, { __index = P })',
        'cfg.h = setmetatable({}, { __index = A })',
        'local M = { hook = setmetatable({}, { __index = B }) }',
        'function M.run() M.hook:m(cfg); local k = ("x"):upper(); return cfg[k]:m() end',
        'return M' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = true, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local T = D.solution.taint
    local cfg
    for _, s in ipairs(D.sites) do if s.label == 'tbl:lua/m/init.lua:5:25' then cfg = s.id end end
    assert(cfg, 'cfg has a site')
    local late = false
    for _, e in ipairs(T.escaped_root) do if e[1] == cfg and tostring(e[2]):find('^escmore') then late = true end end
    ok(late, 'cfg escapes late: ' .. vim.inspect(T.escaped_root))
    ok(vim.tbl_contains(T.outside_written, cfg), 'cfg is outside-written: ' .. vim.inspect(T.outside_written))
    local tp, n = {}, 0
    for _, p in ipairs(T.ports) do tp[p] = true end
    for _, F in ipairs(D.functions) do
        -- (the tree's: a host model's own bodies load dynamically too, CART-1785)
        if not tostring(D.names.functions[F.id + 1]):find('hostmodel', 1, true) then
            for _, ins in ipairs(F.body) do
                if ins[1] == 'loadDyn' then n = n + 1; ok(tp[ins[2]], 'the dynamic load is tainted: ' .. vim.json.encode(ins)) end
            end
        end
    end
    eq(1, n, 'one dynamic load in the tree')
end)

-- (CART-1785, the host as plain code: a model a call ran is a SUPPLIED premise — `contracts.host_models` names it,
-- [key, [function ids]], and the clause `host-model` is stated; the model's table is no export in open mode — outside
-- code cannot reach the host's own internals through it. No model ran: no clause)
test('flowdump: a host model a call ran is stated — host_models and the host-model clause; it is no export (CART-1785)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local MODEL = 'local REG = {}\nreturn { ["debug#getregistry"] = function () return REG end }\n'
    local root = tree({ ['lua/m/init.lua'] = 'local M = {}\nfunction M.get() return debug.getregistry() end\nreturn M\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = true, dump = true, hostmodels = { test = MODEL } })
    local N = flowtype.solve(store, { open = true, dump = true, hostmodels = false })
    vim.fn.delete(root, 'rf')
    local D, DN = vim.json.decode(R.dump), vim.json.decode(N.dump)
    local hm = D.contracts.host_models
    eq(1, #hm, 'one model ran: ' .. vim.inspect(hm))
    eq('debug#getregistry', hm[1][1])
    -- (a keyed model is APPLIED as its summary — instructions at the call, no body of its own: CART-1783's fs.lua)
    eq(0, #hm[1][2], 'applied as a summary: no function of its own in the dump')
    ok(D.contracts.clauses['host-model'], 'the clause is stated')
    local lab = {}
    for _, s in ipairs(D.sites) do lab[s.id] = s.label end
    local root_of = {}
    for _, e in ipairs(D.solution.taint.escaped_root) do root_of[lab[e[1]]] = e[2] end
    for l in pairs(root_of) do ok(not l:find('^tbl:hostmodel:'), 'no model table at all: ' .. l) end
    eq('export', root_of['sum:tbl:hostmodel:test:0:12'], 'the registry M.get hands out is exported — ONE shared object: ' .. vim.inspect(root_of))
    eq(0, #DN.contracts.host_models, 'no model: none listed')
    ok(not DN.contracts.clauses['host-model'], 'and no clause')
end)

-- (CART-1791: a builtin's NATIVE object is a function value with no fields — it never escapes, unknown code never
-- writes it, and the dump states it a FIXED host site (kind type, host prim), which the E-tables drop. A LIBRARY object
-- (`table`) is ordinary data — `table.foo = f` writes it — and never-escaping WITHOUT a clause broke the E-reading's
-- cells: vimruntime 29 -> 33,962 refusals, flowpath on CART-1791. CART-1797: it never escapes under the stated clause
-- libraries-never-escape, its site listed in contracts.library_sites; experiment libs-escape is the reading without it)
test('flowdump: a native is a fixed host site that never escapes; a library never escapes under its clause (CART-1791, CART-1797)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = '\nlocal function lose(q) return q end\nlose(table)\nlose({})\nlose({})\nlocal f = load(("return ..."):lower())\nf(table)\nlocal s = {}\ntable.insert(s, a)\nreturn s\n'
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, SRC)
    local ok2, D2 = pcall(dump, SRC, 'libs-escape')
    flowtype.CAP = cap
    assert(ok_, D); assert(ok2, D2)
    local function libsite(X)
        for _, x in ipairs(X.sites) do if x.label == 'lib:table' then return x.id end end
    end
    local function escaped(X, id) for _, i in ipairs(X.solution.taint.escaped) do if i == id then return true end end end
    local lab = {}
    for _, x in ipairs(D.sites) do lab[x.id] = x.label end
    ok(#D.solution.taint.escaped > 0, 'something escaped')
    for _, i in ipairs(D.solution.taint.escaped) do
        ok(not tostring(lab[i]):match('^native:'), 'a native never escapes: ' .. tostring(lab[i]))
    end
    local lt = libsite(D)
    ok(lt and not escaped(D, lt), 'the table library, lost past CAP, does not escape under the clause')
    ok(vim.tbl_contains(D.contracts.library_sites, lt), 'its site is listed: ' .. vim.inspect(D.contracts.library_sites))
    ok(D.contracts.clauses['libraries-never-escape'], 'the clause is stated')
    ok(escaped(D2, libsite(D2)), 'libs-escape: it escapes like any object')
    eq(nil, D2.contracts.clauses['libraries-never-escape'], 'libs-escape: no clause')
    local nat = 0
    for _, x in ipairs(D.sites) do
        if tostring(x.label):match('^native:') then nat = nat + 1; ok(x.kind == 'type' and x.host == 'prim', 'a native is a fixed host site: ' .. vim.inspect(x)) end
    end
    ok(nat > 0, 'natives are in the dump: ' .. nat)
end)

-- (CART-1794, flowpath's sigInline: in a DUMP solve a builtin reached by value runs its model AND inlines the model's
-- instructions into the caller — the certificate checks it as code; nothing escapes, the dump is closed. A model with
-- no template (tostring's runs __tostring) stays a lost call: its argument escapes)
test('flowdump: a builtin reached by value inlines its model\'s IR in the dump; one with no template is lost (CART-1794)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('\nlocal rg = rawget\nlocal t = { x = a }\nreturn rg(t, "x")\n')
    eq(0, #D.solution.taint.escaped, 'nothing escapes: ' .. vim.inspect(D.solution.taint.escaped))
    local raw = 0
    for _, F in ipairs(D.functions) do for _, i in ipairs(F.body) do if i[1] == 'loadRaw' then raw = raw + 1 end end end
    ok(raw >= 1, 'the model\'s loadRaw is in the IR')
    eq(0, flowcheck.check(D).failed, 'and the dump is closed')
    -- (an aliased table.insert inlines the by-name path's own instruction — a `store` into the array part `#` — not a
    -- raw dynamic store its solution lacks, CART-1795)
    local I = dump('\nlocal tinsert = table.insert\nlocal s = {}\ntinsert(s, a)\nreturn s\n')
    local stores = 0
    for _, F in ipairs(I.functions) do
        for _, i in ipairs(F.body) do
            if i[1] == 'store' and I.names.fields[i[3] + 1] == '#' then stores = stores + 1 end
            ok(i[1] ~= 'storeRawDyn', 'no raw dynamic store: ' .. vim.json.encode(i))
        end
    end
    ok(stores >= 1, 'a store into `#`')
    eq(0, flowcheck.check(I).failed, 'and the dump is closed')
    -- (tostring HAS a model — it runs __tostring — but no template: in the dump it stays lost, its argument escapes)
    local L = dump('\nlocal f = tostring\nlocal t = setmetatable({}, { __tostring = function (s) return "s" end })\nreturn f(t)\n')
    local lab = {}
    for _, x in ipairs(L.sites) do lab[x.id] = x.label end
    local esc = {}
    for _, i in ipairs(L.solution.taint.escaped) do esc[tostring(lab[i])] = true end
    ok(next(esc) ~= nil, 'no template: a lost call, its argument escapes: ' .. vim.inspect(esc))
end)

-- (CART-1793: the string library's natives sit in a library object of their own, never in the string METHOD table —
-- STRLIB is every string value's __index, and natives there reached every `s[k]`: 1,016 prim-base / host-store check
-- failures on vimruntime. string.format by value still reaches its native)
test('flowdump: string natives are not in the string method table; string.format by value still has one (CART-1793)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('\nlocal f = string.format\nlocal k = ("a"):upper()\nlocal g = ("x")[k]\nreturn f("%s", a), g\n')
    local lab, natives = {}, {}
    for _, x in ipairs(D.sites) do lab[x.id] = x.label; if tostring(x.label):match('^native:') then natives[x.id] = true end end
    local strlib
    for id, l in pairs(lab) do if l == 'stringlib' then strlib = id end end
    assert(strlib, 'the string library site')
    for _, h in ipairs(D.solution.h) do
        if h[1] == strlib then for _, v in ipairs(h[3]) do ok(not natives[v], 'no native in stringlib: ' .. tostring(lab[v])) end end
    end
    local has = false
    for id, l in pairs(lab) do if l == 'native:string.format' then has = true end end
    ok(has, 'string.format has its native')
end)

-- (CART-1796, the user's decision: code loaded from a NON-literal source is a stated CONTRACT — `loaded-code`, only when
-- the tree has such a call — not the sound reading (experiment loaded-globals: it may touch every global by name))
test('flowdump: a non-literal load states the loaded-code contract; a literal one does not need it (CART-1796)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local N = dump('\nlocal f = loadstring(("x = 1"):lower())\nf()\nreturn x\n')
    ok(N.contracts.clauses['loaded-code'], 'a non-literal load: the clause is stated')
    local L = dump('\nlocal f = loadstring("x = 1")\nf()\nreturn x\n')
    ok(not L.contracts.clauses['loaded-code'], 'a literal load is tree code: no clause')
end)

-- (CART-1797: package.loaded lists _G and the libraries; a load of any other entry — a module, `package.loaded[k]`,
-- pairs over it — reads what the solve does not model there (the modules are the experiment pkg-modules): a GAP, so
-- the certificate refuses instead of certifying a vacuous load)
test('flowdump: a load of package.loaded beyond its listed entries is a gap (CART-1797)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function gaps(D) local n = 0; for _, g in ipairs(D.gaps) do if g.kind == 'package-loaded' then n = n + 1 end end; return n end
    eq(0, gaps(dump('package.loaded._G.x = a\nprint(use(x))\npackage.loaded.string.lower("A")\n')), '_G and a library are listed: no gap')
    eq(1, gaps(dump('package.loaded.mymod.x = a\n')), 'a module is not listed: a gap')
    eq(1, gaps(dump('local k = ...\nlocal m = package.loaded[k]\n')), 'a computed key: a gap')
    ok(gaps(dump('for _, m in pairs(package.loaded) do print(m) end\n')) >= 1, 'pairs over it: a gap')
    -- (CART-1815: pkg-modules waives the gap only where it LINKED a module — this tree has none under lua/)
    eq(1, gaps(dump('local k = ...\nlocal m = package.loaded[k]\n', 'pkg-modules')), 'pkg-modules with no module linked: still a gap')
end)

-- (CART-1799, flowpath's GN review: a NUMERIC key is no name. `_G[1]` / ipairs(_G) load `#`, which a dynamic-key store
-- may write — put(_G, 1, b) — so the load reads it, and no contract:strict-global is tagged on it; a named global read
-- keeps its tag)
test('flowdump: a numeric-key load of _G sees a dynamic store and is not tagged strict-global (CART-1799)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D, R = dump('local function put(t, i, v) t[i] = v end\nput(_G, 1, b)\nprint(use(_G[1]))\n')
    local v
    for _, a in ipairs(D.answers) do if a.call[3] == 29 then v = a end end -- (use's p:m())
    ok(v and #v.targets == 2 and not v.partial, "_G[1] holds what put stored: {A.m, B.m}: " .. vim.inspect(v or D.answers))
    local tagged, hashload = false, false
    for _, F in ipairs(D.functions) do
        local at = {}
        for _, t in ipairs(F.tags) do if t[2] == 'contract:strict-global' then at[t[1]] = true end end
        for i, ins in ipairs(F.body) do
            if ins[1] == 'load' and D.names.fields[ins[4] + 1] == '#' then hashload = true; if at[i - 1] then tagged = true end end
        end
    end
    ok(hashload, 'the dump holds the `#` load')
    ok(not tagged, 'a `#` load is not tagged strict-global')
    local D2 = dump('x = b\nprint(use(_G.x))\n')
    local named = false
    for _, F in ipairs(D2.functions) do for _, t in ipairs(F.tags) do if t[2] == 'contract:strict-global' then named = true end end end
    ok(named, 'a named global read keeps its tag')
end)

-- (CART-1803: the IR has no upvalue op — a debug.setupvalue / getupvalue / upvaluejoin call by name is a gap; the
-- solve carries its flows. debug.getmetatable is the RAW slot: its getmeta names a field no code writes, so no
-- `__metatable` override applies; debug.setmetatable is setmetatable's `setmeta`)
test('flowdump: debug upvalue calls are copies, not gaps; debug.getmetatable is a raw getmeta (CART-1803, CART-1813)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (since CART-1813 no gap: the dump translates the call into copies between its value and every upvalue of the
    -- functions the solution lists — closed, and the captured local holds what was written)
    local D = dump('local o = b\nlocal function get() return o end\ndebug.setupvalue(get, 1, a)\nprint(use(get()))\n')
    local g = 0
    for _, x in ipairs(D.gaps) do if x.kind == 'debug-upvalue' then g = g + 1 end end
    eq(0, g, 'setupvalue by name: no gap')
    eq(0, flowcheck.check(D).failed, 'the dump with the copies is closed')
    -- (the COPY itself: get's upvalue — the variable its `return o` reads — is written twice in the chunk, by `local o = b`
    -- and by the setupvalue translation)
    local U, writes = nil, 0
    for _, F in ipairs(D.functions) do
        if tostring(D.names.functions[F.id + 1]):find('get', 1, true) then
            for _, ins in ipairs(F.body) do if ins[1] == 'copy' and not U then U = ins[3] end end
        end
    end
    for _, F in ipairs(D.functions) do
        if D.names.functions[F.id + 1] == 'chunk:m.lua' then
            for _, ins in ipairs(F.body) do if ins[1] == 'copy' and ins[2] == U then writes = writes + 1 end end
        end
    end
    ok(U and writes >= 2, 'the upvalue is written by the translation too: ' .. tostring(U) .. ' x' .. writes)
    local v
    for _, x in ipairs(D.answers) do if x.call[3] == 29 then v = x end end
    ok(v and #v.targets == 2, 'use(get()) holds A and B: ' .. vim.inspect(v))
    local D2 = dump('local t = setmetatable({}, { __index = b })\ndebug.getmetatable(t).__index = a\nlocal u = {}\ndebug.setmetatable(u, {})\n')
    local raw, setm = false, 0
    for _, F in ipairs(D2.functions) do
        for _, ins in ipairs(F.body) do
            if ins[1] == 'getmeta' and D2.names.fields[ins[4] + 1] == '\1raw' then raw = true end
            if ins[1] == 'setmeta' then setm = setm + 1 end
        end
    end
    ok(raw, 'debug.getmetatable: a getmeta naming no written field')
    ok(setm >= 3, 'debug.setmetatable: a setmeta beside the two setmetatable calls: ' .. setm)
end)

-- (CART-1801: each answer lists the contract clauses its callee's derivation rests on — labels propagated over the
-- dumped IR with its solution, flowpath's slice read forwards. Pinned both ways: through a named global read GN;
-- through a host load host; a derivation of locals, setmetatable and parameters nothing)
test('flowdump: an answer lists the contracts its derivation rests on; a plain one lists none (CART-1801)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function ans(D, col)
        for _, a in ipairs(D.answers) do if a.call[3] == col then return a end end
    end
    local D0 = dump('')
    local a0 = ans(D0, 29)
    ok(a0, 'use\'s p:m() has an answer')
    local G = {}
    for i, c in ipairs(D0.labels.clauses) do if bit.band(D0.labels.global, bit.lshift(1, i - 1)) ~= 0 then G[#G + 1] = c end end
    -- (GE's world side and unknown-receiver are seeded where they reach, CART-1807: not in the global set)
    ok(not vim.tbl_contains(G, 'globals-never-escape'), 'GE is not global: ' .. vim.inspect(G))
    ok(not vim.tbl_contains(G, 'unknown-receiver'), 'init\'s ext-channel call is no unresolved call (CART-1807): ' .. vim.inspect(G))
    table.sort(G); local got = vim.deepcopy(a0.contracts); table.sort(got)
    eq(G, got, 'locals and setmetatable rest on nothing but the whole-program clauses')
    local D1 = dump('x = b\nprint(use(x))\n')
    local a1 = ans(D1, 29)
    ok(a1 and vim.tbl_contains(a1.contracts, 'GN'), 'a value read from a named global rests on GN: ' .. vim.inspect(a1 and a1.contracts))
    ok(D1.labels and D1.labels.clauses[1] == 'GN', 'the dump carries its labels: ' .. vim.inspect(D1.labels and D1.labels.clauses))
    local D2 = dump('local X, Y = {}, {}\nfunction X:upper() return 1 end\nfunction Y:upper() return 2 end\nlocal s = UNDEFINED_SOURCE\nlocal x = s:lower():upper()\nreturn X, Y, x\n')
    local hs = false
    for _, a in ipairs(D2.answers) do if a.kind == 'string' and vim.tbl_contains(a.contracts, 'host') then hs = true end end
    ok(hs, 'a call on a host value rests on host: ' .. vim.inspect(D2.answers))
    -- (GE's world side, CART-1807: outside code holding _G may store through its __newindex table — an answer reading
    -- that table rests on GE; the plain one above does not)
    local D3 = dump('local P = { zz = b }\nsetmetatable(_G, { __newindex = P })\nprint(use(P.zz))\n')
    local a3 = ans(D3, 29)
    ok(a3 and vim.tbl_contains(a3.contracts, 'globals-never-escape'), 'reading _G\'s __newindex table rests on GE: ' .. vim.inspect(a3 and a3.contracts))
    ok(not vim.tbl_contains(a0.contracts, 'globals-never-escape'), 'the plain answer does not: ' .. vim.inspect(a0.contracts))
    -- (and through an __index table — outside code reads through it and may write into what it gets: flowpath's h18)
    local D4 = dump('local P = { cfg = { p = b } }\nsetmetatable(_G, { __index = P })\nprint(use(P.cfg.p))\n')
    local a4 = ans(D4, 29)
    ok(a4 and vim.tbl_contains(a4.contracts, 'globals-never-escape'), 'a table reached from _G\'s __index table rests on GE: ' .. vim.inspect(a4 and a4.contracts))
end)

-- (CART-1805: an answer that reaches the ESCAPED region rests on what the region rests on — a value unknown code produced,
-- stored into an escaped cell the answer reads, is how flowpath's run-time witnesses went wrong; and an unresolved
-- callee makes unknown-receiver a whole-program clause)
test('flowlabels: an answer reaching the escaped region carries the region; an unresolved call seeds what it reaches (CART-1805, CART-1807)', function ()
    local FL = require 'cartograph.flowlabels'
    local function D(unresolved)
        return {
            names = { fields = { 'a', 'b', 'c', 'd', 'e', 'f' } },
            sites = { { id = 1, kind = 'table', label = 'tbl:x' }, { id = 2, kind = 'ext', label = 'external' },
                { id = 3, kind = 'function', label = 'fn', fn = 1 }, { id = 4, kind = 'table', label = 'tbl:y' },
                { id = 5, kind = 'function', label = 'fn2', fn = 2 } },
            functions = {
                { id = 0, params = {}, self = 20, body = {
                    { 'new', 10, 2 }, { 'call', { 11 }, 10, {} }, { 'store', 12, 5, 11 }, { 'load', 13, 12, 5 },
                    { 'call', { 14 }, 13, {} }, unresolved and { 'call', { 16 }, 15, { 17 } } or { 'copy', 16, 14 } } },
                { id = 1, params = {}, self = 21, body = { { 'ret', {} } } },
                { id = 2, params = { 30 }, self = 22, body = { { 'ret', { 30 } } } } },
            solution = { v = { { 10, { 2 } }, { 12, { 1 } }, { 13, { 3 } }, { 17, { 4 } } }, h = { { 1, 5, { 3 } }, { 4, 6, { 5 } } }, top = {},
                taint = { ports = {}, escaped = { 1 } } },
            contracts = { clauses = {}, library_sites = {}, host_models = {} },
        }
    end
    local L = FL.compute(D(false))
    local names = L.names(L.mask(0, 4))
    ok(vim.tbl_contains(names, 'C1'), 'the load read an escaped cell: ' .. vim.inspect(names))
    ok(vim.tbl_contains(names, 'unknown-code'), 'and so rests on the region, which unknown code wrote: ' .. vim.inspect(names))
    eq(0, L.global, 'nothing unresolved, nothing stated: no global clause')
    eq(nil, L.v[30], 'nothing unresolved: the function in tbl:y is not seeded')
    -- (CART-1807: an unresolved callee's unknown-receiver reaches what its arguments reach — tbl:y's cells, the function
    -- it holds (its parameters), the call's own result — not every answer)
    local L2 = FL.compute(D(true))
    local UR = 'unknown-receiver'
    ok(not vim.tbl_contains(L2.names(L2.global), UR), 'not global')
    ok(vim.tbl_contains(L2.names(L2.w[4] or 0), UR), 'the argument\'s table may be written')
    ok(vim.tbl_contains(L2.names(L2.v[30] or 0), UR), 'the function it holds may be called with anything')
    ok(vim.tbl_contains(L2.names(L2.v[16] or 0), UR), 'its result is its own')
end)

-- (CART-1808: a literal load's chunk is walked nested — the walk left the recorder off, and every instruction after
-- `loadstring("…")` in the caller went missing from the dump: the checker checked a smaller program than the one that
-- runs. The caller's chunk keeps its calls after the load)
test('flowdump: instructions after a literal load stay in the caller\'s body (CART-1808)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function calls(D)
        local n = 0
        for _, F in ipairs(D.functions) do
            if D.names.functions[F.id + 1] == 'chunk:m.lua' then for _, ins in ipairs(F.body) do if ins[1] == 'call' then n = n + 1 end end end
        end
        return n
    end
    local base = calls(dump('local c = 1\n'))
    local n = calls(dump('local c = loadstring("return ...")(1)\nprint(use(a))\n'))
    ok(n >= base + 3, 'the loaded chunk\'s call, print and use(a) are recorded: ' .. base .. ' -> ' .. n)
end)

-- (CART-1811: the string metatable's __index is the string library, and what code WRITES there is a prototype of the
-- string library — the library tables themselves are not: lib:string's natives on every string method were CART-1793's
-- check failures, and the link cost WoW w2 a 41 s re-solve)
test('flowdump: the string metatable keeps lib:string\'s natives off string methods (CART-1811)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('getmetatable("").__index.zz = a\nlocal u = ("x"):format()\n')
    local nat
    for _, x in ipairs(D.sites) do if x.label == 'native:string.format' then nat = x.id end end
    local held = 0
    for _, e in ipairs(D.solution.v) do for _, o in ipairs(e[2]) do if o == nat then held = held + 1 end end end
    eq(0, held, 'no variable holds string.format\'s native: ' .. tostring(nat))
end)

-- (CART-1814: table.move by name inlines a load of its source's elements and a store into its target — the dump denotes
-- the move, and stays closed)
test('flowdump: table.move is a load and a store in the IR (CART-1814)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local t = { b }\ntable.move({ a }, 1, 1, 1, t)\nprint(use(t[1]))\n')
    local stores = 0
    for _, F in ipairs(D.functions) do
        if D.names.functions[F.id + 1] == 'chunk:m.lua' then
            for _, ins in ipairs(F.body) do if ins[1] == 'store' and D.names.fields[ins[3] + 1] == '#' then stores = stores + 1 end end
        end
    end
    ok(stores >= 1, 'a store into the target\'s array part: ' .. stores)
    eq(0, flowcheck.check(D).failed, 'closed')
end)

-- (CART-1813: a literal module lookup of package.loaded is no gap; a computed one still is)
test('flowdump: package.loaded["<module>"] is no gap; package.loaded[k] still is (CART-1813)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function gaps_of(src)
        local root = tree({ ['m.lua'] = CLASSES .. src, ['lua/my/mod.lua'] = 'local M = {}\nreturn M\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, dump = true })
        vim.fn.delete(root, 'rf')
        local n = 0
        for _, g in ipairs(vim.json.decode(R.dump).gaps) do if g.kind == 'package-loaded' then n = n + 1 end end
        return n
    end
    eq(0, gaps_of('local s = package.loaded["my.mod"]\n'), 'literal: no gap')
    eq(1, gaps_of('local k = ...\nlocal s = package.loaded[k]\n'), 'computed: a gap')
end)

-- (CART-1815, flowpath: under pkg-modules a computed package.loaded read is no gap ONLY where a module was linked — a root
-- whose files are not under lua/ links none, and the reads must stay gaps)
test('flowdump: pkg-modules waives the computed package.loaded gap only where modules were linked (CART-1815)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function gaps_of(files)
        local root = tree(files)
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, dump = true, exp = 'pkg-modules' })
        vim.fn.delete(root, 'rf')
        local n = 0
        for _, g in ipairs(vim.json.decode(R.dump).gaps) do if g.kind == 'package-loaded' then n = n + 1 end end
        return n
    end
    local SRC = CLASSES .. 'local k = ...\nlocal s = package.loaded[k]\n'
    eq(0, gaps_of({ ['m.lua'] = SRC, ['lua/my/mod.lua'] = 'return {}\n' }), 'a module linked: the computed read lists it, no gap')
    eq(1, gaps_of({ ['m.lua'] = SRC, ['my/mod.lua'] = 'return {}\n' }), 'no module linked (no lua/ dir): still a gap')
end)

-- (CART-1816: reflection over package.loaded is a LABEL at its reads — computed key, pairs, keys — carried wherever
-- the result flows; the dump reports the reads, the reflecting functions, and the BOUNDARY: labelled variables of other
-- functions, each with the instruction that first carried the label into it)
test('flowdump: a reflective read over package.loaded labels what flows from it, and the dump reports its boundary (CART-1816)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (with the tree's modules listed — pkg-modules — a reflective read reaches a MODULE: what is read through it is
    -- reflected content; through _G or a library, reachable by name, it is an ordinary global read)
    local root = tree({ ['m.lua'] = CLASSES .. table.concat({
        'require("my.mod").obj = a',
        'local function find() for _, m in pairs(package.loaded) do if type(m) == "table" and m.obj then return m.obj end end end',
        'local function outside() local o = find(); return o end',
        'print(use(outside() or b))',
        'for _, m in pairs(package.loaded) do if type(m) == "table" and m.run then m.run(1) end end' }, '\n') .. '\n',
        ['lua/my/mod.lua'] = 'local M = {}\nfunction M.run(q) return q end\nreturn M\n' })
    store.ingest(ts.extract(root))
    local RR = flowtype.solve(store, { open = false, dump = true, exp = 'pkg-modules' })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(RR.dump)
    local R = D.labels.reflection
    ok(R and #R.seeds >= 1, 'the reflective read is a seed: ' .. vim.inspect(R and R.seeds))
    ok(#R.functions == 2, 'two reflecting functions (find, the chunk): ' .. vim.inspect(R.functions))
    local fname = D.names.functions
    local outside = false
    for _, b in ipairs(R.boundary) do
        if tostring(fname[b[2] + 1]):find('outside', 1, true) then outside = true; ok(b[3] >= 0, 'with a first cause: ' .. vim.inspect(b)) end
    end
    ok(outside, 'outside\'s variable is on the boundary: ' .. vim.inspect(R.boundary))
    -- (a function reflection CALLS is not reflected content: its parameter holds what the call passed — the callee's label
    -- does not ride into it, or every module function's parameters were labelled)
    for _, b in ipairs(R.boundary) do ok(not tostring(fname[b[2] + 1]):find('M.run', 1, true), 'M.run\'s parameter is not labelled: ' .. vim.inspect(b)) end
    local a
    for _, x in ipairs(D.answers) do if x.call[3] == 29 then a = x end end
    ok(a and vim.tbl_contains(a.contracts, 'reflection:package.loaded'), 'use\'s answer carries it: ' .. vim.inspect(a and a.contracts))
    local D0 = dump('')
    local a0
    for _, x in ipairs(D0.answers) do if x.call[3] == 29 then a0 = x end end
    ok(a0 and not vim.tbl_contains(a0.contracts, 'reflection:package.loaded'), 'a plain answer does not')
end)

-- (CART-1814 (d), flowpath: a by-name table.insert keeps a call to the native beside its inlined model — a no-op in the
-- denoted program; the in-tree check reads it as the caller's write into its arguments, the positional shift included)
test('flowdump: table.insert by name keeps a call to the native beside its model (CART-1814)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local t = { b }\ntable.insert(t, 1, a)\n')
    local nat
    for _, x in ipairs(D.sites) do if x.label == 'native:table.insert' then nat = x.id end end
    local V = {}
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    local calls, stores = 0, 0
    for _, F in ipairs(D.functions) do
        if D.names.functions[F.id + 1] == 'chunk:m.lua' then
            for _, ins in ipairs(F.body) do
                if ins[1] == 'call' and nat and vim.tbl_contains(V[ins[3]] or {}, nat) then calls = calls + 1 end
                if ins[1] == 'store' and D.names.fields[ins[3] + 1] == '#' then stores = stores + 1 end
            end
        end
    end
    eq(1, calls, 'one call whose callee holds native table.insert')
    ok(stores >= 1, 'beside the model\'s store')
    eq(0, flowcheck.check(D).failed, 'closed')
end)

-- (CART-1817 stage 3, flowpath FLOW-0093: under refl-scope the REGION — a region top whose holdings did not escape, a
-- port only the region's taint reached — is the dump's rtop / rcells, and rroots names what the region reads: the
-- checker lists there the closure of the roots and the escaped universe. An inspecting region escapes no module;
-- without the experiment the saturated region escapes them and nothing of this is written)
test('flowdump: refl-scope states the region as rtop / rcells / rroots, and its modules stay unescaped (CART-1817)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = CLASSES .. 'for _, mod in pairs(package.loaded) do print(type(mod)) end\n'
    local function dump_of(exp)
        local root = tree({ ['m.lua'] = SRC, ['lua/ma.lua'] = 'local M = {}\nfunction M.f(p) return p:m() end\nreturn M\n',
            ['lua/mb.lua'] = 'return { x = 1 }\n', ['lua/mc.lua'] = 'return { y = 2 }\n' })
        store.ingest(ts.extract(root))
        local cap = flowtype.CAP
        flowtype.CAP = 2
        local ok_, R = pcall(flowtype.solve, store, { open = false, dump = true, exp = exp })
        flowtype.CAP = cap
        vim.fn.delete(root, 'rf')
        assert(ok_, R)
        return vim.json.decode(R.dump)
    end
    local function site_of(D, prefix) for _, st in ipairs(D.sites) do if st.label:sub(1, #prefix) == prefix then return st.id end end end
    local D0 = dump_of('pkg-modules')
    local ma0 = site_of(D0, 'tbl:lua/ma.lua')
    ok(ma0 and vim.tbl_contains(D0.solution.taint.escaped, ma0), 'without the scope the module escapes')
    eq(nil, D0.solution.rtop, 'and no region is written')
    local D1 = dump_of('pkg-modules,refl-scope')
    local ma1 = site_of(D1, 'tbl:lua/ma.lua')
    local S = D1.solution
    ok(ma1 and not vim.tbl_contains(S.taint.escaped, ma1), 'with it the module does not escape: ' .. vim.inspect(S.taint.escaped))
    ok(S.rtop and #S.rtop > 0, 'the region top is stated: ' .. vim.inspect(S.rtop))
    ok(vim.tbl_contains(S.rroots, ma1), 'the module is a region root: ' .. vim.inspect(S.rroots))
    for _, x in ipairs(S.rtop) do ok(not vim.tbl_contains(S.top, x), 'a region top is not ⊤: ' .. x) end
end)

-- (and a port the ORDINARY taint reached that also carries a live region top's mark is region too: an escaped function's
-- parameter, handed a module by an inspecting loop, may hold the region — listed as plain taint it held none of it, and
-- the copy into it was refused; the self tree's resolve_requires)
test('flowdump: refl-scope — a tainted port the region reaches is in rtop (CART-1817)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = CLASSES .. table.concat({
        'local function g(x) print(x) end', 'local function g2(x) end', 'local function g3(x) end',
        'local h = g; if math.random() > 0.3 then h = g2 elseif math.random() > 0.5 then h = g3 end; h(1)',
        'for _, mod in pairs(package.loaded) do g(mod) end' }, '\n') .. '\n'
    local root = tree({ ['m.lua'] = SRC, ['lua/ma.lua'] = 'return { f = 1 }\n', ['lua/mb.lua'] = 'return { x = 1 }\n',
        ['lua/mc.lua'] = 'return { y = 2 }\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, R = pcall(flowtype.solve, store, { open = false, dump = true, exp = 'pkg-modules,refl-scope' })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(ok_, R)
    local D = vim.json.decode(R.dump)
    local x
    for _, F in ipairs(D.functions) do if D.names.functions[F.id + 1]:match('::g@') then x = F.params[1] end end
    ok(x and vim.tbl_contains(D.solution.taint.ports, x), 'g escaped: its parameter is tainted: ' .. tostring(x))
    ok(vim.tbl_contains(D.solution.rtop, x), 'and the region reaches it: rtop ' .. vim.inspect(D.solution.rtop))
end)
