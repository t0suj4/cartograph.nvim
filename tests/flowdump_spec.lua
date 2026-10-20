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
test('flowdump: getfenv is no gap under fixed environments, and stays one when the tree calls setfenv', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function kinds(D) local g = {}; for _, x in ipairs(D.gaps) do g[x.kind] = true end; return g end
    local D = dump('\nlocal G = getfenv(0)\nreturn G\n')
    ok(not kinds(D).getfenv, 'no getfenv gap without setfenv')
    ok(D.contracts.clauses['fixed-env'] ~= nil, 'the fixed-env clause is stated')
    D = dump('\nlocal G = getfenv(0)\nsetfenv(1, {})\nreturn G\n')
    ok(kinds(D).getfenv, 'with a setfenv the getfenv gap stays')
    ok(D.contracts.clauses['fixed-env'] == nil, 'and the fixed-env clause is not stated')
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
        'local t = { x = {} }', 'local f = load("return ...")', 'f(t)',
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
        'local f = load("return ...")',
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
        for _, ins in ipairs(F.body) do
            if ins[1] == 'loadDyn' then n = n + 1; ok(tp[ins[2]], 'the dynamic load is tainted: ' .. vim.json.encode(ins)) end
        end
    end
    eq(1, n, 'one dynamic load')
end)
