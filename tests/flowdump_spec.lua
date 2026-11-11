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

-- (CART-1832: `a and b` passes a's FALSE — a boolean, and ext — through a filter the core IR has no instruction for. The
-- solve put type:boolean into the result, no instruction said so: the dump states it as a `new` of the boolean site into the
-- and's result, in the and's function, for each such object a's final set holds)
test('flowdump: an `a and b` states the booleans its left side passes as a `new` into the result (CART-1832)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = 'local t, u = {}, {}\nlocal function g(flag) w = flag and t end\ng(rawequal(t, u))\nlocal function h(x) v = x and t end\nh(t)\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local bool
    for _, s in ipairs(D.sites) do if s.label == 'type:boolean' then bool = s.id end end
    ok(bool, 'the boolean site')
    local function body(name) for _, F in ipairs(D.functions) do if D.names.functions[F.id + 1]:match(name) then return F.body end end end
    local function stated(b)
        local stored, newb = {}, {}
        for _, i in ipairs(b) do
            if i[1] == 'store' then stored[i[4]] = true end
            if i[1] == 'new' and i[3] == bool then newb[i[2]] = true end
        end
        for v in pairs(newb) do if stored[v] then return true end end
        return false
    end
    ok(stated(body('::g@')), 'g: the boolean flag passes into w through a `new`: ' .. vim.inspect(body('::g@')))
    ok(not stated(body('::h@')), 'h: x holds only a table, no boolean is stated: ' .. vim.inspect(body('::h@')))
    local c = flowcheck.check(D, 5)
    eq(0, c.unwritten, 'complete')
end)

test('flowdump: the format — the Lua instance\'s field ids, host sites, per-function error ports, tags, contracts', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local ok, e = pcall(function () error(b) end)\nprint(use(e))\nlocal t = { x = a }\nfor k in pairs(t) do print(k) end\n')
    eq(1, D.format)
    -- (the PRODUCER's commit is cartograph's, wherever the caller stands; a corpus that is no repository has none — CART-1721)
    eq(vim.fn.systemlist({ 'git', '-C', vim.fn.fnamemodify(debug.getinfo(require('cartograph.flowtype').solve, 'S').source:sub(2), ':h'), 'rev-parse', 'HEAD' })[1], D.cartograph)
    eq('git', D.cartograph_via, 'and it says where the commit came from (CART-1997)')
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
        -- (saturates past CAP 2: x, y, z escape. Not `(#arg == 1 and x) or …` since CART-1901: a comparison holds its
        -- boolean, which saturated the inner `or` instead, and z then reached T exactly — not escaped)
        'local T = x or y or z',
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

-- (CART-1772: newproxy(true)'s fresh metatable is setmetatable's — `setmeta` in the IR, no proto / hidden-store gap)
test('flowdump: newproxy(true) is setmeta, not gaps', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump(table.concat({ '',
        'local u = newproxy(true)', 'local mt = getmetatable(u)', 'mt.__index = { x = a }', 'mt.__gc = function () end',
        'return u.x' }, '\n') .. '\n')
    local ops = {}
    for _, F in ipairs(D.functions) do for _, i in ipairs(F.body) do ops[i[1]] = true end end
    eq(0, #D.gaps, 'no gap: ' .. vim.inspect(D.gaps))
    ok(ops.setmeta, 'setmeta is emitted')
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
    local kinds = {}
    for _, s in ipairs(D.sites) do kinds[s.label:match('^(proxy%w*):') or ''] = s.kind end
    eq('proxy', kinds.proxy, 'the userdata is a proxy site')
    eq('table', kinds.proxymt, 'its metatable is a table site')
end)

-- (CART-1775, fixed environments: a tree that never calls setfenv has every environment _G — getfenv leaves no gap and
-- the dump states `fixed-env`; one that does keeps the gap and claims nothing)
test('flowdump: getfenv is no gap under fixed environments, and stays one when a setfenv may target a tree function (CART-1775, CART-1813)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function kinds(D) local g = {}; for _, x in ipairs(D.gaps) do g[x.kind] = true end; return g end
    local D = dump('\nlocal G = getfenv(0)\nreturn G\n')
    ok(not kinds(D).getfenv, 'no getfenv gap without setfenv')
    ok(D.contracts.clauses['fixed-env'] ~= nil, 'the fixed-env clause is stated')
    -- (level 1, the calling function's: getfenv(0) is the thread's, no gap under thread-env since CART-1838)
    D = dump('\nlocal G = getfenv(1)\nsetfenv(1, {})\nreturn G\n')
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
        -- (by value the call has no walk position: the claim is withheld and init carries the setfenv gap, CART-1838)
        ok(D2.contracts.clauses['fixed-env'] == nil and kinds(D2).setfenv, 'not fixed, a setfenv gap: ' .. src)
    end
    for _, src in ipairs {
        '\nlocal sf = setfenv\nlocal G = getfenv(0)\nreturn G, sf\n',
        '\nlocal g = loadstring(tostring(1))\nsetfenv(g, {})\nlocal G = getfenv(0)\nreturn G\n' } do
        local D2 = dump(src)
        ok(D2.contracts.clauses['fixed-env'] ~= nil and not kinds(D2).setfenv and not kinds(D2).getfenv, 'fixed, no gap: ' .. src)
    end
end)

-- (CART-1840: a LEVEL held in a variable — the argument holds a number (its type object since CART-1901; nothing before). It sets the calling
-- function's environment: no fixed-env, a setfenv gap, and the solve applies it)
test('flowdump: a setfenv level held in a variable withholds fixed-env and keeps a gap; the solve applies it (CART-1840)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D, R = dump('\nlocal n = 1\nlocal function f() setfenv(n, { y = a }); return y:m() end\nreturn f\n')
    local kinds = {}
    for _, g in ipairs(D.gaps) do kinds[g.kind] = true end
    ok(D.contracts.clauses['fixed-env'] == nil and kinds.setfenv, 'no fixed-env, a setfenv gap: ' .. vim.inspect(D.gaps))
    -- (`y` in f reads the environment's field — CLASSES' a, whose m is A.m)
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'y:m' then v = R.verdict(c) end end
    ok(v and v.kind == 'exact' and tostring(v.targets[1]):find('A.m', 1, true), 'y:m() is A.m: ' .. vim.inspect(v))
    -- (a level may be 0, the thread's: a store through getfenv(0) lands in E)
    D, R = dump('\nlocal E = {}\nlocal n = 0\nsetfenv(n, E)\ngetfenv(0).z = b\nE.z:m()\nreturn E\n')
    v = nil
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'E.z:m' then v = R.verdict(c) end end
    ok(v and v.kind == 'exact' and tostring(v.targets[1]):find('B.m', 1, true), 'E.z:m() is B.m: ' .. vim.inspect(v))
end)

-- (CART-1838 (experiment no-getfenv0: the plain union): getfenv(0) is the THREAD's environment. A setfenv at level 1 withholds fixed-env, but
-- getfenv(0) is still the globals table — no gap, under the clause thread-env; a setfenv that may set level 0 keeps it)
test('flowdump: getfenv(0) is the globals table under thread-env; a setfenv that may set level 0 keeps the gap (CART-1838)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function kinds(D) local g = {}; for _, x in ipairs(D.gaps) do g[x.kind] = true end; return g end
    local src = '\nlocal M = {}\nlocal G = getfenv(0)\nlocal function f() setfenv(1, M) end\nreturn G, f\n'
    local D = dump(src)
    ok(not kinds(D).getfenv, 'no getfenv gap: ' .. vim.inspect(D.gaps))
    ok(D.contracts.clauses['thread-env'] ~= nil and D.contracts.clauses['fixed-env'] == nil, 'thread-env stated, fixed-env not')
    local C = flowcheck.check(D)
    eq(0, C.failed, 'the dump is closed')
    -- (init makes the globals site in getfenv(0)'s variable too — one `new` more than the stock dump: a copy out of an
    -- unwritten variable checks closed, vacuously)
    local function gnews(X)
        local n, initid = 0, nil
        for i, nm in ipairs(X.names.functions) do if nm == 'init' then initid = i - 1 end end
        for _, F in ipairs(X.functions) do
            if F.id == initid then for _, i in ipairs(F.body) do if i[1] == 'new' and i[3] == X.contracts.globals_site then n = n + 1 end end end
        end
        return n
    end
    local g0 = gnews(D)
    D = dump(src, 'no-getfenv0')
    ok(kinds(D).getfenv and D.contracts.clauses['thread-env'] == nil, 'no-getfenv0: the gap stays, no clause')
    eq(gnews(D) + 1, g0, 'init news the globals site into getfenv(0)\'s variable')
    for _, s in ipairs {
        '\nlocal M = {}\nlocal G = getfenv(0)\nsetfenv(0, M)\nreturn G\n',
        '\nlocal n = 0\nlocal G = getfenv(0)\nsetfenv(n, {})\nreturn G\n' } do
        D = dump(s)
        ok(kinds(D).getfenv and D.contracts.clauses['thread-env'] == nil, 'may set level 0, the gap stays: ' .. s)
    end
    -- (loaded code is a function, as fixed-env reads it: no level 0, and fixed-env already covers getfenv)
    D = dump('\nlocal G = getfenv(0)\nsetfenv(loadstring(tostring(1)), {})\nreturn G\n')
    ok(not kinds(D).getfenv and D.contracts.clauses['fixed-env'] ~= nil, 'loaded code: no gap, fixed-env')
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

-- (CART-1850: what unknown code is handed is recorded past CAP — G7.EXTCALL is ONE port for every load and outside module,
-- it saturated on every corpus, and settop dropped what it held: the unknown-code rule saw nothing, `a` rooted as a mere
-- saturation and its fields untainted by that rule)
test('flowdump: what is handed to unknown code keeps its unknown-code root after the sink passes CAP (CART-1850)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local SRC = table.concat({ '',
        'local f = load(("return ..."):lower())',
        'local a = { x = {} }',
        'f(a)', 'f({})', 'f({})', 'f({})',
        'local b = { y = {} }',
        'f(b)',                                    -- (handed AFTER the sink passed CAP)
        'return a.x, b.y' }, '\n') .. '\n'
    local okd, D, RD = pcall(dump, SRC)
    -- (and outside the dump, where a saturated port collapses into ⊤ and the sink must stay its own port; and with sets
    -- as bitsets from the first object, so a delivery to the saturated sink is a bitset)
    local root = tree({ ['m.lua'] = SRC })
    store.ingest(ts.extract(root))
    local oks, R = pcall(flowtype.solve, store, { open = false })
    local big = flowtype.BIG
    flowtype.BIG = 1
    store.ingest(ts.extract(root))
    local okb, RB = pcall(flowtype.solve, store, { open = false })
    flowtype.BIG = big
    vim.fn.delete(root, 'rf')
    flowtype.CAP = cap
    assert(okd, D); assert(oks, R); assert(okb, RB)
    -- (the seven, by the dump's labels: a, a.x, the three `{}`, b, b.y — and not type:string, the tables' key sets' type:
    -- a scalar's type object is no object outside code may write, CART-1869)
    eq(7, RD.stats.unknown_code, 'dump: every object handed reaches the unknown-code rule')
    eq(7, R.stats.unknown_code, 'with the ⊤ node')
    eq(7, RB.stats.unknown_code, 'with bitsets')
    local id = {}
    for _, s in ipairs(D.sites) do id[s.label] = s.id end
    local cls = {}
    for _, e in ipairs(D.solution.taint.escaped_root) do cls[e[1]] = e[2] end
    local a, b = id['tbl:m.lua:8:10'], id['tbl:m.lua:13:10']
    assert(a and b, 'a and b have sites: ' .. vim.inspect(vim.tbl_keys(id)))
    eq('unknown-code', cls[a], 'a, handed before the sink saturated: ' .. vim.inspect(D.solution.taint.escaped_root))
    eq('unknown-code', cls[b], 'b, handed after: ' .. vim.inspect(D.solution.taint.escaped_root))
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

-- (CART-2006, flowpath FLOW-0170: a DIRECT assert runs its model by name — every argument a copy into its result in the
-- IR, not the signature's first only — and table.foreach / foreachi inline their callback's call: by name both had left
-- results 2..n with no route, or only a taint the certificate need not keep)
test('flowdump: a direct assert copies every argument, table.foreach calls its callback, pcall(pcall, f) inlines, in the IR (CART-2006)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D1 = dump('local _, x = assert(a)\nprint(use(x))\n')
    local D2 = dump('local _, x = assert(a, b)\nprint(use(x))\n')
    ok((opcodes(D2).copy or 0) > (opcodes(D1).copy or 0), 'assert(a, b): a copy of b into the second result')
    eq(0, flowcheck.check(D2).failed, 'closed')
    local D0 = dump('local r = nil\nprint(use(r))\n')
    local D3 = dump('local r = table.foreach({ 1 }, function (k, v) return b end)\nprint(use(r))\n')
    ok((opcodes(D3).keys or 0) > (opcodes(D0).keys or 0), 'foreach: the keys its callback gets')
    ok((opcodes(D3).call or 0) > (opcodes(D0).call or 0) + 1, 'foreach: the native AND its callback are called')
    eq(0, flowcheck.check(D3).failed, 'closed')
    -- (a protected BUILTIN with a template inlines its model too: pcall(pcall, f)'s inner pcall calls f — it had been a
    -- lost call, its third result only a taint)
    local D4 = dump('local function f() return b end\nlocal _, _, r = pcall(pcall, f)\nprint(use(r))\n')
    eq(2, opcodes(D4).pcall, 'the outer pcall and the inlined inner one')
    eq(0, #D4.solution.taint.ports, 'no taint stands in for f\'s result')
    eq(0, flowcheck.check(D4).failed, 'closed')
    local D5 = dump('local function f() return b end\npcall(pcall, f)\n') -- (one result: the other branch)
    eq(2, opcodes(D5).pcall, 'a statement pcall(pcall, f) inlines too')
    eq(0, flowcheck.check(D5).failed, 'closed')
    -- (and ONLY pcall: table.sort's model calls a comparator that raises — inlined into the caller, unprotected, that
    -- raise would be the caller's and the dump not closed; it stays a lost call)
    local D6 = dump('local ok, e = pcall(table.sort, { 2, 1 }, function (x, y) error(b) end)\nprint(use(e))\n')
    eq(0, flowcheck.check(D6).failed, 'a protected sort stays closed')
end)

-- (CART-2007: a string METHOD runs its builtin's model once the receiver holds a string, inlined where the model has a
-- template — gsub's: a table replacement is LOADED by a key it lacks, so its __index runs in the IR, the handler's
-- parameters written; a model-less builtin by name loads each argument the same way)
test('flowdump: s:gsub(p, repl) loads a table replacement, os.time(t) loads t, by a key they lack (CART-2007)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function misses(D)
        local n = 0
        for _, F in ipairs(D.functions) do
            for _, ins in ipairs(F.body) do
                if ins[1] == 'load' and D.names.fields[ins[4] + 1] == '(a key it lacks)' then n = n + 1 end
            end
        end
        return n
    end
    local H = 'local E = setmetatable({ v = b }, { __index = function (t, k) use(rawget(t, "v")); return "x" end })\n'
    local D1 = dump(H .. 'local r = ("a"):gsub("a", E)\n')
    eq(1, misses(D1), 'the method gsub: one load of its replacement')
    eq(0, flowcheck.check(D1).failed, 'closed')
    local D2 = dump(H .. 'local r = os.time(E)\n')
    eq(1, misses(D2), 'os.time: one load of its argument')
    eq(0, flowcheck.check(D2).failed, 'closed')
    -- (a function replacement takes every capture: the call spreads its one capture port from the first parameter)
    local D3 = dump('local r = ("k=v"):gsub("(%w)=(%w)", function (x, y) return y end)\n')
    local spread = 0
    for _, F in ipairs(D3.functions) do for _, sp in ipairs(F.spread or {}) do if sp[2] == 1 then spread = spread + 1 end end end
    eq(1, spread, 'the replacement call spreads from position 1')
    eq(0, flowcheck.check(D3).failed, 'closed')
end)

-- (CART-2016, flowpath FLOW-0049: debug.getinfo(...) is a fresh table whose `func` is the function the call names — a
-- literal level 1 the calling closure, through its `self`; a function argument itself — with no gap; any other level,
-- or an argument that may be a level, is any function and the gap debug-getinfo. `func` had held nothing)
test('flowdump: debug.getinfo\'s func is the named function; another level is the gap debug-getinfo (CART-2016)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function run(src)
        local D = dump(src)
        local n = 0
        for _, g in ipairs(D.gaps) do if g.kind == 'debug-getinfo' then n = n + 1 end end
        local lab, fid, held = {}, nil, {}
        for _, st in ipairs(D.sites) do lab[st.id] = st.label end
        for i, nm in ipairs(D.names.fields) do if nm == 'func' then fid = i - 1 end end
        for _, e in ipairs(D.solution.h) do
            if e[2] == fid and tostring(lab[e[1]]):match('^getinfo:') then for _, o in ipairs(e[3]) do held[#held + 1] = lab[o] end end
        end
        return n, held, D
    end
    local n, held, D = run('local function g() return debug.getinfo(1, "f").func end\nprint(use(g()))\n')
    eq(0, n, 'level 1: no gap')
    ok(#held == 1 and tostring(held[1]):find('::g@', 1, true), 'level 1: func is g: ' .. vim.inspect(held))
    eq(0, flowcheck.check(D).failed, 'closed')
    n, held, D = run('local function g() end\nlocal f = debug.getinfo(g, "f").func\nprint(use(f))\n')
    eq(0, n, 'a function argument: no gap')
    ok(#held == 1 and tostring(held[1]):find('::g@', 1, true), 'a function argument: func is it: ' .. vim.inspect(held))
    eq(0, flowcheck.check(D).failed, 'closed')
    n = run('local function g() return debug.getinfo(2, "f").func end\nprint(use(g()))\n')
    eq(1, n, 'level 2: the gap')
    n = run('local k = 2\nlocal function g() return debug.getinfo(k, "f").func end\nprint(use(g()))\n')
    eq(1, n, 'an argument that may be a level: the gap')
    -- (only where `func` exists and is read: a `what` without "f" has no func — lua5.1, LuaJIT, 5.4 — and a getinfo
    -- read for its scalars, the common shape, is no gap; the THREAD form names a frame of that coroutine: the gap)
    eq(0, (run('local function g() return debug.getinfo(2, "S").source end\nprint(g())\n')), 'what "S": no func, no gap')
    eq(0, (run('local function g() return debug.getinfo(2).currentline end\nprint(g())\n')), 'a scalar read: no gap')
    n, held = run('local co = coroutine.create(function () end)\nlocal f = debug.getinfo(co, 1, "f").func\nprint(f)\n')
    eq(1, n, 'the thread form: the gap')
    eq(0, (run('local function g() return debug.getinfo(2, "S").func end\nprint(g())\n')), 'what "S", func read: nil, no gap')
    eq(1, (run('local co = coroutine.create(function () end)\nlocal k = 1\nlocal f = debug.getinfo(co, k, "f").func\nprint(f)\n')),
        'a thread with a computed level: the gap')
    for _, l in ipairs(held) do ok(not tostring(l):match('^thread:'), 'the thread is not func: ' .. vim.inspect(held)) end
end)

-- (CART-2013, flowpath FLOW-0049: debug.sethook BY IDENTITY — the native's model calls the hook, tagged host:sethook,
-- for a call the text rule did not recognise: `local d = debug; d.sethook(h, "c")` had called no hook, a certified
-- answer missing the hook's error. The spelled forms keep their one call; a shadowed `debug` calls nothing)
test('flowdump: debug.sethook through a library alias calls its hook, tagged host:sethook (CART-2013)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function hooks(src)
        local D = dump(src)
        local n = 0
        for _, F in ipairs(D.functions) do for _, t in ipairs(F.tags or {}) do if tostring(t[2]):find('^host:sethook') then n = n + 1 end end end
        return n, D
    end
    local H = 'local function h(ev) error(b) end\n'
    local n, D = hooks(H .. 'local d = debug\nd.sethook(h, "c")\n')
    ok(n >= 1, 'a library alias: the hook is called: ' .. n)
    eq(0, flowcheck.check(D).failed, 'closed')
    eq(1, (hooks(H .. 'debug.sethook(h, "c")\n')), 'by name: one call, not the model\'s too')
    eq(1, (hooks(H .. 'local sh = debug.sethook\nsh(h, "c")\n')), 'a function alias: one call')
    eq(0, (hooks(H .. 'local debug = { sethook = function () end }\ndebug.sethook(h, "c")\n')), 'a shadowed debug: none')
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

-- (a region value stored as a KEY — `t[m] = 1` over package.loaded's modules — makes t's key set the region's: rkeys,
-- where flowpath adds UR to the key set; without it the store was refused, the self tree's resolve_requires, CART-1817)
test('flowdump: refl-scope — a key set the region writes is in rkeys (CART-1817)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES .. 'local t = {}\nfor _, m in pairs(package.loaded) do t[m] = 1 end\nreturn t\n',
        ['lua/ma.lua'] = 'return { f = 1 }\n', ['lua/mb.lua'] = 'return { x = 1 }\n', ['lua/mc.lua'] = 'return { y = 2 }\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, R = pcall(flowtype.solve, store, { open = false, dump = true, exp = 'pkg-modules,refl-scope' })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(ok_, R)
    local D = vim.json.decode(R.dump)
    local t
    for _, st in ipairs(D.sites) do if st.label == 'tbl:m.lua:6:10' then t = st.id end end
    ok(t, 'the table t: ' .. vim.inspect(vim.tbl_map(function (x) return x.label end, D.sites)))
    ok(D.solution.rkeys and vim.tbl_contains(D.solution.rkeys, t), 'its key set is the region\'s: ' .. vim.inspect(D.solution.rkeys))
end)

-- (CART-1810: `ver` is the analysed code's Lua version — its profile's lua_version, 51 when none is declared: flowpath's
-- core keys comparison semantics on it. It had been written 51 for Factorio's 5.2 too)
test('flowdump: ver is the profile\'s Lua version (CART-1810)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function ver_of(profile)
        local root = tree({ ['m.lua'] = CLASSES })
        store.ingest(ts.extract(root))
        if profile then store.data.profile = profile end
        local R = flowtype.solve(store, { open = false, dump = true })
        vim.fn.delete(root, 'rf')
        return vim.json.decode(R.dump).ver
    end
    eq(51, ver_of(nil), 'no profile: Lua 5.1')
    eq(51, ver_of('nvim'), 'nvim declares none: 5.1 (LuaJIT)')
    eq(52, ver_of('lua-factorio'), 'Factorio: 5.2')
end)

-- (a region top whose holdings ESCAPE at a capability taints them as the ordinary taint does: an escaped module's cells
-- are ⊤, never stated as region — run with the region's mark, `ma`'s `[]` cell and the callee of `require("ma").f`
-- came out rcells / rtop and the checker refused the call fixture at 6 instructions, CART-1817)
test('flowdump: refl-scope — what a capability escapes is not stated as region (CART-1817)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = CLASSES .. 'require("ma").f(b)\nfor _, mod in pairs(package.loaded) do if type(mod) == "table" and mod.f then mod.f(a) end end\n'
    local root = tree({ ['m.lua'] = SRC, ['lua/ma.lua'] = 'local M = {}\nfunction M.f(p) return p:m() end\nreturn M\n',
        ['lua/mb.lua'] = 'return { x = 1 }\n', ['lua/mc.lua'] = 'return { y = 2 }\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, R = pcall(flowtype.solve, store, { open = false, dump = true, exp = 'pkg-modules,refl-scope' })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(ok_, R)
    local D = vim.json.decode(R.dump)
    local ma
    for _, st in ipairs(D.sites) do if st.label:sub(1, 14) == 'tbl:lua/ma.lua' then ma = st.id end end
    ok(ma and vim.tbl_contains(D.solution.taint.escaped, ma), 'the call through the region escaped ma')
    for _, c in ipairs(D.solution.rcells or {}) do ok(c[1] ~= ma, 'an escaped module\'s cell is not region: ' .. vim.inspect(c)) end
end)

-- (a variable that only ever holds KEYS read from region objects is rtopk: flowpath gives it the union of UR's key sets,
-- not UR — `n .. "." .. k` over the modules' keys, where the one __concat object is itself a module, was refused at the
-- concatenations with k as rtop; flowpath's opfix probe on CART-1817)
test('flowdump: refl-scope — a key read from the region is rtopk, and its copy too (CART-1817)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = 'for n, mod in pairs(package.loaded) do if type(mod) == "table" then for k in pairs(mod) do print(n .. "." .. k) end end end\n',
        ['lua/hz.lua'] = 'local H = setmetatable({}, { __concat = function (x, y) return "h" end })\nreturn H\n',
        ['lua/mb.lua'] = 'return { x = 1 }\n', ['lua/mc.lua'] = 'return { y = 2 }\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, R = pcall(flowtype.solve, store, { open = false, dump = true, exp = 'pkg-modules,refl-scope' })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(ok_, R)
    local D = vim.json.decode(R.dump)
    local S = D.solution
    local keysdst, copied
    for _, F in ipairs(D.functions) do
        for _, ins in ipairs(F.body) do
            if ins[1] == 'keys' and vim.tbl_contains(S.rtop, ins[3]) then keysdst = ins[2] end
        end
        for _, ins in ipairs(F.body) do if ins[1] == 'copy' and ins[3] == keysdst then copied = ins[2] end end
    end
    ok(keysdst and vim.tbl_contains(S.rtopk, keysdst), 'the keys read through a region base: rtopk ' .. vim.inspect(S.rtopk))
    ok(copied and vim.tbl_contains(S.rtopk, copied), 'and the loop variable it is copied into')
    ok(not vim.tbl_contains(S.rtop, keysdst) and not vim.tbl_contains(S.rtop, copied), 'neither is rtop: ' .. vim.inspect(S.rtop))
end)

-- (CART-1820: the dump states the names a literal-keyed dynamic _G step reaches, gn_exclude — flowpath's GN takes them
-- out of its named set)
test('flowdump: gn_exclude names the globals a literal-keyed dynamic _G step reaches (CART-1820)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump('local MAJOR = "LibStub"\n_G[MAJOR] = function (n) return a end\nprint(LibStub("x"))\n')
    local names = {}
    for _, id in ipairs(D.gn_exclude or {}) do names[#names + 1] = D.names.fields[id + 1] end
    eq({ 'LibStub' }, names, 'LibStub, and nothing else')
    eq(nil, dump('print(use(b))\n').gn_exclude, 'no such step: no field')
end)

-- (CART-1822: a declared loader's values are created in init — one private table per package, the chunk's `...` a copy
-- of each position — under the clause loader-args; the name is a key literal, so a DYNAMIC `_G[name]` excludes it from
-- GN. CART-1755: a local bound to the name and never assigned is a constant key — `_G[addonName]` a named load)
test('flowdump: a declared loader\'s chunk values are init\'s, under loader-args; the addon name is a named key, or excluded from GN (CART-1822, CART-1755)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['Addon/Addon.toc'] = '## Title: Addon\na.lua\nb.lua\n',
        ['Addon/a.lua'] = 'local name, ns = ...\nns.f = function () return 1 end\nname = name\n_G[name] = {}\n',
        ['Addon/b.lua'] = 'local name, ns = ...\nlocal x = ns.f()\nAddon.y = 1\n',
        ['Addon/c.lua'] = 'local addonName = ...\nlocal t = _G[addonName]\n',
    })
    local root0 = root
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    local D = vim.json.decode(R.dump)
    local pkg
    for _, s in ipairs(D.sites) do if s.label == 'tbl:package:Addon' then pkg = s end end
    ok(pkg and pkg.kind == 'table', 'the private table is a table site')
    local news = 0
    for i, F in ipairs(D.functions) do
        for _, ins in ipairs(F.body) do
            if ins[1] == 'new' and ins[3] == pkg.id then
                eq('init', D.names.functions[i], 'created in init'); news = news + 1
            end
        end
    end
    eq(3, news, 'one new per file reading `...`, of the one site')
    ok(D.contracts.clauses['loader-args'] ~= nil, 'the clause is stated')
    local ex = {}
    for _, f in ipairs(D.gn_exclude or {}) do ex[D.names.fields[f + 1]] = true end
    ok(ex.Addon, 'a dynamic key (name is assigned in a.lua): the addon name is excluded from GN: ' .. vim.inspect(D.gn_exclude))
    eq(0, #D.gaps, 'no gap')
    -- (the named lowering is opts.litkeys', CART-1755: by default c.lua's read stays dynamic)
    local dyn0 = false
    for i, F in ipairs(D.functions) do
        if D.names.functions[i] == 'chunk:Addon/c.lua' then for _, ins in ipairs(F.body) do if ins[1] == 'loadDyn' then dyn0 = true end end end
    end
    ok(dyn0, 'default: `_G[addonName]` stays a dynamic read')
    store.ingest(ts.extract(root0))
    D = vim.json.decode(flowtype.solve(store, { open = false, dump = true, litkeys = true }).dump)
    vim.fn.delete(root0, 'rf')
    local cops, named = {}, false
    for i, F in ipairs(D.functions) do
        if D.names.functions[i] == 'chunk:Addon/c.lua' then
            for _, ins in ipairs(F.body) do
                cops[ins[1]] = true
                if ins[1] == 'load' and D.names.fields[ins[4] + 1] == 'Addon' then named = true end
            end
        end
    end
    ok(named and not cops.loadDyn, 'c.lua: `_G[addonName]` is a named load of Addon: ' .. vim.inspect(cops))
end)

-- (CART-1824, flowpath FLOW-0097: the taint's first-cause links are dumped — taint.from, [node, parent | null, reason |
-- null] — a top the GN exclusion made carries its own reason, not CAP's, and two runs dump the same links)
test('flowdump: taint.from links, the GN-exclusion top\'s reason, and a stable order (CART-1824)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local src = 'local MAJOR = "LibStub"\n_G[MAJOR] = function (n) return a end\nlocal L = LibStub("x")\nprint(use(L))\n'
    local D = dump(src)
    local from = D.solution.taint.from
    ok(from and #from > 0, 'the links are dumped')
    local gn, cap = false, false
    for _, l in ipairs(from) do
        if type(l[3]) == 'string' and l[3]:find('contract GN: _G.LibStub', 1, true) then gn = true end
    end
    ok(gn, 'the GN-exclusion top is seeded under the contract, not CAP: ' .. vim.inspect(from):sub(1, 400))
    local partial
    for _, a in ipairs(D.answers) do if a.partial then partial = a end end
    ok(partial and partial.ptport ~= nil, 'a partial answer names the tainted port it read')
    eq(vim.json.encode(from), vim.json.encode(dump(src).solution.taint.from), 'the same links on a second run')
end)

-- (CART-1825, flowpath FLOW-0099: a function's `self` variable is numbered by the WALK — a solve that makes a different
-- number of ports (here one cut short by fuel: fewer call instances) dumps the same program, so a base and a resumed
-- dump meet without renaming; the variables a solve makes come after every walk port)
test('flowdump: `self` variables do not move with the solve (CART-1825)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local src = table.concat({ '',
        'local function iter(t) local i = 0; return function () i = i + 1; return t[i] end end',
        'local t = { { v = function () return 1 end }, { v = function () return 2 end } }',
        'for x in iter(t) do print(x.v()) end', 'for y in iter({ t[1] }) do print(y.v()) end',
        'local co = coroutine.wrap(function () return 1 end)', 'print(co())' }, '\n') .. '\n'
    local function run(fuel)
        local root = tree({ ['m.lua'] = CLASSES .. src })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, dump = true, fuel = fuel })
        vim.fn.delete(root, 'rf')
        return vim.json.decode(R.dump), R
    end
    local A, RA = run(nil)
    local B, RB = run(3)
    ok(RA.stats.ports ~= RB.stats.ports, 'the solves made different ports: ' .. RA.stats.ports .. ' vs ' .. RB.stats.ports)
    local sb = {}
    for _, F in ipairs(B.functions) do sb[F.id] = F.self end
    local n, same = 0, 0
    for _, F in ipairs(A.functions) do n = n + 1; if sb[F.id] == F.self then same = same + 1 end end
    eq(n, same, 'every function keeps its self variable')
end)

-- (CART-1826: what an ESCAPED function raises escapes with it — outside code that calls it may catch the value. escret
-- had closed over its returns only: gencheck.lua's callback, saturated, raised a table the dump did not list as escaped,
-- and the E-certificate's function closure refused the whole self tree)
test('flowdump: an escaped function\'s raised value escapes with it (CART-1826)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, D = pcall(dump, table.concat({ '',
        'local function lose(x) return x end',
        'lose({})', 'lose({})', 'lose({})',
        'local function spend() error({ fuel = true }) end',
        'local cb = lose(function () spend() end)',             -- the callback escapes through lose's saturated port
        'return cb' }, '\n') .. '\n')
    flowtype.CAP = cap
    assert(ok_, D)
    local lab, fsite = {}, {}
    for _, s in ipairs(D.sites) do lab[s.id] = s.label; if s.fn then fsite[s.fn] = s.id end end
    local esc = {}
    for _, o in ipairs(D.solution.taint.escaped) do esc[o] = true end
    local cbfn, raised
    for i, nm in ipairs(D.names.functions) do if tostring(nm):match('::lose#cb@') then cbfn = i - 1 end end
    ok(cbfn and esc[fsite[cbfn]], 'the callback escaped: ' .. tostring(cbfn))
    for _, e in ipairs(D.solution.err.fn) do if e[1] == cbfn then raised = e[2] end end
    ok(raised and #raised > 0, 'the callback raises something')
    for _, o in ipairs(raised) do ok(esc[o], 'what it raises escaped: ' .. tostring(lab[o])) end
end)

-- (CART-1664: the labels read the dump's own Lua values (LD), not the finished JSON parsed back — a whole decoded copy
-- of the dump beside the solve. LD lists by hand what flowlabels reads, so it is pinned to the parsed-back route: every
-- fixture's dump byte-identical both ways — a section LD missed would label less, silently)
test('flowdump: labels from the dump\'s Lua values equal labels from its JSON parsed back (CART-1664)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local FD = require 'cartograph.flowdump'
    local fixtures = {
        { ['m.lua'] = CLASSES .. 'x = b\nprint(use(x))\n' },
        { ['m.lua'] = CLASSES .. 'local s = UNDEFINED_SOURCE\nlocal x = s:lower():upper()\nlocal t = {}\nt[s] = x\nprint(use(t[UNDEFINED_KEY] or a))\nreturn t\n' },
        { ['m.lua'] = CLASSES .. 'local h = {}\nh[G_KEY] = b\nlocal r = h[G_KEY2]\nloadstring(CODE)(r)\nprint(use(r or a))\nprint(use(GLOBAL_OBJ))\nprint(coroutine.wrap(function (v) return use(v) end)(b))\n' },
        { ['m.lua'] = CLASSES .. 'require("my.mod").obj = a\nfor _, m in pairs(package.loaded) do if type(m) == "table" and m.run then m.run(b) end end\n',
          ['lua/my/mod.lua'] = 'local M = {}\nfunction M.run(q) return use and q end\nreturn M\n', exp = 'pkg-modules' },
        -- (a function reached only through a DYNAMIC cell of a table handed to an unresolved callee: hdyn)
        { ['m.lua'] = CLASSES .. 'local t = {}\nt[UNKNOWN_K] = function (q) return use(q) end\nUNRESOLVED_FN(t)\n' },
        -- (the vararg markers — a slot, a spread call / pcall / ret, a 5.1 arg table: CART-1924)
        { ['m.lua'] = CLASSES .. 'local function va(x, ...) local p, q = ... return p, q end\nlocal function sp(...) return 1, va(...) end\nlocal function old(...) return arg end\nprint(va(a, b, b), sp(a), old(b), pcall(va, a))\n' },
        -- (a closure capturing an outer local: upvalues, CART-1958)
        { ['m.lua'] = CLASSES .. 'local function cap() return a end\nlocal function cap2() return function () return b end end\nprint(use(cap()), cap2())\n' },
        -- (a call into a host model: host_models)
        { ['m.lua'] = CLASSES .. 'debug.getregistry().obj = a\nprint(use(debug.getregistry().obj))\n',
          hostmodels = { test = 'local REG = {}\nreturn { ["debug#getregistry"] = function () return REG end }\n' } },
    }
    local function run(files, byd)
        local f = vim.deepcopy(files); local exp, hm = f.exp, f.hostmodels; f.exp, f.hostmodels = nil, nil
        local root = tree(f)
        store.ingest(ts.extract(root))
        FD._labels_by_decode = byd
        -- (and LD itself against the same projection of the parsed-back dump: a section no fixture's labels depend on —
        -- host_models has function ids on no corpus — is still pinned)
        local same = true
        FD._ld_probe = function (LD, D)
            local s, c = D.solution, D.contracts
            local proj = { functions = {}, sites = {}, names = { fields = D.names.fields }, program_vars = D.program_vars,
                solution = { v = s.v, top = s.top, h = s.h, hdyn = s.hdyn, htop = s.htop, taint = { ports = s.taint.ports, escaped = s.taint.escaped } },
                contracts = { library_sites = c.library_sites, package_loaded_sites = c.package_loaded_sites, host_models = c.host_models, ext_channel = c.ext_channel, clauses = c.clauses } }
            for i, f in ipairs(D.functions) do proj.functions[i] = { id = f.id, params = f.params, self = f.self, body = f.body, tags = f.tags,
                upvalues = f.upvalues, -- (what it captures, CART-1958)
                declares = f.declares, -- (what it declares, CART-1987)
                vararg = f.vararg, spread = f.spread, argtable = f.argtable, -- (the vararg markers, CART-1924)
                rest = f.rest } end -- (a call's rest result, CART-1948)
            for i, x in ipairs(D.sites) do proj.sites[i] = { id = x.id, kind = x.kind, label = x.label, fn = x.fn, host = x.host } end
            same = vim.deep_equal(vim.json.decode(vim.json.encode(LD)), vim.json.decode(vim.json.encode(proj)))
        end
        local okr, R = pcall(flowtype.solve, store, { open = false, dump = true, exp = exp, hostmodels = hm })
        FD._labels_by_decode, FD._ld_probe = nil, nil
        ok(same, 'LD is the parsed-back dump\'s projection')
        vim.fn.delete(root, 'rf')
        assert(okr, R)
        return R.dump
    end
    for i, fx in ipairs(fixtures) do
        -- (each run has its own temp root, which the dump records: the rest must agree byte for byte)
        local a, b = run(fx, false), run(fx, true)
        local D = vim.json.decode(a)
        a, b = a:gsub('"corpus":{"root":"[^"]*"', '', 1), b:gsub('"corpus":{"root":"[^"]*"', '', 1)
        ok(D.labels and #D.labels.clauses > 0 and #D.answers > 0, 'fixture ' .. i .. ' carries labels and answers')
        ok(a == b, 'fixture ' .. i .. ': the dump is the same both ways (' .. #a .. ' vs ' .. #b .. ' bytes)')
    end
end)

-- (CART-1664: a dump to a FILE streams there — never one string — and is byte for byte the text dump = true returns.
-- Over 4,096 variables, so a list crosses the writer's chunk boundary)
test('flowdump: a dump written to a file is the text dump = true returns, across chunk boundaries (CART-1664)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local lines = {}
    for i = 1, 4500 do lines[i] = ('local t%d = { a = %d }'):format(i, i) end
    local root = tree({ ['m.lua'] = CLASSES .. table.concat(lines, '\n') .. '\nprint(use(b))\n' })
    store.ingest(ts.extract(root))
    local path = vim.fn.tempname()
    local Rf = flowtype.solve(store, { open = false, dump = path })
    local Rs = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local fd = assert(io.open(path, 'rb')); local text = fd:read('a'); fd:close(); os.remove(path)
    eq(nil, Rf.dump, 'a file dump returns no text')
    local D = vim.json.decode(text)
    ok(#D.solution.v > 4096, 'the v list crosses a chunk: ' .. #D.solution.v)
    ok(text == Rs.dump, ('the same bytes (%d vs %d)'):format(#text, #Rs.dump))
end)

-- (CART-1664: a dump is a batch run — the collector's pause is 110 during it, the caller's own afterwards; opts.gcpause
-- sets another, false keeps the caller's)
test('flowdump: a dump solves at GC pause 110 and restores the caller\'s pause (CART-1664)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES })
    store.ingest(ts.extract(root))
    local seen = {}
    local FD = require 'cartograph.flowdump'
    local build0 = FD.build
    FD.build = function (...) seen[#seen + 1] = collectgarbage('setpause', 0); collectgarbage('setpause', seen[#seen]); return build0(...) end
    local before = collectgarbage('setpause', 175)
    local ok1 = pcall(flowtype.solve, store, { open = false, dump = true })
    local after = collectgarbage('setpause', 175)
    pcall(flowtype.solve, store, { open = false, dump = true, gcpause = false })
    pcall(flowtype.solve, store, { open = false, dump = true, gcpause = 130 })
    collectgarbage('setpause', before)
    FD.build = build0
    vim.fn.delete(root, 'rf')
    ok(ok1, 'the dump solved')
    eq({ 110, 175, 130 }, seen, 'the pause during each dump')
    eq(175, after, 'the caller\'s pause is back afterwards')
end)

-- (CART-1924, for flowpath FLOW-0047: the dump wrote a function's vararg port as an ordinary LAST PARAMETER and a call
-- whose last argument is `...` as an ordinary argument list, so the checker bound arguments by position and a solution
-- missing the third argument's site in `q` of `local p, q = ...` passed the certificate. Now: the vararg slot is NAMED
-- per function, a spread call / pcall / ret names its instruction and the position it spreads from (and carries the tag
-- `vararg:spread`, so today's checker classifies a failure there), and under ver 51 a vararg function that never names
-- `...` has PUC 5.1's `arg` table — flowtype reads `arg` there as a global, so a read of it is a GAP)
local VARARGS = table.concat({
    'local function va(x, ...) local p, q = ... return p, q end',
    'local function sp(...) return va(...) end',
    'local function rs(...) return 1, ... end',
    'local function old(...) return arg end',
    'local function fixed(z) return z end',
    'local function pc(...) return pcall(va, ...) end',
    'print(va(a, b, b), sp(a), rs(a), old(a), fixed(a), pc(a))' }, '\n') .. '\n'

local function fn_named(D, nm)
    for _, F in ipairs(D.functions) do
        local name = D.names.functions[F.id + 1] or ''
        if name:match('[^%w_]' .. nm .. '$') or name == nm or name:match('[^%w_]' .. nm .. '[^%w_]') then return F, name end
    end
end

test('flowdump (CART-1924): the vararg slot is named, a spread call / pcall / return says where it spreads, 5.1 arg is stated', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local D = dump(VARARGS)
    eq(51, D.ver)
    local va, fixed = fn_named(D, 'va'), fn_named(D, 'fixed')
    ok(va and fixed, 'found the functions: ' .. vim.inspect(D.names.functions))
    eq(va.params[#va.params], va.vararg, 'va names its vararg slot, still the last of params')
    eq(nil, fixed.vararg, 'a fixed-arity function has no vararg slot')
    local function spread_on(F, op)
        for _, s in ipairs(F.spread or {}) do
            if F.body[s[1] + 1][1] == op then
                local tagged = false
                for _, t in ipairs(F.tags) do if t[1] == s[1] and t[2] == 'vararg:spread' then tagged = true end end
                return s[2], tagged
            end
        end
    end
    local sp = fn_named(D, 'sp')
    local pos, tagged = spread_on(sp, 'call')
    eq(1, pos, '`va(...)` spreads from its first argument: ' .. vim.inspect(sp.spread))
    ok(tagged, 'and the call carries vararg:spread')
    ok(spread_on(fn_named(D, 'pc'), 'pcall'), '`pcall(va, ...)` is a spread pcall')
    eq(2, (spread_on(fn_named(D, 'rs'), 'ret')), '`return 1, ...` spreads from result 2')
    eq(nil, va.spread, 'va spreads nothing')
    local old = fn_named(D, 'old')
    eq(true, old.argtable, 'a vararg function that never names `...` has 5.1\'s arg table')
    eq(nil, va.argtable, 'one that names `...` does not')
    local gap = false
    for _, g in ipairs(D.gaps) do if g.kind == 'vararg-arg' and g.fn == old.id and #g.vars > 0 then gap = true end end -- (naming the read's port)
    ok(gap, 'and its read of `arg` is a GAP, not a global read: ' .. vim.inspect(D.gaps))
    -- under 5.2 (Factorio's profile) there is no `arg` table: `arg` IS a global read there
    local root = tree({ ['m.lua'] = CLASSES .. VARARGS })
    store.ingest(ts.extract(root))
    store.data.profile = 'lua-factorio'
    local D52 = vim.json.decode(flowtype.solve(store, { open = false, dump = true }).dump)
    vim.fn.delete(root, 'rf')
    eq(52, D52.ver)
    local old52 = fn_named(D52, 'old')
    eq(nil, old52.argtable, 'no arg table under 5.2')
    for _, g in ipairs(D52.gaps) do ok(g.kind ~= 'vararg-arg', 'and no vararg-arg gap under 5.2') end
end)

-- (CART-1955, flowpath FLOW-0144: a handler the HOST calls. WoW's frame:SetScript / frame:HookScript hand a function to
-- the client, which calls it at the frame's events — the method is no tree code and ran nothing, so the handler's
-- writes reached no reader. The ecosystem declares the registrars (spec/ecosystem/lua-wow.lua `handlers`); the dump
-- carries the host's call at the registration, tagged contract:host-handlers, the receiver first and the rest tainted)
test('flowdump: a WoW frame handler is CALLED by the host — receiver as self, the rest tainted, only for a declared registrar (CART-1955)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({
        'local a = { cur = 1 }',
        'local f = { tag = 1 }',
        'f:HookScript("OnEvent", function (self, ev) a.cur = {}; a.ev = ev end)',
        'local g = CreateFrame("Frame")',
        'g:SetScript("OnUpdate", function (self, el) a.up = {} end)',
        'f:Other("OnEvent", function (self) a.no = {} end)',
        'function A_get() return a.cur, a.up end' }, '\n') .. '\n'
    local function solve(files)
        local root = tree(files)
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, dump = true })
        vim.fn.delete(root, 'rf')
        return vim.json.decode(R.dump), R
    end
    local D, R = solve({ ['A/A.toc'] = '## Interface: 110000\n## Title: A\nh.lua\n', ['A/h.lua'] = SRC })
    local site, fnid = {}, {}
    for _, s in ipairs(D.sites) do
        site[s.label] = s.id
        if s.kind == 'function' then fnid[s.label] = s.fn end
    end
    local hook, setp, other = site['A/h.lua::HookScript#cb@2'], site['A/h.lua::SetScript#cb@4'], site['A/h.lua::Other#cb@5']
    local ftab, atab = site['tbl:A/h.lua:1:10'], site['tbl:A/h.lua:0:10']
    ok(hook and setp and other and ftab and atab, 'the fixture\'s sites: ' .. vim.inspect(vim.tbl_keys(site)))
    local V = {}
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    local F = {}
    for _, fn in ipairs(D.functions) do F[fn.id] = fn end
    -- the tagged calls: exactly the two declared registrars, each calling its handler
    local called = {}
    for _, fn in ipairs(D.functions) do
        for _, t in ipairs(fn.tags or {}) do
            if t[2] == 'contract:host-handlers' then
                local ins = fn.body[t[1] + 1]
                eq('call', ins[1])
                for _, o in ipairs(V[ins[3]] or {}) do called[o] = true end
            end
        end
    end
    ok(called[hook] and called[setp], 'HookScript\'s and SetScript\'s handlers are called: ' .. vim.inspect(called))
    ok(not called[other], 'an undeclared method calls nothing')
    eq(2, R.stats.handlers)
    -- self is the receiver; what the host passes after it is tainted (never a whole answer of nothing)
    local hf = F[fnid['A/h.lua::HookScript#cb@2']]
    ok(vim.tbl_contains(V[hf.params[1]] or {}, ftab), 'self holds the receiver f: ' .. vim.inspect(V[hf.params[1]]))
    ok(vim.tbl_contains(D.solution.taint.ports, hf.params[2]), 'ev is tainted: ' .. vim.inspect(hf.params))
    -- (NOT a heap fact: flow-insensitively a handler's `a.cur = {}` lands through the shared upvalue whether or not
    -- anything calls it — on stock too. What was missing is the CALL: a MOD over called functions, self and ev)
    -- the premise is stated, and labels what the call hands in
    ok(D.contracts.clauses['host-handlers'], 'the clause is stated')
    local bitn
    for i, c in ipairs(D.labels.clauses) do if c == 'host-handlers' then bitn = i - 1 end end
    local m
    for _, e in ipairs(D.labels.v) do if e[1] == hf.params[1] then m = e[2] end end
    ok(bitn and m and require('bit').band(m, require('bit').lshift(1, bitn)) ~= 0, 'self carries the host-handlers label')
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
    -- no ecosystem declares a registrar outside a WoW package: the same file alone calls nothing
    local D2, R2 = solve({ ['h.lua'] = SRC })
    eq(0, R2.stats.handlers)
    for _, fn in ipairs(D2.functions) do
        for _, t in ipairs(fn.tags or {}) do ok(t[2] ~= 'contract:host-handlers', 'no host call outside WoW') end
    end
    ok(not D2.contracts.clauses['host-handlers'], 'and no clause')
end)

-- (CART-1949 (1), flowpath FLOW-0049: debug.sethook's HOOK is called by the VM at the masked events — no tree code
-- calls it. The dump carries the VM's call at the sethook, tagged host:sethook[:<mask>], the event name a string)
test('flowdump: debug.sethook calls its hook — the event a string, the hook found by the mask, a shadowed debug calls nothing (CART-1949)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local function h1(ev) return ev end',
        'debug.sethook(h1, "c")',
        'local co = coroutine.create(function () end)',
        'local function h2(ev) return ev end',
        'debug.sethook(co, h2, "r")',
        'local function h3(ev) return ev end',
        'local m = "l"',
        'debug.sethook(h3, m)',
        'local function h4(ev) return ev end',
        'do local debug = { sethook = function () end }; debug.sethook(h4, "c") end',
        'return h1, h2, h3, h4' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local fnid, str = {}, nil
    for _, s in ipairs(D.sites) do
        if s.kind == 'function' then fnid[s.label:match('::(h%d)@')  or s.label] = s.fn end
        if s.label == 'type:string' then str = s.id end
    end
    local V = {}
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    local F = {}
    for _, fn in ipairs(D.functions) do F[fn.id] = fn end
    local function holds_str(h) local p = F[fnid[h]].params[1]; return vim.tbl_contains(V[p] or {}, str) end
    ok(holds_str('h1'), 'h1 is called with the event name')
    ok(holds_str('h2'), 'the thread form: h2 is the hook')
    ok(holds_str('h3'), 'a non-literal mask: h3 is still called')
    ok(not holds_str('h4'), 'a LOCAL debug is not the library: h4 is not called')
    local tags = {}
    for _, fn in ipairs(D.functions) do for _, t in ipairs(fn.tags or {}) do if t[2]:find('^host:sethook') then tags[#tags + 1] = t[2] end end end
    table.sort(tags)
    -- (h1 by its mask; h2 alone — co is no hook; h3 and its neighbour `m` both tried, untagged by a mask)
    eq({ 'host:sethook', 'host:sethook', 'host:sethook:c', 'host:sethook:r' }, tags)
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- (CART-1956, from CART-1949 / flowpath FLOW-0049: debug.setlocal / getlocal by name were the gap debug-local, a
-- refusal; the dump now carries them as COPIES over the frame the solve's frame_locals names)
test('flowdump: debug.setlocal / getlocal are copies over the named frame\'s locals, not a gap (CART-1956)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local a, b = {}, {}',
        'local function f() local o = b; debug.setlocal(1, 1, a); return o end',
        'local function set2() debug.setlocal(2, 1, a) end',
        'local function g() local p = b; local n, v = debug.getlocal(1, 1); return v end',
        'local function get2() local _, w = debug.getlocal(2, 1); return w end',
        'local function late() local q = {}; return q end',
        'return f, set2, g, get2, late' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    for _, gp in ipairs(D.gaps) do ok(gp.kind ~= 'debug-local', 'no frame gap: ' .. vim.inspect(gp)) end
    local site = {}
    for _, s in ipairs(D.sites) do site[s.label] = s.id end
    local A, Bt = site['tbl:m.lua:0:13'], site['tbl:m.lua:0:17']
    ok(A and Bt, 'a and b have sites')
    local V = {}
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    -- each frame call: its value / result variable and the copies that name it, in the calling function's body
    local per = {}
    for _, fn in ipairs(D.functions) do
        for _, ins in ipairs(fn.body) do
            if ins[1] == 'call' then
                for _, o in ipairs(V[ins[3]] or {}) do
                    local lab
                    for l, id in pairs(site) do if id == o then lab = l end end
                    if lab == 'native:debug.setlocal' then per[fn.id] = { fn = fn, op = 'set', val = ins[4][3] } end
                    if lab == 'native:debug.getlocal' then per[fn.id] = { fn = fn, op = 'get', res = ins[2][2] } end
                end
            end
        end
    end
    local fnof = {}
    for _, st in ipairs(D.sites) do if st.kind == 'function' then fnof[st.label] = st.fn end end
    local set1, set2, get1 = per[fnof['m.lua::f@1']], per[fnof['m.lua::set2@2']], per[fnof['m.lua::g@3']]
    ok(set1 and set2 and get1, 'three frame calls, one per function: ' .. vim.inspect(vim.tbl_keys(per)))
    local function copies(c)
        local n = 0
        for _, ins in ipairs(c.fn.body) do
            if ins[1] == 'copy' and ((c.op == 'set' and ins[3] == c.val) or (c.op == 'get' and ins[2] == c.res)) then
                n = n + 1
                if c.op == 'set' then ok(vim.tbl_contains(V[ins[2]] or {}, A), 'the local holds the value') end
            end
        end
        return n
    end
    eq(1, copies(set1), 'level 1: the calling function\'s one local')
    -- (and every one of them holds a: also g's n, declared AFTER set2 was walked — the solve had missed it, CART-1956)
    ok(copies(set2) >= 8, 'level 2: every function\'s locals (coarse, as the solve)')
    eq(3, copies(get1), 'getlocal(1): the calling function\'s three locals (p, n, v) into the second result')
    ok(vim.tbl_contains(V[get1.res] or {}, Bt), 'getlocal\'s value holds b')
    -- (an any-frame getlocal reads a local declared AFTER it was walked: late's q)
    local get2, Q = per[fnof['m.lua::get2@4']], nil
    for l, id in pairs(site) do if l:find('^tbl:m%.lua:5:') then Q = id end end
    ok(get2 and Q and vim.tbl_contains(V[get2.res] or {}, Q), 'getlocal(2) reads late\'s q')
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- (CART-1957, from CART-1949 / flowpath FLOW-0049: debug.setmetatable on a value that is no table sets its TYPE's
-- metatable. On a function: every function reads through its __index — `h.foo` on another function had read nothing, a
-- whole answer certified under function-no-metatable. The dump names the call (gap debug-typemeta) and withholds the
-- clause; a number target holds no object: the gap alone)
test('flowdump: debug.setmetatable on a function is every function\'s; a scalar target is a named gap (CART-1957)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function solve(src)
        local root = tree({ ['m.lua'] = src })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, dump = true })
        vim.fn.delete(root, 'rf')
        return vim.json.decode(R.dump), R
    end
    local function gaps(D) local n = 0; for _, gp in ipairs(D.gaps) do if gp.kind == 'debug-typemeta' then n = n + 1 end end; return n end
    local function foo_targets(D) -- (what the dump's `load _ h foo` holds, by site label)
        local lab, V, fid = {}, {}, nil
        for _, st in ipairs(D.sites) do lab[st.id] = st.label end
        for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
        for i, nm in ipairs(D.names.fields) do if nm == 'foo' then fid = i - 1 end end
        local out = {}
        for _, fn in ipairs(D.functions) do
            for _, ins in ipairs(fn.body) do
                if ins[1] == 'load' and ins[4] == fid then for _, o in ipairs(V[ins[2]] or {}) do out[#out + 1] = lab[o] end end
            end
        end
        return out
    end
    local FN = 'local function g() return {} end\n%s\nlocal h = function () end\nlocal r = h.foo()\nreturn r\n'
    -- (CART-2017: through an ALIAS the call is a named gap too — it had been by spelling — and a C FUNCTION target,
    -- `debug.setmetatable(print, mt)`, sets every function's: the clause had been kept, false)
    for _, form in ipairs({ 'debug.setmetatable(function () end, { __index = { foo = g } })',
            'local dsm = debug.setmetatable\ndsm(function () end, { __index = { foo = g } })',
            'debug.setmetatable(print, { __index = { foo = g } })' }) do
        local D = solve(FN:format(form))
        ok(not D.contracts.clauses['function-no-metatable'], form .. ': the clause is withheld')
        local t = foo_targets(D)
        ok(#t == 1 and tostring(t[1]):find('::g@0', 1, true), form .. ': h.foo is g: ' .. vim.inspect(t))
        eq(0, flowcheck.check(D).failed, form .. ': closed')
        -- (and EVERY function holds mt in its slot, not only the target: h's closure)
        local hs
        for _, st in ipairs(D.sites) do if st.label:find('^m%.lua::h@') then hs = st.id end end
        local slot = {}
        for _, e in ipairs(D.solution.h) do if e[1] == hs and e[2] == 100 then slot = e[3] end end
        ok(hs and #slot >= 1, form .. ': h\'s closure has the metatable in its slot: ' .. vim.inspect({ hs, slot }))
        eq(1, gaps(D), form .. ': the call is a named gap, by name or by value')
    end
    local D = solve('debug.setmetatable(0, { __index = {} })\nlocal y = (5).foo\nreturn y\n')
    eq(0, gaps(D), 'a number target: its type\'s metatable, no gap (CART-1957)')
    ok(D.contracts.clauses['function-no-metatable'], 'no function target: the clause stands')
    D = solve('local t = {}\ndebug.setmetatable(t, { __index = {} })\nreturn t\n')
    eq(0, gaps(D), 'a table target: no gap')
    ok(D.contracts.clauses['function-no-metatable'], 'and the clause stands')
    -- (CART-2017: OPEN mode, an exported parameter as the target — outside code may pass a function: the gap, and the
    -- clause withheld)
    do
        local root = tree({ ['m.lua'] = 'local M = {}\nfunction M.f(x, mt) debug.setmetatable(x, mt) end\nreturn M\n' })
        store.ingest(ts.extract(root))
        local Do = vim.json.decode(flowtype.solve(store, { open = true, dump = true }).dump)
        vim.fn.delete(root, 'rf')
        eq(1, gaps(Do), 'open: an exported target is a named gap')
        ok(not Do.contracts.clauses['function-no-metatable'], 'open: the clause is withheld')
    end
end)

-- (CART-1987, flowpath FLOW-0148: the core keeps a captured variable as ONE cell per activation of its DECLARING
-- function, and `upvalues` says who captures, not who declares — `local n` with no initializer names n in no body, so
-- the chunk that declares it could not be recovered. Each function lists `declares`; `program_vars` the rest)
test('flowdump: each function lists the variables it DECLARES, and the rest are program_vars — a partition (CART-1987)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}',
        'local n',
        'local function inc(v) local old = n; n = v; return old end',
        'inc(A); local y = inc(B)',
        'local function outer() local k = A; return function () return function () return k end end end',
        'local function pure(p) local q = p; return q end',
        'local function two() return B, A, n end',
        'for i = 1, 2 do local w = i end',
        'local function g1() return tostring(A) end',
        'local function g2() return tostring(B) end',
        'return y, outer, pure, two, g1, g2' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    eq(#D.functions, select(2, R.dump:gsub('"declares":%[', '')), 'every function entry has the key')
    ok(R.dump:find('"program_vars":[', 1, true), 'and the dump states its program-wide variables')
    local F = {}
    for i, nm in ipairs(D.names.functions) do F[nm] = D.functions[i] end
    local function has(l, v) return vim.tbl_contains(l or {}, v) end
    local chunk, inc = F['chunk:m.lua'], F['m.lua::inc@2']
    local n = inc.upvalues[1]
    -- ★ THE CASE upvalues COULD NOT ANSWER: the chunk declares n, and never names it (`local n` emits nothing)
    ok(has(chunk.declares, n), 'the chunk declares n')
    ok(not has(inc.declares, n), 'inc captures n and does not declare it')
    for _, p in ipairs(inc.params) do ok(has(inc.declares, p), 'inc declares its parameter') end
    ok(has(inc.declares, inc.self), 'and its self')
    local old
    for _, ins in ipairs(inc.body) do if ins[1] == 'copy' and ins[3] == n then old = ins[2] end end
    ok(old and has(inc.declares, old), 'and its own local `old` (the copy n -> old writes it)')
    -- its TEMPORARIES too: a call's result variables are the calling function's own, fresh per activation (the walk's
    -- creator record) — the chunk's, and a NESTED function's (g1's tostring call), which the walk enters on its own id
    local results, inner_results = 0, 0
    for nm, f in pairs(F) do
        for _, ins in ipairs(f.body) do
            if ins[1] == 'call' then
                for _, r in ipairs(ins[2]) do
                    -- (init runs ONCE and builds the program's shared state: its results are program_vars, checked below)
                    if nm ~= 'init' then
                        results = results + 1
                        if nm ~= 'chunk:m.lua' then inner_results = inner_results + 1 end
                        ok(has(f.declares, r), nm .. ' declares its call result ' .. r)
                    end
                end
            end
        end
    end
    ok(results > 0 and inner_results > 0, 'the premise: the chunk and a nested function have call results')
    local outer, mid, inner = F['m.lua::outer@4'], F['m.lua::outer#ret@4'], F['m.lua::fn#ret@4']
    local k = inner.upvalues[1]
    ok(has(outer.declares, k), 'outer declares k')
    ok(not has(mid.declares, k) and not has(inner.declares, k), 'the functions that capture k do not')
    -- ★ THE PARTITION: each variable declared once, never also program-wide; each upvalue declared by ANOTHER function
    local owner = {}
    for nm, f in pairs(F) do
        local sorted = vim.deepcopy(f.declares); table.sort(sorted)
        eq(sorted, f.declares, nm .. ': sorted')
        for _, v in ipairs(f.declares) do
            ok(owner[v] == nil, ('%d is declared by %s and %s'):format(v, tostring(owner[v]), nm)); owner[v] = nm
        end
    end
    local prog = {}
    for _, v in ipairs(D.program_vars) do ok(not owner[v], v .. ' is program-wide AND declared by ' .. tostring(owner[v])); prog[v] = true end
    for nm, f in pairs(F) do
        for _, u in ipairs(f.upvalues) do
            ok(owner[u] and owner[u] ~= nm, ('%s captures %d, declared by %s'):format(nm, u, tostring(owner[u])))
        end
    end
    for _, row in ipairs(D.solution.v) do
        ok(owner[row[1]] or prog[row[1]], 'every solved variable is declared or program-wide: ' .. row[1])
    end
    -- ★ AND NO BODY NAMES ANOTHER FUNCTION'S DECLARED VARIABLE except through its own upvalues — one cell per activation
    -- of the declarer is only sound if nobody else reaches it. g1 and g2 both read the global tostring: the CACHED read
    -- (G7.gread) is created by whichever reads first and copied by the other, so it must be program-wide, never g1's
    local POS = { new = { 2 }, copy = { 2, 3 }, load = { 2, 3 }, loadDyn = { 2, 3, 4 }, store = { 2, 4 }, storeDyn = { 2, 3, 4 },
        call = { 2, 3, 4 }, pcall = { 2, 3, 4 }, keys = { 2, 3 }, storeRaw = { 2, 4 }, storeRawDyn = { 2, 3, 4 },
        loadRaw = { 2, 3, 4 }, error = { 2 }, getmeta = { 2, 3 }, copyKeyed = { 2, 3, 4, 5 }, op = { 2, 3 },
        setmeta = { 2, 3 }, cocreate = { 2, 4 }, resume = { 2, 3, 4 }, yield = { 2, 3 }, ret = { 2 } }
    local cross = 0
    for nm, f in pairs(F) do
        local up = {}
        for _, u in ipairs(f.upvalues) do up[u] = true end
        local function chk(v)
            if type(v) == 'number' and owner[v] and owner[v] ~= nm and not up[v] then
                cross = cross + 1; ok(false, ('%s names %d, declared by %s'):format(nm, v, owner[v]))
            end
        end
        for _, ins in ipairs(f.body) do
            ok(POS[ins[1]], 'a known opcode: ' .. tostring(ins[1]))
            for _, k in ipairs(POS[ins[1]] or {}) do
                local x = ins[k]
                if type(x) == 'table' then for _, v in ipairs(x) do chk(v) end else chk(x) end
            end
        end
    end
    eq(0, cross)
    -- the globals port init creates is program-wide; init declares only its self
    eq('new', F.init.body[1][1])
    ok(prog[F.init.body[1][2]], 'the globals port is a program var')
    eq({ F.init.self }, F.init.declares)
    for _, ins in ipairs(F.init.body) do
        if ins[1] == 'call' then for _, r in ipairs(ins[2]) do ok(prog[r], 'init\'s call result is program-wide: ' .. r) end end
    end
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- (CART-1958, flowpath FLOW-0147: a captured local is ONE variable for every function naming it, and nothing said
-- which of a function's variables it captures. Each function entry carries `upvalues`, present even when empty)
test('flowdump: each function lists the variables it CAPTURES (upvalues), always present (CART-1958)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}',
        'local n',
        'local function inc(v) local old = n; n = v; return old end',
        'inc(A); local y = inc(B)',
        'local function outer() local k = A; return function () return function () return k end end end',
        'local function pure(p) local q = p; return q end',
        'local function two() return B, A, n end',
        'return y, outer, pure, two' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    -- (the key on EVERY function entry, in the text: an empty JSON array decodes like an absent key)
    local nkeys = select(2, R.dump:gsub('"upvalues":%[', ''))
    eq(#D.functions, nkeys, 'every function entry has the key')
    local F = {}
    for i, nm in ipairs(D.names.functions) do F[nm] = D.functions[i] end
    for _, nm in ipairs({ 'chunk:m.lua', 'init', 'm.lua::pure@5' }) do
        ok(F[nm] and #F[nm].upvalues == 0, nm .. ' captures nothing: ' .. vim.inspect(F[nm] and F[nm].upvalues))
    end
    local inc = F['m.lua::inc@2']
    eq(1, #inc.upvalues, 'inc captures n alone')
    local n = inc.upvalues[1]
    ok(not vim.tbl_contains(inc.params, n), 'n is not inc\'s parameter')
    local wrote = false
    for _, ins in ipairs(inc.body) do if ins[1] == 'copy' and ins[2] == n and ins[3] == inc.params[1] then wrote = true end end
    ok(wrote, 'and it is the variable `n = v` writes')
    -- (each function between the local's and the reader captures it: outer's two nested functions both list k)
    local mid, inner = F['m.lua::outer#ret@4'], F['m.lua::fn#ret@4']
    ok(mid and inner and #mid.upvalues == 1 and mid.upvalues[1] == inner.upvalues[1], 'the middle and the innermost function capture k')
    local outer = F['m.lua::outer@4']
    ok(outer and #outer.upvalues == 1 and outer.upvalues[1] ~= mid.upvalues[1], 'outer captures A, not its own k')
    -- (sorted, as every list in the dump: the dump is compared byte for byte)
    local two = F['m.lua::two@6']
    ok(two and #two.upvalues == 3, 'two captures A, B and n')
    local sorted = vim.deepcopy(two.upvalues); table.sort(sorted)
    eq(sorted, two.upvalues, 'in ascending order')
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- CART-1991: hooksecurefunc through a LOCAL ALIAS (AceHook-3.0:39 `local hooksecurefunc = hooksecurefunc`) is the
-- builtin — its wrapper is stored raw — and an alias the file ASSIGNS is not: no wrapper, a named gap instead of a silent
-- ordinary call. A plain alias of another builtin never raises the gap (the gap is the hooksecurefunc path's own).
test('flowdump: hooksecurefunc through a local alias stores the wrapper; a reassigned alias leaves builtin-alias-reassigned', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function census(D)
        local sraw, gap = 0, 0
        for _, F in ipairs(D.functions) do for _, i in ipairs(F.body) do if i[1] == 'storeRaw' then sraw = sraw + 1 end end end
        for _, g in ipairs(D.gaps) do if g.kind == 'builtin-alias-reassigned' then gap = gap + 1 end end
        return sraw, gap
    end
    local HOOK = 'local T = { f = function (x) return x end }\nhooksecurefunc(T, "f", function (x) return use(x) end)\nT.f(b)\n'
    local s0 = census((dump(HOOK)))
    ok(s0 > 0, 'the global form stores its wrapper raw (the baseline)')
    local s1, g1 = census((dump('local hooksecurefunc = hooksecurefunc\n' .. HOOK)))
    eq(s0, s1, 'the aliased form translates exactly as the global form'); eq(0, g1)
    local s2, g2 = census((dump('local hooksecurefunc = hooksecurefunc\nif b then hooksecurefunc = print end\n' .. HOOK)))
    eq(s0 - 1, s2, 'a reassigned alias stores no wrapper'); eq(1, g2, 'and the dump names it')
    local _, g3 = census((dump('local pairs = pairs\nif b then pairs = next end\nfor k in pairs(A) do print(k) end\n')))
    eq(0, g3, 'another builtin alias, reassigned, raises no hooksecurefunc gap')
end)

-- CART-1990 (flowpath FLOW-0050): the CLIENT calls a hooksecurefunc target — every w1 target is a Blizzard function or
-- frame method — so the hook runs at calls no dump holds. Where the file's ecosystem declares the hook form host_calls
-- (spec/ecosystem/lua-wow.lua `hooks`), the dump carries the host's call of the WRAPPER at the hooksecurefunc, tagged
-- contract:host-handlers: the global form once, all arguments unknown; the member form twice, `t:name(…)` (t first) and
-- `t.name(…)`. A target with no tree definition and no in-tree caller ("BlzUpdate") is no longer a dead hook.
test('flowdump: a WoW hooksecurefunc target is CALLED by the host — the wrapper, tainted arguments, only where declared (CART-1990)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({
        'local a = { cur = 1 }',
        'local F = { tag = 1 }',
        'function F:Show() return 1 end',
        'hooksecurefunc("BlzUpdate", function (x) a.seen = x; x.hooked = true end)',
        'hooksecurefunc(F, "Show", function (self) a.shown = self end)',
        'function A_get() return a.seen, a.shown end' }, '\n') .. '\n'
    local function solve(files)
        local root = tree(files)
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, dump = true })
        vim.fn.delete(root, 'rf')
        return vim.json.decode(R.dump), R
    end
    local D, R = solve({ ['A/A.toc'] = '## Interface: 110000\n## Title: A\nh.lua\n', ['A/h.lua'] = SRC })
    local site, fnid = {}, {}
    for _, s in ipairs(D.sites) do
        site[s.label] = s.id
        if s.kind == 'function' then fnid[s.label] = s.fn end
    end
    local wg, wm, ftab = site['ts:hook:A/h.lua:3:0'], site['ts:hook:A/h.lua:4:0'], site['tbl:A/h.lua:1:10']
    ok(wg and wm and ftab, 'the fixture\'s sites: ' .. vim.inspect(vim.tbl_keys(site)))
    local V = {}
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    local F = {}
    for _, fn in ipairs(D.functions) do F[fn.id] = fn end
    -- the tagged calls: the global form's wrapper once, the member form's twice
    local calls = {}
    for _, fn in ipairs(D.functions) do
        for _, t in ipairs(fn.tags or {}) do
            if t[2] == 'contract:host-handlers' then
                local ins = fn.body[t[1] + 1]
                eq('call', ins[1])
                for _, o in ipairs(V[ins[3]] or {}) do calls[o] = (calls[o] or 0) + 1 end
            end
        end
    end
    eq(1, calls[wg], 'the global form\'s wrapper: one host call'); eq(2, calls[wm], 'the member form\'s: two')
    eq(2, R.stats.hostcalls_hooks); eq(0, R.stats.handlers)
    -- the hooks' parameters: unknown host values (never empty); the member hook's self also holds its table
    local hg, hm = F[fnid['A/h.lua::hooksecurefunc#cb@3']], F[fnid['A/h.lua::hooksecurefunc#cb@4']]
    ok(vim.tbl_contains(D.solution.taint.ports, hg.params[1]), 'BlzUpdate\'s hook: x is tainted, not empty')
    ok(vim.tbl_contains(D.solution.taint.ports, hm.params[1]), 'the member hook: self tainted (t.name(…))')
    ok(vim.tbl_contains(V[hm.params[1]] or {}, ftab), 'and self holds F (t:name(…)): ' .. vim.inspect(V[hm.params[1]]))
    ok(D.contracts.clauses['host-handlers'], 'the clause is stated')
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
    -- outside a WoW package no ecosystem declares host_calls: the same file makes no host call
    local D2, R2 = solve({ ['h.lua'] = SRC })
    eq(0, R2.stats.hostcalls_hooks)
    for _, fn in ipairs(D2.functions) do
        for _, t in ipairs(fn.tags or {}) do ok(t[2] ~= 'contract:host-handlers', 'no host call outside WoW') end
    end
    ok(not D2.contracts.clauses['host-handlers'], 'and no clause')
    -- a WoW package whose hook forms do NOT declare host_calls: no host call — the declaration decides, not the name
    local E = assert(require('cartograph.spec.ecosystem').load('lua-wow'))
    local saved = {}
    for k, h in ipairs(E.hooks) do saved[k] = h.host_calls; h.host_calls = nil end
    local okd, D3, R3 = pcall(solve, { ['A/A.toc'] = '## Interface: 110000\n## Title: A\nh.lua\n', ['A/h.lua'] = SRC })
    for k, h in ipairs(E.hooks) do h.host_calls = saved[k] end
    ok(okd, tostring(D3))
    eq(0, R3.stats.hostcalls_hooks, 'undeclared: no host call')
    ok(not D3.contracts.clauses['host-handlers'], 'and no clause')
end)

-- CART-1993: every builtin the walk recognises by SPELLING is recognised through a local alias too — `local cc =
-- coroutine.create`, `local ls = loadstring`, `local err = error` … (GALIAS: a local declared from a global, or from a
-- member of a global table, never assigned in its file). Before, such a call was the builtin reached by VALUE: a lost
-- call (sound, tainted) or, with no native, an ordinary call. Each aliased form must translate EXACTLY as the direct one
-- — the same builtin instructions, synthetic functions, host tags, gaps and the same verdict at p:m().
test('flowdump: a spelling-recognised builtin through a local alias translates as the direct call (CART-1993)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local callrec = require 'cartograph.callrec'
    local function sig(src)
        local D, R = dump(src)
        local ops, gaps, synth, tags = {}, {}, 0, {}
        for _, F in ipairs(D.functions) do
            for _, i in ipairs(F.body) do
                if ({ cocreate = 1, resume = 1, yield = 1, setmeta = 1 })[i[1]] then ops[i[1]] = (ops[i[1]] or 0) + 1 end
            end
            for _, t in ipairs(F.tags or {}) do if t[2]:find('^host:') then tags[t[2]] = (tags[t[2]] or 0) + 1 end end
        end
        for _, g in ipairs(D.gaps) do gaps[g.kind] = (gaps[g.kind] or 0) + 1 end
        for _, n in ipairs(D.names.functions) do if tostring(n):find('^load:') or tostring(n):find('^ts:') then synth = synth + 1 end end
        local v
        for _, c in ipairs(store.data.calls) do
            if callrec.full(c) == 'p:m' then
                local x = R.verdict(c)
                v = x and { x.kind, x.partial or false, #(x.targets or {}) } or 'none'
            end
        end
        return { ops = ops, gaps = gaps, synth = synth, tags = tags, v = v }
    end
    local CASES = {
        { 'coroutine.create/resume', 'local co = coroutine.create(function (x) use(x) end)\ncoroutine.resume(co, b)\n',
            'local cc, cr = coroutine.create, coroutine.resume\nlocal co = cc(function (x) use(x) end)\ncr(co, b)\n' },
        { 'coroutine.wrap/yield', 'local w = coroutine.wrap(function () coroutine.yield(b) end)\nprint(use(w()))\n',
            'local wrap, yield = coroutine.wrap, coroutine.yield\nlocal w = wrap(function () yield(b) end)\nprint(use(w()))\n' },
        { 'loadstring', 'local f = loadstring("return ...")\nprint(use(f(b)))\n',
            'local ls = loadstring\nlocal f = ls("return ...")\nprint(use(f(b)))\n' },
        { 'newproxy', 'local u = newproxy(true)\ngetmetatable(u).__index = function () return b end\nprint(use(u.x))\n',
            'local np = newproxy\nlocal u = np(true)\ngetmetatable(u).__index = function () return b end\nprint(use(u.x))\n' },
        { 'getfenv', 'local env = getfenv(1)\nenv.q = b\nprint(use(q))\n', 'local gf = getfenv\nlocal env = gf(1)\nenv.q = b\nprint(use(q))\n' },
        { 'debug.sethook', 'debug.sethook(function (ev) print(ev) end, "c")\n',
            'local sh = debug.sethook\nsh(function (ev) print(ev) end, "c")\n' },
        { 'error ends its block', 'local function g() error("x"); use(b) end\npcall(g)\n',
            'local err = error\nlocal function g() err("x"); use(b) end\npcall(g)\n' },
    }
    local bad = {}
    for _, c in ipairs(CASES) do
        local d, a = sig(c[2]), sig(c[3])
        if not vim.deep_equal(d, a) then bad[#bad + 1] = c[1] .. ': direct ' .. vim.inspect(d) .. ' alias ' .. vim.inspect(a) end
    end
    eq({}, bad, 'each aliased form translates as the direct one')
    -- a dotted alias whose BASE the file assigns is not the builtin: the named gap
    local r = sig('local cc = coroutine.create\nif b then coroutine = {} end\nlocal co = cc(function (x) use(x) end)\n')
    eq(nil, r.ops.cocreate, 'no cocreate through a reassigned base'); eq(1, r.gaps['builtin-alias-reassigned'])
    -- one gap per call, though two branches ask about loadstring (the literal-source walk and the unknown-code load)
    local l = sig('local ls = loadstring\nif b then ls = print end\nls("return 1")\n')
    eq(1, l.gaps['builtin-alias-reassigned'], 'the gap once per call'); eq(0, l.synth, 'and no literal chunk walked')
    -- require through an alias resolves the tree's module (a lua/ layout: the module path names it), as the direct
    -- call does; a module only the static resolver finds (root level) stays the by-value call — partial, not unknown
    local function rv(main, modpath)
        local root = tree({ ['m.lua'] = CLASSES .. 'use(b)\n' .. main,
            [modpath] = 'local X = {}\nfunction X.m(self) return "X" end\nreturn { v = setmetatable({}, { __index = X }) }\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do
            if callrec.full(c) == 'p:m' then local x = R.verdict(c); return x and { x.kind, x.partial or false, #(x.targets or {}) } or 'none' end
        end
    end
    local D_, A_ = 'print(use(require("x").v))\n', 'local req = require\nprint(use(req("x").v))\n'
    local rd = rv(D_, 'lua/x.lua')
    eq({ 'narrowed', false, 3 }, rd, 'the direct require reaches X.m')
    eq(rd, rv(A_, 'lua/x.lua'), 'require through an alias: the same verdict')
    local ra = rv(A_, 'x.lua')
    ok(type(ra) == 'table' and ra[2] == true, 'a module the walk cannot name through an alias: partial, never unknown: ' .. vim.inspect(ra))
end)

-- CART-1994 (flowpath FLOW-0074, the hidden-calls map): an instruction that may RUN CODE — load / loadDyn / store /
-- storeDyn / copyKeyed / call / pcall / op / resume — carries the source position of what it lowers, so an answer about
-- it (which handlers a load may start) can be placed at the access, not only in its function. A side table
-- `positions = { files, at = [[fn, index, file, line, col]] }`: line 1-based, col 0-based (an answer's `call` too);
-- an expression's start, a store's statement's. init's synthetic instructions have none.
test('flowdump: per-instruction source positions for every instruction that may run code (CART-1994)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({
        'local t = setmetatable({}, { __index = function (s, k) return k end })',
        'local v = t.x',
        't.y = v',
        'local function f(a) return a + 1 end',
        'print(f(v))',
        'local k = "z"; local w = t[k]',
        'local w2 = f(1)' }, '\n') .. '\n'
    local root = tree({ ['m.lua'] = SRC })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    eq({ 'm.lua' }, D.positions.files)
    local F, NAME = {}, {}
    for _, fn in ipairs(D.functions) do F[fn.id] = fn; NAME[fn.id] = D.names.functions[fn.id + 1] end
    local CODE = { load = true, loadDyn = true, store = true, storeDyn = true, copyKeyed = true, call = true, pcall = true, op = true, resume = true }
    local at, seen = {}, {}
    for _, e in ipairs(D.positions.at) do
        local ins = F[e[1]].body[e[2] + 1]
        ok(CODE[ins[1]], 'only an instruction that may run code: ' .. vim.inspect(ins))
        ok(not seen[e[1] .. ':' .. e[2]], 'one position per instruction'); seen[e[1] .. ':' .. e[2]] = true
        local k = ins[1] .. '@' .. e[4] .. ':' .. e[5]
        at[k] = (at[k] or 0) + 1
    end
    -- every such instruction outside init is placed
    for _, fn in ipairs(D.functions) do
        for k, ins in ipairs(fn.body) do
            if CODE[ins[1]] and NAME[fn.id] ~= 'init' then ok(seen[fn.id .. ':' .. (k - 1)], 'placed: ' .. NAME[fn.id] .. ' ' .. vim.inspect(ins)) end
        end
    end
    ok(at['load@2:10'], 't.x: the load at its expression: ' .. vim.inspect(at))
    ok(at['store@3:0'], 't.y = v: the store at its statement')
    ok(at['call@5:6'], 'f(v): the call at its expression')
    eq(2, at['op@4:27'], 'a + 1: both operands\' __add at the expression')
    ok(at['loadDyn@6:25'], 't[k]: the dynamic load')
    ok(at['call@7:11'], 'f(1) in a declaration\'s value list: the call at its expression, not the statement')
    for _, e in ipairs(D.positions.at) do ok(NAME[e[1]] ~= 'init', 'init (synthetic, after the walk) has no position') end
end)

-- CART-1948 (flowpath FLOW-0047 / FLOW-0143): the vararg routes the dump still dropped, each now marked. (1) a yield's
-- values and a resume's arguments spread from a last `...` or call; (2) a call whose values are all forwarded — `v(f())`,
-- `return f()` — has a REST result: its last result variable collects every value past it (`rest` [[index, position]],
-- tag vararg:rest), and the consumer's operand spreads from there; (3) a file chunk's own `...` is the chunk's vararg.
test('flowdump: yield / resume spreads, a forwarded call\'s rest result, the chunk\'s own ... (CART-1948)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({
        'local name = ...',
        'local function five() return 1, 2, 3, 4, 5 end',
        'local function v(...) return ... end',
        'print(v(five()))',
        'local function g() return five() end',
        'local co = coroutine.create(function (...) coroutine.yield(...); coroutine.yield(five()) end)',
        'local function r(...) return coroutine.resume(co, ...) end',
        'r(g())' }, '\n') .. '\n'
    local root = tree({ ['m.lua'] = SRC })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local F, BY = {}, {}
    for _, fn in ipairs(D.functions) do F[fn.id] = fn; BY[D.names.functions[fn.id + 1]] = fn end
    local function marks(fn, key, op)
        local out = {}
        for _, s in ipairs(fn[key] or {}) do
            local ins = fn.body[s[1] + 1]
            if ins[1] == op then out[#out + 1] = s[2] end
        end
        return out
    end
    local chunk = BY['chunk:m.lua']
    ok(chunk, 'the chunk: ' .. vim.inspect(vim.tbl_keys(BY)))
    -- (3) the chunk's `...` is its vararg, the last of its params
    ok(chunk.vararg and chunk.params[#chunk.params] == chunk.vararg, 'the chunk declares its `...`: ' .. vim.inspect(chunk.params))
    -- (2) v(five()): five's call has a rest result at 4, v's call spreads from 4
    ok(vim.tbl_contains(marks(chunk, 'rest', 'call'), 4), 'five() forwarded into v: rest at 4: ' .. vim.inspect(chunk.rest))
    ok(vim.tbl_contains(marks(chunk, 'spread', 'call'), 4), 'v(five()): the 4th operand spreads: ' .. vim.inspect(chunk.spread))
    local g = BY['m.lua::g@4']
    ok(g and vim.tbl_contains(marks(g, 'rest', 'call'), 4) and vim.tbl_contains(marks(g, 'spread', 'ret'), 4),
        'return five(): the call\'s rest, the ret spreads from 4: ' .. vim.inspect(g and { g.rest, g.spread }))
    -- (1) yield(...) spreads from 1; resume(co, ...) from its first argument after co
    local yieldfn, rfn
    for nm, fn in pairs(BY) do
        if #marks(fn, 'spread', 'yield') > 0 then yieldfn = fn end
        if nm == 'm.lua::r@6' then rfn = fn end
    end
    ok(yieldfn and vim.tbl_contains(marks(yieldfn, 'spread', 'yield'), 1), 'yield(...) spreads')
    ok(yieldfn and vim.tbl_contains(marks(yieldfn, 'spread', 'yield'), 4), 'yield(five()): its rest value spreads from 4')
    ok(rfn and vim.tbl_contains(marks(rfn, 'spread', 'resume'), 1), 'resume(co, ...) spreads its arguments: ' .. vim.inspect(rfn and rfn.spread))
    -- every marker is tagged
    for _, fn in ipairs(D.functions) do
        local tg = {}
        for _, t in ipairs(fn.tags or {}) do tg[t[1] .. t[2]] = true end
        for _, s in ipairs(fn.spread or {}) do ok(tg[s[1] .. 'vararg:spread'], 'spread tagged') end
        for _, s in ipairs(fn.rest or {}) do ok(tg[s[1] .. 'vararg:rest'], 'rest tagged') end
    end
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- CART-1996: pcall's, coroutine.resume's and coroutine.yield's OWN result lists, forwarded (`v(pcall(f))`), carry
-- `rest` too: the last result collects every value past it (the solve: route fixtures pcall_five / resume_five /
-- resume_yield_five); the consumer's operand spreads from there
test('flowdump: a forwarded pcall / resume / yield marks its rest result, the consumer spreads (CART-1996)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({
        'local function five() return 1, 2, 3, 4, 5 end',
        'local function v(...) return ... end',
        'print(v(pcall(five)))',
        'local co = coroutine.create(function () print(v(coroutine.yield(1))) end)',
        'print(v(coroutine.resume(co)))' }, '\n') .. '\n'
    local root = tree({ ['m.lua'] = SRC })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local rests, spreads = {}, {}
    for _, fn in ipairs(D.functions) do
        for _, s in ipairs(fn.rest or {}) do local op = fn.body[s[1] + 1][1]; rests[op] = (rests[op] or 0) + 1 end
        for _, s in ipairs(fn.spread or {}) do local op = fn.body[s[1] + 1][1]; spreads[op] = (spreads[op] or 0) + 1 end
    end
    ok(rests.pcall and rests.resume and rests.yield, 'pcall / resume / yield results marked rest: ' .. vim.inspect(rests))
    ok((spreads.call or 0) >= 3, 'each consumer v(…) spreads: ' .. vim.inspect(spreads))
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- CART-1995 (flowpath FLOW-0075): a pcall whose callee is a HOST builtin starts no activation in the core. error / assert
-- are protected as a SYNTHETIC function the dump holds (`error p1`; assert `error p2`, a string, its arguments returned),
-- so the caught value flows by core steps; any other host builtin's pcall is tagged gap:host-pcall (outside-raises-strings
-- not claimed: what it runs may raise an object)
test('flowdump: pcall(error / assert, …) protects a synthetic function; another host builtin is tagged gap:host-pcall (CART-1995)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({
        'local t = {}',
        'local ok, e = pcall(error, t)',
        'local ok2, e2 = pcall(assert, false, t)',
        'local err = error',
        'local ok3, e3 = pcall(err, t)',
        'local ok4 = pcall(table.sort, { 2, 1 }, function (x, y) error(t) end)',
        'return e, e2, e3, ok4' }, '\n') .. '\n'
    local root = tree({ ['m.lua'] = SRC })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local V = {}
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    local site, label = {}, {}
    for _, s in ipairs(D.sites) do site[s.label] = s.id; label[s.id] = s.label end
    local tsite = site['tbl:m.lua:0:10']
    ok(tsite, 't has a site')
    local pcalls, tagged = {}, 0
    for _, fn in ipairs(D.functions) do
        for k, ins in ipairs(fn.body) do
            if ins[1] == 'pcall' then
                local cl = {}
                for _, o in ipairs(V[ins[3]] or {}) do cl[#cl + 1] = label[o] end
                pcalls[#pcalls + 1] = { callee = table.concat(cl, ','), e = ins[2][2] }
            end
        end
        for _, tg in ipairs(fn.tags or {}) do if tg[2] == 'gap:host-pcall' then tagged = tagged + 1 end end
    end
    local syn = 0
    for _, p in ipairs(pcalls) do
        if p.callee:find('^ts:error:') or p.callee:find('^ts:assert:') then
            syn = syn + 1
            ok(p.e and vim.tbl_contains(V[p.e] or {}, tsite), 'the caught value is t, by the call: ' .. p.callee)
        end
    end
    eq(3, syn, 'error, assert and an alias of error protect a synthetic function: ' .. vim.inspect(pcalls))
    eq(1, tagged, 'table.sort\'s pcall is tagged gap:host-pcall')
    for _, fn in ipairs(D.functions) do
        local nm = D.names.functions[fn.id + 1]
        if nm:find('^ts:error:') then eq('error', fn.body[1][1], 'the synthetic body raises its first parameter') end
    end
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- CART-1998 (flowpath FLOW-0075): what a module's chunk raises reaches the pcall protecting the code that requires it —
-- `pcall(fc)`, fc doing `require("x")`, x raising an object. require is a copy of the module's result and the chunk is
-- run by the program, so no call carried it: e held only the runtime-error string. The chunk now raises into its own port,
-- which the require hands to the requiring function's; the dump lists the route in `require_raises`
test('flowdump: a module chunk\'s raise reaches the pcall around its require; require_raises names it (CART-1998)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/x.lua'] = 'local B = {}\nfunction B.m(self) return "B" end\nerror(setmetatable({}, { __index = B }))\n',
        ['lua/quiet.lua'] = 'return {}\n',
        ['m.lua'] = table.concat({
            'local A = {}', 'function A.m(self) return "A" end',
            'local a = setmetatable({}, { __index = A })',
            'local function use(p) return p:m() end', 'use(a)',
            'local function fc() return require("x") end',
            'local ok, e = pcall(fc)',
            'use(e)',
            'local function fq() return require("quiet") end',
            'local okq, eq_ = pcall(fq)',
            'return eq_' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then v = R.verdict(c) end end
    local has = {}
    for _, tg in ipairs(v and v.targets or {}) do has[tostring(tg):match('::(%a)%.m@') or ''] = true end
    ok(v and has.A and has.B, 'e holds what x raised: B.m is a target of use(e): ' .. vim.inspect(v))
    local D = vim.json.decode(R.dump)
    local name = {}
    for _, fn in ipairs(D.functions) do name[fn.id] = D.names.functions[fn.id + 1] end
    local rr = {}
    for _, e in ipairs(D.require_raises) do rr[#rr + 1] = name[e[1]] .. ' <- ' .. name[e[2]] .. ' @' .. e[3] .. ':' .. e[4] end
    ok(vim.tbl_contains(rr, 'm.lua::fc@5 <- chunk:lua/x.lua @6:27'), 'fc requires x: ' .. vim.inspect(rr))
    -- (the quiet module raises nothing of its own: x's object does not reach ITS requirer's pcall — per-chunk ports, not
    -- one module-level set)
    local V, label = {}, {}
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    for _, s in ipairs(D.sites) do label[s.id] = s.label end
    local pc = {}
    for _, fn in ipairs(D.functions) do
        if name[fn.id] == 'chunk:m.lua' then for _, ins in ipairs(fn.body) do if ins[1] == 'pcall' then pc[#pc + 1] = ins end end end
    end
    eq(2, #pc, 'two pcalls in m.lua')
    local caught = {}
    for _, o in ipairs(V[pc[2][2][2]] or {}) do caught[#caught + 1] = label[o] end
    for _, l in ipairs(caught) do ok(not l:find('lua/x.lua', 1, true), 'quiet\'s pcall catches nothing of x: ' .. vim.inspect(caught)) end
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- CART-1997: the producer's commit from a .git-less snapshot. git first (the root its own repository's top level), then
-- CARTOGRAPH_COMMIT, then <root>/.cartograph-commit or lua/cartograph/COMMIT (git archive fills it by export-subst; a
-- plain copy's `$Format:%H$` is refused). The dump says which: cartograph_via.
test('flowdump: the producer commit from git, CARTOGRAPH_COMMIT, a commit file, or git archive\'s COMMIT (CART-1997)', function ()
    local FD = require 'cartograph.flowdump'
    local env0 = vim.env.CARTOGRAPH_COMMIT
    vim.env.CARTOGRAPH_COMMIT = nil
    local snap = vim.fn.tempname()
    vim.fn.mkdir(snap .. '/lua/cartograph', 'p')
    eq(nil, FD.producer(snap), 'no repository, no statement: none')
    -- a plain copy's placeholder is refused
    local fd = assert(io.open(snap .. '/lua/cartograph/COMMIT', 'w')); fd:write('$Format:%H$\n'); fd:close()
    eq(nil, FD.producer(snap), 'an unfilled placeholder is no commit')
    -- what git archive writes
    local sha = 'd6a58af8a1b2c3d4e5f60718293a4b5c6d7e8f90'
    fd = assert(io.open(snap .. '/lua/cartograph/COMMIT', 'w')); fd:write(sha .. '\n'); fd:close()
    eq({ sha, 'file' }, { FD.producer(snap) })
    -- the snapshot maker's file wins over the archive's
    fd = assert(io.open(snap .. '/.cartograph-commit', 'w')); fd:write('  ABCDEF1\n'); fd:close()
    eq({ 'abcdef1', 'file' }, { FD.producer(snap) })
    -- the environment wins over both
    vim.env.CARTOGRAPH_COMMIT = '0123456789abcdef'
    eq({ '0123456789abcdef', 'env' }, { FD.producer(snap) })
    vim.env.CARTOGRAPH_COMMIT = 'not a sha'
    eq({ 'abcdef1', 'file' }, { FD.producer(snap) }, 'a malformed statement is ignored')
    vim.env.CARTOGRAPH_COMMIT = env0
    vim.fn.delete(snap, 'rf')
    -- and the real checkout: git, its HEAD
    local here = vim.fn.fnamemodify(debug.getinfo(require('cartograph.flowtype').solve, 'S').source:sub(2), ':h:h:h')
    local head = vim.fn.systemlist({ 'git', '-C', here, 'rev-parse', 'HEAD' })[1]
    eq({ head, 'git' }, { FD.producer(here) })
    -- git archive fills COMMIT (the export-subst attribute is the repository's)
    local out = vim.fn.system({ 'git', '-C', here, 'archive', 'HEAD', 'lua/cartograph/COMMIT', '.gitattributes' })
    if vim.v.shell_error == 0 and out:find('export-subst', 1, true) then
        local tf = vim.fn.tempname()
        vim.fn.mkdir(tf, 'p')
        vim.fn.system('git -C ' .. vim.fn.shellescape(here) .. ' archive HEAD lua/cartograph/COMMIT | tar -x -C ' .. vim.fn.shellescape(tf))
        local cf = io.open(tf .. '/lua/cartograph/COMMIT')
        local filled = cf and cf:read('*l'); if cf then cf:close() end
        eq(head, filled, 'git archive wrote the commit')
        vim.fn.delete(tf, 'rf')
    end
end)

-- CART-1716 (flowpath FLOW-0083, CORE.md D34): builtins by IDENTITY, cartograph's half. Every call expression has a
-- `.call` in the dump — a builtin spelled into its own instructions (`pcall`, `setmeta`, `cocreate`, `loadRaw` …) also
-- records its call AS WRITTEN (tag native:twin: its result variables, the callee expression's value, the arguments in
-- Lua order) — and `natives` maps each host builtin's site to its name, so a checker steps a `.call` whose callee holds a
-- native site as that builtin. The twin binds nothing (the solve is the spelled branch's) and flowlabels skips it.
test('flowdump: every call expression has a .call; spelled builtins add an identity twin; natives names each native site (CART-1716)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({
        'local t = {}',
        'local mt = { __metatable = 1 }',
        'local ok, e = pcall(function () end)',
        'local ok2 = xpcall(function () end, function () end)',
        'setmetatable(t, mt)',
        'local m = getmetatable(t)',
        'local v = rawget(t, "k")',
        'rawset(t, "k", 1)',
        'local co = coroutine.create(function (x) coroutine.yield(x) end)',
        'coroutine.resume(co, 1)',
        'local w = coroutine.wrap(function () end)',
        'local function g() error(t) end',
        'assert(t, "m")',
        'local p = pcall',
        'p(function () end)',
        'local n = next(t)',
        'for k in pairs(t) do end',
        'local x = require("nothere")',
        'local ok3, e3 = pcall(error, t)',
        'return e, m, v, w, n, x, e3' }, '\n') .. '\n'
    local root = tree({ ['m.lua'] = SRC })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local F, V, label = {}, {}, {}
    for _, fn in ipairs(D.functions) do F[fn.id] = fn end
    for _, e in ipairs(D.solution.v) do V[e[1]] = e[2] end
    for _, s in ipairs(D.sites) do label[s.id] = s.label end
    -- the natives table: each entry's site is labelled native:<name>
    local natname = {}
    for _, e in ipairs(D.natives) do eq('native:' .. e[2], label[e[1]], 'a native site\'s label names it'); natname[e[1]] = e[2] end
    for _, nm in ipairs({ 'pcall', 'setmetatable', 'getmetatable', 'rawget', 'rawset', 'coroutine.create', 'coroutine.resume', 'coroutine.yield', 'error' }) do
        local found = false
        for _, e in ipairs(D.natives) do if e[2] == nm then found = true end end
        ok(found, 'natives names ' .. nm)
    end
    -- every call expression has a `.call` at its position
    local callat = {}
    for _, e in ipairs(D.positions.at) do if F[e[1]].body[e[2] + 1][1] == 'call' then callat[e[4] .. ':' .. e[5]] = true end end
    local tree_ = vim.treesitter.get_string_parser(SRC, 'lua'):parse()[1]
    local q = vim.treesitter.query.parse('lua', '(function_call) @c')
    local miss = {}
    for _, node in q:iter_captures(tree_:root(), SRC) do
        local l, c = node:start()
        if not callat[(l + 1) .. ':' .. c] then miss[#miss + 1] = vim.treesitter.get_node_text(node, SRC) end
    end
    eq({}, miss, 'every call expression has a .call')
    -- the twins: tagged, and the callee of each holds the native its spelling names
    local twins = {}
    for _, fn in ipairs(D.functions) do
        for _, tg in ipairs(fn.tags or {}) do
            if tg[2] == 'native:twin' then
                local ins = fn.body[tg[1] + 1]
                eq('call', ins[1])
                for _, o in ipairs(V[ins[3]] or {}) do if natname[o] then twins[natname[o]] = (twins[natname[o]] or 0) + 1 end end
            end
        end
    end
    for _, nm in ipairs({ 'pcall', 'xpcall', 'setmetatable', 'getmetatable', 'rawget', 'rawset', 'coroutine.create', 'coroutine.resume',
        'coroutine.yield', 'coroutine.wrap', 'next', 'pairs', 'require' }) do
        ok(twins[nm], 'a twin calls the native ' .. nm .. ': ' .. vim.inspect(twins))
    end
    -- pcall(error, t)'s twin passes the native error itself (its spelled pcall protects CART-1995's synthetic function)
    local errarg = false
    for _, fn in ipairs(D.functions) do
        for _, tg in ipairs(fn.tags or {}) do
            local ins = tg[2] == 'native:twin' and fn.body[tg[1] + 1]
            if ins and ins[4][1] then
                local callee, first = {}, {}
                for _, o in ipairs(V[ins[3]] or {}) do callee[natname[o] or ''] = true end
                for _, o in ipairs(V[ins[4][1]] or {}) do first[natname[o] or ''] = true end
                if callee.pcall and first.error then errarg = true end
            end
        end
    end
    ok(errarg, 'pcall(error, t)\'s twin: the native error as its first argument')
    -- xpcall(f, h)'s twin: the handler is its second argument
    local hgot = false
    for _, fn in ipairs(D.functions) do
        for _, tg in ipairs(fn.tags or {}) do
            local ins = tg[2] == 'native:twin' and fn.body[tg[1] + 1]
            if ins then
                local callee = {}
                for _, o in ipairs(V[ins[3]] or {}) do callee[natname[o] or ''] = true end
                if callee.xpcall and ins[4][2] then
                    for _, o in ipairs(V[ins[4][2]] or {}) do if tostring(label[o]):find('xpcall#cb', 1, true) or tostring(label[o]):find('m.lua::', 1, true) then hgot = true end end
                end
            end
        end
    end
    ok(hgot, 'xpcall(f, h)\'s twin passes the handler')
    -- flowlabels skips a twin: the pcall's results carry no GN from the twin's global read of `pcall`
    local gnbit
    for i, c in ipairs(D.labels.clauses) do if c == 'GN' then gnbit = i - 1 end end
    local L = {}
    for _, e in ipairs(D.labels.v) do L[e[1]] = e[2] end
    local pres
    for _, fn in ipairs(D.functions) do
        for _, ins in ipairs(fn.body) do if ins[1] == 'pcall' and not pres then pres = ins[2][1] end end
    end
    ok(gnbit and pres, 'the GN clause and a pcall')
    eq(0, require('bit').band(L[pres] or 0, require('bit').lshift(1, gnbit)), 'the pcall\'s status carries no GN from its twin')
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
end)

-- CART-1957 (flowpath FLOW-0049; the user's approval 2026-11-07): debug.setmetatable on a NUMBER or a BOOLEAN sets its
-- TYPE's metatable — `(5).foo` reads mt.__index.foo. The type's object (CART-1901) indexes through a holder whose
-- prototype is the __index; the dump names it in `type_metatables` and keeps no gap. nil stays the named gap
-- debug-typemeta; a number's metatable is not a string's.
test('flowdump: debug.setmetatable on a number / boolean is its type\'s metatable; nil stays the gap (CART-1957)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function run(src)
        local root = tree({ ['m.lua'] = 'local function g() return 1 end\nlocal mt = { __index = { foo = g } }\n' .. src })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, explain = true })
        local Rd = flowtype.solve(store, { open = false, dump = true })
        vim.fn.delete(root, 'rf')
        local D = vim.json.decode(Rd.dump)
        local p = R.port('g:Y')
        local y = p and R.objs_of(p) or {}
        local gap = 0
        for _, g in ipairs(D.gaps) do if g.kind == 'debug-typemeta' then gap = gap + 1 end end
        return y, gap, D
    end
    local function holds_g(y) return #y == 1 and tostring(y[1]):find('::g@0', 1, true) ~= nil end
    local y, gap, D = run('debug.setmetatable(0, mt)\nY = (5).foo\n')
    ok(holds_g(y), 'a number: (5).foo is g: ' .. vim.inspect(y)); eq(0, gap, 'no gap')
    eq(1, #D.type_metatables, 'type_metatables names the number type'); eq('number', D.type_metatables[1][1])
    eq(0, flowcheck.check(D).failed, 'the dump is closed')
    -- (CART-2017: and the metatable is the TYPE SITE's META cell — a checker reads the chain through it; it had been
    -- only in type_metatables' holder, and flowpath's check failed setmeta:meta (host-store))
    local lab = {}
    for _, st in ipairs(D.sites) do lab[st.id] = st.label end
    local meta = {}
    for _, e in ipairs(D.solution.h) do if e[1] == D.type_metatables[1][2] and e[2] == 100 then meta = e[3] end end
    ok(#meta == 1 and tostring(lab[meta[1]]):match('^tbl:m%.lua:1:'), 'type:number\'s META cell holds mt: ' .. vim.inspect(meta))
    -- (an INTEGER target — a profile's declared integer — is the same type: the site type_metatables names holds it)
    local _, _, D2 = run('debug.setmetatable(math.floor(1.5), mt)\nY = (5).foo\n')
    local meta2 = {}
    for _, e in ipairs(D2.solution.h) do if e[1] == D2.type_metatables[1][2] and e[2] == 100 then meta2 = e[3] end end
    eq(1, #meta2, 'an integer target: the number type site\'s META cell holds mt')
    y, gap = run('debug.setmetatable(true, mt)\nY = (false).foo\n')
    ok(holds_g(y), 'a boolean: (false).foo is g: ' .. vim.inspect(y)); eq(0, gap)
    y = run('debug.setmetatable(1 > 2, mt)\nlocal n = 3\nY = (n == 3).foo\n')
    ok(holds_g(y), 'a comparison result is a boolean: ' .. vim.inspect(y))
    y = run('local dsm = debug.setmetatable\ndsm(0, mt)\nY = (7).foo\n')
    ok(holds_g(y), 'by value, through an alias: ' .. vim.inspect(y))
    y, gap = run('debug.setmetatable(nil, mt)\nlocal z\nY = z\n')
    eq({}, y); eq(1, gap, 'nil: the named gap')
    y = run('debug.setmetatable(0, mt)\nY = ("s").foo\n')
    eq({}, y, 'a number\'s metatable is not a string\'s')
    y = run('Y = (5).foo\n')
    eq({}, y, 'no debug.setmetatable: a number indexes nothing')
    -- a load on a number reached only AFTER the type took its metatable — a function found through it, called with 7
    y = run('mt.__index.bar = g\nmt.__index.foo2 = function (n) Y = n.bar end\ndebug.setmetatable(0, mt)\nlocal f = (5).foo2\nf(7)\n')
    ok(holds_g(y), 'a load first seen after the holder exists reads through it: ' .. vim.inspect(y))
end)
