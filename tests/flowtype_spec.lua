-- cartograph.flowtype — WHAT VALUE REACHES A RECEIVER, BY FLOW (CART-1621). An inclusion points-to analysis: the
-- functions / tables / types that flow to an AMBIGUOUS call's receiver decide it — one function (exact, possibly one
-- the name join never listed), a type (string), or nothing claimed when an unknown value may arrive.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local flowtype = require 'cartograph.flowtype'

local function tree(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        vim.fn.mkdir((root .. '/' .. rel):match('^(.*)/[^/]+$'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    return root
end

local FILES = {
    -- (two modules each defining `get` and `lower`: every `x.get()` / `s:lower()` below is AMBIGUOUS by name)
    ['a.lua'] = 'local A = {}\nfunction A.get(t) t.n = 1; return t end\nfunction A.lower(s) return s end\nreturn A\n',
    ['b.lua'] = 'local B = {}\nfunction B.get(t) t.m = 2; return t end\nfunction B.lower(s) return s end\nreturn B\n',
    ['main.lua'] = table.concat({
        -- a record of closures returned by a constructor: `r.get` is the closure, not A.get / B.get
        'local function reader(src)',
        '  return { get = function (i) return src:sub(i, i) end }',
        'end',
        'local function first(src)',
        '  local r = reader(src)',
        '  return r.get(1)',
        'end',
        -- a receiver only ever a string BY FLOW (the parameter of a local function its callers hand literals):
        -- name:lower() is string.lower, neither A.lower nor B.lower
        'local function shout(name)',
        '  return name:lower()',
        'end',
        'local function greet() return shout("ada"), shout("bob") end',
        -- a dispatch table called through pcall: the handler reached is the table's
        'local VERBS = { get = function (t) return t end }',
        'local function run(verb, t)',
        '  local h = VERBS[verb]',
        '  local ok, v = pcall(h, t)',
        '  return v',
        'end',
        'return { first = first, greet = greet, run = run }',
    }, '\n'),
}

test('flowtype: a returned record\'s closure, a string-only receiver — decided by what FLOWS there, not by the name', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree(FILES)
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local by = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' then by[tostring(callrec.full(c) or callrec.callee(c))] = R.verdict(c) end
    end
    local g = by['r.get']
    eq('exact', g and g.kind, 'the record\'s closure: ' .. vim.inspect(g))
    ok(g and g.targets[1] and g.targets[1]:match('^main%.lua::'), 'a main.lua function — neither A.get nor B.get: ' .. vim.inspect(g))
    local s = by['name:lower']
    eq('string', s and s.kind, 'only a string reaches s: ' .. vim.inspect(s))
end)

test('flowtype: a store into a SCALAR writes no field — the shared string object never holds `.body`; explain names a saturation (CART-1683)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local L3 = 'local function main() put("s"); put({}) end'
    local sinks = {}
    for i = 1, 70 do sinks[i] = 'sink({})' end -- (70 tables through one parameter: past CAP)
    local root = tree({
        ['m.lua'] = table.concat({
            'local function f() return 1 end',
            'local function put(x) x.body = f end', -- x is a string at one call, a table at the other
            L3,
            'local function sink(x) return x end',
            table.concat(sinks, '\n'),
            'return main' }, '\n') .. '\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false, explain = true, keepsat = true })
    local so = R.object('type:string')
    ok(so, 'the string type object exists')
    eq(nil, R.field_port(so, 'body'), 'a string has no field to write: `x.body = f` raises on one')
    local tb = R.object('tbl:m.lua:2:' .. (L3:find('{', 1, true) - 1)) -- (an object's key: file, 0-based line and column)
    ok(tb and R.field_port(tb, 'body'), 'the table handed to put does get .body')
    -- (explain: the first sink table escaped through sink's saturated parameter, and that port saturated past CAP)
    local path = R.escape_of(R.object('tbl:m.lua:4:5'))
    ok(path[#path]:find('[saturated]', 1, true), 'escape_of ends at a saturated port: ' .. table.concat(path, ' | '))
    local late = R.escape_of(R.object('tbl:m.lua:73:5')) -- (the last: it reached the port AFTER it saturated)
    ok(late[#late]:find('[saturated]', 1, true), 'a late arrival is recorded too: ' .. table.concat(late, ' | '))
    local why = R.taint_path(R._escport)
    eq('<- saturated (past CAP)', why[#why], 'taint_path names the seed')
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a load over many objects sharing one deep prototype chain walks the chain ONCE, not once per object (CART-1686)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (50 objects, each its own allocation site, all with __index = P1, the head of a 30-link prototype chain linked
    -- AFTER the loads: each object's load `o.x` is replayed onto P1 once P1 is its prototype, and P1 already holds
    -- that load — the old code re-walked the whole chain every time: 1760 load_obj calls here, 290 with the return)
    local src = { 'local ' .. table.concat(vim.tbl_map(function (k) return 'P' .. k end, vim.fn.range(1, 30)), ', '),
        'local P31 = { x = 1 }', 'local get' }
    for k = 0, 49 do src[#src + 1] = ('local o%d = setmetatable({}, { __index = P1 })'):format(k) end
    src[#src + 1] = 'get = function (o) return o.x end'
    for k = 0, 49 do src[#src + 1] = ('get(o%d)'):format(k) end
    for k = 30, 1, -1 do src[#src + 1] = ('P%d = setmetatable({}, { __index = P%d })'):format(k, k + 1) end
    src[#src + 1] = 'return get'
    local root = tree({ ['m.lua'] = table.concat(src, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false, ctx = false })
    ok(R.stats.loadvisits > 0, 'the counter counts')
    ok(R.stats.loadvisits < 500, 'linear in objects + chain, not their product: ' .. R.stats.loadvisits)
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a store through a SATURATED base may write any escaped object\'s field — a load through that object\'s own port is partial (CART-1643 rule 1, CART-1696)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (o holds A.run; o and 70 other tables reach g's parameter, which saturates: o ESCAPES. g writes `t.run = B.run`
    -- through it, which the solve no longer follows into o. A load o.run through o's own, untainted port must not
    -- answer a whole exact A.run — at run time it may be B.run)
    local sinks = {}
    for k = 1, 70 do sinks[k] = 'g({})' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['m.lua'] = table.concat({
            'local A, B = require("a"), require("b")',
            'local o = { run = A.run }',
            'local function g(t) t.run = B.run end',
            'g(o)',
            table.concat(sinks, '\n'),
            'return o:run()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'o:run' then call = c end end
    ok(call and call.refused, 'the call is ambiguous: ' .. vim.inspect(call and call.refused and call.refused.rule))
    local v = flowtype.of(store, { open = false }).verdict(call)
    ok(not (v and v.kind == 'exact' and not v.partial), 'no WHOLE exact through the escaped object: ' .. vim.inspect(v))
    vim.fn.delete(root, 'rf')
end)

-- (CART-1726: a function stored by a COMPUTED key may be any member — `M[op] = D[op]` overrides M.generalize when op is
-- 'generalize' — and a named load reads those stores too. A KEYED COPY `T[k] = S[k]` is field-wise: T gets S's members,
-- and keeps the ones S lacks)
local function kcase(src)
    local sinks = {}
    for k = 1, 70 do sinks[k] = src.sink or '' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nfunction A.stop(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nfunction B.stop(self) return 2 end\nreturn B\n',
        ['m.lua'] = 'local A, B = require("a"), require("b")\n' .. src.body .. '\n' .. table.concat(sinks, '\n') .. '\nreturn o:run(), o:stop()\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local R = flowtype.solve(store, { open = false, order = src.order })
    local v = {}
    for _, c in ipairs(store.data.calls) do
        local f = callrec.full(c)
        if f == 'o:run' or f == 'o:stop' then ok(c.refused, f .. ' is ambiguous'); v[f:sub(3)] = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    return v
end
local function whole(v, m) return v and v.kind == 'exact' and not v.partial and #v.targets == 1 and tostring(v.targets[1]):match('%u%.' .. m .. '@') end

test('flowtype: a function stored by a computed key may be the named member — no whole exact of the named one (CART-1726)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local v = kcase { body = 'local o = { run = A.run, stop = A.stop }\nlocal k = ("run"):lower()\no[k] = B.run' }
    ok(not whole(v.run, 'run'), 'o[k] = B.run may be o.run: ' .. vim.inspect(v.run))
    ok(not whole(v.stop, 'stop'), '… or o.stop: ' .. vim.inspect(v.stop))
end)

test('flowtype: a keyed copy T[k] = S[k] gives T the source\'s members — what S lacks stays exact (CART-1726)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local v = kcase { body = 'local o = { run = A.run, stop = A.stop }\nlocal S = { run = B.run }\nfor _, op in ipairs({ "run" }) do o[op] = S[op] end' }
    ok(not whole(v.run, 'run'), 'o.run may be B.run: ' .. vim.inspect(v.run))
    ok(whole(v.stop, 'stop') and tostring(v.stop.targets[1]):match('A%.stop'), 'S has no stop: o.stop is A.stop, whole: ' .. vim.inspect(v.stop))
    -- (a member the source gains AFTER the copy is walked; a target / a source that reaches the copy through a parameter,
    -- and one stored where the call reads it only AFTER the call is walked — in every worklist ORDER: the solve's hook for
    -- a target gaining objects and the one for a source gaining them cover for each other unless one side fills only
    -- once the other's objects were processed, in asc / fifo here)
    for what, body in pairs {
        ['a later member of S'] = 'local o = { run = A.run, stop = A.stop }\nlocal S = {}\nfor _, op in ipairs({ "run" }) do o[op] = S[op] end\nS.run = B.run',
        -- (a store makes S's metatable PORT, to look for __newindex — no metatable is there)
        ['a member stored before'] = 'local o = { run = A.run, stop = A.stop }\nlocal S = {}\nS.run = B.run\nfor _, op in ipairs({ "run" }) do o[op] = S[op] end',
        ['a target by parameter'] = 'local S = { run = B.run }\nlocal function g(t) for _, op in ipairs({ "run" }) do t[op] = S[op] end end\nlocal o = { run = A.run, stop = A.stop }\ng(o)',
        ['a source by parameter'] = 'local o = { run = A.run, stop = A.stop }\nlocal function h(s) for _, op in ipairs({ "run" }) do o[op] = s[op] end end\nh({ run = B.run })',
        ['a target stored late'] = 'local S = { run = B.run }\nlocal function g(t) for _, op in ipairs({ "run" }) do t[op] = S[op] end end\nlocal box = {}\nlocal function later() g(box.v) end\nlater()\nbox.v = { run = A.run, stop = A.stop }\nlocal o = box.v',
        ['a source stored late'] = 'local o = { run = A.run, stop = A.stop }\nlocal function h(s) for _, op in ipairs({ "run" }) do o[op] = s[op] end end\nlocal box = {}\nlocal function later() h(box.v) end\nlater()\nbox.v = { run = B.run }',
    } do
        for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
            v = kcase { body = body, order = order }
            ok(not whole(v.run, 'run'), what .. ' ' .. order .. ': o.run may be B.run: ' .. vim.inspect(v.run))
            ok(whole(v.stop, 'stop'), what .. ' ' .. order .. ': o.stop is A.stop, whole: ' .. vim.inspect(v.stop))
        end
    end
end)

-- (CART-1734: a set answer is the FLOW's, whatever the name join listed — `helper` is no candidate for `o:run`, and the
-- kind was decided against the candidates: `same`, no answer)
test('flowtype: a flow set with a function the join never listed is an answer (narrowed), not dropped', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local v = kcase { body = 'local function helper(self) return 0 end\nlocal o = (#arg > 0) and { run = A.run, stop = A.stop } or { run = helper, stop = A.stop }' }
    eq('narrowed', v.run and v.run.kind, vim.inspect(v.run))
    local names = {}
    for _, t in ipairs(v.run and v.run.targets or {}) do names[#names + 1] = tostring(t):match('::(.-)@') end
    table.sort(names)
    eq('A.run,helper', table.concat(names, ','), 'the flow set')
end)

test('flowtype: a keyed copy from a source with a METATABLE is a dynamic-key store — its __index answers any key (CART-1726)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    for what, src in pairs {
        ['a prototype table'] = 'local S = setmetatable({}, { __index = { run = B.run } })',
        ['an __index function'] = 'local S = setmetatable({}, { __index = function () return B.run end })',
    } do
        local v = kcase { body = src .. '\nlocal o = { run = A.run, stop = A.stop }\nfor _, op in ipairs({ "run" }) do o[op] = S[op] end' }
        ok(not whole(v.run, 'run'), what .. ': o.run may be B.run: ' .. vim.inspect(v.run))
    end
    -- (the metatable arrives AFTER the copy is walked; the source reaches the copy only after its metatable was solved)
    for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
        local v = kcase { order = order, body = 'local S = {}\nlocal o = { run = A.run, stop = A.stop }\nfor _, op in ipairs({ "run" }) do o[op] = S[op] end\nsetmetatable(S, { __index = { run = B.run } })' }
        ok(not whole(v.run, 'run'), 'a later metatable ' .. order .. ': o.run may be B.run: ' .. vim.inspect(v.run))
        v = kcase { order = order, body = 'local o = { run = A.run, stop = A.stop }\nlocal function h(s) for _, op in ipairs({ "run" }) do o[op] = s[op] end end\nlocal box = {}\nlocal function later() h(box.v) end\nlater()\nbox.v = setmetatable({}, { __index = { run = B.run } })' }
        ok(not whole(v.run, 'run'), 'a metatable source stored late ' .. order .. ': o.run may be B.run: ' .. vim.inspect(v.run))
    end
end)

test('flowtype: a keyed copy through a port the solve lost — into any escaped object, or from anything (CART-1726)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (the TARGET saturates: o escapes, and the copy may write S's members into it unseen)
    local v = kcase { body = 'local o = { run = A.run, stop = A.stop }\nlocal S = { run = B.run }\nlocal function g(t) for _, op in ipairs({ "run" }) do t[op] = S[op] end end\ng(o)', sink = 'g({})' }
    ok(not whole(v.run, 'run'), 'a lost target: o.run may be B.run: ' .. vim.inspect(v.run))
    -- (… from a source whose __index answers any key: every escaped object's computed-key port)
    v = kcase { body = 'local o = { run = A.run, stop = A.stop }\nlocal S = setmetatable({}, { __index = { run = B.run } })\nlocal function g(t) for _, op in ipairs({ "run" }) do t[op] = S[op] end end\ng(o)', sink = 'g({})' }
    ok(not whole(v.run, 'run'), 'a lost target, a metatable source: o.run may be B.run: ' .. vim.inspect(v.run))
    -- (the SOURCE saturates: what it held under any key may land in o)
    v = kcase { body = 'local o = { run = A.run, stop = A.stop }\nlocal function h(s) for _, op in ipairs({ "run" }) do o[op] = s[op] end end\nh({ run = B.run })', sink = 'h({})' }
    ok(not whole(v.run, 'run'), 'a lost source: o.run may be B.run: ' .. vim.inspect(v.run))
end)

-- (CART-1732: an object that escapes DURING the taint — here the value a store through a saturated base wrote — has
-- its DYNAMIC loads tainted once any field of escaped objects may have been written unseen: `pairs(H)` may yield `use`)
test('flowtype: an object escaping during the taint — a store\'s value — has its dynamic loads partial once a field is hit (CART-1732)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.m(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.m(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local A, B = require "a", require "b"',
            'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
            'local function use(p) return p:m() end',
            'use(a)',
            'local function sink(t) t.f = use end',
            'sink({}); sink({}); sink({})',
            'local H = {}',
            'local function sink2(t) t.x = H end',
            'sink2({}); sink2({}); sink2({})',
            'for _, fn in pairs(H) do fn(b) end',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local R = flowtype.solve(store, { open = false, ctx = false })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local c
    for _, x in ipairs(store.data.calls) do if callrec.file(x) == 'main.lua' and tostring(callrec.full(x)) == 'p:m' then c = x end end
    local v = R.verdict(c)
    ok(not (v and v.kind == 'exact' and not v.partial), 'H may hold use: no whole exact A.m — ' .. vim.inspect(v))
end)

test('flowtype: a loop\'s per-site instance of its iterator is walked AT ITS OWN POSITIONS — the original call\'s answer is the union (CART-1688)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (the loop hands `node` to an instance of `it`; a direct call hands `other` to the original. The call n:kid inside
    -- `it` reaches BOTH — an answer naming other.kid alone was an unsound exact)
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.kid(self, i) return nil end',
        'function B.kid(self, i) return nil end',
        'local node = { kid = function (self, i) if i < 2 then return i end end }',
        'local other = { kid = function (self, i) return nil end }',
        'local function it(n, i)',
        '    local c = n:kid(i + 1)',
        '    if c then return i + 1, c end',
        'end',
        'it(other, 0)',
        'for _, c in it, node, -1 do print(c) end',
        'return A' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'n:kid' then call = c end end
    ok(call, 'the ambiguous call is recorded')
    for _, open in ipairs { false, true } do
        local v = flowtype.of(store, { open = open }).verdict(call)
        ok(not (v and v.kind == 'exact'), (open and 'open' or 'closed') .. ': no exact through the loop\'s instance: ' .. vim.inspect(v))
    end
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a loop site minted INSIDE an instance takes no instance of its own — a chain of iterators instantiates once per original site (CART-1687)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (three small closed iterators, each looping over the next; global, so each is closed. Without the bound every
    -- instance's own loop instantiated the next again — 6 instances here, a cycle of them never stopped on WoW)
    local root = tree({ ['m.lua'] = table.concat({
        'function it3(s, i) return nil end',
        'function it2(s, i) for _ in it3, s, i do end return nil end',
        'function it1(s, i) for _ in it2, s, i do end return nil end',
        'for _ in it1, {}, 0 do end',
        'return it1' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false, ctx = false })
    eq(3, R.stats.instances, 'one instance per loop site of the original code')
    vim.fn.delete(root, 'rf')
end)

-- ★ LUA'S HIDDEN VALUE ROUTES (CART-1699): classes A and B with a method m; a function's parameter p receives `a` through
-- an ordinary call and `b` through a construct the walk did not model. At run time B.m runs; the answer for p:m() must
-- not be a WHOLE exact A.m. The routes themselves — CART-1699's, the errors of tree code a builtin runs (CART-1708),
-- varargs, code outside the tree, environments, raw access, hooks, wrap, finalizers (CART-1707), the Lean model's R1-R20
-- — are FIXTURES, run on every Lua version and analysed in every order: tests/fixtures/routes/, tests/routes_spec.lua
-- (CART-1711). The specs below use the same prologue
local CLASSES = table.concat({
    'local A, B = {}, {}',
    'function A.m(self) return "A" end',
    'function B.m(self) return "B" end',
    'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })' }, '\n') .. '\n'

-- (the same fixtures, read the other way: `t[k]` never returns a HIDDEN field — the metatable rides on t as `\1mt`. The
-- dynamic load registered BEFORE setmetatable's store got the metatable as a value, one registered after did not; mt
-- has an m of its own, so a load that returned it made p:m() a set, CART-1707)
for _, late in ipairs { false, true } do
    test(('flowtype: `t[k]` never reads the metatable — setmetatable %s the load (CART-1707)'):format(late and 'after' or 'before'), function ()
        if not parser_available('lua') then skip 'no lua parser' end
        local sm = 'setmetatable(t, mt)\n'
        local root = tree({ ['m.lua'] = CLASSES .. table.concat({
            'local function use(p) return p:m() end',
            'use(a)',
            'local mt = { __index = {}, m = function (self) return "MT" end }',
            'local t = {}',
            late and '' or sm,
            'local function rd(x, k) return x[k] end',
            'print(use(rd(t, ("q"):upper())))',
            late and sm or '' }, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        local callrec = require 'cartograph.callrec'
        local call
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
        for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
            local v = flowtype.solve(store, { open = false, order = order }).verdict(call)
            ok(v and v.kind == 'exact' and not v.partial and tostring(v.targets[1]):match('A%.m'), order .. ': ' .. vim.inspect(v))
        end
        vim.fn.delete(root, 'rf')
    end)
end

-- (a metamethod is looked up in the object's OWN metatable: an __index prototype's metatable is never consulted — `o + b`
-- with __add only on o's prototype raises, so add never runs with b. A load of the hidden `\1mt` that walked the
-- prototype chain answered it did, CART-1707)
-- (both orders: `o + b` loads o's metatable at the walk, before the prototype link — a replayed load; `plus(o, b)` loads
-- it when o reaches the parameter, after the link — the chain walk)
for _, viaparam in ipairs { false, true } do
test(('flowtype: a metamethod is the object\'s own — a prototype\'s metatable is not consulted%s (CART-1707)'):format(viaparam and ', through a parameter' or ''), function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES .. table.concat({
        'local function add(x, p) return p:m() end',
        'add(nil, a)',
        'local base = setmetatable({}, { __add = add })',
        'local o = setmetatable({}, { __index = base })',
        viaparam and 'local function plus(x, y) return x + y end\nprint(pcall(plus, o, b))' or 'print(pcall(function () return o + b end))' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
        local v = flowtype.solve(store, { open = false, order = order }).verdict(call)
        ok(v and v.kind == 'exact' and not v.partial and tostring(v.targets[1]):match('A%.m'), order .. ': ' .. vim.inspect(v))
    end
    vim.fn.delete(root, 'rf')
end)
end

-- (a HANDLER PORT the cap left incomplete is parked until some metatable can hold the handler — and the metatables were
-- never recorded, so it was never released: `o1 + 1` runs __add, which returns a, where the metatable parameter
-- saturated; the answer was a WHOLE exact B.m. Found by CART-1707's finalizer deferral, which reads the same list)
test('flowtype: a handler port the cap cut is RELEASED once a metatable can hold the handler — no whole exact (CART-1707)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES .. table.concat({
        'local function use(p) return p:m() end',
        'use(b)',
        'local function mk(mt) return setmetatable({}, mt) end',
        'local o1 = mk({ __add = function (x, y) return a end })',
        'local o2 = mk({})',
        'local o3 = mk({})',
        'print(use(o1 + 1))' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local cap = flowtype.CAP
    flowtype.CAP = 2 -- (the metatable parameter saturates)
    for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
        local v = flowtype.solve(store, { open = false, order = order }).verdict(call)
        ok(not (v and v.kind == 'exact' and not v.partial), order .. ': ' .. vim.inspect(v))
    end
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
end)

-- (the contract's third edge: _G never ESCAPES. `put` receives three tables at CAP 2, _G among them; its parameter
-- saturates, so the store `t.q = b` is not followed into _G — and _G's fields are not tainted for it. WoW passes _G as
-- an argument: an escaped _G took every addon's namespace with it, w3 308 whole answers partial. A fix that keeps the
-- precision flips this spec)
for _, held in ipairs { false, true } do
test(('flowtype: a write to _G through a value the cap cut is not followed — _G never escapes%s (CART-1707)'):format(held and ', held in a field' or ''), function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES .. table.concat({
        'local function use(p) return p:m() end',
        'use(a)',
        held and 'local function put(t) t.g.q = b end' or 'local function put(t) t.q = b end',
        held and 'put({ g = {} })' or 'put({})',
        held and 'put({ g = {} })' or 'put({})',
        held and 'put({ g = _G })' or 'put(_G)',
        'print(use(q))' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local v = flowtype.solve(store, { open = false }).verdict(call)
    flowtype.CAP = cap
    eq('exact', v and v.kind, 'the miss: ' .. vim.inspect(v))
    ok(not v.partial, 'whole: ' .. vim.inspect(v))
    vim.fn.delete(root, 'rf')
end)
end

-- (`setfenv(1, env)` at a file's top level is that CHUNK's environment — its functions' global reads, nobody else's.
-- Without the chunk, env became a prototype of _G for every global read in the tree: WoW's `setfenv(1, Prat)`)
test('flowtype: setfenv(1, env) at the top level is the file chunk\'s environment — another file\'s global read does not see env (CART-1707)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lib.lua'] = 'B2 = setmetatable({}, { __index = { m = function (self) return "B" end } })\nsetfenv(1, { q = B2 })\nprint(q)\n',
        ['m.lua'] = CLASSES .. 'local function use(p) return p:m() end\nuse(a)\nprint(use(q))\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local v = flowtype.solve(store, { open = false }).verdict(call)
    ok(v and v.kind == 'exact' and not v.partial and tostring(v.targets[1]):match('A%.m'), vim.inspect(v))
    vim.fn.delete(root, 'rf')
end)

-- (and a fourth: a call on a MEMBER of unknown code's value runs nothing — `Obj` came back from a loaded chunk, so
-- `Obj:Register(t)` does not reach Reg:Register, which writes t.m. At run time B.m runs. A member of EXT made EXT
-- was measured — 427 typed / string answers went unknown — and the name join, which named Register, is no input
-- (CART-1715). A fix that keeps the precision flips this spec)
test('flowtype: a call on a member of unknown code\'s value runs nothing — the contract\'s edge (CART-1715)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES .. table.concat({
        'local function use(p) return p:m() end',
        'use(a)',
        'local Reg = {}',
        'function Reg:Register(x) x.m = B.m end',
        'local Obj = loadstring(("return ..."):lower())(Reg)',
        'local t = { m = A.m }',
        'Obj:Register(t)',
        'use(t)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local v = flowtype.solve(store, { open = false }).verdict(call)
    eq('exact', v and v.kind, 'the miss: ' .. vim.inspect(v))
    vim.fn.delete(root, 'rf')
end)

-- (CART-1783: what escapes LATE in open mode is written by the outside too, under C1. `M.hook` is a data field the
-- outside may replace (O2), so `M.hook:m(cfg)` may run the outside's function, which keeps `cfg` and writes its DATA
-- field `h`: a call through it is partial. It had stayed whole — the `[]` rule fired only before the taint phase)
test('flowtype: open mode — a table handed to a call the outside may supply has its data fields written (CART-1783)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['lua/m/init.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.m(self) return "A" end',
        'function B.m(self) return "B" end',
        'local cfg = { h = setmetatable({}, { __index = A }) }',
        'local M = { hook = setmetatable({}, { __index = B }) }',
        'function M.run() M.hook:m(cfg); return cfg.h:m() end',
        'return M' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local R = flowtype.solve(store, { open = true, explain = true })
    local n = 0
    for _, c in ipairs(store.data.calls) do
        if callrec.full(c) == 'cfg.h:m' then
            n = n + 1
            local v = R.verdict(c)
            ok(v and v.kind == 'exact' and v.partial, 'cfg escaped to the outside\'s m: cfg.h is outside-written: ' .. vim.inspect(v))
            local why = table.concat(R.taint_path(v.ptport), ' | ')
            ok(why:find('DATA field of what escaped', 1, true), 'by the late outside write: ' .. why)
        end
    end
    eq(1, n, 'the call is found')
    vim.fn.delete(root, 'rf')
end)

-- (CART-1783: once `[]` is hit the outside may key an escaped table by ANY escaped object — `t[obj] = v` — so a key
-- `pairs` yields of it is partial: for a table escaping LATE (a lost call's argument) and for one escaped BEFORE the
-- hit (past CAP). The solve held this already — the tainted `[]` cell reaches the loop's key; the DUMP's key set did
-- not (flowdump_spec). Pinned here)
test('flowtype: closed — with `[]` hit, an escaped table\'s keys are partial, late or early (CART-1783)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local CLS = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local w = setmetatable({}, { __index = B }); w:m()' }
    local function keycall(src, cap)
        local root = tree({ ['m.lua'] = table.concat(CLS, '\n') .. '\n' .. table.concat(src, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        local c0 = flowtype.CAP
        if cap then flowtype.CAP = cap end
        local ok_, R = pcall(flowtype.solve, store, { open = false })
        flowtype.CAP = c0
        vim.fn.delete(root, 'rf')
        assert(ok_, R)
        local callrec = require 'cartograph.callrec'
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'k:m' then return R.verdict(c) end end
    end
    -- late: u escapes in the taint phase, handed to t.cb, which unknown code may have replaced
    local v1 = keycall({
        'local t = { cb = function () end }', 'local f = load(("return ..."):lower())', 'f(t)',
        'local u = { [setmetatable({}, { __index = A })] = 1 }', 't.cb(u)',
        'for k in pairs(u) do k:m() end' })
    ok(v1 and v1.kind == 'exact' and v1.partial, 'late: k is partial ' .. vim.inspect(v1))
    -- early: v1 escapes past CAP before the hit
    local v2 = keycall({
        'local function lose(q) return q end',
        'local v = { [setmetatable({}, { __index = A })] = 1 }', 'lose(v)', 'lose({})', 'lose({})',
        'for k in pairs(v) do k:m() end' }, 2)
    ok(v2 and v2.kind == 'exact' and v2.partial, 'early: k is partial ' .. vim.inspect(v2))
end)

-- ★ O2 / C1 (CART-1685, the user's decision): in OPEN mode outside code may write the DATA fields of what it reaches
-- from the exports — `M.config`, `M.cache.last`, an object stored on the module — so what is read through one is
-- PARTIAL (`exact~`: the targets stay, the claim is no longer whole); it does not replace FUNCTION members (C1) — an
-- exported function, a method the prototype supplies — so an object an exported function MAKES keeps a whole answer.
-- Open answers through a reachable receiver say they rest on C1; closed mode is untouched
test('flowtype: open mode — outside code writes DATA fields (O2), not function members (C1); answers carry C1 (CART-1685)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['lua/m/init.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.m(self) return "A" end',
        'function B.m(self) return "B" end',
        'local M = { config = { item = setmetatable({}, { __index = A }) }, cache = {} }',
        'M.cache.last = setmetatable({}, { __index = A })',
        'function M.make() return setmetatable({}, { __index = A }) end',
        'M.obj = setmetatable({}, { __index = A })',
        'function M.run2() return M.obj:m() end',
        'function M.run() return M.config.item:m() end',
        'function M.peek() return M.cache.last:m() end',
        'local function id(x) return x end',
        'function M.fresh() local o = id(M.make()); return o:m() end',
        'return M' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local function at(full) for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return c end end end
    local closed, open = flowtype.solve(store, { open = false }), flowtype.solve(store, { open = true })
    for _, full in ipairs { 'M.config.item:m', 'M.cache.last:m', 'M.obj:m', 'o:m' } do
        local v = closed.verdict(at(full))
        ok(v and v.kind == 'exact' and not v.partial and not v.contracts, 'closed: ' .. full .. ' ' .. vim.inspect(v))
    end
    for _, full in ipairs { 'M.config.item:m', 'M.cache.last:m', 'M.obj:m' } do
        local v = open.verdict(at(full))
        ok(v and v.kind == 'exact' and v.partial, 'O2: read through a data field outside code may write — partial: ' .. full .. ' ' .. vim.inspect(v))
    end
    local v = open.verdict(at('o:m'))
    ok(v and v.kind == 'exact' and not v.partial, 'C1: an object an exported function makes keeps a whole answer: ' .. vim.inspect(v))
    eq('C1', (v.contracts or {})[1], 'and names the contract it rests on')
    vim.fn.delete(root, 'rf')
end)

-- ★ THE CONTRACT'S EDGE, PINNED (CART-1707): a global read is a STRICT load of _G's field — it sees `_G.q = v`,
-- `rawset(_G, 'q', v)`, getfenv's table and setfenv's environments, not a DYNAMIC-key `_G[k] = v`. Reading `[]` made
-- every global read on the repo partial (typed RIGHT 121 -> 0 on the runtime oracle): mix's evaluator holds _G among
-- its values and writes `o[k] = v`. This miss is the price; a fix that keeps the precision flips this spec
test('flowtype: a dynamic-key write `_G[k] = v` is not seen by a global read — the contract\'s edge (CART-1707)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES .. 'local function use(p) return p:m() end\nuse(a)\nlocal k = ("q"):lower()\n_G[k] = b\nprint(use(q))\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local v = flowtype.solve(store, { open = false }).verdict(call)
    eq('exact', v and v.kind, 'the miss: ' .. vim.inspect(v))
    vim.fn.delete(root, 'rf')
end)

-- (and its mirror: a read by COMPUTED name `_G[k]` sees what a dynamic-key write stored, and EXT — a global the host
-- defines — not the named globals: pulling every named global's set into each `_G[k]` took WoW w2 from 41 to 632 s.
-- So `_G[name](b)` does not bind the named global function; a fix that keeps the cost flips this spec)
for _, viaparam in ipairs { false, true } do
    test(('flowtype: a read by computed name `_G[k]` does not see the NAMED globals — the contract\'s edge%s (CART-1707)'):format(viaparam and ', through a parameter' or ''), function ()
        if not parser_available('lua') then skip 'no lua parser' end
        local root = tree({ ['m.lua'] = CLASSES .. table.concat({
            'function gf(p) return p:m() end',
            'gf(a)',
            'local k = ("g"):rep(1) .. "f"',
            viaparam and 'local function get(t, j) return t[j] end\nget(_G, k)(b)' or '_G[k](b)' }, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        local callrec = require 'cartograph.callrec'
        local call
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
        for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
            local v = flowtype.solve(store, { open = false, order = order }).verdict(call)
            eq('exact', v and v.kind, order .. ': the miss: ' .. vim.inspect(v))
        end
        vim.fn.delete(root, 'rf')
    end)
end

test('flowtype: an error is caught only by a pcall protecting what raises it — another function\'s error() reaches no other pcall (CART-1705)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (the global error set saturated on the repo and made every `local ok, v = pcall(f)` ⊤: v holds what f — and what
    -- f calls — raises, never what an unrelated function raises)
    local root = tree({ ['m.lua'] = CLASSES .. table.concat({
        'local function boom() error(b) end',                     -- raises b, protected elsewhere
        'local function make() return a end',
        'local ok, v = pcall(make)',
        'local function use(p) return p:m() end',
        'print(use(v), pcall(boom))' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local v = flowtype.of(store, { open = false }).verdict(call)
    eq('exact', v and v.kind, 'v holds make\'s a (and a runtime error\'s string), never boom\'s b: ' .. vim.inspect(v))
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a string is the receiver only of a string-library member — ("x"):finish() would raise (CART-1690)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = CLASSES .. 'local function use(p) return p:m() end\nuse(a)\nuse("s")\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local v = flowtype.of(store, { open = false }).verdict(call)
    eq('exact', v and v.kind, 'the string has no m: a, alone, is the receiver: ' .. vim.inspect(v))
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a FUEL budget stops the solve and taints what it left queued — no whole answer from the unfinished work; a budget larger than needed changes nothing (CART-1706)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (the methods sit on the objects, so a lookup needs no prototype link; `a` reaches p as the calls are walked,
    -- `b` only through x, which is empty when use(x) is walked and gains b later — the worklist carries it to p. At
    -- run time setx runs first: b.m runs. A cut that left x queued must not answer a whole exact a.m)
    local root = tree({ ['m.lua'] = table.concat({
        'local a, b = {}, {}',
        'function a.m(self) return 1 end',
        'function b.m(self) return 2 end',
        'local x',
        'local function main() use(a); return use(x) end',
        'local function setx() x = b end',
        'function use(p) return p:m() end',
        'setx()',
        'print(main())' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local cut = flowtype.solve(store, { open = false, fuel = 0 })
    ok((cut.stats.fuel_cut or 0) > 0, 'the budget ran out with ports queued')
    local v = cut.verdict(call)
    ok(not (v and v.kind == 'exact' and not v.partial), 'no whole exact A.m from a cut solve: ' .. vim.inspect(v))
    local full, big = flowtype.solve(store, { open = false }), flowtype.solve(store, { open = false, fuel = 1e12 })
    eq(nil, big.stats.fuel_cut, 'a budget larger than needed never runs out')
    eq(vim.inspect(full.verdict(call)), vim.inspect(big.verdict(call)), 'and answers as the unbudgeted solve')
    vim.fn.delete(root, 'rf')
    -- (a STORE through a port the cut left queued: holder's table reaches put's t only through y, so `t.m = b.m` may
    -- never have reached it — the queued objects ESCAPE, and the store through the tainted t reaches their field m.
    -- Which budget leaves exactly that queued is the schedule's choice: every order, budgets 0..40)
    root = tree({ ['m.lua'] = table.concat({
        'local a, b = {}, {}',
        'function a.m(self) return 1 end',
        'function b.m(self) return 2 end',
        'local holder = { m = a.m }',
        'local y',
        'local function main() put(y); return holder:m() end',
        'local function sety() y = holder end',
        'function put(t) t.m = b.m end',
        'sety()',
        'print(main())' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    call = nil
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'holder:m' then call = c end end
    for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
        for fuel = 0, 40 do
            local w = flowtype.solve(store, { open = false, fuel = fuel, order = order }).verdict(call)
            ok(not (w and w.kind == 'exact' and not w.partial), ('%s fuel %d: no whole exact a.m — %s'):format(order, fuel, vim.inspect(w)))
        end
    end
    vim.fn.delete(root, 'rf')
end)

test('flowtype: an object whose __index SOURCE the cut left unfinished is prototype-incomplete — no whole answer through it (CART-1709)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (one allocation site, prototypes {D, C} uncut; C still on its way to mk's parameter when D is linked: the chain
    -- the verdict walks lacks C, and y:m() runs C.m — fifo, budgets 32..36 had answered a WHOLE exact D.m. The flowpath
    -- research's fixture, ~/work/flowpath/probes/fuel/roots/protocut2)
    local root = tree({ ['m.lua'] = table.concat({
        'local C, D = {}, {}',
        'function C.m(self) return "C" end',
        'function D.m(self) return "D" end',
        'local function id(v) return v end',
        'local function mk(proto) return setmetatable({}, { __index = proto }) end',
        'local x = mk(D)',
        'local y = mk(id(id(id(id(id(id(C)))))))',
        'print(y:m())' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'y:m' then call = c end end
    for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
        for fuel = 0, 60 do
            local v = flowtype.solve(store, { open = false, ctx = false, fuel = fuel, order = order }).verdict(call)
            ok(not (v and v.kind == 'exact' and not v.partial), ('%s fuel %d: no whole exact D.m — %s'):format(order, fuel, vim.inspect(v)))
        end
    end
    vim.fn.delete(root, 'rf')
end)

test('flowtype: an EXPORTED function\'s parameter may hold anything (open) — no claim through it', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.get(t) t.n = 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.get(t) t.m = 2 end\nreturn B\n',
        ['m.lua'] = 'local M = {}\nlocal function g() return 1 end\nfunction M.use(x) return x.get() end\nfunction M.inside() return M.use({ get = g }) end\nreturn M\n',
    })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'x.get' then call = c end end
    ok(call, 'the ambiguous call is recorded')
    local closed = flowtype.of(store, { open = false }).verdict(call)
    eq('exact', closed and closed.kind, 'closed world: the one table that flows in decides it')
    eq(nil, flowtype.of(store).verdict(call), 'open (the default): M.use is exported — an outside caller may pass anything')
    vim.fn.delete(root, 'rf') -- (after: the analysis reads the sources)
end)

test('effects by flow: a joined call flow decides takes ITS target — not every same-named candidate\'s writes', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local effects = require 'cartograph.effects'
    local root = tree({
        ['a.lua'] = 'local A = {}\nlocal hits = 0\nfunction A.get() hits = hits + 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nlocal seen = 0\nfunction B.get() seen = seen + 1 end\nreturn B\n',
        ['main.lua'] = 'local function reader(src)\n  return { get = function (i) return i end }\nend\nlocal function first(src)\n  local r = reader(src)\n  return r.get(1)\nend\nreturn first\n',
    })
    store.ingest(ts.extract(root))
    local first
    for _, n in ipairs(store.data.nodes) do if n.name == 'first' then first = n end end
    store._fx = nil
    local by_name = effects.purity(store, first.id)
    store._fx = nil
    effects.FLOW = true
    local ok_, by_flow = pcall(effects.purity, store, first.id)
    effects.FLOW = nil
    store._fx = nil
    vim.fn.delete(root, 'rf')
    ok(ok_, tostring(by_flow))
    eq('writes~', by_name, 'the name join takes A.get and B.get: their writes')
    eq('pure~', by_flow, 'by flow, r.get is the record\'s closure: no write (a premise: ~)')
end)

-- ★ THE GO WALKER, the language the type checker can SCORE (tools/experiments/flowtype_oracle: on helm, 709 exact,
-- 0 wrong): declared types are ignored — an allocation names its type (`&T{…}` carries T's methods), embedding
-- promotes, the rest flows. Two types both declare `Get` / `Base` / `Run`: every call below is decided by what reaches it
test('flowtype (go): a method reached through a constructor, an embedded type, a map range, a struct field', function ()
    if not parser_available('go') then skip 'no go parser' end
    local root = tree({
        ['go.mod'] = 'module example.com/m\n\ngo 1.22\n',
        ['p/p.go'] = table.concat({
            'package p',
            'type S struct{ n int }',
            'func (s S) Base() int { return s.n }',
            'type T struct {',
            '\tS',
            '\tname string',
            '}',
            'func (t *T) Get(i int) (int, error) { return i, nil }',
            'type U struct{ S }',
            'func (u *U) Get(i int) (int, error) { return -i, nil }',
            'func (u *U) Base() int { return 0 }',
            'type Runner interface{ Run() }',
            'type R1 struct{}',
            'func (R1) Run() {}',
            'type R2 struct{}',
            'func (R2) Run() {}',
            'type Holder struct{ r Runner }',
            'func New(name string) *T { return &T{name: name} }',
            'func use() {',
            '\tt := New("x")',
            '\tv, err := t.Get(1)',
            '\t_, _ = v, err',
            '\tm := map[string]*T{"a": t}',
            '\tfor _, x := range m {',
            '\t\tx.Base()',
            '\t}',
            '\th := Holder{r: R1{}}',
            '\th.r.Run()',
            '}',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.member .. '@' .. p.line] = p end
    local function one(key, pat, why)
        local p = by[key]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('Get@20', 'T%.Get', 't := New(...): *T\'s Get, not U\'s')
    one('Base@24', 'S%.Base', 'a *T from the map, Base promoted from the embedded S — not U.Base')
    one('Run@27', 'R1%.Run', 'the field holds an R1: R1.Run, not R2.Run (the declared type is only the interface)')
end)

-- ★ THE ALLOCATIONS A GO PROGRAM MAKES WITHOUT A LITERAL (scored on helm: exact-right 709 -> 1063, still 0 wrong): a
-- zero value `var x T`, a typed const (and its iota successors), a conversion `T(x)`, and a method's RECEIVER (a T,
-- always: Go has no struct subtyping). Two types each declare every method named below
test('flowtype (go): zero values, typed consts, conversions and the receiver are allocations of their type', function ()
    if not parser_available('go') then skip 'no go parser' end
    local root = tree({
        ['go.mod'] = 'module example.com/m\n\ngo 1.22\n',
        ['p/p.go'] = table.concat({
            'package p',
            'type labels map[string]string',
            'func (l *labels) init() { *l = labels{} }',
            'type other map[string]int',
            'func (o *other) init() {}',
            'type Status string',
            'func (s Status) String() string { return string(s) }',
            'type Kind string',
            'func (k Kind) String() string { return string(k) }',
            'const (',
            '\tDeployed Status = "deployed"',
            '\tFailed',
            ')',
            'type T struct{}',
            'func (t *T) Get() int { return 1 }',
            'func (t *T) Twice() int { return t.Get() }',
            'type U struct{}',
            'func (u *U) Get() int { return 2 }',
            'func use() {',
            '\tvar lb labels',
            '\tlb.init()',
            '\t_ = Failed.String()',
            '\t_ = Status("x").String()',
            '}',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.member .. '@' .. p.line] = p end
    local function one(key, pat, why)
        local p = by[key]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('init@20', 'labels%.init', 'var lb labels: a zero labels value')
    one('String@21', 'Status%.String', 'Failed repeats the iota block\'s type: a Status')
    one('String@22', 'Status%.String', 'a conversion Status("x") is a Status')
    one('Get@15', 'T%.Get', 'inside T\'s method the receiver is a T')
end)

-- ★ A TYPE ASSERTION IS A RUNTIME TYPE CHECK, so it FILTERS: through an `any` both T and U arrive, and `x.(*T)` /
-- `case *T:` pass only the T (on helm, tests included: the one wrong exact — v2's Validate for a v3 call — gone)
test('flowtype (go): x.(*T) and a one-type `case *T:` keep only the T that flows through an `any`', function ()
    if not parser_available('go') then skip 'no go parser' end
    local root = tree({
        ['go.mod'] = 'module example.com/m\n\ngo 1.22\n',
        ['p/p.go'] = table.concat({
            'package p',
            'type T struct{}',
            'func (t *T) Get() int { return 1 }',
            'type U struct{}',
            'func (u *U) Get() int { return 2 }',
            'func pass(x any) any { return x }',
            'func use() {',
            '\ta := pass(&T{})',
            '\t_ = pass(&U{})',
            '\tt := a.(*T)',
            '\t_ = t.Get()',
            '\tswitch v := a.(type) {',
            '\tcase *U:',
            '\t\t_ = v.Get()',
            '\t}',
            '}',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.member .. '@' .. p.line] = p end
    local t, u = by['Get@10'], by['Get@13']
    eq('exact', t and t.kind, 'the assertion passes only the T: ' .. vim.inspect(t))
    ok(t and t.targets[1]:match('T%.Get'), vim.inspect(t and t.targets))
    eq('exact', u and u.kind, 'the case clause passes only the U: ' .. vim.inspect(u))
    ok(u and u.targets[1]:match('U%.Get'), vim.inspect(u and u.targets))
end)

-- ★ THE JS / TS WALKER (scored by the TypeScript checker, tools/experiments/flowtype_oracle/ts: on
-- typescript-language-server 661 of 759 class-method calls exact-right, 0 wrong; turborepo 213, 0 wrong). Types are
-- ignored: `new C()` takes C's prototype, `this` inside C's method is a C, a static is the class's own, an imported
-- name is the module's export. Two classes declare `get`: every call below is decided by flow
test('flowtype (ts): new, this, statics, imports and object literals decide a member call', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local root = tree({
        ['src/a.ts'] = table.concat({
            'export class A {',
            '  get(): number { return 1; }',
            '  run(): number { return this.get(); }',
            '  static make(): A { return new A(); }',
            '}',
            'export class B {',
            '  get(): number { return 2; }',
            '}',
        }, '\n'),
        ['src/b.ts'] = table.concat({
            "import { A } from './a';",
            'const a = A.make();',
            'a.get();',
            'const o = { get: () => 3 };',
            'o.get();',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.file .. ':' .. p.member .. '@' .. p.line] = p end
    local function one(key, pat, why)
        local p = by[key]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('src/a.ts:get@2', 'A%.get', 'this inside A.run is an A')
    one('src/b.ts:make@1', 'make', 'A.make: the imported class\'s static')
    one('src/b.ts:get@2', 'A%.get', 'a = A.make() = new A(): A.get, not B.get')
    one('src/b.ts:get@4', 'b%.ts::', 'the object literal\'s own arrow function')
end)

-- ★ `x instanceof C` NARROWS THE FLOW, not only the verdict (arktype, scored: `if (out instanceof ArkErrors)
-- out.transform(e => e.transform(...))` had handed the callback to BaseNode.transform too, so `e` held BaseNodes and
-- `e.transform` read wrong). Inside the branch x is a port of C's instances among x's — solved to a fixpoint
test('flowtype (ts): inside `if (x instanceof B)` and `x instanceof B ? …` x holds only the B instances', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local root = tree({
        ['src/m.ts'] = table.concat({
            'class Leaf { visit(f: (x: Leaf) => void): void { f(this); } name(): string { return "leaf"; } }',
            'class Node2 { visit(f: (x: Node2) => void): void { f(this); } name(): string { return "node"; } }',
            'function pick(k: number) { return k > 0 ? new Leaf() : new Node2(); }',
            'const v = pick(1);',
            'if (v instanceof Leaf) {',
            '  v.visit(x => x.name());',
            '}',
            'const w = v instanceof Node2 ? v.name() : "";',
            'const u = v instanceof Node2 ? v.visit(y => y.name()) : 0;',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.member .. '@' .. p.line .. ':' .. p.col] = p end
    local function one(key, pat, why)
        local p = by[key]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('visit@5:2', 'Leaf%.visit', 'the branch sees only the Leaf')
    one('name@5:15', 'Leaf%.name', 'and so does the callback it hands Leaf.visit: x is a Leaf, never a Node2')
    one('name@7:31', 'Node2%.name', 'the ternary consequence sees only the Node2')
    one('name@8:44', 'Node2%.name', 'and the callback it hands Node2.visit holds only Node2s')
end)

-- ★ a TS NAMESPACE is an object of its exports, a barrel's `export * from` / `export { a as b } from` re-exports,
-- and a bare specifier resolves through tsconfig `paths` (typebox-codegen, scored: `Formatter.Format(…)` from
-- `export namespace Formatter`, reached via `export * from './formatter'` and `@sinclair/typebox-codegen` → src/index.ts:
-- 12 → 183 of 183 exact-right). A call inside a template string's `${…}` is a probe too
test('flowtype (ts): namespaces, re-exports, tsconfig paths and template substitutions reach the function', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local root = tree({
        ['tsconfig.json'] = table.concat({
            '{ "compilerOptions": {',
            '  // JSONC: a comment and a trailing comma',
            '  "paths": { "@pkg": ["src/index.ts"], "@lib/*": ["src/lib/*"], },',
            '} }',
        }, '\n'),
        ['src/lib/fmt.ts'] = 'export namespace Fmt { export function format(s: string) { return s; } }',
        ['src/lib/enc.ts'] = 'export namespace Enc { export function encode(s: string) { return s; } }',
        ['src/index.ts'] = "export * from './lib/fmt'\nexport { Enc as E } from '@lib/enc'",
        ['example/use.ts'] = table.concat({
            "import * as P from '@pkg'",
            'const a = P.Fmt.format("x")',
            'const b = `<${P.E.encode("y")}>`',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do if p.file == 'example/use.ts' then by[p.member] = p end end
    local function one(m, pat, why)
        local p = by[m]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('format', '^src/lib/fmt%.ts::.*format', 'P.Fmt.format: paths → the barrel → export * → the namespace')
    one('encode', '^src/lib/enc%.ts::.*encode', 'P.E.encode: an aliased re-export through `@lib/*`, inside `${…}`')
end)

-- ★ OCCLUDING THE TYPES is an instrument: flowtype on a tree with every type blanked (positions kept) must answer as
-- on the typed tree — it reads no type. Its first run found two places where TYPES STILL CHANGED THE ANSWER:
-- tree-sitter-typescript parses `await c.m<T>(…)` as `(await c.m)<T>(…)`, so the typed call had no probe at all
-- (typescript-language-server: withProgress, getWorkspaceConfiguration); and a 17th parameter indexed past the fixed
-- 16 parameter ports and crashed the walk (arktype's tests)
test('flowtype (ts): a generic call under await is a probe, and a function may take more than 16 parameters', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local ps = {}
    for k = 1, 18 do ps[#ps + 1] = 'p' .. k end
    local root = tree({
        ['src/m.ts'] = table.concat({
            'class C { async w<T>(x: T): Promise<T> { return x; } }',
            'const c = new C();',
            'async function f() { return await c.w<number>(1); }',
            'function many(' .. table.concat(ps, ', ') .. ') { return p18; }',
            'const r = many(' .. table.concat(ps, ', '):gsub('p%d+', '0') .. ');',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local p
    for _, x in ipairs(R.probes) do if x.member == 'w' then p = x end end
    eq('exact', p and p.kind, 'the awaited generic call is a probe: ' .. vim.inspect(p))
    ok(p and p.targets[1]:match('C%.w'), vim.inspect(p and p.targets))
end)

-- ★ `setmetatable(t, { __index = idx })` links t's objects to idx's whichever side arrives LAST (CART-1621): the link
-- was made only when t gained an object, so an __index table whose value flowed in later was never a prototype — a
-- missed flow, and an ORDER-dependent one (here: lost under the ascending and FIFO schedules, kept under the others).
-- And `require` reaches its module at all: the import edge's range is an index once ingest FOLDS it, and a table-only
-- guard had left every require unresolved since flowtype shipped
test('flowtype: an __index table that receives its value after the object becomes its prototype, in every order', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.hello(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.hello(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local holder = { k = 1 }',
            'local t = setmetatable({ n = 0 }, { __index = holder.base })',
            'holder.base = require "a"',
            'return t:hello()',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local got = {}
    for _, order in ipairs({ 'desc', 'asc', 'lifo', 'fifo' }) do
        local R = flowtype.solve(store, { open = false, order = order })
        for _, c in ipairs(store.data.calls) do if callrec.file(c) == 'main.lua' and c.refused then got[order] = R.verdict(c) end end
    end
    vim.fn.delete(root, 'rf')
    for _, order in ipairs({ 'desc', 'asc', 'lifo', 'fifo' }) do
        local v = got[order]
        eq('exact', v and v.kind, order .. ': t:hello() through the late __index: ' .. vim.inspect(v))
        ok(v and tostring(v.targets[1]):match('A%.hello'), order .. ': ' .. vim.inspect(v and v.targets))
    end
end)

-- ★ AN UNRELATED FILE MOVES NO ANSWER (CART-1621). A port that saturates mid-solve has handed downstream whatever it
-- held when it was processed, so the schedule decides the answer. A stack's order followed port numbers (through
-- `pairs` over integer-keyed sets), and adding ANY file shifts every number — arktype: 127 of 7917 answers in untouched
-- files moved when one 3-line file was added, and the per-process string hash moved them run to run (456 / 413 / 422
-- exact). The worklist is now a heap over a stable order. Fixture: tests/fixtures/flowsched, delta-debugged from
-- arktype to the 151 lines where a comment-only file still moved an answer under the stack
test('flowtype: adding an unrelated file moves no answer — under any worklist order (CART-1741)', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local FIX = vim.fn.getcwd() .. '/tests/fixtures/flowsched/ark/schema/shared/'
    local files = {}
    for _, f in ipairs({ 'errors.ts', 'traversal.ts' }) do
        files['ark/schema/shared/' .. f] = assert(io.open(FIX .. f)):read('a')
    end
    local function answers(extra, order)
        local fs = vim.deepcopy(files)
        if extra then fs['aaa_unrelated.ts'] = '// nothing\n' end
        local root = tree(fs)
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, order = order })
        vim.fn.delete(root, 'rf')
        local out, n = {}, 0
        for _, p in ipairs(R.probes) do
            if p.file:match('^ark/') then
                out[p.file .. ':' .. p.line .. ':' .. p.col] = p.kind .. ' ' .. table.concat(p.targets, ','); n = n + 1
            end
        end
        return out, n
    end
    local function moved(a, b) local m = 0 for k, v in pairs(a) do if b[k] ~= v then m = m + 1 end end return m end
    local a, n = answers(false)
    ok(n >= 5, 'the fixture has answers: ' .. n)
    eq(0, moved(a, (answers(true))), 'the default schedule: nothing moves')
    -- (and NO order moves one: the stack order (lifo) had, through a port saturating while queued that then saturated
    -- its successors when popped — schedule-made saturation, gone with CART-1741. Restoring that spread makes lifo move
    -- an answer again here, which keeps this fixture live)
    for _, order in ipairs { 'asc', 'lifo', 'fifo' } do
        eq(0, moved((answers(false, order)), (answers(true, order))), order .. ': nothing moves')
    end
end)

-- ★ PARTIAL (CART-1643): the stable schedule made a saturated port's leak REPRODUCIBLE, not whole — what it held went
-- downstream, what came after was lost. An answer read through a port the cap may have left incomplete is `partial`;
-- one that is not is a function of the graph: the same under every schedule, and the same with a bigger cap. Measured
-- on arktype / lua/cartograph: every answer that varied by schedule was flagged (268 / 13), no unflagged answer changed
-- at CAP 256 (283 / 445), while 192 / 150 flagged ones did
test('flowtype: a non-partial answer is the same under every schedule and a bigger cap; what varies is flagged', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local FIX = vim.fn.getcwd() .. '/tests/fixtures/flowsched/ark/schema/shared/'
    local files = {}
    for _, f in ipairs({ 'errors.ts', 'traversal.ts' }) do files['ark/schema/shared/' .. f] = assert(io.open(FIX .. f)):read('a') end
    local root = tree(files)
    store.ingest(ts.extract(root))
    local function rows(order)
        local out = {}
        for _, p in ipairs(flowtype.solve(store, { open = false, order = order }).probes) do
            out[p.file .. ':' .. p.line .. ':' .. p.col] = { a = p.kind .. ' ' .. table.concat(p.targets, ','), partial = p.partial }
        end
        return out
    end
    local cap = flowtype.CAP
    flowtype.CAP = 3 -- (a small cap: this fixture saturates at once)
    local runs = {}
    for _, o in ipairs({ 'desc', 'asc', 'lifo', 'fifo' }) do runs[o] = rows(o) end
    flowtype.CAP = 64
    local big = rows()
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    local npartial, nwhole = 0, 0
    for k, x in pairs(runs.desc) do
        if x.partial then npartial = npartial + 1 else nwhole = nwhole + 1 end
        local varies = false
        for _, o in ipairs({ 'asc', 'lifo', 'fifo' }) do
            local y = runs[o][k]
            if y and y.a ~= x.a then varies = true end
            if y and not x.partial and not y.partial then eq(x.a, y.a, k .. ': non-partial under desc and ' .. o) end
        end
        if varies then ok(x.partial, k .. ' varies by schedule, so it is partial') end
        if not x.partial and not x.a:match('^none') then eq(x.a, big[k] and big[k].a, k .. ': non-partial at CAP 3 holds at CAP 64') end
    end
    ok(npartial > 0 and nwhole > 0, ('both kinds occur: %d partial, %d whole'):format(npartial, nwhole))
end)

-- ★ THE ARRAY PART `#` (CART-1643): what a NUMBER key stores (t[i] in a numeric for, t[#t + 1], table.insert, a
-- positional constructor field) is no field NAME, so `t.handler` does not read it — while a key we cannot type (`t[k]`)
-- may be any name, and still reaches every named load. On lua/cartograph `[]` had been the commonest saturated hub
test('flowtype: a list built into a table does not reach its named fields; an untyped key still does', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local A, B = require "a", require "b"',
            'local reg = { handler = A, B }',
            'for i = 1, 3 do reg[i] = B end',
            'reg[#reg + 1] = B; reg[#reg] = B',
            'table.insert(reg, B)',
            'local one = reg.handler:run()',
            'local dyn = { handler = A }',
            'local function put(k) dyn[k] = B end',
            'put("handler")',
            'local two = dyn.handler:run()',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' and c.refused and c.at then v[atr.sl(c.at)] = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    eq('exact', v[5] and v[5].kind, 'reg.handler:run() — the list of Bs is not the field: ' .. vim.inspect(v[5]))
    ok(v[5] and tostring(v[5].targets[1]):match('A%.run'), vim.inspect(v[5] and v[5].targets))
    ok(not (v[9] and v[9].kind == 'exact'), 'dyn[k] = B may write `handler`: no exact claim — ' .. vim.inspect(v[9]))
end)

-- ★ A LOAD THROUGH A TAINTED FIELD IS PARTIAL (CART-1643): field reads are implicit — an object keeps the loads that
-- read it (96% of all edges were object x load, 339 MB on lua/cartograph) — so taint reaches a load through the same
-- readers. Here `put` saturates (CAP 2), box escapes into it, and box.handler may have been written there unseen
test('flowtype: a load of a field the cap may have left incomplete is partial', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local A, B = require "a", require "b"',
            'local box = { handler = A }',
            'local function put(t, v) t.handler = v end',
            'put(box, A); put({ n = 1 }, B); put({ n = 2 }, B)',
            'local x = box.handler',
            'return x:run()',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local R = flowtype.solve(store, { open = false })
    flowtype.CAP = cap
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' and c.refused and c.at and atr.sl(c.at) == 5 then v = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    ok(v ~= nil, 'x:run() is answered')
    eq(true, v and v.partial, 'box.handler may hold what put wrote unseen: ' .. vim.inspect(v))
end)

-- ★ A STRING METHOD ON AN EMPTY RECEIVER (CART-1643): nothing reaches `name`, but a program past `name:lower()` had a
-- string there — the result is a string, hedged (partial). A receiver the solve DID fill keeps its own answer
test('flowtype: a string method on an empty receiver returns the string library\'s type, partial', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.find(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.find(self) return 2 end\nreturn B\n',
        ['main.lua'] = 'local function f(name)\n  local l = name:lower()\n  return l:find("x")\nend\nreturn f\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.file(c) == 'main.lua' and tostring(callrec.full(c)) == 'l:find' then v = R.verdict(c) end end
    eq('string', v and v.kind, 'what :lower() returns: ' .. vim.inspect(v))
    eq(true, v and v.partial, 'the evidence is the call, not a flow: hedged')
end)

-- ★ A GENERIC RETURN IS ITS ARGUMENT (CART-1653): `assert(v: T, …): T` returns v. Read as an object of a type named T
-- the algebra table never reached `A().node(…)` — 48 empty receivers on lua/cartograph
test('flowtype: a profile function returning its generic parameter (assert) returns the argument, not a type named T', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['main.lua'] = 'local A = require "a"\nlocal x = assert(A, "no a")\nreturn x:run()\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.file(c) == 'main.lua' and tostring(callrec.full(c)) == 'x:run' then v = R.verdict(c) end end
    eq('exact', v and v.kind, 'assert hands A through: ' .. vim.inspect(v))
    ok(v and v.targets[1] == 'a.lua::A.run@1', vim.inspect(v))
end)

-- ★ SELECTIVE CONTEXT SENSITIVITY (CART-1653): a function whose parameter SATURATES upstream of an unknown answer gets
-- an instance per resolved call site, walked inside the scopes it was defined in (a closure: `use` reads `count`), and
-- a call in it is answered over its instances. At CAP 2 the merged `x` holds A and two plain tables: saturated, no
-- claim; each instance holds one, and of the three only A has `run`
test('flowtype: a closure whose parameter saturates gets an instance per call site — its call is answered over them (CART-1653)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local A = require "a"',
            'local count = 0',
            'local function use(x)',
            '  count = count + 1',
            '  x:run()',
            '  return A',
            'end',
            'use(A); use({ n = 1 })',
            'local r = use({ n = 2 })',
            'return r:run()',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local merged = flowtype.solve(store, { open = false, ctx = false })
    local split = flowtype.solve(store, { open = false })
    -- (the instances are keyed on the selecting solve's FLOW, never on the name join's c.to — CART-1715: with every
    -- claim erased the answers are the same)
    local saved = {}
    for i, x in ipairs(store.data.calls) do saved[i] = x.to; x.to = nil end
    local unjoined = flowtype.solve(store, { open = false })
    for i, x in ipairs(store.data.calls) do x.to = saved[i] end
    -- (the BUDGET, CART-1788: a selected function re-walked at every site may not cost more than the tree — scaled to 0
    -- here, `use` is cut and the answer is the one walk's)
    local cut = flowtype.solve(store, { open = false, ctxbudget = 0 })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local c, rc
    for _, x in ipairs(store.data.calls) do
        if callrec.file(x) == 'main.lua' and tostring(callrec.full(x)) == 'x:run' then c = x end
        if callrec.file(x) == 'main.lua' and tostring(callrec.full(x)) == 'r:run' then rc = x end
    end
    ok(c ~= nil, 'the call x:run() is in the graph')
    eq(nil, merged.verdict(c), 'one walk: x saturates, no claim')
    local v = split.verdict(c)
    eq('exact', v and v.kind, 'instances: ' .. vim.inspect(v))
    ok(v and v.targets[1] == 'a.lua::A.run@1', 'A.run, the only receiver with run: ' .. vim.inspect(v))
    ok((split.stats.ctxfns or 0) >= 1, 'use was selected: ' .. tostring(split.stats.ctxfns))
    -- (the instance sees the scopes `use` was defined in: its upvalue A is the module, not a global)
    local rv = split.verdict(rc)
    eq('exact', rv and rv.kind, 'what an instance returns from its upvalue: ' .. vim.inspect(rv))
    eq(vim.inspect(v), vim.inspect(unjoined.verdict(c)), 'no c.to: the same instances')
    eq(vim.inspect(rv), vim.inspect(unjoined.verdict(rc)), 'no c.to: the same return')
    eq(nil, cut.verdict(c), 'over the budget: no instances, the one walk\'s answer')
end)

-- ★ WHAT AN ESCAPED OBJECT HOLDS ESCAPES WITH IT (CART-1643): a call through a tainted callee taints the parameters of
-- every escaped function — but the function is often not what escaped: here a P instance reaches `keep`'s saturated
-- parameter, and `r.go(q)` would read P's method `go` through it, binding q to its o. The instance escaped, its metatable
-- and the metatable's methods did not, so `o:hit()` read exact P:hit (uncapped: P:hit and Q:hit) — and under another
-- schedule it was not (lua/cartograph's ir.lua P:skip_group: exact under desc, saturated under asc)
test('flowtype: a method reached only through an escaped object has partial parameters', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['main.lua'] = table.concat({
            'local P = {}; P.__index = P',
            'function P:hit() return 1 end',
            'function P.go(o) return o:hit() end',
            'local Q = {}; Q.__index = Q',
            'function Q:hit() return 2 end',
            'function Q.go(o) return 0 end',
            'local function keep(x) return x end',
            'keep(setmetatable({}, P)); keep({}); keep({})',
            'local q = setmetatable({}, Q)',
            'local r = keep(setmetatable({}, P))',
            'r.go(q)',
            'P.go(setmetatable({}, P))',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local R = flowtype.solve(store, { open = false })
    flowtype.CAP = cap
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' and c.refused and c.at and atr.sl(c.at) == 2 then v = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    ok(v ~= nil, 'o:hit() is answered')
    eq(true, v and v.partial, 'go may get q, unseen: ' .. vim.inspect(v))
end)

-- ★ DENSE SETS ARE THE SAME SETS (CART-1643): past M.BIG objects a set and its delta become bitsets, moved word by word
-- — the complete solve of arktype went 707 s -> ~186 s with every answer unchanged. Under the default cap no set gets
-- that big, so this solves uncapped with BIG forced down (dense almost everywhere) and up (never), and every answer —
-- probes and Lua verdicts — must be the same
test('flowtype: dense (bitset) sets give exactly the answers hash sets give', function ()
    if not parser_available('typescript') or not parser_available('lua') then skip 'no parsers' end
    local FIX = vim.fn.getcwd() .. '/tests/fixtures/flowsched/ark/schema/shared/'
    local files = {}
    for _, f in ipairs({ 'errors.ts', 'traversal.ts' }) do files['ark/schema/shared/' .. f] = assert(io.open(FIX .. f)):read('a') end
    -- (and a Lua part with fan-in: many tables through one helper)
    local L = { 'local M = {}', 'local function keep(x) return x end', 'local out = {}' }
    for i = 1, 40 do L[#L + 1] = ('out[%d] = keep({ id = %d, run = function () return %d end })'):format(i, i, i) end
    L[#L + 1] = 'for _, x in ipairs(out) do local r = x.run() end'
    L[#L + 1] = 'return M'
    files['lib/many.lua'] = table.concat(L, '\n')
    local root = tree(files)
    store.ingest(ts.extract(root))
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local function rows()
        local R = flowtype.solve(store, { open = false })
        local out = {}
        for _, p in ipairs(R.probes) do out[#out + 1] = p.file .. ':' .. p.line .. ':' .. p.col .. ' ' .. p.kind .. ' ' .. table.concat(p.targets, ',') end
        for _, c in ipairs(store.data.calls) do
            local v = R.verdict(c)
            if v and c.at then out[#out + 1] = callrec.file(c) .. ':' .. atr.sl(c.at) .. ' ' .. v.kind .. ' ' .. table.concat(v.targets or {}, ',') end
        end
        table.sort(out)
        return out, R.stats.ports
    end
    local cap, big = flowtype.CAP, flowtype.BIG
    flowtype.CAP = 1e9
    flowtype.BIG = 1e9
    local hashed = rows()
    flowtype.BIG = 2
    local dense = rows()
    flowtype.CAP, flowtype.BIG = cap, big
    vim.fn.delete(root, 'rf')
    ok(#hashed > 10, 'the fixture answers: ' .. #hashed)
    eq(hashed, dense, 'the same answers, dense or not')
end)

-- ★ VALUES FROM OUTSIDE THE TREE (CART-1643): on lua/cartograph most ambiguous calls with nothing at the receiver held
-- values from nvim's API — tree-sitter nodes, strings. The environment profile types them (`vim.split` -> string[]),
-- and a value read out of a container type is its ELEMENT type: `parts[1]` is a string, so `parts[1]:upper()` is the
-- string method, neither in-tree `upper`
test('flowtype: an element read out of a profile-typed container has the element type', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        -- (laid out as an nvim plugin: that SHAPE is what composes the nvim profile in)
        ['lua/fx/a.lua'] = 'local A = {}\nfunction A.upper(s) return s end\nreturn A\n',
        ['lua/fx/b.lua'] = 'local B = {}\nfunction B.upper(s) return s end\nreturn B\n',
        ['lua/fx/main.lua'] = 'local parts = vim.split("a,b", ",")\nlocal p = parts[1]\nreturn p:upper()\n',
        ['plugin/fx.lua'] = 'require("fx.main")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and atr.sl(c.at) == 2 then v = R.verdict(c); refused = c.refused end
    end
    vim.fn.delete(root, 'rf')
    if not refused then skip('the extractor already decides p:upper() (profile ' .. tostring(store.data.profile) .. ')') end
    eq('string', v and v.kind, 'parts[1] is a string: ' .. vim.inspect(v) .. ' profile ' .. tostring(store.data.profile))
end)

-- ★ MULTIPLE VALUES (CART-1643): Lua's walker gave every call ONE value and bound a generic for's variables to nothing
-- unless it was pairs / ipairs — so `local ok, parser = pcall(get_string_parser, …)` left parser empty, `return i, c`
-- lost c, and `for _, c in tsutil.inext, node, -1` / `for c in node:iter_children()` (the profile's `fun(): TSNode,
-- string`) left c empty. On lua/cartograph the generic for alone took the empty receivers 1441 -> 975 and the typed
-- verdicts 14 -> 381
test('flowtype: multiple values — pcall, a second return, an iterator in the tree and a typed one', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = table.concat({
            'local A = {}; A.__index = A',
            'function A:run() return 1 end',
            'function A:type() return 1 end',
            'local B = {}; B.__index = B',
            'function B:run() return 2 end',
            'function B:type() return 2 end',
            'local function two() return 1, setmetatable({}, A) end',
            'local function inext(t, i) i = i + 1; local v = t[i]; if v then return i, v end end',
            'local function scan(src)',
            '    local ok, x = pcall(function () return setmetatable({}, A) end)',
            '    local r1 = x:run()',
            '    local _, y = two()',
            '    local r2 = y:run()',
            '    for _, z in inext, { setmetatable({}, B) }, 0 do local r3 = z:run() end',
            '    local p = vim.treesitter.get_string_parser(src, "lua")',
            '    local t = p:parse()',
            '    local root = t[1]:root()',
            '    for c in root:iter_children() do local k = c:type() end',
            '    return r1, r2',
            'end',
            'return scan',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.a")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/a.lua' and c.refused and c.at then v[atr.sl(c.at) + 1] = R.verdict(c) or false end
    end
    vim.fn.delete(root, 'rf')
    local function one(line, want, what)
        local x = v[line]
        ok(x, what .. ': answered — ' .. vim.inspect(x))
        if want == 'TSNode' then eq('typed', x and x.kind, what); eq('TSNode', x and x.type, what)
        else eq('exact', x and x.kind, what); ok(x and tostring(x.targets[1]):match(want), what .. ': ' .. vim.inspect(x)) end
    end
    one(11, 'A:run', "pcall's second value is the function's first")
    one(13, 'A:run', 'the second return')
    one(14, 'B:run', "an iterator in the tree: inext's second value")
    one(18, 'TSNode', "a typed iterator: iter_children's first value")
end)

-- ★ A REQUIRE THE GRAPH HAS NO IMPORT EDGE FOR (CART-1643): `pcall(require, 'cartograph.algebra.core')` passes require
-- as a VALUE, and cartograph.algebra's whole API comes out of that one call (M.load()). A literal module name now
-- resolves by Lua's path convention (lua/a/b.lua, lua/a/b/init.lua) to a file in the tree: on lua/cartograph exact
-- verdicts 279 -> 387, and the runtime oracle saw 57 more executed exact answers right, 0 wrong
test('flowtype: pcall(require, "m") reaches module m', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/core.lua'] = 'local M = {}\nfunction M.run() return 1 end\nreturn M\n',
        ['lua/fx/other.lua'] = 'local O = {}\nfunction O.run() return 2 end\nreturn O\n',
        ['lua/fx/main.lua'] = table.concat({
            'local ok, A = pcall(require, "fx.core")',
            'local function load() return A end',
            'return load().run()',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.main"); require("fx.other")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and atr.sl(c.at) == 2 and (callrec.callee(c) == 'run') then v = R.verdict(c); refused = c.refused end
    end
    vim.fn.delete(root, 'rf')
    if not refused then skip 'the extractor already decides load().run()' end
    eq('exact', v and v.kind, vim.inspect(v))
    ok(v and tostring(v.targets[1]):match('core%.lua::M%.run'), vim.inspect(v and v.targets))
end)

-- ★ AN OBJECT WITHOUT THE MEMBER IS NOT THE RECEIVER (CART-1643): `x:upper()` on a table that has no `upper` raises,
-- so a program past the call held the string there. The exact answer always read a call that way; a string beside
-- such a table read `none` (275 of lua/cartograph's non-empty `none` receivers). A table that holds functions under a
-- key the walk could not name (`t[k] = f`) may have the member: no claim
test('flowtype: a receiver object lacking the member is excluded; one with unnamed function keys is not', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = 'local A = {}\nfunction A.upper(s) return s end\nreturn A\n',
        ['lua/fx/b.lua'] = 'local B = {}\nfunction B.upper(s) return s end\nreturn B\n',
        ['lua/fx/main.lua'] = table.concat({
            'local M = {}',
            'function M.pick(c) if c then return "text" end return { n = 1 } end',
            'local x = M.pick(true)',
            'local r1 = x:upper()',
            'local dyn = { n = 2 }',
            'function M.put(k) dyn[k] = function () return 1 end end',
            'function M.pick2(c) if c then return "text" end return dyn end',
            'local y = M.pick2(true)',
            'local r2 = y:upper()',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.main"); require("fx.a"); require("fx.b")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused = {}, {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and callrec.callee(c) == 'upper' then
            v[atr.sl(c.at) + 1] = R.verdict(c) or false; refused[atr.sl(c.at) + 1] = c.refused
        end
    end
    vim.fn.delete(root, 'rf')
    if not refused[4] or not refused[9] then skip 'the extractor already decides the upper() calls' end
    eq('string', v[4] and v[4].kind, 'the table has no upper: ' .. vim.inspect(v[4]))
    eq(false, v[9], 'dyn may hold upper under a key the walk cannot name: ' .. vim.inspect(v[9]))
end)

-- (…and an ESCAPED object without the member may have gained it where the solve no longer follows it: the answer
-- that excludes it is partial)
test('flowtype: excluding an escaped receiver object that lacks the member makes the answer partial', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = 'local A = {}\nfunction A.upper(s) return s end\nreturn A\n',
        ['lua/fx/b.lua'] = 'local B = {}\nfunction B.upper(s) return s end\nreturn B\n',
        ['lua/fx/main.lua'] = table.concat({
            'local M = {}',
            'local t = { n = 1 }',
            'local function keep(v) return v end',
            'keep(t); keep({ n = 2 }); keep({ n = 3 })',
            'function M.pick(c) if c then return "text" end return t end',
            'local x = M.pick(true)',
            'local r1 = x:upper()',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.main"); require("fx.a"); require("fx.b")\n',
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local R = flowtype.solve(store, { open = false })
    flowtype.CAP = cap
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and atr.sl(c.at) == 6 then v = R.verdict(c); refused = c.refused end
    end
    vim.fn.delete(root, 'rf')
    if not refused then skip 'the extractor already decides x:upper()' end
    eq('string', v and v.kind, vim.inspect(v))
    eq(true, v and v.partial, 't escaped into keep: it may have gained upper unseen — ' .. vim.inspect(v))
end)

-- ★ OPEN REACHES PAST THE EXPORTS (CART-1652): an outside caller can call a method on what an exported function
-- RETURNS — `M.b():go()` runs A:go with a B instance, though the tree itself only ever calls `M.a():go()`. Open, the
-- answer inside A:go is partial; closed (only the tree's own callers), it stays whole
test('flowtype: open — a method reached through an exported return has partial parameters', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = table.concat({
            'local M = {}',
            'local A = {}; A.__index = A',
            'function A:hit() return 1 end',
            'function A:go() return self:hit() end',
            'local B = setmetatable({}, { __index = A }); B.__index = B',
            'function B:hit() return 2 end',
            'function M.a() return setmetatable({}, A) end',
            'function M.b() return setmetatable({}, B) end',
            'M.a():go()',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.a")\n',
    })
    store.ingest(ts.extract(root))
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local function at3(R)
        for _, c in ipairs(store.data.calls) do
            if callrec.file(c) == 'lua/fx/a.lua' and c.at and atr.sl(c.at) == 3 and c.refused then return R.verdict(c), true end
        end
    end
    local vo, ro = at3(flowtype.solve(store, {}))
    local vc = at3(flowtype.solve(store, { open = false }))
    vim.fn.delete(root, 'rf')
    if not ro then skip 'the extractor already decides self:hit()' end
    eq('exact', vc and vc.kind, 'closed: ' .. vim.inspect(vc))
    eq(nil, vc and vc.partial, 'closed: whole')
    eq(true, vo and vo.partial, 'open: an outside caller may run go with a B — ' .. vim.inspect(vo))
end)

-- ★ A PROFILE FUNCTION AS A VALUE (CART-1643): `pcall(vim.treesitter.get_string_parser, src, lang)` — 65 of
-- lua/cartograph's tree-sitter entry points — passes the function, and a load off the global `vim` held nothing, so no
-- parser, tree or node existed downstream. A dotted reference rooted at a GLOBAL that names a profile signature holds its
-- function type; a local of the root's name is not the profile's
test('flowtype: a profile function passed as a value returns its declared type; a shadowing local does not', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = 'local A = {}\nfunction A:root() return self end\nfunction A:parse() return self end\nreturn A\n',
        ['lua/fx/b.lua'] = 'local B = {}\nfunction B:root() return self end\nfunction B:parse() return self end\nreturn B\n',
        ['lua/fx/main.lua'] = table.concat({
            'local M = {}',
            'function M.scan(src)',
            '    local ok, parser = pcall(vim.treesitter.get_string_parser, src, "lua")',
            '    local t = M.first(parser:parse())',
            '    local tree = M.first(t[1])',
            '    return tree:root()',
            'end',
            'function M.first(x) return x end',
            'function M.shadow(src)',
            '    local vim = { treesitter = { get_string_parser = function () return nil end } }',
            '    local ok, parser = pcall(vim.treesitter.get_string_parser, src, "lua")',
            '    return parser:parse()',
            'end',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.main"); require("fx.a"); require("fx.b")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused = {}, {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and (callrec.callee(c) == 'root' or atr.sl(c.at) + 1 == 12) then
            v[atr.sl(c.at) + 1] = R.verdict(c) or false; refused[atr.sl(c.at) + 1] = c.refused
        end
    end
    vim.fn.delete(root, 'rf')
    if not refused[6] then skip 'the extractor already decides tree:root()' end
    eq('typed', v[6] and v[6].kind, 'tree holds what parse() returned: ' .. vim.inspect(v[6]))
    if not refused[12] then skip 'the extractor already decides parser:parse()' end
    ok(not (v[12] and v[12].kind == 'typed'), 'the local vim is not the profile: ' .. vim.inspect(v[12]))
end)

-- ★ PER-LOOP INSTANCES OF A SMALL CLOSED ITERATOR (CART-1643): a generic for binds its iterator to an instance of its
-- own when the function is small and CLOSED (every name it reads is its own or a global, nothing nested) — so one loop's
-- values do not pour into another's. tsutil.inext took every loop's node and saturated; with instances, lua/cartograph's
-- executed WHOLE typed answers went 47 -> 126 right (runtime oracle). An iterator that reads an UPVALUE is shared
test('flowtype: a closed iterator is instantiated per loop; one reading an upvalue is shared', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = table.concat({
            'local A = {}; A.__index = A',
            'function A:run() return 1 end',
            'local B = {}; B.__index = B',
            'function B:run() return 2 end',
            'local function inext(t, i) i = i + 1; local v = t[i]; if v then return i, v end end',
            'local shift = 1',
            'local function onext(t, i) i = i + shift; local v = t[i]; if v then return i, v end end',
            'local function vals(s) s.i = s.i + 1; return s.list[s.i] end',
            'local function nnext(t, i) local function step(j) return j + 1 end; i = step(i); local v = t[i]; if v then return i, v end end',
            'local M = {}',
            'function M.more()',
            '    for a in vals, { list = { setmetatable({}, A) }, i = 0 } do a:run() end',
            '    for b in vals, { list = { setmetatable({}, B) }, i = 0 } do b:run() end',
            '    for _, c in nnext, { setmetatable({}, A) }, 0 do c:run() end',
            '    for _, d in nnext, { setmetatable({}, B) }, 0 do d:run() end',
            'end',
            'function M.go()',
            '    for _, x in inext, { setmetatable({}, A) }, 0 do x:run() end',
            '    for _, y in inext, { setmetatable({}, B) }, 0 do y:run() end',
            '    for _, z in onext, { setmetatable({}, A) }, 0 do z:run() end',
            '    for _, w in onext, { setmetatable({}, B) }, 0 do w:run() end',
            'end',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.a")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/a.lua' and c.refused and c.at then v[atr.sl(c.at) + 1] = R.verdict(c) or false end
    end
    vim.fn.delete(root, 'rf')
    ok(v[18] and v[18].kind == 'exact' and tostring(v[18].targets[1]):match('A:run'), 'inext loop 1: A only — ' .. vim.inspect(v[18]))
    ok(v[19] and v[19].kind == 'exact' and tostring(v[19].targets[1]):match('B:run'), 'inext loop 2: B only — ' .. vim.inspect(v[19]))
    ok(not (v[20] and v[20].kind == 'exact'), 'onext reads `shift`: shared, both loops hold A and B — ' .. vim.inspect(v[20]))
    ok(v[12] and v[12].kind == 'exact' and tostring(v[12].targets[1]):match('A:run'), 'vals, its FIRST value: A only — ' .. vim.inspect(v[12]))
    ok(v[13] and v[13].kind == 'exact' and tostring(v[13].targets[1]):match('B:run'), 'vals loop 2: B only — ' .. vim.inspect(v[13]))
    ok(not (v[14] and v[14].kind == 'exact'), 'nnext holds a function of its own: shared — ' .. vim.inspect(v[14]))
end)

-- the walker looks its tree up by the PARSE VIEW, the key the extractor stored it under: keyed by the raw text, a file
-- that mentions `global` (the view renames it, TSGAP-0012) missed the shared tree and was parsed a second time
test('flowtype: a file that mentions `global` reuses the extractor\'s tree — no second parse', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['g.lua'] = 'local global = { a = 1 }\nlocal function get() return global.a end\nreturn get\n' })
    store.ingest(ts.extract(root))
    local pcache = require 'cartograph.parsecache'
    local m0 = pcache.stats.misses
    flowtype.solve(store, {})
    vim.fn.delete(root, 'rf')
    eq(0, pcache.stats.misses - m0, 'the walker parsed nothing of its own')
end)

-- an ABSENT child list — a bare `return`, `local x` with no value — is walked through EMPTY_NODE, the stand-in for
-- "no node": it must answer every iterator the walker uses (inamed asks named_child; its absence crashed the solve
-- on the 428-file corpus while the suite passed)
test('flowtype: a bare return and a valueless local walk an absent child list without crashing', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['e.lua'] = 'local function f() local x; return end\nlocal function g() return f() end\nreturn g\n' })
    store.ingest(ts.extract(root))
    local ok_, err = pcall(flowtype.solve, store, {})
    vim.fn.delete(root, 'rf')
    ok(ok_, tostring(err))
end)

-- (CART-1737: a PROGRAM is the files that share one globals table and string library — one for the whole tree unless
-- config says otherwise; the derived require closures are only CANDIDATES the explainer shows)
-- (an INSTANCE walked mid-file leaves the caller's environment as it was: walk_file sets a file's environment and never
-- restored it, so a call-site instance of a function from ANOTHER program's file left the rest of the caller reading
-- that program's globals — CART-1785, found through a host model's instance)
test('flowtype: a call-site instance of another program\'s function leaves the caller in its own environment', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['helper.lua'] = 'local M = {}\nfunction M.id(x) return x end\nreturn M\n',
        ['w/caller.lua'] = 'local A = require "a"\nlocal H = require "helper"\nwobj = setmetatable({}, { __index = A })\nlocal _ = H.id(1)\nlocal o = wobj\nreturn o:run()\n',
        ['r/other.lua'] = 'local B = require "b"\nlocal _ = setmetatable({}, { __index = B }):run()\n',
    })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local c
    for _, x in ipairs(store.data.calls) do if tostring(callrec.full(x)) == 'o:run' then c = x end end
    local cfg = require 'cartograph.config'
    local saved = cfg.scoped
    cfg.scoped = { [root .. '/w'] = { program = 'per-file' } }
    store.generation = store.generation + 1
    local R = flowtype.solve(store, { open = false, exp = 'callsite' })
    cfg.scoped = saved
    vim.fn.delete(root, 'rf')
    local v = R.verdict(c)
    ok(R.stats.instances and R.stats.instances > 0, 'the helper was instanced at the call: ' .. tostring(R.stats.instances))
    eq('a.lua::A.run@1', v and v.targets and v.targets[1], 'after the instance the caller reads its OWN program\'s wobj: ' .. vim.inspect(v))
end)

test('flowtype: programs — one environment by default; a config split hides one program\'s globals from another', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['w/writer.lua'] = 'local A = require "a"\nshared_obj = setmetatable({}, { __index = A })\nstring.objx = setmetatable({}, { __index = A })\n',
        ['r/reader.lua'] = 'local B = require "b"\nlocal o = shared_obj\nlocal k = ("OBJ"):lower() .. "x"\nlocal q = ("q")[k]\nreturn o:run(), q:run()\n',
    })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local c
    local cq
    for _, x in ipairs(store.data.calls) do if tostring(callrec.full(x)) == 'o:run' then c = x end; if tostring(callrec.full(x)) == 'q:run' then cq = x end end
    local programs = require 'cartograph.programs'
    local cfg = require 'cartograph.config'
    local saved = cfg.scoped
    local R1 = flowtype.solve(store, { open = false })
    local v1, q1 = R1.verdict(c), R1.verdict(cq)
    local e1 = programs.explain(store)
    cfg.scoped = { [root .. '/w'] = { program = 'per-file' } }
    store.generation = store.generation + 1 -- (programs.of is memoized per graph generation)
    local R2 = flowtype.solve(store, { open = false })
    local v2, q2 = R2.verdict(c), R2.verdict(cq)
    local p2 = programs.of(store)
    cfg.scoped = saved
    vim.fn.delete(root, 'rf')
    eq('a.lua::A.run@1', v1 and v1.targets and v1.targets[1], 'one program: the reader sees the writer\'s global — ' .. vim.inspect(v1))
    ok(table.concat(e1, '\n'):find('CANDIDATES, not applied', 1, true), 'the derived closures are candidates only: ' .. table.concat(e1, ' | '))
    eq('w/writer.lua', p2.env['w/writer.lua'], 'per-file: the writer is a program of its own')
    eq('default', p2.env['r/reader.lua'], 'the reader stays in the default program')
    ok(not (v2 and v2.kind == 'exact'), 'split: shared_obj is the writer program\'s — the reader holds nothing of it: ' .. vim.inspect(v2))
    -- (and its STRING LIBRARY: `("q")[k]` reads the reader's own — walked before the writer's program existed, so the
    -- solve must read the default program's, not the last walked file's)
    eq('a.lua::A.run@1', q1 and q1.targets and q1.targets[1], 'one program: string.objx is the reader\'s too — ' .. vim.inspect(q1))
    ok(not (q2 and q2.kind == 'exact'), 'split: the writer\'s string.objx is not in the reader\'s library: ' .. vim.inspect(q2))
end)

-- (CART-1715 step 1, cartograph.flowlinks: a Lua call no BINDING links takes its link from flow. byexample.lua's
-- `site.where()` was name-joined to mix.lua's cx.where; flow knows the table holds byexample's own `where`)
test('flowlinks: a wrong name-joined link becomes flow\'s target; a set is refused with flow\'s candidates; the edges follow', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local cx = {}\nfunction cx.where() return 1 end\nfunction cx.pick() return 1 end\nreturn cx\n',
        ['b.lua'] = table.concat({
            'local function p1() return 3 end',
            'local function p2() return 4 end',
            'local site = { where = function () return 2 end }',
            'local alt = { pick = (#arg > 0) and p1 or p2 }',
            'return site.where(), alt.pick()',
        }, '\n') .. '\n',
    })
    store.ingest(ts.extract(root))
    local function call(name) for _, c in ipairs(store.data.calls) do if c.file == 'b.lua' and (c.full or c.callee) == name then return c end end end
    local w0, p0 = call('site.where'), call('alt.pick')
    eq('a.lua::cx.where@1', w0.to, 'the name join: the only `where` with that tail')
    eq(true, w0.inferred, '… inferred')
    local st = require('cartograph.flowlinks').apply(store)
    vim.fn.delete(root, 'rf')
    local w, p = call('site.where'), call('alt.pick')
    eq('b.lua::where@2', w.to, 'flow: the table holds b.lua\'s own where — ' .. vim.inspect(st))
    eq(nil, w.inferred, 'one function, whole: confirmed')
    eq('flow', w.prov)
    eq(nil, p.to, 'two functions reach alt.pick: no link …')
    eq('flow-set', p.refused and p.refused.rule)
    eq({ 'b.lua::p1@0', 'b.lua::p2@1' }, p.refused.cands, '… refused with flow\'s candidates')
    local edges = {}
    for _, e in ipairs(store.data.edges) do if e.kind == 'ref' then edges[e.to] = true end end
    ok(edges['b.lua::where@2'], 'the new edge')
    ok(not edges['a.lua::cx.where@1'], 'the name join\'s edge is gone')
    ok(not edges['a.lua::cx.pick@2'], 'and the pick guess\'s')
end)

-- (CART-1715: the SELF SEED, opts.selfseed — flowlinks. WoW w2's 11,375 name-only `self:m()` sit in methods only the
-- HOST calls; `function T:m` declares self as T or an object prototyped by T)
test('flowtype selfseed: a host-called method\'s self is an instance of T — hedged, never T itself, only where self is empty', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = table.concat({
            'local addon = {}',
            'function addon:OnEnable() return self:Setup() end', -- 1: no caller in the tree
            'function addon:Setup() return 1 end',
            'local Base = {}',
            'Base.__index = Base',
            'function Base:run() return self:step() end', -- 5: a subclass overrides step
            'function Base:step() return 1 end',
            'local Sub = setmetatable({}, { __index = Base })',
            'function Sub:step() return 2 end',
            'local Called = {}',
            'function Called:go() return self:there() end', -- 10: called below — no seed
            'function Called:there() return 2 end',
            'Called:go()',
            'local Lib = {}',
            'function Lib:a() return 1 end',
            'function Lib:embed(k) self[k] = function () end end', -- 15: a write through self
            'local x = Lib.a()', -- 16: stays Lib:a alone
            'local lib = Factory:NewLibrary("x")', -- 17: T from a call the solve does not follow
            'function lib:Open() return self:Close() end',
            'function lib:Close() return 1 end',
            'return addon, x',
        }, '\n') .. '\n',
    })
    store.ingest(ts.extract(root))
    local function at(line, name) for _, c in ipairs(store.data.calls) do if c.line == line and (c.full or c.callee) == name then return c end end end
    local function callee(R, line, name) local fns, how = R.callee_of(at(line, name)); return (fns and table.concat(fns, ',') or '') .. ' ' .. tostring(how) end
    local R0 = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    local R = flowtype.solve(store, { open = false, ctx = false, allcallees = true, selfseed = true })
    eq(' whole', callee(R0, 1, 'self:Setup'), 'off: no caller, an empty self')
    eq('a.lua::addon:Setup@2 partial', callee(R, 1, 'self:Setup'), 'seeded: Setup, hedged')
    eq('a.lua::Base:step@6,a.lua::Sub:step@8 partial', callee(R, 5, 'self:step'), 'a subclass instance may be self: both steps')
    eq('a.lua::Called:there@11 whole', callee(R, 10, 'self:there'), 'a method the tree calls is not seeded: still whole')
    -- (one target: the write landed on the instance, not on Lib — seeding Lib itself made it a set. Hedged: Lib may be
    -- the self the host hands in, and a store through a hedged base taints what it may write)
    eq('a.lua::Lib:a@14 partial', callee(R, 16, 'Lib.a'), 'a write through self adds nothing to Lib')
    eq('a.lua::Lib:a@14 whole', callee(R0, 16, 'Lib.a'), 'off: whole')
    eq('a.lua::lib:Close@19 partial', callee(R, 18, 'self:Close'), 'an empty T gets a stand-in table: its methods meet')
    eq(1, R.selfseed.standin, vim.inspect(R.selfseed))
    local st = require('cartograph.flowlinks').apply(store)
    vim.fn.delete(root, 'rf')
    local c = at(1, 'self:Setup')
    eq('a.lua::addon:Setup@2', c.to, 'flowlinks: the link — ' .. vim.inspect(st))
    eq(true, c.inferred, '… hedged')
end)

-- (CART-1715: a named load off the globals TABLE is a global read — strict, as the identifier read is; non-strict it read
-- every dynamic-key `_G[k] = v` in the tree: AceHook's `_G[method] = uid` reached every `_G.LibStub`-shaped read)
test('flowtype: a named load off _G is strict — a dynamic-key write into _G does not reach it', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['s.lua'] = 'Stub = {}\nfunction Stub.get() return 1 end\n',
        ['h.lua'] = 'local G = _G\nlocal function hook(name, v) G[name] = v end\nhook(arg[1], { get = function () return 2 end })\n',
        ['a.lua'] = 'local G = _G\nlocal x = G.Stub.get()\nreturn x\n',
    })
    store.ingest(ts.extract(root))
    local function at(file, line, name) for _, c in ipairs(store.data.calls) do if c.file == file and c.line == line and (c.full or c.callee) == name then return c end end end
    local R = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    vim.fn.delete(root, 'rf')
    eq({ 's.lua::Stub.get@1' }, (R.callee_of(at('a.lua', 1, 'G.Stub.get'))), 'G.Stub is the global Stub alone, not the hook\'s table')
end)

-- (CART-1729, opts.litkeys: a call passing LITERALS at a small closed function's key parameters binds to one instance per
-- value — LibStub's `self.libs[major]`, flowpath FLOW-01's value-keyed instances — and a constant local is its string)
test('flowtype litkeys: value-keyed instances separate a registry by its literal keys; anything else binds the original', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['stub.lua'] = table.concat({
            'local MAJOR = "Stub"',
            'local Stub = _G[MAJOR] or { libs = {} }',
            '_G[MAJOR] = Stub',
            'function Stub:New(major) self.libs[major] = self.libs[major] or {}; return self.libs[major] end',
            'function Stub:Get(major) return self.libs[major] end',
            'function Stub:Rec(major, n) if n then return self:Rec(major, nil) end return self.libs[major] end',
            'setmetatable(Stub, { __call = Stub.Get })',
            'REG = { A = function () return 3 end }',
            'function Look(k, n) if n then return Look(k, nil) end return REG[k] end', -- a GLOBAL: bound while walked
        }, '\n') .. '\n',
        ['a.lua'] = table.concat({
            'local A = Stub:New("A"); function A.hello() return 1 end',
            'local BN = "B"',
            'local B = Stub:New(BN); function B.hello() return 2 end',
            'local x = Stub("A").hello()', -- 3
            'local y = Stub("B").hello()', -- 4
            'local z = Stub(arg[1]).hello()', -- 5
            'local w = Stub:Rec("A", 1).hello()', -- 6
            'local q = Look("A", 1)()', -- 7
        }, '\n') .. '\n',
        ['r.lua'] = table.concat({
            'local T = { t = {} }',
            'function T:get(k) k = k .. "" return self.t[k] end',
            'T.t.a = function () return 1 end',
            'T.t.b = function () return 2 end',
            'local f = T:get("a")',
            'local v = f()', -- 5
        }, '\n') .. '\n',
    })
    store.ingest(ts.extract(root))
    local function at(file, line, tail) for _, c in ipairs(store.data.calls) do if c.file == file and c.line == line and tostring(c.full or c.callee):sub(-#tail) == tail then return c end end end
    local function callee(R, file, line, tail)
        local c = at(file, line, tail)
        local fns = c and R.callee_of(c) or {}
        return table.concat(fns, ',')
    end
    local R0 = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    local R = flowtype.solve(store, { open = false, ctx = false, allcallees = true, litkeys = true })
    vim.fn.delete(root, 'rf')
    eq('', callee(R0, 'a.lua', 3, 'hello'), 'off: `_G[MAJOR]` is a dynamic write, no global Stub')
    eq('a.lua::A.hello@0', callee(R, 'a.lua', 3, 'hello'), 'Stub("A") is library A alone')
    eq('a.lua::B.hello@2', callee(R, 'a.lua', 4, 'hello'), 'Stub("B") — B registered through a constant local')
    eq('a.lua::A.hello@0,a.lua::B.hello@2', callee(R, 'a.lua', 5, 'hello'), 'a computed name binds the original: every library')
    ok(callee(R, 'a.lua', 6, 'hello'):find('A.hello', 1, true), 'a recursive call binds the original: no endless instance')
    ok(R.stats.vinstances < 50, 'a recursive call to a function bound while its instance is walked: no endless instance')
    eq('r.lua::T.t.a@2,r.lua::T.t.b@3', callee(R, 'r.lua', 5, 'f'), 'k is reassigned in its file: no instance, every entry')
    ok(R.stats.vinstances >= 4, 'instances: ' .. tostring(R.stats.vinstances))
end)

-- (CART-1742: all saturated ports as ONE top node is an optimisation, never a change — with it and without it the
-- answers are the same, on a fixture whose ports saturate)
test('flowtype: one top node for every saturated port moves no answer', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local FIX = vim.fn.getcwd() .. '/tests/fixtures/flowsched/ark/schema/shared/'
    local files = {}
    for _, f in ipairs({ 'errors.ts', 'traversal.ts' }) do files['ark/schema/shared/' .. f] = assert(io.open(FIX .. f)):read('a') end
    local root = tree(files)
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 8
    local function rows(top1)
        local R = flowtype.solve(store, { open = false, top1 = top1 })
        local out = {}
        for _, p in ipairs(R.probes) do out[#out + 1] = p.file .. ':' .. p.line .. ':' .. p.col .. ' ' .. p.kind .. ' ' .. table.concat(p.targets, ',') .. (p.partial and '~' or '') end
        table.sort(out)
        return out, R.stats
    end
    local a = rows(false)
    local b = rows(nil)
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    ok(#a > 5, 'answers: ' .. #a)
    eq(a, b, 'the same answers')
end)

-- (CART-1836: a dynamic `o[k]` walk into ⊤ over an object whose key set a completed ⊤ walk already fed is skipped — an
-- optimisation, never a change: twelve objects share a prototype P, each `oI[K]` saturates its destination on oI's own
-- five fields and then walks P into ⊤; every walk of P after the first is a skip, and the solution is the same without it)
test('flowtype: a dynamic walk into a saturated destination over an already-fed object is skipped, the solution unchanged (CART-1836)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local src = { 'local A, B = {}, {}', 'function A:go() return 1 end', 'function B:go() return 2 end',
        'local P = { x = function () end, y = A, z = {} }', 'local mt = { __index = P }', 'local K = UNKNOWN_KEY' }
    for i = 1, 12 do
        src[#src + 1] = ('local o%d = setmetatable({ a = {}, b = {}, c = {}, d = {}, e = B }, mt)'):format(i)
        src[#src + 1] = ('local v%d = o%d[K]'):format(i, i)
        src[#src + 1] = ('v%d:go(); o%d.y:go(); o%d.e:go()'):format(i, i, i)
    end
    -- (P gains a key DURING the solve, after walks of it: a later walk is no skip — its new field's objects arrive)
    src[#src + 1] = 'local function put(t, v) t.w = v end'
    src[#src + 1] = 'put(o12[K], { go = function () return 3 end })'
    src[#src + 1] = 'put(P, function () end)'
    src[#src + 1] = 'local L = P.w; L:go()'
    src[#src + 1] = 'return P, A, B'
    local root = tree({ ['m.lua'] = table.concat(src, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 4
    local function solution(fedk)
        local R = flowtype.solve(store, { open = false, ctx = false, fedk = fedk, exp = 'expose' })
        local I, out = R.internals, {}
        for p = 1, I.NW do
            local os = {}
            if not I.top[p] then for o in I.each(p) do os[#os + 1] = tostring(I.obinfo[o]) end end
            table.sort(os)
            out[#out + 1] = p .. (I.top[p] and ' T' or '') .. (I.tainted[p] and ' ~' or '') .. ' ' .. table.concat(os, ',')
        end
        local esc = {}
        for o in pairs(I.escaped) do esc[#esc + 1] = tostring(I.obinfo[o]) end
        table.sort(esc)
        out[#out + 1] = 'escaped ' .. table.concat(esc, ',')
        for _, pr in ipairs(R.probes) do out[#out + 1] = pr.line .. ':' .. pr.col .. ' ' .. pr.kind .. ' ' .. table.concat(pr.targets, ',') .. (pr.partial and '~' or '') end
        return out, R.stats
    end
    local a, sa = solution(false)
    local b, sb = solution(nil)
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    eq(0, sa.fedk_skips, 'opts.fedk = false: every walk runs')
    ok(sb.fedk_skips >= 10, 'the walks of P after the first are skipped: ' .. sb.fedk_skips)
    ok(sb.probes >= 30, 'the probes: ' .. sb.probes)
    eq(a, b, 'the same ports, objects, tops, taint, escapes and answers')
end)

-- (CART-1834: LuaJIT seeds its string hash PER PROCESS, so `pairs` over field names runs in a different order in every
-- run. Where that order decides something — which port a field gets (ports are numbered as they are made), which carrier
-- an escape is recorded through — the solve walks the names SORTED, and two runs give the same dump)
test('flowtype: field names are walked in one order — a keyed copy makes the target\'s fields sorted, an escape is carried by the first field (CART-1834)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local names = { 'kilo', 'alpha', 'juliet', 'bravo', 'india', 'charlie', 'hotel', 'delta', 'golf', 'echo', 'foxtrot', 'lima' }
    local src = { 'local X = {}' }
    local hub = {}
    for i, n in ipairs(names) do
        src[#src + 1] = ('local C%d = { x = X }'):format(i)
        hub[#hub + 1] = ('%s = C%d'):format(n, i)
    end
    src[#src + 1] = 'local E = { ' .. table.concat(hub, ', ') .. ' }'
    src[#src + 1] = 'local T = {}'
    src[#src + 1] = 'for k in pairs(E) do T[k] = E[k] end' -- (a KEYED COPY, CART-1726)
    src[#src + 1] = 'local function sink(x) return x end'
    src[#src + 1] = 'sink(E)'
    for _ = 1, 70 do src[#src + 1] = 'sink({})' end -- (past CAP: sink's parameter saturates and E escapes)
    src[#src + 1] = 'return T'
    local root = tree({ ['m.lua'] = table.concat(src, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false, explain = true, keepsat = true })
    local T = R.object('tbl:m.lua:' .. (#names + 2) .. ':10')
    ok(T, 'the copy target T')
    local sortedn = vim.deepcopy(names); table.sort(sortedn)
    local ports = {}
    for _, n in ipairs(sortedn) do ports[#ports + 1] = R.field_port(T, n) or -1 end
    local asc = vim.deepcopy(ports); table.sort(asc)
    ok(ports[1] > 0, 'the copy made T\'s fields: ' .. vim.inspect(ports))
    eq(asc, ports, 'T\'s field ports are made in name order')
    -- (X escapes with E's fields' objects: the carrier recorded is the one under the FIRST name, alpha = C2)
    local path = R.escape_of(R.object('tbl:m.lua:0:10'))
    local s = table.concat(path, ' | ')
    ok(s:find('m.lua:2:', 1, true) and not s:find('m.lua:1:', 1, true), 'carried through alpha\'s table (line 3): ' .. s)
    vim.fn.delete(root, 'rf')
end)

-- (GE's metatable slot, the default since CART-1837 (experiment no-ge-meta: the plain reading) — _G takes a metatable
-- only through a target that holds nothing else. On WoW w3 a debug printer's `pcall(t[k], t)` called AceDB's ResetDB with _G among t's values, initdb set dbmt on
-- it, and every undefined global read then called dbmt's __index)
test('flowtype: GE\'s metatable slot (no-ge-meta off): a setmetatable target that also holds other tables gives _G no metatable; an exact _G target does', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = table.concat({
            'local mt = { __index = function (t, k) return k end }',
            'local function set(x) setmetatable(x, mt) end',
            'set({})',
            'set(_G)',
            'local mt2 = { __index = function (t, k) return 2 end }',
            'local function only(g) setmetatable(g, mt2) end',
            'only(_G)',
            'return set, only' }, '\n') .. '\n',
    })
    store.ingest(ts.extract(root))
    local function g_protos(exp)
        local R = flowtype.solve(store, { open = false, ctx = false, exp = exp })
        local I, G = R.internals, nil
        for o, n in pairs(I.obinfo) do if n == '_G' then G = o end end
        local out = {}
        for c in pairs(I.protos[G] or {}) do out[#out + 1] = tostring(I.obinfo[c]) end
        table.sort(out)
        return table.concat(out, ' ')
    end
    local stock, ge = g_protos('expose,no-ge-meta'), g_protos('expose')
    vim.fn.delete(root, 'rf')
    ok(stock:find('@0', 1, true) and stock:find('@4', 1, true), 'no-ge-meta: _G has both __index functions as prototypes: ' .. stock)
    ok(not ge:find('@0', 1, true), 'default: set\'s target held {} too, so _G takes no mt: ' .. ge)
    ok(ge:find('@4', 1, true), 'default: only\'s target held exactly _G, so it does: ' .. ge)
end)

-- (CART-1838: a FUNCTION takes no metatable — setmetatable raises on one, the dump's clause function-no-metatable — so
-- a setmetatable target that may hold a function links its __index to the tables only; debug.setmetatable may set one)
test('flowtype: a setmetatable target holding a function gives the function no prototype; debug.setmetatable does (CART-1838)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = table.concat({
            'local idx = { m = function () return 1 end }',
            'local mt = { __index = idx }',
            'local function set(x) setmetatable(x, mt) end',
            'local t = {}',
            'local function f() end',
            'set(t)',
            'set(f)',
            'local function g() end',
            'debug.setmetatable(g, mt)',
            'return t, f, g' }, '\n') .. '\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, exp = 'expose' })
    local I = R.internals
    local function obj(pat) for o, n in pairs(I.obinfo) do if tostring(n):find(pat) then return o end end end
    local idx, t, f, g = obj('^tbl:a.lua:0:'), obj('^tbl:a.lua:3:'), obj('::f@4$'), obj('::g@7$')
    vim.fn.delete(root, 'rf')
    ok(idx and t and f and g, 'objects found')
    ok(I.protos[t] and I.protos[t][idx], 'the table takes __index')
    ok(not (I.protos[f] and I.protos[f][idx]), 'the function set reached does not')
    ok(I.protos[g] and I.protos[g][idx], 'debug.setmetatable\'s function does')
end)

-- (CART-1838 (experiment no-getfenv0: the plain union): getfenv(0) is the thread's environment — not every environment a setfenv set. MySales
-- on WoW w3 read `getfenv(0)` after `setfenv(1, MS)` elsewhere: every function MS held became an __index of MS's objects)
test('flowtype: getfenv(0) holds the globals table, not what setfenv(1, ...) set; setfenv(0, ...) does reach it (CART-1838)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function held(lines, exp)
        local root = tree({ ['a.lua'] = table.concat(lines, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, ctx = false, exp = exp })
        vim.fn.delete(root, 'rf')
        local callrec = require 'cartograph.callrec'
        local I, recv = R.internals, {}
        for _, pr in pairs(I.probes) do
            if callrec.full(pr.c) == 'G.hub' then for o in I.each(pr.recv) do recv[tostring(I.obinfo[o])] = true end end
        end
        for _, c in ipairs(store.data.calls) do
            if callrec.full(c) == 'G.hub' then return (R.verdict(c) or { kind = 'none' }).kind, recv end
        end
    end
    local one = { 'local M = { hub = function () return 1 end }',
        'local N = { hub = function () return 2 end }', -- (a second hub: the name join is ambiguous, so the call has a verdict)
        'local function f() setfenv(1, M) end',
        'local G = getfenv(0)', 'G.hub()', 'return f, N' }
    eq('exact', held(one, 'expose,no-getfenv0'), 'no-getfenv0: getfenv returns every environment set — M among them')
    ok(held(one, 'expose') ~= 'exact', 'default: getfenv(0) is _G alone, which has no hub')
    local zero = { 'local M = { hub = function () return 1 end }',
        'local N = { hub = function () return 2 end }', -- (a second hub: the name join is ambiguous, so the call has a verdict)
        'local function f() setfenv(0, M) end',
        'local G = getfenv(0)', 'G.hub()', 'return f, N' }
    -- (level 0 also makes M a prototype of _G — the walk's deeper-level reading — so the lookup alone would pass: the
    -- receiver must hold M itself, as getfenv(0) returns it)
    local k, recv = held(zero, 'expose')
    eq('exact', k, 'default: a setfenv at level 0 sets the thread\'s environment')
    ok(recv['tbl:a.lua:0:10'], 'getfenv(0) holds M itself: ' .. vim.inspect(recv))
end)

-- (CART-1784, open mode: O2 taints a prototype's DATA field the outside may write — but `M.mk_b` reads M's OWN member, a
-- function C1 says the outside does not replace, so the lookup never reaches P.mk_b. A reader of P itself keeps it)
test('flowtype open mode: a prototype field read only through a child\'s function member is not tainted by O2 (CART-1784)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['lua/m/init.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.m(self) return "A" end',
        'function B.m(self) return "B" end',
        'local P = {}',
        'function P.one() end',
        'local M = setmetatable({}, { __index = P })',
        'M.one = setmetatable({}, { __index = A })',
        'function M.mk_b() return setmetatable({}, { __index = B }) end',
        'function M.run() return M[("oth"):lower() .. "er"]:m() end',
        'local w = M.mk_b(); w:m()',
        'P.cfg = setmetatable({}, { __index = A })',
        'local z = P.cfg; z:m()',
        -- (the same shape, but P2.mk_b is ALSO read on P2 itself: the outside's write reaches that reader, and the
        -- taint of the one cell reaches every reader of it — w2 stays partial)
        'local P2 = {}',
        'local M2 = setmetatable({}, { __index = P2 })',
        'function M2.mk_b() return setmetatable({}, { __index = B }) end',
        'M.two = M2',
        'local raw = P2.mk_b',
        'local w2 = M2.mk_b(); w2:m()',
        'return M' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { ctx = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local by = {}
    for _, c in ipairs(store.data.calls) do
        local full = callrec.full(c)
        if full == 'w:m' or full == 'z:m' or full == 'w2:m' then by[full] = R.verdict(c) or { kind = 'none' } end
    end
    local w = by['w:m']
    ok(w, 'the call w:m(): ' .. vim.inspect(by))
    eq('exact', w.kind, vim.inspect(w))
    ok(not w.partial, 'M.mk_b reads M\'s own function: P.mk_b\'s taint does not reach it — ' .. vim.inspect(w))
    local z = by['z:m']
    ok(z and z.kind == 'exact', 'the call z:m(): ' .. vim.inspect(by))
    ok(z.partial, 'P.cfg is a data field read on P ITSELF: the outside may write it, the answer stays partial — ' .. vim.inspect(z))
    local w2 = by['w2:m']
    ok(w2 and w2.kind == 'exact', 'the call w2:m(): ' .. vim.inspect(by))
    ok(w2.partial, 'P2.mk_b is also read on P2 itself: its taint reaches M2.mk_b\'s reader too — ' .. vim.inspect(w2))
end)

-- (USER 2026-10-17: "flowtype could have some experiments" — a variant of the solve is a NAMED switch, selected by opts.exp
-- or CARTOGRAPH_FLOWTYPE_EXP, recorded in R.exp; an unknown name is an error)
test('flowtype experiments: named switches from opts or the environment; an unknown name refuses; no-sinf turns the rule off', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A, B = {}, {}\nfunction A:upper() return 1 end\nfunction B:upper() return 2 end\nlocal s = UNDEFINED_SOURCE\nlocal x = s:lower():upper()\nreturn A, B, x\n',
    })
    store.ingest(ts.extract(root))
    local c
    -- (the rule types the RESULT of `s:lower()` on an empty s: its answer is the next call's, `:upper` on that result)
    for _, x in ipairs(store.data.calls) do if tostring(x.full or x.callee):find('upper', 1, true) then c = x end end
    ok(c, 'the call')
    local R0 = flowtype.solve(store, { open = false, ctx = false })
    eq({}, R0.exp, 'none active')
    local v0 = R0.verdict(c)
    eq('string', v0 and v0.kind, 'an empty receiver of a string method: the string rule (sinf) — ' .. vim.inspect(v0))
    local R1 = flowtype.solve(store, { open = false, ctx = false, exp = 'no-sinf,expose' })
    eq({ ['no-sinf'] = true, expose = true }, R1.exp)
    ok(R1.internals and R1.internals.pts, 'expose: the solver tables')
    local v1 = R1.verdict(c)
    ok(not (v1 and v1.kind == 'string'), 'no-sinf: the rule is off — ' .. vim.inspect(v1))
    local okk, err = pcall(flowtype.solve, store, { exp = { 'no-such-thing' } })
    ok(not okk and tostring(err):find('unknown experiment', 1, true), 'an unknown name refuses: ' .. tostring(err))
    local R3 = flowtype.solve(store, { open = false, ctx = false, exp = 'loc' })
    local seen = false
    for _, w in pairs(R3.internals.loc) do if tostring(w):match('a%.lua:%d+$') then seen = true; break end end
    ok(seen, 'loc: a port names the statement it was made at')
    vim.env.CARTOGRAPH_FLOWTYPE_EXP = 'order=asc'
    local R2 = flowtype.solve(store, { open = false, ctx = false })
    vim.env.CARTOGRAPH_FLOWTYPE_EXP = nil
    eq({ order = 'asc' }, R2.exp, 'the environment selects')
    vim.fn.delete(root, 'rf') -- (after the solves: flowtype reads the sources)
end)

-- (experiment `callsite`, CART-1697: a call binds a small closed function to an instance of its own — `id(A).go()` and
-- `id(B).go()` are A's and B's go, not both; off by default)
test('flowtype experiment callsite: per-call-site instances separate an identity helper\'s callers', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local function id(x) return x end',
        'local A = { go = function () return 1 end }',
        'local B = { go = function () return 2 end }',
        'local a = id(A)',
        'local b = id(B)',
        'local r1 = a.go()',
        'local r2 = b.go()',
        'return r1, r2',
    }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local function callee(R, name)
        for _, c in ipairs(store.data.calls) do if (c.full or c.callee) == name then return table.concat(R.callee_of(c) or {}, ',') end end
    end
    local R0 = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    local R1 = flowtype.solve(store, { open = false, ctx = false, allcallees = true, exp = 'callsite' })
    vim.fn.delete(root, 'rf')
    eq('m.lua::go@1,m.lua::go@2', callee(R0, 'a.go'), 'off: one id merges both callers')
    eq('m.lua::go@1', callee(R1, 'a.go'), 'callsite: A\'s go')
    eq('m.lua::go@2', callee(R1, 'b.go'), 'callsite: B\'s go')
end)

-- (experiment `trace`, CART-1697: the solve as a bounded graph — ports folded onto their function, deliveries counted per
-- (source, destination, kind): `id(A)` / `id(B)` deliver both tables into id, whose parameter holds 2, and id returns them)
test('flowtype experiment trace: deliveries per (source, destination, kind), the largest set per node', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = 'local function id(x) return x end\nlocal a = id({})\nlocal b = id({})\nreturn a, b\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, exp = 'trace' })
    local R0 = flowtype.solve(store, { open = false, ctx = false })
    vim.fn.delete(root, 'rf')
    eq(nil, R0.trace, 'off: no trace')
    eq(2, R.trace.maxset['m.lua::id@0'], 'id merges both callers\' tables')
    eq(2, R.trace.edges['chunk:m.lua\tm.lua::id@0\tedge'], 'two objects bound into id')
    -- (id's return port is id's own: its 2 merged objects reach BOTH call results — the merge's fan-out, 4 deliveries)
    eq(4, R.trace.edges['m.lua::id@0\tchunk:m.lua\tcopy'], 'and returned to both callers')
end)

-- (CART-1745: a statement calling the GLOBAL error never returns — the rest of its block is not walked. vimruntime's LuaLS
-- stubs open with `error('Cannot require a meta file')`; a local named error is not the global)
test('flowtype: an unconditional raise ends its block — a stub chunk defines nothing; a local `error` does not count', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['m.lua'] = 'local M = {}\nerror("a declaration file")\nfunction M.go() return 1 end\nreturn M\n',
        ['n.lua'] = 'local function error() end\nlocal N = {}\nerror()\nfunction N.go() return 2 end\nreturn N\n',
        ['a.lua'] = 'local M = require "m"\nlocal N = require "n"\nlocal x = M.go()\nlocal y = N.go()\nreturn x, y\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    vim.fn.delete(root, 'rf')
    local function callee(name) for _, c in ipairs(store.data.calls) do if c.file == 'a.lua' and (c.full or c.callee) == name then return table.concat(R.callee_of(c) or {}, ',') end end end
    eq('', callee('M.go'), 'm.lua stops at its raise: M.go is never defined')
    eq('n.lua::N.go@3', callee('N.go'), 'n.lua\'s error is a local function: the chunk runs on')
end)

-- (experiment `strict-names`, CART-1697: a named load reads only its field, never `[]` — the strict-global contract for
-- every table. `t[k] = g` with k computed no longer reaches `t.go`)
test('flowtype experiment strict-names: a named load skips the computed-key cell', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = 'local t = {}\nfunction t.go() return 1 end\nlocal k = arg[1]\nt[k] = function () return 2 end\nreturn t.go()\n' })
    store.ingest(ts.extract(root))
    local function callee(R) for _, c in ipairs(store.data.calls) do if (c.full or c.callee) == 't.go' then return table.concat(R.callee_of(c) or {}, ',') end end end
    local R0 = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    local R1 = flowtype.solve(store, { open = false, ctx = false, allcallees = true, exp = 'strict-names' })
    vim.fn.delete(root, 'rf')
    ok(not callee(R0):find('^m%.lua::t%.go@1$'), 'off: t[k] may be go — ' .. callee(R0))
    eq('m.lua::t.go@1', callee(R1), 'strict-names: only the named go')
end)

-- (experiment `strict-records`, CART-1697: a constructor bound to a name its file indexes by computed key is a MAP site;
-- every other table is a RECORD, whose named loads skip `[]`)
test('flowtype experiment strict-records: a record skips the computed-key cell, a map keeps it', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local rec = { go = function () return 1 end }',
        'local function put(x, k, v) x[k] = v end',
        'put(rec, arg[1], function () return 2 end)',
        'local by_id = {}',
        'by_id[arg[1]] = function () return 3 end',
        'local a = rec.go()',
        'local b = by_id.special()',
        'return a, b',
    }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local function callee(R, nm) for _, c in ipairs(store.data.calls) do if (c.full or c.callee) == nm then return table.concat(R.callee_of(c) or {}, ',') end end end
    local R0 = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    local R1 = flowtype.solve(store, { open = false, ctx = false, allcallees = true, exp = 'strict-records' })
    vim.fn.delete(root, 'rf')
    ok(callee(R0, 'rec.go'):find(',', 1, true), 'off: put\'s computed-key write may be rec.go — ' .. callee(R0, 'rec.go'))
    eq('m.lua::go@0', callee(R1, 'rec.go'), 'strict-records: rec is a record, only its named go')
    ok(callee(R1, 'by_id.special') ~= '', 'by_id is a map site: its computed-key entries still answer a named load')
end)

-- (CART-1754: a FUNCTION has no metatable of its own — the dump's contract function-no-metatable; calling one never
-- consults __call. A builtin's call — a generic for's iterator — goes through the __call route like a direct call, and
-- the function's `\1mt` cell, once the metatable slot and `__call` were hit through a lost base, made the loop's
-- values partial: 74 of the runtime oracle's whole answers. Pinned in the DUMP: the escaped plain iterator has NO
-- metatable cell (META, field 100) at all. Since CART-1776 its RESULTS are partial anyway — what escapes is written
-- by the outside — so the loop's answer no longer tells the two cases apart)
test('flowtype: a plain function iterator has no metatable cell, even escaped and with `\\1mt` / `__call` hit', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local sinks = {}
    for k = 1, 70 do sinks[k] = 'pick({})' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A = {}', 'function A.m(self) return 1 end',
        'local a = setmetatable({}, { __index = A })',
        'local function pick(x) return x end', table.concat(sinks, '\n'),
        'local T = pick({})', 'setmetatable(T, {})', 'T.__call = 1',
        'local function it(s, c) if c == nil then return a end end',
        'pick(it)',
        'for v in it, nil do local _ = v:m() end' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local D = vim.json.decode(flowtype.solve(store, { open = false, dump = true }).dump)
    vim.fn.delete(root, 'rf')
    local itsite
    for _, st in ipairs(D.sites) do if st.kind == 'function' and tostring(st.label):match('::it@') then itsite = st.id end end
    ok(itsite, 'the iterator is a function site')
    local S = D.solution
    for _, l in ipairs({ S.h, S.htaint, S.htop }) do
        for _, c in ipairs(l or {}) do ok(not (c[1] == itsite and c[2] == 100), 'no metatable cell on the plain function: ' .. vim.inspect(c)) end
    end
end)

-- (CART-1761: what a HOST type is comes from the environment profile — prim / open / members. An OPEN host object is an
-- ordinary one: a field stored on it is read back. A MEMBERS one (the default for userdata, io.open's `file`) has its
-- declared members only)
test('flowtype: an OPEN host type reads back a field stored on it; a members one does not', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
        'local a = setmetatable({}, { __index = A })', 'local _ = setmetatable({}, { __index = B }):m()',
        'local fh = io.open("x")', 'fh.mine = a', 'local g = fh.mine', 'return g:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'g:m' then call = c end end
    local members = flowtype.solve(store, { open = false }).verdict(call)
    ok(not members, 'members (the default): no field is read back: ' .. vim.inspect(members))
    local open = flowtype.solve(store, { open = false, host_kinds = { file = 'open' } }).verdict(call)
    ok(open and open.kind == 'exact' and #open.targets == 1 and tostring(open.targets[1]):match('A%.m'), 'open: A.m: ' .. vim.inspect(open))
    vim.fn.delete(root, 'rf')
end)

-- (CART-1761, creation: a profile signature says what TYPE it returns, not how the value comes to be. An OPEN host type
-- is CREATED per call site by default (`creates[sig] = 'new'`): two io.open results are two objects, so a field stored
-- on one is not read from the other. Declared 'shared', they are one object again)
test('flowtype: an open host value is created per call: a field stored on one is not read from another', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
        'local a = setmetatable({}, { __index = A })', 'local b = setmetatable({}, { __index = B })',
        'local f1, f2 = io.open("x"), io.open("y")', 'f1.mine = a', 'f2.mine = b',
        'local g = f1.mine', 'return g:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'g:m' then call = c end end
    local new = flowtype.solve(store, { open = false, host_kinds = { file = 'open' } }).verdict(call)
    ok(new and new.kind == 'exact' and #new.targets == 1 and tostring(new.targets[1]):match('A%.m'), 'new per call: only A.m: ' .. vim.inspect(new))
    local shared = flowtype.solve(store, { open = false, host_kinds = { file = 'open' }, creates = { ['io#open'] = 'shared' } }).verdict(call)
    ok(shared and #(shared.targets or {}) == 2, 'shared: one object, both methods: ' .. vim.inspect(shared))
    vim.fn.delete(root, 'rf')
end)

-- (CART-1761, the user: Lua TABLE types a host function returns — `string[]`, `table<K, V>`, `table`, a `{ … }` shape —
-- take the kind of the ALIAS `table`: `members` by default (no field is read back), `open` when set — then a field
-- stored on one is read back, and it is CREATED per call, so `vim.split`'s two results are two objects)
test('flowtype: a host function\'s table type takes the `table` alias\'s kind; open, it is created per call (CART-1761)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
        'local a = setmetatable({}, { __index = A })', 'local b = setmetatable({}, { __index = B })',
        'local p, q = vim.split("a b", " "), vim.split("c", " ")', 'p.mine = a', 'q.mine = b',
        'local g = p.mine', 'return g:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    store.data.profile = 'nvim'
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'g:m' then call = c end end
    -- (by the SIGNATURE: no host model — CART-1785's shared.lua is vim.split's real body)
    local v = flowtype.solve(store, { open = false, hostmodels = false, host_kinds = { table = 'open' } }).verdict(call)
    ok(v and v.kind == 'exact' and #v.targets == 1 and tostring(v.targets[1]):match('A%.m'), 'open, new per call: only A.m: ' .. vim.inspect(v))
    local m = flowtype.solve(store, { open = false, hostmodels = false }).verdict(call)
    ok(not m, 'the alias by default (members): no field is read back: ' .. vim.inspect(m))
    vim.fn.delete(root, 'rf')
end)

-- (CART-1785, the host as plain code: a host function with a Lua MODEL runs it. `debug.getregistry()` returns ONE
-- existing table — a field stored through one call is read through another; `table.move(a1, f, e, t, a2)` copies a1's
-- elements into a2 (or a1) and returns it. Without a model both return a `table` of the signature: no field is read
-- back. (rawset / rawget are the language's own: a store and a load, no model needed)
local HOSTMODEL = table.concat({
    'local REG = {}',
    'return {',
    '    ["debug#getregistry"] = function () return REG end,',
    '    ["table#move"] = function (a1, f, e, t, a2) local d = a2 or a1; for i = f, e do d[t + i - f] = a1[i] end; return d end,',
    '}' }, '\n') .. '\n'
test('flowtype: a modelled host function runs its Lua model (CART-1785)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
        'local a = setmetatable({}, { __index = A })', 'local _ = setmetatable({}, { __index = B }):m()',
        'local r1 = debug.getregistry()', 'r1.x = a',
        'local r2 = debug.getregistry()', 'local g = r2.x', 'g:m()',
        'local u = table.move({ a }, 1, 1, 1, {})', 'local h = u[1]', 'h:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local at = {}
    for _, c in ipairs(store.data.calls) do local k = callrec.full(c); if k then at[k] = c end end
    local R = flowtype.solve(store, { open = false, hostmodels = { test = HOSTMODEL } })
    for _, full in ipairs { 'g:m', 'h:m' } do
        local v = R.verdict(at[full])
        ok(v and v.kind == 'exact' and #v.targets == 1 and tostring(v.targets[1]):match('A%.m'), 'modelled: ' .. full .. ' is A.m: ' .. vim.inspect(v))
    end
    local N = flowtype.solve(store, { open = false, hostmodels = false })
    -- (table.move needs no model either since CART-1814: built in, it copies the elements)
    local vh = N.verdict(at['h:m'])
    ok(vh and vh.kind == 'exact' and tostring(vh.targets[1]):match('A%.m'), 'no model, the built-in table.move: h:m is A.m: ' .. vim.inspect(vh))
    -- (the registry needs no model since CART-1811: debug.getregistry() is one table per environment, built in)
    local vg = N.verdict(at['g:m'])
    ok(vg and vg.kind == 'exact' and tostring(vg.targets[1]):match('A%.m'), 'no model, the built-in registry: g:m is A.m: ' .. vim.inspect(vg))
    -- (the model is no tree code: it records no ACCESS — an access row is about a file of the tree)
    local W = flowtype.solve(store, { open = false, accesses = true, hostmodels = { test = HOSTMODEL } })
    local nacc, inmodel = 0, 0
    for _, r in ipairs(W.accesses or {}) do nacc = nacc + 1; if tostring(r.file):find('hostmodel', 1, true) then inmodel = inmodel + 1 end end
    ok(nacc > 0, 'the tree\'s accesses are recorded')
    eq(0, inmodel, 'none in the model')
    vim.fn.delete(root, 'rf')
end)

-- (CART-1785 H1, the luajit host model that SHIPS — spec/hostmodel/luajit.lua: `table.remove` returns an element of
-- its list; `debug.getregistry()` is one table)
test('flowtype: the shipped luajit host model — table.remove returns an element, the registry is one table (CART-1785)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
        'local a = setmetatable({}, { __index = A })', 'local _ = setmetatable({}, { __index = B }):m()',
        'local stack = {}', 'stack[#stack + 1] = a', 'local x = table.remove(stack)', 'x:m()',
        'debug.getregistry().mine = a', 'local g = debug.getregistry().mine', 'g:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local at = {}
    for _, c in ipairs(store.data.calls) do local k = callrec.full(c); if k then at[k] = c end end
    local R = flowtype.solve(store, { open = false, dump = true, hostmodels = true })
    for _, full in ipairs { 'x:m', 'g:m' } do
        local v = R.verdict(at[full])
        ok(v and v.kind == 'exact' and #v.targets == 1 and tostring(v.targets[1]):match('A%.m'), full .. ' is A.m: ' .. vim.inspect(v))
    end
    local keys = {}
    for _, e in ipairs(vim.json.decode(R.dump).contracts.host_models) do keys[#keys + 1] = e[1] end
    eq('debug#getregistry,table#remove', table.concat(keys, ','), 'the dump names the models the calls ran')
    vim.fn.delete(root, 'rf')
end)

-- (CART-1785 H2: where the host IS Lua its own source is the model — nvim's vim/_core/shared.lua, read under the nvim
-- profile's sig_source. `vim.tbl_map(f, t)` runs its real body: f is CALLED with t's elements, and the result is a
-- NEW table of what f returns. By the signature alone (`table`) neither is known)
test('flowtype: nvim\'s own Lua is its host model — vim.tbl_map calls the callback and builds the result (CART-1785)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local pr = require('cartograph.spec.profile').load('nvim')
    if not (pr and pr.sig_source and vim.uv.fs_stat(pr.sig_source .. '/lua/vim/_core/shared.lua')) then skip 'the nvim runtime the profile was distilled from is not here' end
    local root = tree({ ['lua/p/init.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
        'local a = setmetatable({}, { __index = A })', 'local _ = setmetatable({}, { __index = B }):m()',
        'local r = vim.tbl_map(function (x) x:m(); return x end, { a })', 'local y = r[1]', 'y:m()',
        'local b = setmetatable({}, { __index = B })',
        'local p, q = vim.split("a b", " "), vim.split("c", " ")', 'p.mine = a', 'q.mine = b', 'local g = p.mine', 'g:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    store.data.profile = 'nvim'
    local callrec = require 'cartograph.callrec'
    local at = {}
    for _, c in ipairs(store.data.calls) do local k = callrec.full(c); if k then at[k] = c end end
    local R = flowtype.solve(store, { open = false, hostsources = true, exp = 'host-inst' })
    -- (g: vim.split's real body allocates ONE table for every caller — instanced per call site, the two results are two)
    for _, full in ipairs { 'x:m', 'y:m', 'g:m' } do
        local v = R.verdict(at[full])
        ok(v and v.kind == 'exact' and #v.targets == 1 and tostring(v.targets[1]):match('A%.m'), 'shared.lua: ' .. full .. ' is A.m: ' .. vim.inspect(v))
    end
    -- (CART-1786: the SAME answers from shared.lua's SUMMARY applied at the calls as edges — no walk of it, no instance)
    local SM = flowtype.solve(store, { open = false, hostsummary = true })
    for _, full in ipairs { 'x:m', 'y:m', 'g:m' } do
        local v = SM.verdict(at[full])
        ok(v and v.kind == 'exact' and #v.targets == 1 and tostring(v.targets[1]):match('A%.m'), 'summary: ' .. full .. ' is A.m: ' .. vim.inspect(v))
    end
    local N = flowtype.solve(store, { open = false, hostmodels = false })
    for _, full in ipairs { 'x:m', 'y:m' } do ok(not N.verdict(at[full]), 'by the signature: ' .. full .. ' has no answer') end
    vim.fn.delete(root, 'rf')
end)

-- (CART-1790, flowpath's witness: table.remove(stack) returns the removed ELEMENT — its result had been the fixed host
-- value `any` of the signature, the element lost, and `use(p)` answered a WHOLE exact {A.m} where Lua prints B, under
-- a certified dump. And the class: a builtin declared to return `any` from arguments may return what it was handed —
-- vim.fn.get({ b }, 1) is b — so its result is TAINTED, never a fixed value)
test('flowtype: table.remove returns an element; a declared `any` result of a call with arguments is tainted (CART-1790)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function verdict_of(src, profile, mode)
        local root = tree({ ['m.lua'] = table.concat({
            'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
            'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
            'local function use(p) return p:m() end', 'use(a)', src }, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        store.data.profile = profile
        local callrec = require 'cartograph.callrec'
        local R = flowtype.solve(store, { open = mode })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    for _, mode in ipairs { false, true } do
        local v = verdict_of('local stack = { b }\nlocal p = table.remove(stack)\nprint(use(p))', nil, mode)
        ok(v and v.kind == 'narrowed' and #v.targets == 2 and not v.partial, (mode and 'open' or 'closed') .. ': table.remove gives b, {A.m, B.m}, whole: ' .. vim.inspect(v))
    end
    local w = verdict_of('local y = vim.fn.get({ b }, 1)\nuse(y)', 'nvim', false)
    ok(not (w and w.kind == 'exact' and not w.partial), 'vim.fn.get\'s `any` is no fixed value: no whole exact {A.m}: ' .. vim.inspect(w))
    ok(w and w.partial, 'it is partial: ' .. vim.inspect(w))
    -- (CART-1791: the tainted `any` result holds the ESCAPED objects, so the call's arguments must escape — through an
    -- alias, `tr(s)` returns s's element b, which must be in the abstraction: no whole answer, b escaped)
    local tv = verdict_of('local tr = table.remove\nlocal s = { b }\nlocal p = tr(s)\nprint(use(p))', nil, false)
    ok(tv and tv.kind == 'narrowed' and #tv.targets == 2 and not tv.partial, 'through an alias: the model, whole {A.m, B.m} (CART-1793): ' .. vim.inspect(tv))
    do
        local root = tree({ ['m.lua'] = table.concat({
            'local B = {}', 'function B.m(self) return "B" end', 'local b = setmetatable({}, { __index = B })',
            'return vim.fn.get({ b }, 1)' }, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        store.data.profile = 'nvim'
        local D = vim.json.decode(flowtype.solve(store, { open = false, dump = true }).dump)
        vim.fn.delete(root, 'rf')
        local lab = {}
        for _, x in ipairs(D.sites) do lab[x.id] = x.label end
        local esc = {}
        for _, i in ipairs(D.solution.taint.escaped) do esc[lab[i]] = true end
        ok(esc['tbl:m.lua:2:23'], 'b — the element vim.fn.get may return — is ESCAPED: ' .. vim.inspect(esc))
    end
    -- (a generic `T` of a `T[]` argument is its ELEMENT: vim.version.last({ b }) is b, not a fixed value named T)
    local g = verdict_of('local z = vim.version.last({ b })\nuse(z)', 'nvim', false)
    ok(g and g.kind == 'narrowed' and #g.targets == 2, 'vim.version.last gives b: {A.m, B.m}: ' .. vim.inspect(g))
end)

-- (CART-1791, flowpath's alias witnesses: a builtin reached by VALUE — renamed, same-name, `tinsert or table.insert`
-- — had no object, its call ran nothing, and `use(p)` answered a WRONG whole {B.m} where Lua prints A. A native object
-- now: it runs the builtin's MODEL, what the call by name runs — whole {A.m, B.m}; one with no model (ipairs) is a LOST
-- call, partial, its arguments escaped; a direct call by name keeps its own path)
test('flowtype: a builtin reached by value is a native object — its call is lost, never runs nothing (CART-1791)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function v_of(src)
        local root = tree({ ['m.lua'] = table.concat({
            'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
            'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
            'local function use(p) return p:m() end', 'use(b)', src }, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        local callrec = require 'cartograph.callrec'
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    for _, src in ipairs {
        'local f, t = rawget, { x = a }\nprint(use(f(t, "x")))',
        'local rawset = rawset\nlocal t = {}\nrawset(t, "x", a)\nprint(use(t.x))',
        'local tinsert = tinsert or table.insert\nlocal s = {}\ntinsert(s, a)\nprint(use(s[1]))' } do
        local v = v_of(src)
        ok(not (v and v.kind == 'exact' and not v.partial and not tostring(v.targets[1]):match('A%.m')), 'no wrong whole {B.m}: ' .. vim.inspect(v) .. '\n' .. src)
        ok(v and v.kind == 'narrowed' and #v.targets == 2 and not v.partial, 'the model: whole {A.m, B.m}: ' .. vim.inspect(v) .. '\n' .. src)
    end
    -- (no model yet: a LOST call — partial, never runs nothing)
    local lv = v_of('local w = coroutine.wrap\nlocal g = w(function () return a end)\nuse(g())')
    ok(lv and lv.partial, 'coroutine.wrap by value, no model: partial: ' .. vim.inspect(lv))
    -- (CART-1793: the models run what the call by NAME runs — __lt for a comparator-less sort, __tostring for tostring
    -- and string.format, setmetatable's table, getmetatable's __metatable, ipairs' elements)
    for _, src in ipairs {
        'local f = table.sort\nlocal mt = { __index = A, __lt = function (x, y) use(x); return false end }\nf({ setmetatable({}, mt), setmetatable({}, mt) })',
        'local f = tostring\nf(setmetatable({}, { __index = A, __tostring = function (s) use(s); return "s" end }))',
        'local f = string.format\nf("%s", setmetatable({}, { __index = A, __tostring = function (s) use(s); return "s" end }))',
        'local f = setmetatable\nuse(f({}, { __index = A }))',
        'local f = getmetatable\nuse(f(setmetatable({}, { __metatable = a })))',
        'local f = ipairs\nfor _, v in f({ a }) do use(v) end',
        -- (table.insert runs __newindex as by name, 5.3's lua_seti: the handler receives the value, CART-1795)
        'local f = table.insert\nf(setmetatable({}, { __newindex = function (_, _, v) use(v) end }), a)' } do
        local mv = v_of(src)
        ok(mv and mv.kind == 'narrowed' and #mv.targets == 2 and not mv.partial, 'by value as by name, whole {A.m, B.m}: ' .. vim.inspect(mv) .. '\n' .. src)
    end
    -- (by NAME the builtin's own path runs: rawget(t, "x") is a, whole)
    local d = v_of('local t = { x = a }\nprint(use(rawget(t, "x")))')
    ok(d and d.kind == 'narrowed' and not d.partial, 'a direct call stays whole: ' .. vim.inspect(d))
end)

-- (CART-1793: a NATIVE used as a dynamic key through an escaped base with an __index handler possible — the taint
-- phase's release step escaped the key's objects, a native never escapes, and the drain ran forever: vimruntime's solve
-- hung once the string library had natives. It terminates, and the key stays unescaped)
test('flowtype: a native as a dynamic key through an escaped base does not hang the taint phase (CART-1793)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local function lose(q) return q end',
        'local t = setmetatable({}, { __index = function () return 1 end })',
        'lose(t)', 'lose({})', 'lose({})',
        'local k = string.format', 'local v = t[k]', 'return v' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local t0 = vim.uv.hrtime()
    local ok_, R = pcall(flowtype.solve, store, { open = false, ctx = false })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(ok_, R)
    ok((vim.uv.hrtime() - t0) / 1e9 < 20, 'the solve terminates')
end)

-- (CART-1796, flowpath's witness: `loadstring("x = y")()` writes the global x from y BY NAME in the caller's
-- environment — as unknown code it was unmodelled, and `use(x)` answered a WRONG whole {B.m} where Lua prints A. A
-- literal source is walked as the body of the function load returns: {A.m, B.m}, whole, and the dump is closed)
test('flowtype: code loaded from a literal is tree code — loadstring("x = y") writes x (CART-1796)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(b)',
        'y = a', 'loadstring("x = y")()', 'print(use(x))' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local R = flowtype.solve(store, { open = false })
    local D = vim.json.decode(flowtype.solve(store, { open = false, dump = true }).dump)
    vim.fn.delete(root, 'rf')
    local v
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then v = R.verdict(c) end end
    ok(v and v.kind == 'narrowed' and #v.targets == 2 and not v.partial, 'the loaded chunk writes x = y: {A.m, B.m}: ' .. vim.inspect(v))
    eq(0, require('cartograph.flowcheck').check(D).failed, 'the dump holds the chunk and is closed')
end)

-- (CART-1798, flowpath's c01: `l1 <= l2` with only __lt in the metatable runs __lt(l2, l1) — 5.1, LuaJIT, nvim, 5.4
-- compat — and the handler stores y.v: `use(got)` runs A. The comparison had run __le only: a WRONG whole {B.m}. And
-- `>=` falls back to __lt with the operands as written)
test('flowtype: <= / >= fall back to __lt on swapped operands when there is no __le (CART-1798)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    for _, cmp in ipairs { 'l1 <= l2', 'l2 >= l1' } do
        local root = tree({ ['m.lua'] = table.concat({
            'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
            'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
            'local function use(p) return p:m() end', 'use(b)', 'local got = b',
            'local mt = { __lt = function (x, y) got = y.v; return false end }',
            'local l1, l2 = setmetatable({ v = a }, mt), setmetatable({ v = a }, mt)',
            'local _ = ' .. cmp, 'print(use(got))' }, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        local callrec = require 'cartograph.callrec'
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        local v
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then v = R.verdict(c) end end
        ok(v and v.kind == 'narrowed' and #v.targets == 2 and not v.partial, cmp .. ': the __lt fallback runs: {A.m, B.m}: ' .. vim.inspect(v))
    end
end)

-- (CART-1797, flowpath's g07: `package.loaded._G.x = a` writes the GLOBAL x — package.loaded listed nothing, the store
-- went nowhere, and `use(x)` answered a WRONG whole {B.m}. package.loaded holds _G, the libraries and the tree's
-- modules: `package.loaded.mymod` is what `require "mymod"` returns)
test('flowtype: package.loaded holds _G; the tree\'s modules under pkg-modules (CART-1797)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HDR = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(b)' }
    local function v_of(src, extra, exp)
        local files = { ['m.lua'] = table.concat(HDR, '\n') .. '\n' .. src .. '\n' }
        for k, v in pairs(extra or {}) do files[k] = v end
        local root = tree(files)
        store.ingest(ts.extract(root))
        local callrec = require 'cartograph.callrec'
        local R = flowtype.solve(store, { open = false, exp = exp })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    local g = v_of('package.loaded._G.x = a\nprint(use(x))')
    ok(g and g.kind == 'narrowed' and #g.targets == 2 and not g.partial, 'package.loaded._G is the globals: {A.m, B.m}: ' .. vim.inspect(g))
    -- (the MODULE entries are the experiment pkg-modules: by default `package.loaded.mymod` is still lost — a computed-key
    -- read over every module saturates and escapes them all, a contract decision, CART-1797)
    local m = v_of('package.loaded.mymod.obj = a\nprint(use(require("mymod").obj))', { ['lua/mymod.lua'] = 'local M = {}\nreturn M\n' }, 'pkg-modules')
    ok(m and m.kind == 'narrowed' and #m.targets == 2 and not m.partial, 'package.loaded.mymod is the module: {A.m, B.m}: ' .. vim.inspect(m))
end)

-- (CART-1777, open mode: a closure the tree stores into the STRING LIBRARY is callable by every other program — one string
-- metatable per Lua state, `("x").pick(…)` reaches it from any code — so its parameters may hold anything, as an
-- export's do. Closed, nothing outside exists)
test('flowtype: open mode — a closure stored into the string library is callable from outside', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return 1 end', 'function B.m(self) return 2 end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(a)',
        'string.pick_route = function (_, p) return use(p) end', 'local s = "x"', 's:pick_route(b)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
    local closed = flowtype.solve(store, { open = false }).verdict(call)
    ok(closed and closed.kind == 'narrowed' and not closed.partial, 'closed: complete {A, B}: ' .. vim.inspect(closed))
    local open = flowtype.solve(store, { open = true }).verdict(call)
    ok(not (open and open.kind == 'narrowed' and not open.partial and not open.contracts),
        'open: not a complete, uncontracted answer — outside code may call pick_route with anything: ' .. vim.inspect(open))
    -- (and the dump writes the mode the solve ran in)
    local D = vim.json.decode(flowtype.solve(store, { open = true, dump = true }).dump)
    eq('open', D.mode, 'the dump says open')
    ok(D.contracts.clauses['globals-per-program'] == nil, 'one program: no globals-per-program clause')
    vim.fn.delete(root, 'rf')
end)

-- (CART-1803, flowpath's GE review: the debug library rewrites tree state — each printed A at run time while the answer
-- was a certified whole {B.m}. debug.setmetatable is setmetatable; debug.getmetatable the raw slot; setupvalue /
-- getupvalue / upvaluejoin write, read and share a closure's upvalues — any captured local, whatever the index)
test('flowtype: debug.setmetatable / getmetatable / setupvalue / getupvalue reach tree state (CART-1803)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HDR = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(b)' }
    local callrec = require 'cartograph.callrec'
    local function v_of(src)
        local root = tree({ ['m.lua'] = table.concat(HDR, '\n') .. '\n' .. src .. '\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    local function both(v) return v and v.kind == 'narrowed' and #v.targets == 2 end
    local h14b = v_of('local t = {}\ndebug.setmetatable(t, { __index = A })\nprint(use(t))')
    ok(both(h14b), 'h14b: debug.setmetatable is setmetatable: ' .. vim.inspect(h14b))
    local d01 = v_of('local t = setmetatable({}, { __index = B })\ndebug.getmetatable(t).__index = A\nprint(use(t))')
    ok(both(d01), 'd01: debug.getmetatable is the metatable slot: ' .. vim.inspect(d01))
    local d02 = v_of('local o = b\nlocal function get() return o end\ndebug.setupvalue(get, 1, a)\nprint(use(get()))')
    ok(both(d02) or (d02 and d02.partial), 'd02: setupvalue writes the captured local: ' .. vim.inspect(d02))
    ok(d02 and vim.tbl_contains(d02.targets or {}, 'm.lua::A.m@1'), 'd02 includes A.m: ' .. vim.inspect(d02))
    local gu = v_of('local o = a\nlocal function get() return o end\nlocal _, x = debug.getupvalue(get, 1)\nprint(use(x))')
    ok(both(gu), 'getupvalue reads the captured local: ' .. vim.inspect(gu))
    local bv = v_of('local o = b\nlocal function get() return o end\nlocal su = debug.setupvalue\nsu(get, 1, a)\nprint(use(get()))')
    ok(bv and vim.tbl_contains(bv.targets or {}, 'm.lua::A.m@1'), 'by value too: ' .. vim.inspect(bv))
end)

-- (CART-1806, flowpath's h16 witnesses: a store to a bare global name is `_G.zz = v` — it runs _G's __newindex. A table
-- handler receives the store, a function handler is called with it, a handler set after setmetatable(_G, mt) too)
test('flowtype: a bare global store runs _G\'s __newindex as _G.zz = v does (CART-1806)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HDR = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'local P = { zz = b }' }
    local callrec = require 'cartograph.callrec'
    local function v_of(src)
        local root = tree({ ['m.lua'] = table.concat(HDR, '\n') .. '\n' .. src .. '\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    local function both(v) return v and v.kind == 'narrowed' and #v.targets == 2 end
    local h16c = v_of('setmetatable(_G, { __newindex = P })\nzz = a\nprint(use(P.zz))')
    ok(both(h16c), 'h16c: a table __newindex receives the bare store: ' .. vim.inspect(h16c))
    local h16e = v_of('setmetatable(_G, { __newindex = function (t, k, v) P.zz = v end })\nzz = a\nprint(use(P.zz))')
    ok(both(h16e), 'h16e: a function __newindex is called with it: ' .. vim.inspect(h16e))
    local h16h = v_of('local mt = {}\nsetmetatable(_G, mt)\nmt.__newindex = P\nzz = a\nprint(use(P.zz))')
    ok(both(h16h), 'h16h: a handler set after setmetatable: ' .. vim.inspect(h16h))
    local h16g = v_of('setmetatable(_G, { __newindex = P })\n_G.zz = a\nprint(use(P.zz))')
    ok(both(h16g), 'h16g: _G.zz, as before: ' .. vim.inspect(h16g))
end)

-- (CART-1804: debug.setlocal / getlocal write and read the locals of the frame their level names — a literal 1 is the
-- calling function; another level, a thread, a call by value: any function's, sound and coarse)
test('flowtype: debug.setlocal / getlocal reach the locals of the frame (CART-1804)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HDR = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'local function use2(q) return q:m() end', 'use(b)' }
    local callrec = require 'cartograph.callrec'
    local function v_of(src, full)
        local root = tree({ ['m.lua'] = table.concat(HDR, '\n') .. '\n' .. src .. '\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == (full or 'p:m') then return R.verdict(c) end end
    end
    local function hasA(v) return v and vim.tbl_contains(v.targets or {}, 'm.lua::A.m@1') end
    ok(hasA(v_of('local function f() local o = b; debug.setlocal(1, 1, a); return o end\nprint(use(f()))')), 'setlocal(1): the calling function\'s local')
    ok(hasA(v_of('local function g() local o = a; local _, x = debug.getlocal(1, 1); return x end\nprint(use(g()))')), 'getlocal(1) reads it')
    ok(hasA(v_of('local function set() debug.setlocal(2, 1, a) end\nlocal function f() local o = b; set(); return o end\nprint(use(f()))')), 'level 2: the caller\'s (coarse: any function\'s)')
    ok(hasA(v_of('local sl = debug.setlocal\nlocal function f() local o = b; sl(1, 1, a); return o end\nprint(use(f()))')), 'by value: any function\'s')
    local v = v_of('local function h() local z = b; return z end\nlocal function f() local o = b; debug.setlocal(1, 1, a); return o end\nf()\nprint(use2(h()))', 'q:m')
    ok(v and not hasA(v), 'level 1 does not reach another function\'s locals: ' .. vim.inspect(v))
end)

-- (CART-1800: only the profile's library NAMESPACES are globals — `io` holds its library, `file` (an io handle's
-- methods, `file#close` in the signatures) is no global: reading it reads nothing the profile put there)
test('flowtype: a host type\'s method table is no global; a library namespace is (CART-1800)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = 'local f = file\nlocal i = io\nreturn f, i\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, explain = true })
    vim.fn.delete(root, 'rf')
    eq({}, R.objs_of(R.port('g:file')), 'g:file holds nothing')
    ok(vim.tbl_contains(R.objs_of(R.port('g:io')), 'lib:io'), 'g:io holds the io library: ' .. vim.inspect(R.objs_of(R.port('g:io'))))
end)

-- (CART-1792: `a and b` yields a only where a is falsy — a table never is. `x and x.inner or b` is x.inner or b, never x:
-- the walk had merged both operands, and `spec and spec.fn_types` handed every language's spec module to a dynamic read)
test('flowtype: the left operand of `and` reaches the result only as false, never as a table (CART-1792)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B, C = {}, {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'function C.m(self) return "C" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local x = setmetatable({ inner = a }, { __index = C })',
        'local function use(p) return p:m() end', 'use(b)',
        'print(use(x and x.inner or b))' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then v = R.verdict(c) end end
    ok(v and #v.targets == 2 and not vim.tbl_contains(v.targets, 'm.lua::C.m@4'), 'x itself never flows: {A.m, B.m}: ' .. vim.inspect(v))
end)

-- (CART-1813: `(a and b) or c` is b where truthy, else c — the and's falsy part, a's, never reaches it. The or had read
-- the and's port, so `flag and t or u` held flag's boolean, and an escaped a tainted it)
test('flowtype: `a and b or c` holds b and c, never a (CART-1813)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local t, u = {}, {}', 'local flag = rawequal(t, u)',
        'v = flag and t or u', 'w = flag and t', 'x = u or (flag and t)', 'y = (flag and t) or u',
        'local s = {}', 'local z = flag and t', 'if not z then z = s end', 'q = z or u' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, explain = true })
    vim.fn.delete(root, 'rf')
    local function has(g, o) return vim.tbl_contains(R.objs_of(R.port('g:' .. g)), o) end
    local v = R.objs_of(R.port('g:v'))
    ok(#v == 2 and not has('v', 'type:boolean'), 'v holds t and u only: ' .. vim.inspect(v))
    ok(not has('y', 'type:boolean') and #R.objs_of(R.port('g:y')) == 2, 'parenthesized too: ' .. vim.inspect(R.objs_of(R.port('g:y'))))
    ok(has('w', 'type:boolean'), 'a bare and keeps false: ' .. vim.inspect(R.objs_of(R.port('g:w'))))
    ok(has('x', 'type:boolean'), 'an and on the RIGHT of or keeps false: ' .. vim.inspect(R.objs_of(R.port('g:x'))))
    -- (a LOCAL that held an and keeps its other writers: only the expression itself is short-cut)
    ok(#R.objs_of(R.port('g:q')) == 4, 'z or u holds s too: ' .. vim.inspect(R.objs_of(R.port('g:q'))))
end)

-- (CART-1802, Lua 5.1 / LuaJIT: a comparison runs a handler only when every operand has one — `x == nil` and `x < 0`
-- never run x's __eq / __lt; `x == y` with both objects does)
test('flowtype: a comparison with a literal operand runs no handler (CART-1802)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function v_of(cmp, profile)
        local root = tree({ ['m.lua'] = table.concat({
            'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
            'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
            'local function use(p) return p:m() end', 'use(b)',
            'local mt = { __index = A, __eq = function (x, y) return use(x) == 1 end, __lt = function (x, y) return use(x) == 1 end }',
            'local x, y = setmetatable({}, mt), setmetatable({}, mt)', 'local _ = ' .. cmp }, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        if profile then store.data.profile = profile end
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        local callrec = require 'cartograph.callrec'
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    for _, cmp in ipairs({ 'x == nil', 'x < 0', 'x == "s"', 'false == x' }) do
        local v = v_of(cmp)
        ok(v and v.kind == 'exact', cmp .. ': no handler runs, use sees only b: ' .. vim.inspect(v))
    end
    local v = v_of('x == y')
    ok(v and vim.tbl_contains(v.targets or {}, 'm.lua::A.m@1'), 'x == y: both have the handler, it runs with y: ' .. vim.inspect(v))
    -- (Lua 5.2+ — Factorio's profile, lua_version 5.2: an ordering runs either operand's __lt, the literal's partner too;
    -- == still never runs it with a literal)
    local v52 = v_of('x < 0', 'lua-factorio')
    ok(v52 and vim.tbl_contains(v52.targets or {}, 'm.lua::A.m@1'), '5.2: x < 0 runs x\'s __lt: ' .. vim.inspect(v52))
    local e52 = v_of('x == nil', 'lua-factorio')
    ok(e52 and e52.kind == 'exact', '5.2: x == nil still runs nothing: ' .. vim.inspect(e52))
end)

-- (CART-1812, flowpath's l18: a string's method is also what the tree stored in the string library — `string.m = f;
-- use("x")` runs f; the answer had kept only {B.m}, dropping a target its own solution held)
test('flowtype: a method call on a string includes what the tree stored in the string library (CART-1812)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(b)',
        'string.m = function () return "S" end', 'print(use("x"))' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then v = R.verdict(c) end end
    ok(v and #(v.targets or {}) == 2 and vim.tbl_contains(v.targets, 'm.lua::string.m@6'), 'the string library\'s m and B.m: ' .. vim.inspect(v))
end)

-- (CART-1811, flowpath's progs-lib: a library reached WITHOUT reading its global was an empty value — a write through
-- it vanished and a certified, entailed answer was wrong. Each writes `a` into a library that way and reads it back)
test('flowtype: libraries reached by require, the registry, the string metatable and bit hold what is written (CART-1811)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HDR = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(b)' }
    local callrec = require 'cartograph.callrec'
    local function v_of(src)
        local root = tree({ ['m.lua'] = table.concat(HDR, '\n') .. '\n' .. src .. '\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    local function hasA(v) return v and vim.tbl_contains(v.targets or {}, 'm.lua::A.m@1') end
    for name, src in pairs({
        l02 = 'require("io").zz = a\nprint(use(io.zz or b))',
        l03 = 'local ok, m = pcall(require, "io")\nm.zz = a\nprint(use(io.zz or b))',
        l36 = 'require("string").zz = a\nprint(use(string.zz or b))',
        l42 = 'require("package").loaded.io.zz = a\nprint(use(io.zz or b))',
        l22 = 'bit.zz = a\nprint(use(bit.zz or b))',
        l06 = 'debug.getregistry()._LOADED.io.zz = a\nprint(use(io.zz or b))',
        l07 = 'getmetatable("").__index.zz = a\nprint(use(string.zz or b))',
        l35 = 'getmetatable("").__index.m = A.m\nprint(use("x"))',
        l34 = 'debug.setmetatable("", { __index = { m = A.m } })\nprint(use("x"))',
    }) do
        local v = v_of(src)
        ok(hasA(v), name .. ': the write is read back — ' .. vim.inspect(v))
    end
    -- (and only for a receiver holding STRINGS ONLY: a crawl over a merged port — a string or a table — keeps the tables'
    -- metatables; AceLibrary's crawl had rewritten every string's methods, WoW w1 GE certified -> 143,157 refused)
    local mixed = v_of(table.concat({ 'local C = {}', 'function C.m(self) return "C" end',
        'local function crawl(t) local mt = getmetatable(t); if mt then mt.__index = C end end',
        'crawl("s")', 'crawl(setmetatable({}, {}))', 'print(use("x"))' }, '\n'))
    ok(not (mixed and vim.tbl_contains(mixed.targets or {}, 'm.lua::C.m@7')), 'a merged receiver leaves the strings alone: ' .. vim.inspect(mixed))
    -- (a strings-only receiver: replacing the string metatable's __index reaches every string)
    local pure = v_of(table.concat({ 'local C = {}', 'function C.m(self) return "C" end',
        'getmetatable("s").__index = C', 'print(use("x"))' }, '\n'))
    ok(pure and vim.tbl_contains(pure.targets or {}, 'm.lua::C.m@7'), 'getmetatable("").__index = C: strings get C.m: ' .. vim.inspect(pure))
end)

-- (CART-1814, flowpath's p60 / p69: table.move copies a1's elements into a2 — it had no model, and the target held
-- nothing: `table.move({ a }, 1, 1, 1, t); use(t[1])` answered without a)
test('flowtype: table.move copies the elements into its target, by name and by value (CART-1814)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HDR = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(b)' }
    local callrec = require 'cartograph.callrec'
    local function v_of(src)
        local root = tree({ ['m.lua'] = table.concat(HDR, '\n') .. '\n' .. src .. '\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    local function hasA(v) return v and vim.tbl_contains(v.targets or {}, 'm.lua::A.m@1') end
    ok(hasA(v_of('local function put(p) table.move({ a }, 1, 1, 1, p) end\nlocal t = { b }\nput(t)\nprint(use(t[1]))')), 'p60: by name')
    ok(hasA(v_of('local mv = table.move\nlocal t = { b }\nmv({ a }, 1, 1, 1, t)\nprint(use(t[1]))')), 'by value')
    ok(hasA(v_of('local s = { b, a }\ntable.move(s, 2, 2, 1)\nprint(use(s[1]))')), 'within one table (no a2)')
    ok(hasA(v_of('local t = { b }\nlocal r = table.move({ a }, 1, 1, 1, t)\nprint(use(r[1]))')), 'it returns the target')
end)

-- (CART-1813, flowpath: `package.loaded["<module>"]` with a LITERAL name the tree holds is that module's export table —
-- or nil; a computed lookup stays the package-loaded gap, the user's decision)
test('flowtype: package.loaded with a literal module name is that module (CART-1813)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HDR = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(b)' }
    local root = tree({ ['m.lua'] = table.concat(HDR, '\n') .. '\nlocal s = package.loaded["my.mod"]\nif s then s.obj = a end\nprint(use(require("my.mod").obj))\n',
        ['lua/my/mod.lua'] = 'local M = {}\nreturn M\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then v = R.verdict(c) end end
    ok(v and vim.tbl_contains(v.targets or {}, 'm.lua::A.m@1'), 'the write through package.loaded["my.mod"] is the module\'s: ' .. vim.inspect(v))
end)

-- (CART-1817, scoped saturation: a region top escapes nothing — until the region USES what it found. A call through a
-- region port reaches the module functions it reflected; their parameters must hold its arguments. The capability gate
-- escapes what the region held, or `M.f`'s `p:m()` read a whole {B.m} while the loop handed it `a`)
test('flowtype: refl-scope — a call through the reflection region escapes what it reached (CART-1817)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({ 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'require("ma").f(b)',
        'for _, mod in pairs(package.loaded) do if type(mod) == "table" and mod.f then mod.f(a) end end' }, '\n') .. '\n'
    local function v_of(exp, explain)
        local root = tree({ ['m.lua'] = SRC, ['lua/ma.lua'] = 'local M = {}\nfunction M.f(p) return p:m() end\nreturn M\n',
            ['lua/mb.lua'] = 'return { x = 1 }\n', ['lua/mc.lua'] = 'return { y = 2 }\n' })
        store.ingest(ts.extract(root))
        local cap = flowtype.CAP
        flowtype.CAP = 2
        local ok_, R = pcall(flowtype.solve, store, { open = false, exp = exp, explain = explain })
        flowtype.CAP = cap
        vim.fn.delete(root, 'rf')
        assert(ok_, R)
        local callrec = require 'cartograph.callrec'
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c), R.stats.rcap end end
    end
    local function sound(v) return v and (v.partial or vim.tbl_contains(v.targets or {}, 'm.lua::A.m@1')) end
    local v0 = v_of('pkg-modules')
    ok(sound(v0), 'without the scope the saturated region escapes: partial or {A.m, B.m}: ' .. vim.inspect(v0))
    -- (both with opts.explain and without: explain turns off the collapse of saturated ports into one ⊤ (CART-1742),
    -- which had escaped what a region top held — the scope held, and this answer was a WHOLE {B.m}, only under explain)
    for _, explain in ipairs({ false, true }) do
        local v1, rcap = v_of('pkg-modules,refl-scope', explain)
        ok(sound(v1), 'explain=' .. tostring(explain) .. ': the call through the region escapes what it reached: ' .. vim.inspect(v1))
        ok(rcap and rcap.call >= 1, 'explain=' .. tostring(explain) .. ': the call is a capability the region used: ' .. vim.inspect(rcap))
    end
    -- (and a region that only INSPECTS what it found escapes nothing: M.f is no escaped function, its p whole {B.m})
    SRC = SRC:gsub('if type%(mod%) == "table" and mod.f then mod.f%(a%) end', 'print(type(mod))')
    local w0 = v_of('pkg-modules')
    ok(w0 and w0.partial, 'without the scope the saturated region escapes M.f: partial: ' .. vim.inspect(w0))
    for _, explain in ipairs({ false, true }) do
        local w1, rcap = v_of('pkg-modules,refl-scope', explain)
        ok(w1 and not w1.partial and #w1.targets == 1, 'explain=' .. tostring(explain) .. ': an inspecting region escapes nothing: whole {B.m}: ' .. vim.inspect(w1))
        ok(rcap and rcap.call == 0 and rcap.mutate == 0 and rcap.handout == 0, 'explain=' .. tostring(explain) .. ': no capability: ' .. vim.inspect(rcap))
    end
end)

-- (the region bit is its OWN bit: a store base that holds a region value AND an ordinary taint writes the reflected
-- modules too. Read as the ordinary taint alone — an escaped function's parameter, tainted when the phase is seeded,
-- then handed a module by the loop — the store hit the escaped universe's `.k`, where the module is not, and
-- `require("ma").k` stayed whole {B.m})
test('flowtype: refl-scope — a store through a port both region and tainted writes the region (CART-1817)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local SRC = table.concat({ 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        -- (g escapes — h saturates at CAP 2 — so its parameter is tainted while the taint phase is seeded, before the
        -- region's taint reaches it through the loop's call)
        'local function g(x) x.k = a end', 'local function g2(x) end', 'local function g3(x) end',
        'local h = g; if math.random() > 0.3 then h = g2 elseif math.random() > 0.5 then h = g3 end; h(1)',
        'for _, mod in pairs(package.loaded) do g(mod) end',
        'require("ma").k = b', 'local s = require("ma").k', 'print(s:m())' }, '\n') .. '\n'
    for _, explain in ipairs({ false, true }) do
        local root = tree({ ['m.lua'] = SRC, ['lua/ma.lua'] = 'local M = {}\nreturn M\n',
            ['lua/mb.lua'] = 'return { x = 1 }\n', ['lua/mc.lua'] = 'return { y = 2 }\n' })
        store.ingest(ts.extract(root))
        local cap = flowtype.CAP
        flowtype.CAP = 2
        local ok_, R = pcall(flowtype.solve, store, { open = false, exp = 'pkg-modules,refl-scope', explain = explain })
        flowtype.CAP = cap
        vim.fn.delete(root, 'rf')
        assert(ok_, R)
        local callrec = require 'cartograph.callrec'
        local v
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 's:m' then v = R.verdict(c) end end
        ok(v and (v.partial or vim.tbl_contains(v.targets or {}, 'm.lua::A.m@1')), 'explain=' .. tostring(explain) .. ': the loop may have written a into ma.k: ' .. vim.inspect(v))
        ok(R.stats.rcap and R.stats.rcap.mutate >= 1, 'the store is a capability the region used: ' .. vim.inspect(R.stats.rcap))
    end
end)

-- (an OPERATOR over region values runs a handler only if an operand may be an object whose metatable holds that key: a
-- tree with one unrelated __concat releases the handler name, and `n .. k` over a module's keys was a region call that
-- escaped every module; flowpath on CART-1817)
test('flowtype: refl-scope — an operator over region values is no call where no region object has the handler (CART-1817)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function run(extra)
        local SRC = table.concat({ 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
            'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
            'require("ma").f(b)',
            'local C = setmetatable({}, { __concat = function (x, y) return "c" end })', 'print(C .. "x")',
            'for n, mod in pairs(package.loaded) do for k in pairs(mod) do print(n .. "." .. k) end end' }, '\n') .. '\n'
        local root = tree({ ['m.lua'] = SRC, ['lua/ma.lua'] = 'local M = {}\nfunction M.f(p) return p:m() end\nreturn M\n',
            ['lua/mb.lua'] = 'return { x = 1 }\n', ['lua/mc.lua'] = extra or 'return { y = 2 }\n' })
        store.ingest(ts.extract(root))
        local cap = flowtype.CAP
        flowtype.CAP = 2
        local ok_, R = pcall(flowtype.solve, store, { open = false, exp = 'pkg-modules,refl-scope' })
        flowtype.CAP = cap
        vim.fn.delete(root, 'rf')
        assert(ok_, R)
        local callrec = require 'cartograph.callrec'
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c), R.stats.rcap end end
    end
    local v, rcap = run()
    ok(v and not v.partial and #v.targets == 1, 'no reflected object has __concat: M.f stays unescaped, whole {B.m}: ' .. vim.inspect(v) .. vim.inspect(rcap))
    -- (and a module whose object DOES carry __concat: the concatenation may run it, the region escapes)
    local w = run('local H = setmetatable({}, { __concat = function (x, y) return x end })\nreturn { h = H }\n')
    ok(w and w.partial, 'a reflected object with __concat: the call may run it, M.f escapes: ' .. vim.inspect(w))
end)

-- (CART-1856: a region value handed to a LOST call — a builtin reached by value with no model, a host function's
-- declared `any` result — is a hand-out, as an argument of a call the solve lost is. The two rules escaped their
-- arguments by each(ap), empty for a region top: nothing escaped, no capability fired, and ma.k stayed a whole {B.m})
test('flowtype: refl-scope — a region value handed to a lost builtin or a host `any` call escapes what it held (CART-1856)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function run(call, exp, profile)
        local SRC = table.concat({ 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
            'require("ma").k = setmetatable({}, { __index = B })', 'local w = coroutine.wrap',
            'for _, mod in pairs(package.loaded) do ' .. call .. ' end',
            'local s = require("ma").k', 'print(s:m())' }, '\n') .. '\n'
        local root = tree({ ['m.lua'] = SRC, ['lua/ma.lua'] = 'local M = {}\nreturn M\n',
            ['lua/mb.lua'] = 'return { x = 1 }\n', ['lua/mc.lua'] = 'return { y = 2 }\n' })
        store.ingest(ts.extract(root))
        store.data.profile = profile
        local cap = flowtype.CAP
        flowtype.CAP = 2
        local ok_, R = pcall(flowtype.solve, store, { open = false, exp = exp })
        flowtype.CAP = cap
        vim.fn.delete(root, 'rf')
        assert(ok_, R)
        local callrec = require 'cartograph.callrec'
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 's:m' then return R.verdict(c), R.stats.rcap end end
    end
    for _, k in ipairs({ { 'w(mod)' }, { 'vim.fn.get(mod, "k")', 'nvim' } }) do
        local v0 = run(k[1], 'pkg-modules', k[2])
        ok(v0 and v0.partial, k[1] .. ': without the scope the saturated region escapes: partial: ' .. vim.inspect(v0))
        local v, rcap = run(k[1], 'pkg-modules,refl-scope', k[2])
        ok(v and v.partial, k[1] .. ': the lost call may write ma.k: partial: ' .. vim.inspect(v))
        ok(rcap and rcap.handout >= 1, k[1] .. ': the hand-out is a capability the region used: ' .. vim.inspect(rcap))
    end
    -- (and a region that only inspects: no capability, ma.k whole)
    local u, rcap = run('print(type(mod))', 'pkg-modules,refl-scope')
    ok(u and not u.partial and #u.targets == 1, 'an inspecting region escapes nothing: whole {B.m}: ' .. vim.inspect(u) .. vim.inspect(rcap))
end)

-- (CART-1864: a MEMBER of unknown code is unknown code. `require("notintree").f` read EXT's field port, which holds only
-- what the tree stored there: `ext.f(t)` called nothing, t was never handed to unknown code, and t.k answered a wrong
-- whole exact {B.m} — only `ext(t)` itself was a call of unknown code. A store into it hands the value over too)
test('flowtype: a member of unknown code is unknown code: calling it or storing into it hands the value over (CART-1864)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function v_of(src)
        local root = tree({ ['m.lua'] = table.concat({ 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
            'local ext = require("notintree")', 'local t = { k = setmetatable({}, { __index = B }) }', src,
            'local s = t.k', 'local function use(p) return p:m() end', 'print(use(s))' }, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        local callrec = require 'cartograph.callrec'
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    for _, src in ipairs({ 'ext(t)', 'ext.f(t)', 'ext:f(t)', 'local f = ext.f; f(t)', 'ext.g.h(t)', 'ext.k = t' }) do
        local v = v_of(src)
        ok(v and v.partial, src .. ': the module may write t.k: partial: ' .. vim.inspect(v))
    end
    local w = v_of('print(ext.f)')
    ok(w and not w.partial and #w.targets == 1, 'only READ from it, t is not handed: whole {B.m}: ' .. vim.inspect(w))
end)

-- (CART-1859, the entry points' first piece: every argument handed over — to unknown code, a lost builtin, a host `any`
-- call — names the call it was handed at. A call the solve finds to be unknown code's only later (a member of an
-- unmapped module, load's result) had no site at all: attribution fell back to the files of the objects handed)
test('flowtype: R.handouts names the site and kind of every value handed over (CART-1859)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local t, u, v, w, x = {}, {}, {}, {}, {}',
        'ext.f(t)',
        'local g = load(io.read())',
        'g(u)',
        'load(io.read(), "x", "t", v)',
        'local cw = coroutine.wrap',
        'cw(w)',
        'print(vim.fn.get(x, 1))',
        'local function own(p) return p end',
        'own({})',
        'local z = {}',
        't.cb(z)',
        'local env = {}',
        'setfenv(g, env)',
        'local q = {}',
        't.h = ext.f',
        't.h(q)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    store.data.profile = 'nvim'
    local R = flowtype.solve(store, { open = false })
    vim.fn.delete(root, 'rf')
    local function has(kind, site, label)
        for _, h in ipairs(R.handouts) do
            if h.kind == kind and h.site == site and vim.tbl_contains(h.held, label) then return true end
        end
        return false
    end
    local dump = vim.inspect(R.handouts)
    ok(has('call', 'm.lua:2:0', 'tbl:m.lua:1:22'), 'a member of an unmapped module, called: t at its call: ' .. dump)
    ok(has('call', 'm.lua:4:0', 'tbl:m.lua:1:26'), 'load\'s result, called: u at its call: ' .. dump)
    ok(has('load', 'm.lua:3:10', 'type:any'), 'load\'s own argument: ' .. dump)
    ok(has('load', 'm.lua:5:0', 'tbl:m.lua:1:30'), 'load\'s env argument: ' .. dump)
    ok(has('builtin-lost', 'm.lua:7:0', 'tbl:m.lua:1:34'), 'a builtin reached by value with no model: ' .. dump)
    ok(has('host-any', 'm.lua:8:6', 'tbl:m.lua:1:38'), 'a host function\'s `any` result: ' .. dump)
    ok(has('lost-call:tainted', 'm.lua:12:0', 'tbl:m.lua:11:10'), 'a call through a field unknown code may write: ' .. dump)
    ok(has('setfenv', 'm.lua:14:0', 'tbl:m.lua:13:12'), 'the environment set on unknown code: ' .. dump)
    ok(has('lost-call:ext', 'm.lua:17:0', 'tbl:m.lua:15:10'), 'a lost callee that may hold unknown code: ' .. dump)
    for _, h in ipairs(R.handouts) do ok(h.site ~= 'm.lua:10:0', 'the tree\'s own function is handed nothing: ' .. vim.inspect(h)) end
end)

-- (CART-1868: a HANDLER the walk runs — an operator's, a store's __newindex, `#`'s __len, a generic for's iterator — had
-- no site, or inside a call's arguments that call's: `ext.g(t + x)` handed x to __add's handler AT ext.g's call, and a
-- contract on ext.g governed it. Each is keyed at its operator token; a closed function's instance names its calls too)
test('flowtype: a handler the walk runs names its own access as the hand-out site (CART-1868)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local mt = { __add = ext.add, __newindex = ext.set, __len = ext.len }',
        'local t, u, v, w, x = setmetatable({}, mt), {}, {}, {}, {}',
        'local s = t + u',
        't.k = v',
        't[1] = w',
        'local n = #t',
        'function t.fn() end',
        'for _ in ext.iter, t do end',
        'ext.g(t + x)',
        'local function it(st, c) require("notintree").h(st); return nil end',
        'for _ in it, {} do end',
        'setmetatable(_G, { __newindex = ext.gset })',
        'gy = {}' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local Rc = flowtype.solve(store, { open = false, contracts = { { id = 'g', site = 'm.lua:9:0', clauses = { 'no-write' }, src = 'test' } } })
    vim.fn.delete(root, 'rf')
    local function has(R_, kind, site, label)
        for _, h in ipairs(R_.handouts) do
            if h.kind == kind and h.site == site and vim.tbl_contains(h.held, label) then return true end
        end
        return false
    end
    local dump = vim.inspect(R.handouts)
    ok(has(R, 'call', 'm.lua:3:12', 'tbl:m.lua:2:44'), 'u, handed to __add: at the `+`: ' .. dump)
    ok(has(R, 'call', 'm.lua:4:2', 'tbl:m.lua:2:48'), 'v, handed to __newindex: at the field stored: ' .. dump)
    ok(has(R, 'call', 'm.lua:5:1', 'tbl:m.lua:2:52'), 'w, through a computed key: at the `[`: ' .. dump)
    ok(has(R, 'call', 'm.lua:6:10', 'tbl:m.lua:2:35'), 't, handed to __len: at the `#`: ' .. dump)
    ok(has(R, 'call', 'm.lua:7:11', 'm.lua::t.fn@7'), 'a function declared into t: at its name: ' .. dump)
    ok(has(R, 'call', 'm.lua:8:6', 'tbl:m.lua:2:35'), 'a generic for over unknown code\'s iterator: at the `in`: ' .. dump)
    ok(has(R, 'call', 'm.lua:9:8', 'tbl:m.lua:2:56') and not has(R, 'call', 'm.lua:9:0', 'tbl:m.lua:2:56'),
        'x, handed to __add inside ext.g\'s arguments: at the `+`, not at ext.g\'s call: ' .. dump)
    ok(has(R, 'call', 'm.lua:10:25', 'tbl:m.lua:11:13'), 'a closed iterator\'s instance names its call: ' .. dump)
    ok(has(R, 'call', 'm.lua:13:0', 'tbl:m.lua:13:5'), 'a global stored through _G\'s __newindex: at its name: ' .. dump)
    for _, h in ipairs(R.handouts) do
        if not h.site then ok(#h.held == 1 and h.held[1] == 'external', 'site-less: unknown code calling back alone: ' .. vim.inspect(h)) end
    end
    -- (a contract on ext.g's call governs what ext.g is handed — not what __add's handler is)
    ok(not has(Rc, 'contract:g', 'm.lua:9:0', 'tbl:m.lua:2:56') and has(Rc, 'call', 'm.lua:9:8', 'tbl:m.lua:2:56'),
        'x stays unknown code\'s at the `+`: ' .. vim.inspect(Rc.handouts))
end)

-- (CART-1872: a SITE CONTRACT HOLDS AT A LOST CALL. `t.cb(z)` calls through a field of t, which unknown code holds and
-- may write: the call is lost, and it had handed z to every escaped function whatever the contract at its site said —
-- on self, contracting every hand-out site won 0 answers. The contract now governs it: z goes to the contract's code
-- alone; a function among the arguments is called back unless no-callback)
test('flowtype: a site contract holds at a lost call (CART-1872)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local t = {}',
        'ext.f(t)',
        'local z = { k = setmetatable({}, { __index = A }) }',
        't.cb(z)',
        'local r = z.k:m()',
        'local w = { k = setmetatable({}, { __index = A }) }',
        'local function h(p) return p.k:m() end',
        'h(w)',
        't.cb2(h)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local function con(cls) return { { id = 'cb', site = 'm.lua:7:0', clauses = cls, src = 'test' }, { id = 'cb2', site = 'm.lua:12:0', clauses = cls, src = 'test' } } end
    local R0 = flowtype.solve(store, { open = false })
    local R = flowtype.solve(store, { open = false, contracts = con({ 'no-write', 'no-callback' }) })
    local Rcb = flowtype.solve(store, { open = false, contracts = con({ 'no-write' }) })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local function call(full) for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return c end end end
    local v0, v = R0.verdict(call('z.k:m')), R.verdict(call('z.k:m'))
    ok(v0 and v0.partial, 'no contract: z is handed to whatever t.cb may hold: partial')
    ok(v and not v.partial and v.kind == 'exact' and table.concat(v.targets, ',') == 'm.lua::A.m@2', 'both lost calls under contract: whole {A.m}: ' .. vim.inspect(v))
    eq(R.assumes(call('z.k:m')), { 'cb', 'cb2' }, 'z.k:m stands on both contracts')
    local kinds = {}
    for _, h in ipairs(R.handouts) do if h.site == 'm.lua:7:0' then kinds[h.kind] = true end end
    ok(kinds['contract:cb'] and not kinds['lost-call:tainted'], 'the lost call\'s hand-out is the contract\'s: ' .. vim.inspect(kinds))
    local led = {}
    for _, e in ipairs(R.entry_contracts) do led[e.id] = e end
    eq(led['cb'].sites, { 'm.lua:7:0' }, 'the contract met its lost call')
    -- (no-write alone: the contract's code may call h back with anything — p.k:m is partial, and so, through h, is z.k:m)
    ok(Rcb.verdict(call('p.k:m')).partial, 'h called back with unknown arguments: p.k:m partial')
    -- (past CAP the contract lapses: a SATURATED callee is the analysis's own loss — any tree function — not unknown code)
    root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local t = {}',
        'ext.f(t)',
        'local g = t.cb',
        'g = function() end',
        'g = function() end',
        'g = function() end',
        'local y = {}',
        'g(y)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local okk, Rs = pcall(flowtype.solve, store, { open = false, contracts = { { id = 'g', site = 'm.lua:8:0', clauses = { 'no-write', 'no-callback' }, src = 'test' } } })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    ok(okk, tostring(Rs))
    kinds = {}
    for _, h in ipairs(Rs.handouts) do if h.site == 'm.lua:8:0' then kinds[h.kind] = true end end
    ok(kinds['lost-call:saturated'] and not kinds['contract:g'], 'a saturated callee hands y over past the contract: ' .. vim.inspect(kinds))
end)

-- (CART-1860: the entry-points report's attribution — a partial answer's taint walked back to its seed, and the seed's
-- object to the hand-out that let it go: the call that handed it to unknown code, the lost builtin that took it. The
-- seeds had ended at a reason string, which names no site)
test('flowtype: R.entry_of names the hand-out a partial answer first traces to (CART-1860)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local t = { k = setmetatable({}, { __index = A }) }',
        'ext.f(t)',
        'local r1 = t.k:m()',
        'local function cb(p) return p:m() end',
        'cb(setmetatable({}, { __index = A }))',
        'local cw = coroutine.wrap',
        'cw(cb)',
        'local w = { k = setmetatable({}, { __index = A }) }',
        'cw(w)',
        'local r2 = w.k:m()',
        'local C, D = {}, {}',
        'function C.n(self) return 3 end',
        'function D.n(self) return 4 end',
        'local own = setmetatable({}, { __index = C })',
        'local r3 = own:n()',
        'local kk = io.read()',
        'local r4 = t[kk]:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local function at(R, full)
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return R.verdict(c) end end
    end
    local R0 = flowtype.solve(store, { open = false })
    local R = flowtype.solve(store, { open = false, explain = true })
    vim.fn.delete(root, 'rf')
    for _, full in ipairs({ 't.k:m', 'p:m', 'w.k:m', 'own:n' }) do
        local v0, v = at(R0, full), at(R, full)
        ok(v ~= nil, full .. ' has an answer')
        eq(v and v.partial or false, v0 and v0.partial or false, full .. ': partial with explain off as on')
    end
    local function entry(full) local e = R.entry_of(at(R, full)); return e, vim.inspect(e) end
    local e, d = entry('t.k:m')
    ok(e and e.cause == 'unknown-code' and e.dir == 'out' and vim.deep_equal(e.sites, { 'call m.lua:5:0' }), 'a field unknown code may write: the call that handed t over: ' .. d)
    e, d = entry('p:m')
    ok(e and e.cause == 'builtin-lost' and e.dir == 'in' and vim.deep_equal(e.sites, { 'builtin-lost m.lua:10:0' }), 'a parameter of a function a lost builtin took: its call, passing IN: ' .. d)
    e, d = entry('w.k:m')
    ok(e and e.cause == 'builtin-lost' and e.dir == 'out' and vim.deep_equal(e.sites, { 'builtin-lost m.lua:12:0' }), 'a field of what a lost builtin took: its call: ' .. d)
    e, d = entry('t[kk]:m')
    ok(e and e.cause == 'unknown-code' and vim.deep_equal(e.sites, { 'call m.lua:5:0' }), 'a dynamic read of what unknown code holds — the outside writes any field of what escaped: the call: ' .. d)
    eq(R.entry_of(at(R, 'own:n')), nil, 'a whole answer has no entry')
    local cl = R.xclosure()
    ok((cl['call m.lua:5:0'] or 0) >= 3, 't, its k and k\'s metatable: ' .. vim.inspect(cl))
    -- (a chain that ends at a SATURATED port: the analysis's own loss, named by the port — no entry site)
    root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local function id(x) return x end',
        'id({}); id({}); id({})',
        'local s = id({}) or setmetatable({}, { __index = A })',
        'local r = s:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    R = flowtype.solve(store, { open = false, explain = true })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    e, d = entry('s:m')
    ok(e and e.cause == 'saturated' and e.sites == nil and tostring(e.at):match('^a:m%.lua::id@3:1') ~= nil, 'saturated past CAP: the port: ' .. d)
    -- (an object saturation reached FIRST and unknown code was handed after: its hand-out — the root no refinement of
    -- the solve removes)
    root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local function id(x) return x end',
        'id({}); id({})',
        'local o = { k = setmetatable({}, { __index = A }) }',
        'id(o)',
        'ext.f(o)',
        'local kk = io.read()',
        'local r = o[kk]:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    flowtype.CAP = 2
    R = flowtype.solve(store, { open = false, explain = true })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    e, d = entry('o[kk]:m')
    ok(e and e.cause == 'unknown-code' and vim.deep_equal(e.sites, { 'call m.lua:8:0' }), 'saturated first, then handed to unknown code: the call: ' .. d)
    -- (a lost builtin's RESULT read by the answer — vimruntime's `pcall(require, 'string.buffer')`: the call's site)
    root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local okk, lib = pcall(require, "notintree2")',
        'local u = lib or setmetatable({}, { __index = A })',
        'local r = u:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    R = flowtype.solve(store, { open = false, explain = true })
    vim.fn.delete(root, 'rf')
    e, d = entry('u:m')
    ok(e and e.cause == 'builtin-lost' and vim.deep_equal(e.sites, { 'builtin-lost m.lua:3:17' }), 'a lost builtin\'s result: its call: ' .. d)
    -- (a host function's `any` result: what it was handed escapes, and the result is tainted — each names the call)
    root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local hh = { k = setmetatable({}, { __index = A }) }',
        'local y = vim.fn.get(hh, 1)',
        'local r = hh.k:m()',
        'local bb = setmetatable({}, { __index = A })',
        'local y2 = vim.fn.get({ bb }, 1)',
        'local u = y2 or setmetatable({}, { __index = A })',
        'local r2 = u:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    store.data.profile = 'nvim'
    R = flowtype.solve(store, { open = false, explain = true })
    vim.fn.delete(root, 'rf')
    e, d = entry('hh.k:m')
    ok(e and e.cause == 'host-any' and e.dir == 'out' and vim.deep_equal(e.sites, { 'host-any m.lua:4:10' }), 'a field of what a host `any` call was handed: its call: ' .. d)
    e, d = entry('u:m')
    ok(e and e.cause == 'host-any' and vim.deep_equal(e.sites, { 'host-any m.lua:7:11' }), 'a host `any` result: its call: ' .. d)
end)

-- (CART-1866: EVERY ROOT. R.entry_of's `sites` follow the closure's spanning tree — one witness route per answer; `all`
-- lists every hand-out whose object reaches the answer's object, back over fields and prototypes: x is reached from r1
-- (a field), r2 (a field of a field) and p (x is its prototype); y only from its own hand-out)
test('flowtype: R.entry_of lists every hand-out that reaches an answer, not one witness (CART-1866)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local x = { k = setmetatable({}, { __index = A }) }',
        'local r1 = { x = x }',
        'local r2 = { y = { z = x } }',
        'ext.f(r1)',
        'ext.g(r2)',
        'local a1 = x.k:m()',
        'local y = { k = setmetatable({}, { __index = B }) }',
        'ext.h(y)',
        'local a2 = y.k:m()',
        'local p = setmetatable({}, { __index = x })',
        'ext.p(p)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local function at(R, full) for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return R.verdict(c) end end end
    local R = flowtype.solve(store, { open = false, explain = true })
    vim.fn.delete(root, 'rf')
    local e = R.entry_of(at(R, 'x.k:m'))
    eq(e and e.all, { 'call m.lua:14:0', 'call m.lua:7:0', 'call m.lua:8:0' }, 'x: through a field, a field of a field, a prototype')
    eq(e and #e.sites, 1, 'the witness is one of them')
    e = R.entry_of(at(R, 'y.k:m'))
    eq(e and e.all, { 'call m.lua:11:0' }, 'y: its own hand-out alone')
    -- (a PROTOTYPE alone: p's metatable field is past CAP 2, so no field route reaches x — its prototype link does)
    root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local x = { k = setmetatable({}, { __index = A }) }',
        'local p = {}',
        'setmetatable(p, { __index = x })',
        'setmetatable(p, { __index = {} })',
        'setmetatable(p, { __index = {} })',
        'ext.p(p)',
        'local a1 = x.k:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local okk, R2 = pcall(flowtype.solve, store, { open = false, explain = true })
    e = okk and R2.entry_of(at(R2, 'x.k:m'))
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(okk, R2)
    eq(e and e.all, { 'call m.lua:9:0' }, 'reached through the prototype link alone')
end)

-- (CART-1861: ENTRY CONTRACTS — a declared promise about the unknown code at one entry point, by the MODULE a require
-- the tree cannot map loads or by the SITE that hands values over. What it is handed does not escape there; the answers
-- it makes whole cite it, R.assumes, exactly: dropping that contract alone changes the answer)
test('flowtype: an entry contract makes whole what unknown code was handed, and every answer it makes whole cites it (CART-1861)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local lpeg = require("lpeg")',
        'local ju = require("jit.util")',
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local C, D = {}, {}',
        'function C.n(self) return 3 end',
        'function D.n(self) return 4 end',
        'local E, F = {}, {}',
        'function E.o(self) return 5 end',
        'function F.o(self) return 6 end',
        'local G, H = {}, {}',
        'function G.p(self) return 7 end',
        'function H.p(self) return 8 end',
        'local t = { k = setmetatable({}, { __index = A }) }',
        'lpeg.match(t)',
        'local r1 = t.k:m()',
        'local u = { k = setmetatable({}, { __index = C }) }',
        'ext.f(u)',
        'local r2 = u.k:n()',
        'local w = { k = setmetatable({}, { __index = E }) }',
        'lpeg.match(w)',
        'ext.g(w)',
        'local r3 = w.k:o()',
        'local v = { k = setmetatable({}, { __index = G }) }',
        'ju.funcinfo(v)',
        'local r4 = v.k:p()',
        'local I, J = {}, {}',
        'function I.z(self) return 9 end',
        'function J.z(self) return 10 end',
        'local function cb(q) return q:z() end',
        'cb(setmetatable({}, { __index = I }))',
        'lpeg.Cmt(cb)',
        'local K, L = {}, {}',
        'function K.y(self) return 11 end',
        'function L.y(self) return 12 end',
        'local env = { k = setmetatable({}, { __index = K }) }',
        'setfenv(ext.h, env)',
        'local r6 = env.k:y()',
        'local pat = lpeg.P("a")',
        'local r7 = pat:m()',
        'local M1, M2 = {}, {}',
        'function M1.x(self) return 13 end',
        'function M2.x(self) return 14 end',
        'local function rd(q) return q:x() end',
        'rd(setmetatable({}, { __index = M1 }))',
        'load(rd)',
        'ju.funcinfo(lpeg)',
        'local mix = (os.time() > 0) and lpeg.P("b") or setmetatable({}, { __index = A })',
        'local r8 = mix:m()',
        'local holder = (os.time() > 0) and { m = lpeg.match } or setmetatable({}, { __index = A })',
        'local r9 = holder:m()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local function call(full) for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return c end end end
    local LPEG = { id = 'lpeg-reads', module = 'lpeg', clauses = { 'no-write', 'no-callback' }, src = 'the lpeg manual' }
    local ALL = {
        LPEG,
        { id = 'ext-f', site = 'm.lua:19:0', clauses = { 'no-write', 'no-callback' }, src = 'a test' },
        { id = 'ext-g', site = 'm.lua:23:0', clauses = { 'no-write' }, src = 'a test' },
        { id = 'fenv', site = 'm.lua:38:0', clauses = { 'no-write' }, src = 'a test' },
        { id = 'ld', site = 'm.lua:47:0', clauses = { 'no-write', 'no-callback' }, src = 'a test' },
        { id = 'nowhere', site = 'm.lua:99:0', clauses = { 'no-write' }, src = 'a test' },
    }
    local R0 = flowtype.solve(store, { open = false })
    local R = flowtype.solve(store, { open = false, contracts = ALL })
    local Rcb = flowtype.solve(store, { open = false, contracts = { { id = 'lpeg-calls', module = 'lpeg', clauses = { 'no-write' }, src = 'the lpeg manual' } } })
    for _, full in ipairs({ 't.k:m', 'u.k:n', 'w.k:o', 'v.k:p', 'env.k:y' }) do
        local v = R0.verdict(call(full))
        ok(v and v.partial, full .. ' is partial without a contract: ' .. vim.inspect(v))
    end
    local function whole(Rx, full) local v = Rx.verdict(call(full)); return v ~= nil and not v.partial, vim.inspect(v) end
    -- (lpeg's own value is handed to jit.util too: like EXT it is no object unknown code can write — it does not escape)
    local w, d = whole(R, 't.k:m'); ok(w, 'handed only to lpeg, under its module contract: whole ' .. d)
    eq(R.assumes(call('t.k:m')), { 'lpeg-reads' }, 't.k:m stands on lpeg\'s contract alone')
    w, d = whole(R, 'u.k:n'); ok(w, 'handed only at a site under contract: whole ' .. d)
    -- (on its site's alone: a callback handed out elsewhere that returns what unknown code called it with no longer makes
    -- EXT escape — every member of EXT a callee the solve lost, the call at the site handing u over all the same, CART-1870)
    eq(R.assumes(call('u.k:n')), { 'ext-f' }, 'u.k:n stands on its site\'s contract alone')
    w, d = whole(R, 'w.k:o'); ok(w, 'handed to lpeg and at a site, both under contract: whole ' .. d)
    eq(R.assumes(call('w.k:o')), { 'ext-g', 'lpeg-reads' }, 'w.k:o stands on both its contracts')
    w, d = whole(R, 'env.k:y'); ok(w, 'the environment setfenv handed at a site under contract: whole ' .. d)
    eq(R.assumes(call('env.k:y')), { 'fenv' }, 'env.k:y stands on the setfenv site\'s contract')
    eq(R.verdict(call('q:x')) and R.verdict(call('q:x')).kind, 'exact', 'a load under no-callback does not call its reader')
    eq(R0.verdict(call('q:x')), nil, 'without it the reader is called with unknown arguments')
    eq(R.assumes(call('q:x')), { 'ld' }, 'q:x stands on the load site\'s contract')
    eq(R.verdict(call('pat:m')), nil, 'what lpeg returns is lpeg\'s code: unknown, its contract says nothing of it')
    eq(R.verdict(call('mix:m')), nil, 'a receiver that may hold lpeg\'s value is unknown, beside a tree object')
    eq(R.verdict(call('holder:m')), nil, 'a member that may be lpeg\'s value is an unknown target')
    ok(R.verdict(call('v.k:p')).partial, 'jit.util has no contract: v.k:p stays partial')
    eq(R.assumes(call('v.k:p')), nil, 'a partial answer cites nothing')
    for _, cc in ipairs(store.data.calls) do eq(R.costs(cc), nil, 'under CAP no contract here costs an answer: ' .. tostring(callrec.full(cc))) end
    -- (no-callback both ways: lpeg may call cb with unknown arguments unless its contract says it does not)
    eq(R.verdict(call('q:z')) and R.verdict(call('q:z')).kind, 'exact', 'no-callback: cb is called only by the tree')
    eq(Rcb.verdict(call('q:z')), nil, 'no-write alone: lpeg calls cb, q may be unknown code\'s value')
    w = whole(Rcb, 't.k:m'); ok(w, 'no-write alone still keeps t from escaping')
    -- (the LEDGER: every contract in force, where it met the tree; one that met nothing is listed, unmet)
    local led = {}
    for _, e in ipairs(R.entry_contracts) do led[e.id] = e end
    -- (and m.lua:23:0, ext.g: unknown code holds lpeg's value — jit.util was handed it — so what unknown code returns may
    -- be it, and each callee there is governed by its own contract)
    eq(led['lpeg-reads'].sites, { 'm.lua:16:0', 'm.lua:22:0', 'm.lua:23:0', 'm.lua:33:0', 'm.lua:40:12', 'm.lua:41:11', 'm.lua:49:32', 'm.lua:50:11', 'm.lua:52:11' },
        'lpeg\'s contract met its calls, a method of its value\'s among them')
    eq(led['ext-f'].sites, { 'm.lua:19:0' }, 'the site contract met its site')
    ok(led['nowhere'].met == false and #led['nowhere'].sites == 0, 'a contract no site of the tree is listed, unmet')
    ok(led['lpeg-reads'].dir == 'suppress' and led['lpeg-reads'].basis == 'declared' and led['lpeg-reads'].src == 'the lpeg manual', 'CART-1071\'s record: ' .. vim.inspect(led['lpeg-reads']))
    -- (the hand-outs a contract governed are its rows, not unknown code's)
    local kinds = {}
    for _, h in ipairs(R.handouts) do if h.site == 'm.lua:19:0' then kinds[h.kind] = true end end
    ok(kinds['contract:ext-f'] and not kinds['call'], 'the site\'s hand-out is the contract\'s: ' .. vim.inspect(kinds))
    -- (M.of keys its cache on the contracts in force)
    local Ra, Rb = flowtype.of(store, { open = false }), flowtype.of(store, { open = false, contracts = { LPEG } })
    ok(Ra ~= Rb and Ra.verdict(call('t.k:m')).partial and not Rb.verdict(call('t.k:m')).partial, 'another contract set is another solve')
    -- (a contract is refused, never ignored, when it is not one)
    local function refused(c, pat)
        local okk, err = pcall(flowtype.solve, store, { open = false, contracts = { c } })
        ok(not okk and tostring(err):find(pat, 1, true) ~= nil, pat .. ': ' .. tostring(err))
    end
    refused({ id = 'x', module = 'lpeg', clauses = { 'no-write' } }, '`src` is required')
    refused({ id = 'x', module = 'lpeg', clauses = { 'no-callback' }, src = 's' }, 'no-callback needs no-write')
    refused({ id = 'x', module = 'lpeg', clauses = { 'no-read' }, src = 's' }, 'unknown clause "no-read"')
    refused({ id = 'x', site = '-', clauses = { 'no-write' }, src = 's' }, 'CART-1868')
    refused({ id = 'x', module = 'lpeg', site = 'm.lua:1:0', clauses = { 'no-write' }, src = 's' }, 'exactly one of')
    refused({ id = 'x', module = 'lpeg', clauses = { 'no-write' }, src = 's', dir = 'produce' }, 'unknown field "dir"')
    vim.fn.delete(root, 'rf')
end)

-- (CART-1875: WHAT A CONTRACT COSTS. Past CAP a contract moves saturation both ways (CART-1874): the unknown-code hub
-- holds what unknown code is handed — 5 functions here, past CAP 4. lpeg's no-callback contract keeps its 3 off it,
-- the hub falls under CAP, and unknown code now calls s's setter with EXT: `s.k:m()`, partial without the contract, has
-- no verdict under it. R.costs lists it under the contract — beside R.assumes, from the same drop-one solves)
test('flowtype: an answer less known under a contract than without it lists the contract it costs (CART-1875)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local lpeg = require("lpeg")',
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local s = { k = setmetatable({}, { __index = A }) }',
        'ext.h(function (q) s.k = q end)',
        'lpeg.Cmt(function () return 1 end)',
        'lpeg.Cmt(function () return 2 end)',
        'lpeg.Cmt(function () return 3 end)',
        'ext.h(function () return 4 end)',
        'local function use() return s.k:m() end',
        'local t = { k = setmetatable({}, { __index = B }) }',
        'lpeg.match(t)',
        'local function use2() return t.k:m() end' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local function call(full) for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return c end end end
    local LPEG = { id = 'lpeg-reads', module = 'lpeg', clauses = { 'no-write', 'no-callback' }, src = 'the lpeg manual' }
    local cap = flowtype.CAP
    flowtype.CAP = 4 -- (R.costs solves again on its first call: the cap holds until then)
    local okk, err = pcall(function ()
        local R0 = flowtype.solve(store, { open = false })
        local R = flowtype.solve(store, { open = false, contracts = { LPEG } })
        local v0 = R0.verdict(call('s.k:m'))
        ok(v0 and v0.partial and v0.kind == 'exact', 'without the contract the hub is past CAP: s.k:m partial ' .. vim.inspect(v0))
        eq(R.verdict(call('s.k:m')), nil, 'under it the hub is not, and unknown code calls the setter with EXT')
        eq(R.costs(call('s.k:m')), { 'lpeg-reads' }, 'the answer it lost is listed under the contract')
        eq(R.assumes(call('s.k:m')), nil, 'and stands on nothing')
        local v = R.verdict(call('t.k:m'))
        ok(v and not v.partial, 'what was handed only to lpeg is whole under its contract ' .. vim.inspect(v))
        eq(R.assumes(call('t.k:m')), { 'lpeg-reads' }, 'and stands on it')
        eq(R.costs(call('t.k:m')), nil, 'an answer the contract made whole is no cost')
        eq(R0.costs(call('s.k:m')), nil, 'no contract, no cost')
    end)
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(okk, err)
    -- (a WHOLE answer it costs: under the contract the hub calls `keep` with EXT, `keep`'s parameter — 4 tables and EXT
    -- — passes CAP 4 and escapes x: x.k:m, whole without the contract, is partial under it)
    root = tree({ ['m.lua'] = table.concat({
        'local lpeg = require("lpeg")',
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'lpeg.Cmt(function () return 1 end)',
        'lpeg.Cmt(function () return 2 end)',
        'lpeg.Cmt(function () return 3 end)',
        'ext.h(function () return 4 end)',
        'local function keep(q) local y = q end',
        'local x = { k = setmetatable({}, { __index = A }) }',
        'keep(x); keep({}); keep({}); keep({})',
        'ext.h(keep)',
        'local function use() return x.k:m() end' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    flowtype.CAP = 4
    okk, err = pcall(function ()
        local R0 = flowtype.solve(store, { open = false })
        local R = flowtype.solve(store, { open = false, contracts = { LPEG } })
        local v0, v = R0.verdict(call('x.k:m')), R.verdict(call('x.k:m'))
        ok(v0 and not v0.partial, 'without the contract x.k:m is whole ' .. vim.inspect(v0))
        ok(v and v.partial, 'under it x escaped through keep\'s saturated parameter: partial ' .. vim.inspect(v))
        eq(R.costs(call('x.k:m')), { 'lpeg-reads' }, 'a whole answer made partial is a cost too')
    end)
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(okk, err)
end)

-- (CART-1867: AN UNKNOWN ANSWER'S ENTRY. A receiver that may hold unknown code's own value has no verdict and no taint
-- path; R.unknown_of walks that value's first arrival back to the root the solve made it at — the call of unknown code
-- that returned it, the require of a module outside the tree, a dynamic _G[k] read, unknown code calling a tree
-- function back — and the hand-out site that names; a receiver past CAP is `saturated`. Explain on; the bitset path too)
test('flowtype: an unknown answer traces unknown code\'s value back to the call, require or call-back that made it (CART-1867)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local r = ext.f()',
        'local function u1() return r:m() end',
        'local function u2() return ext.g:m() end',
        'local h = { k = setmetatable({}, { __index = A }) }',
        'if os.time() > 0 then h.k = ext.mk(1) end',
        'if os.time() > 1 then h.k = setmetatable({}, { __index = B }) end',
        'local function u3() return h.k:m() end',
        'local d = _G[("x"):upper()]',
        'local function u4() return d:m() end',
        'local w = setmetatable({}, { __index = B })',
        'local function u5() return w:m() end',
        'local function u6(z) return z:m() end',
        'u6(setmetatable({}, { __index = A })); u6(setmetatable({}, { __index = B }))' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local function call(full) for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return c end end end
    local function pick(u) return u and { cause = u.cause, root = u.root, sites = u.sites, dir = u.dir } end
    local cap, big = flowtype.CAP, flowtype.BIG
    local okk, err = pcall(function ()
        for _, b in ipairs({ big, 1 }) do -- (1: a set of 3 objects is a bitset — h.k's, EXT among them: the dense path)
            flowtype.BIG = b
            local R = flowtype.solve(store, { open = false, explain = true })
            local tag = 'BIG ' .. b .. ': '
            eq(R.stats.xnosrc, 0, tag .. 'every arrival of unknown code\'s value has a source or a root')
            eq(pick(R.unknown_of(call('r:m'))), { cause = 'unknown-code', root = 'call', sites = { 'call m.lua:4:10' }, dir = 'in' }, tag .. 'returned by the call')
            eq(pick(R.unknown_of(call('ext.g:m'))), { cause = 'unknown-code', root = 'require', sites = { 'require m.lua:0:12' }, dir = 'in' }, tag .. 'a member of the module: its require')
            eq(pick(R.unknown_of(call('h.k:m'))), { cause = 'unknown-code', root = 'call', sites = { 'call m.lua:8:28' }, dir = 'in' }, tag .. 'stored in a field: through it, to the call')
            eq(pick(R.unknown_of(call('d:m'))), { cause = 'host-global', root = 'host-global', sites = { 'host-global m.lua:11:10' }, dir = 'in' }, tag .. 'a dynamic _G[k] read, at its site')
            eq(R.unknown_of(call('w:m')), nil, tag .. 'an answer with a verdict has no unknown entry')
        end
        flowtype.BIG = big
        flowtype.CAP = 1 -- (z holds two objects: past CAP — one parameter, ctx off)
        local R = flowtype.solve(store, { open = false, explain = true, ctx = false })
        local u = R.unknown_of(call('z:m'))
        eq(u and u.cause, 'saturated', 'a receiver past CAP is the analysis\'s own loss')
        eq(flowtype.solve(store, { open = false }).unknown_of, nil, 'explain off: no recorder')
    end)
    flowtype.CAP, flowtype.BIG = cap, big
    vim.fn.delete(root, 'rf')
    assert(okk, err)
    -- (unknown code calling a tree function back: CART-1875's fixture under lpeg's contract, CAP 4 — the hub is under
    -- CAP and calls the setter with EXT; s.k:m traces to the setter and the hand-out that gave it to unknown code)
    root = tree({ ['m.lua'] = table.concat({
        'local lpeg = require("lpeg")',
        'local ext = require("notintree")',
        'local A, B = {}, {}',
        'function A.m(self) return 1 end',
        'function B.m(self) return 2 end',
        'local s = { k = setmetatable({}, { __index = A }) }',
        'local function f(q) return q end',
        'local function g(q) s.k = q end',
        'lpeg.Cmt(f)',
        'ext.h(g)',
        'local function use() return s.k:m() end' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    flowtype.CAP = 4
    okk, err = pcall(function ()
        local R = flowtype.solve(store, { open = false, explain = true,
            contracts = { { id = 'lpeg-reads', module = 'lpeg', clauses = { 'no-write', 'no-callback' }, src = 'the lpeg manual' } } })
        local u = R.unknown_of(call('s.k:m'))
        eq(u and { cause = u.cause, root = u.root, sites = u.sites, at = u.at }, { cause = 'unknown-code', root = 'callback', sites = { 'call m.lua:9:0' }, at = 'm.lua::g@7' },
            'called back: the function and where it was handed out')
    end)
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(okk, err)
end)

-- (CART-1861: the scoped key `entry_contracts` — a contract holds for the files of its scope only)
test('flowtype: entry_contracts in scoped config hold in their scope (CART-1861)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local body = function (P, Q, m) return table.concat({
        'local lpeg = require("lpeg")',
        ('local %s, %s = {}, {}'):format(P, Q),
        ('function %s.%s(self) return 1 end'):format(P, m),
        ('function %s.%s(self) return 2 end'):format(Q, m),
        ('local t = { k = setmetatable({}, { __index = %s }) }'):format(P),
        'lpeg.match(t)',
        ('local r = t.k:%s()'):format(m) }, '\n') .. '\n' end
    local root = tree({ ['sub/s.lua'] = body('A', 'B', 'm'), ['o.lua'] = body('C', 'D', 'n') })
    store.ingest(ts.extract(root))
    local cfg = require 'cartograph.config'
    local saved = cfg.scoped
    cfg.scoped = { [root .. '/sub'] = { entry_contracts = { { id = 'lpeg-reads', module = 'lpeg', clauses = { 'no-write', 'no-callback' }, src = 'the lpeg manual' } } } }
    local okk, R = pcall(flowtype.solve, store, { open = false })
    cfg.scoped = saved
    ok(okk, tostring(R))
    local callrec = require 'cartograph.callrec'
    local function v(full) for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return R.verdict(c), c end end end
    local vm, cm = v('t.k:m')
    local vn = v('t.k:n')
    ok(vm and not vm.partial, 'in the scope: whole ' .. vim.inspect(vm))
    ok(vn and vn.partial, 'outside it: partial ' .. vim.inspect(vn))
    eq(R.entry_contracts[1].where, 'scope dir:' .. vim.fn.fnamemodify(root, ':p'):gsub('/+$', '') .. '/sub', 'the ledger names the scope')
    cfg.scoped = { [root .. '/sub'] = { entry_contracts = { { id = 'lpeg-reads', module = 'lpeg', clauses = { 'no-write', 'no-callback' }, src = 'the lpeg manual' } } } }
    local okc, Rc = pcall(flowtype.solve, store, { open = false })
    eq(okc and Rc.assumes(cm), { 'lpeg-reads' }, 'and it is cited')
    cfg.scoped = saved
    vim.fn.delete(root, 'rf')
end)

-- (CART-1870: UNKNOWN CODE'S VALUE NEVER ESCAPES — EXT, or a module contract's. Escaped, the world rule tainted every
-- read of a member of it: every call on unknown code was also a lost call, which hands its arguments over, so a site
-- contract stood on every route that let EXT escape. One fixture per route; each answer cites its own contract alone)
test('flowtype: unknown code\'s value does not escape, whatever route reaches it (CART-1870)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HEAD = { 'local ext = require("notintree")', 'local lpeg = require("lpeg")', 'local A, B = {}, {}',
        'function A.m(self) return 1 end', 'function B.m(self) return 2 end', 'local u = { k = setmetatable({}, { __index = A }) }' }
    local ROUTES = {
        { 'a callback handed out returns what it is called with', 'ext.f(u)', 'local r = u.k:m()', 'ext.on(function (x) return x end)',
            'local C, D = {}, {}', 'function C.n(self) return 3 end', 'function D.n(self) return 4 end',
            'local t = setmetatable({}, { __index = C })', 'ext.slot = t', 'local r2 = t:n()' },
        { 'a field of what unknown code is handed', 'ext.f(u)', 'local r = u.k:m()', 'ext.k({ e = ext })' },
        { 'a prototype of what unknown code is handed', 'ext.f(u)', 'local r = u.k:m()', 'ext.k(setmetatable({}, { __index = ext }))' },
        { 'a saturated port', 'ext.f(u)', 'local r = u.k:m()', 'local s = ext', 's = {}', 's = {}', 's = {}' },
        { 'a module contract\'s value, a field of what other unknown code is handed', 'lpeg.match(u)', 'local r = u.k:m()', 'ext.k({ l = lpeg })' },
        { 'a module contract\'s value in a saturated port', 'lpeg.match(u)', 'local r = u.k:m()', 'local s = lpeg', 's = {}', 's = {}', 's = {}' },
    }
    local callrec = require 'cartograph.callrec'
    for i, rt in ipairs(ROUTES) do
        local lines = vim.list_extend(vim.deepcopy(HEAD), vim.list_slice(rt, 2))
        local root = tree({ ['m.lua'] = table.concat(lines, '\n') .. '\n' })
        store.ingest(ts.extract(root))
        local function call(full) for _, c in ipairs(store.data.calls) do if callrec.full(c) == full then return c end end end
        local con = i >= 5 and { id = 'c', module = 'lpeg', clauses = { 'no-write', 'no-callback' }, src = 'a test' }
            or { id = 'c', site = 'm.lua:6:0', clauses = { 'no-write', 'no-callback' }, src = 'a test' }
        local cap = flowtype.CAP
        if i == 4 or i == 6 then flowtype.CAP = 2 end -- (s's port saturates, holding unknown code's value)
        local R0 = flowtype.solve(store, { open = false })
        local R = flowtype.solve(store, { open = false, contracts = { con } })
        flowtype.CAP = cap
        ok(R0.verdict(call('u.k:m')).partial, rt[1] .. ': u.k:m is partial without the contract')
        local v = R.verdict(call('u.k:m'))
        ok(v and v.kind == 'exact' and not v.partial, rt[1] .. ': whole under its contract ' .. vim.inspect(v))
        eq(R.assumes(call('u.k:m')), { 'c' }, rt[1] .. ': it cites its contract')
        for _, h in ipairs(R0.handouts) do ok(h.kind ~= 'lost-call:ext', rt[1] .. ': no call on unknown code is lost: ' .. vim.inspect(h)) end
        -- (what the tree STORES into unknown code is handed over by the store, not by EXT escaping)
        if call('t:n') then ok(R.verdict(call('t:n')).partial, rt[1] .. ': t, stored into unknown code, stays partial') end
        vim.fn.delete(root, 'rf')
    end
end)

-- (CART-1820, flowpath FLOW-0040: a name a LITERAL-keyed dynamic _G step reaches is no strict global — LibStub's
-- `_G[LIBSTUB_MAJOR] = LibStub`, Altoholic's `_G[v]` over a list of frame names. Its reads were the contract's named
-- global: LibStub listed nothing, `LibStub(...)` called no function, and the answer through it was a WHOLE {B.m})
test('flowtype: a global a literal-keyed dynamic _G step reaches is read as unknown (CART-1820)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local HDR = { 'local A, B = {}, {}', 'function A.m(self) return "A" end', 'function B.m(self) return "B" end',
        'local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })',
        'local function use(p) return p:m() end', 'use(b)' }
    local function v_of(src)
        local root = tree({ ['m.lua'] = table.concat(HDR, '\n') .. '\n' .. src .. '\n' })
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false })
        vim.fn.delete(root, 'rf')
        local callrec = require 'cartograph.callrec'
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then return R.verdict(c) end end
    end
    local function sound(v) return v and (v.partial or vim.tbl_contains(v.targets or {}, 'm.lua::A.m@1')) end
    local v1 = v_of('local MAJOR = "LibStub"\n_G[MAJOR] = function (n) return a end\nprint(use(LibStub("x")))')
    ok(sound(v1), 'a constant local as the key: LibStub may be what was stored: ' .. vim.inspect(v1))
    local v2 = v_of('local frames = { "FrameA", "FrameB" }\nfor _, n in pairs(frames) do _G[n] = a end\nprint(use(FrameB))')
    ok(sound(v2), 'a literal through a table: FrameB may be a: ' .. vim.inspect(v2))
    local v3 = v_of('local k = ...\n_G[k] = a\nprint(use(Other))')
    ok(v3 and not v3.partial, 'a computed key reaches no named global under the contract (FLOW-0108): ' .. vim.inspect(v3))
end)

-- (CART-1818: escape_of answers how an object escaped — a saturated port, or LATE by a named rule (a lost call's argument)
-- — or that it did not: both of the last had read '<- reached ?', and a census of escaped modules took one for the other)
test('flowtype: escape_of names a late escape and a non-escape (CART-1818)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (h saturates at CAP 2: `h(t)` is a lost call, and t escapes LATE, in the taint phase)
    local root = tree({ ['m.lua'] = 'local function g1(x) end\nlocal function g2(x) end\nlocal function g3(x) end\n'
        .. 'local h = g1; if math.random() > 0.3 then h = g2 elseif math.random() > 0.5 then h = g3 end\n'
        .. 'local t = {}\nh(t)\nlocal u = {}\nprint(u)\n' })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local ok_, R = pcall(flowtype.of, store, { open = false, explain = true })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    assert(ok_, R)
    local lt = R.escape_of(R.object('tbl:m.lua:4:10'))
    ok(lt[#lt]:find('escaped late (escmore:lost-call-argument)', 1, true), 'handed to a lost call: ' .. table.concat(lt, ' | '))
    local nu = R.escape_of(R.object('tbl:m.lua:6:10'))
    eq('<- not escaped', nu[#nu], 'u never escaped')
end)

-- (CART-1822: a file chunk's `...` is what its HOST passes — one port per file, read as a lost caller's arguments. It was
-- a fresh empty port per use: WoW's `local _, ns = ...` read nothing, so a call through the addon's private table was
-- whole with no callee)
test('flowtype: a file chunk\'s `...` is its host\'s arguments, not nothing (CART-1822)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local name, ns = ...\nns.f = function () return 1 end\n',
        ['b.lua'] = 'local name, ns = ...\nlocal x = ns.f()\nlocal t = { ... }\nlocal y = t[1].g()\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    vim.fn.delete(root, 'rf')
    local function how(line, name)
        for _, c in ipairs(store.data.calls) do
            if c.line == line and (c.full or c.callee) == name then local _, h = R.callee_of(c); return h end
        end
    end
    eq('partial', how(1, 'ns.f'), 'a call through the host-passed table is no whole answer')
    eq('partial', how(3, 't[1].g'), 'nor through `{ ... }`: every use is the one port')
end)

-- (CART-1822: a DECLARED loader — spec/ecosystem/lua-wow.lua's chunk_args — passes each file of an addon its name and
-- the addon's one private table: a call through `ns` resolves across the addon's files, each position its own value)
test('flowtype: WoW\'s loader passes every file of an addon its name and one private table (CART-1822)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['Addon/Addon.toc'] = '## Title: Addon\na.lua\nb.lua\n',
        ['Addon/a.lua'] = 'local name, ns = ...\nns.f = function () return 1 end\n',
        ['Addon/b.lua'] = 'local name, ns, extra = ...\nlocal x = ns.f()\nlocal y = name.f()\nlocal z = extra.g()\n',
        ['Other/Other.toc'] = '## Title: Other\nc.lua\n',
        ['Other/c.lua'] = 'local _, ns = ...\nlocal w = ns.f()\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    vim.fn.delete(root, 'rf')
    local function callee(file, line, name)
        for _, c in ipairs(store.data.calls) do
            if c.file == file and c.line == line and (c.full or c.callee) == name then
                local fns, how = R.callee_of(c); return (fns and table.concat(fns, ',') or '') .. ' ' .. tostring(how)
            end
        end
    end
    eq('Addon/a.lua::ns.f@1 whole', callee('Addon/b.lua', 1, 'ns.f'), 'the addon\'s private table, shared by its files')
    eq(' whole', callee('Other/c.lua', 1, 'ns.f'), 'another addon\'s table is its own')
    eq(' whole', callee('Addon/b.lua', 3, 'extra.g'), 'past the declared values: nil')
    eq(' whole', callee('Addon/b.lua', 2, 'name.f'), 'position 1 is the name alone, not the table')
end)

-- (CART-1755, opts.litkeys: WoW's `local addon = _G[addonName]` — a local bound to the loader's name and never assigned
-- is the package's name, so the store and the read are the global Addon by name. Off by default: see keyname)
test('flowtype litkeys: `_G[addonName]` is the addon\'s global by name, read and written (CART-1755)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['Addon/Addon.toc'] = '## Title: Addon\na.lua\nb.lua\n',
        ['Addon/a.lua'] = 'local addonName = ...\n_G[addonName] = { g = function () return 1 end }\n',
        ['Addon/b.lua'] = 'local addonName = ...\nlocal addon = _G[addonName]\nlocal x = addon.g()\nlocal y = Addon.g()\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, allcallees = true, litkeys = true })
    vim.fn.delete(root, 'rf')
    local function callee(file, line, name)
        for _, c in ipairs(store.data.calls) do
            if c.file == file and c.line == line and (c.full or c.callee) == name then
                local fns, how = R.callee_of(c); return (fns and table.concat(fns, ',') or '') .. ' ' .. tostring(how)
            end
        end
    end
    eq('Addon/a.lua::g@1 whole', callee('Addon/b.lua', 2, 'addon.g'), '_G[addonName] read by name')
    eq('Addon/a.lua::g@1 whole', callee('Addon/b.lua', 3, 'Addon.g'), 'and the global itself: the store was by name')
end)

-- (CART-1823: a dynamic `_G[k]` read sees the named globals ITS key's literals name — the clause computed-global kept it
-- off every named global, and `Foo = {…}; local k = "Foo"; _G[k].g()` answered whole with no callee)
test('flowtype: a dynamic _G read sees the named global its literal key names (CART-1823)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'Foo = { g = function () return 1 end }',
        'Bar = { g = function () return 2 end }',
        'local k = "Foo"',
        'local x = _G[k].g()',
        'local function get(n) return _G[n] end',
        'local y = get("Bar").g()',
        'local z = _G["Fo" .. "o"]',
    }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, ctx = false, allcallees = true })
    vim.fn.delete(root, 'rf')
    local function callee(line)
        for _, c in ipairs(store.data.calls) do
            if c.line == line and (c.full or c.callee or ''):find('%.g$') then
                local fns, how = R.callee_of(c); return (fns and table.concat(fns, ',') or '') .. ' ' .. tostring(how)
            end
        end
    end
    -- (+nonfn since CART-1864: the dynamic read also holds EXT, "a global the host defines", and a member of unknown
    -- code is unknown code — the one function is still Foo's g alone. Known literals naming no host global: CART-1865)
    eq('m.lua::g@0 whole+nonfn', callee(3), 'the literal through a local: Foo alone')
    eq('m.lua::g@1 whole+nonfn', callee(5), 'through a parameter: only the literal its caller passed')
end)

-- ★ A HOST RECORD'S FIELDS (CART-1827): `debug.getinfo(1, 'S').source` is a string — LuaLS's `---@class debuginfo` /
-- `---@field source string`, distilled into the luajit profile's class_fields. Its receiver had been EMPTY, so `:sub`
-- was the string method hedged (41 such on cartograph's own tree). Only a PRIMITIVE field is believed: `func` is the
-- function asked about — this tree's own g — and a fixed host function there would bind `f()` to nothing, unhedged
local function getinfo_case(src, line, dump)
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.sub(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.sub(self) return 2 end\nreturn B\n',
        ['main.lua'] = src,
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = dump })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' and c.at and atr.sl(c.at) == line then v = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    return v, dump and vim.json.decode(R.dump)
end
test('flowtype: a host record\'s primitive field has its declared type; debuginfo.func stays untyped (CART-1827)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (through a return: the extractor's own record rule, spec/lua.lua RECORD_FIELDS, follows a local, not a call)
    local v = getinfo_case('local function src(i) return debug.getinfo(i, "S").source end\nlocal s = src(1)\nreturn s:sub(2)\n', 2)
    eq('string', v and v.kind, 'source is a string: ' .. vim.inspect(v))
    eq(false, v and v.partial or false, 'a flow, not the empty-receiver hedge: ' .. vim.inspect(v))
    -- (the solve made no fixed host function for `.func`: `f()` may call g)
    local _, D = getinfo_case('local function g() return 1 end\nlocal f = debug.getinfo(g, "f").func\nreturn f()\n', 2, true)
    local labels = {}
    for _, x in ipairs(D.sites) do labels[#labels + 1] = x.label end
    ok(not vim.tbl_contains(labels, 'type:function'), 'no host function site: ' .. table.concat(labels, ' '))
end)

-- ★ A FUNCTION TYPE'S RETURNS, READ WHOLE (CART-1828): `fun():string, ...` (string.gmatch's iterator) had been cut
-- after the first return. Read whole, `...` is no host type — no fixed `type:...` site — while the first stays what it
-- was (gmatch's capture a string). Nor is an ELEMENT the type's own parameters bind (ipairs's V): a fixed `type:V` would
-- swallow a store into the loop's item (vimruntime's TSTreeView:iter())
test('flowtype: a fun type\'s vararg and bound-element returns make no host site (CART-1828)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local _, D = getinfo_case(table.concat({
        'local out = {}',
        'for a, b in ("x=y"):gmatch("(%w+)=(%w+)") do out[a] = b end',
        'local it = ipairs({ "p" })',
        'local i, v = it({ "q" }, 0)',
        'return out, i, v' }, '\n') .. '\n', 99, true)
    local labels = {}
    for _, x in ipairs(D.sites) do labels[x.label] = true end
    ok(labels['type:string'], 'the capture is a string')
    ok(not labels['type:...'], 'no host site for `...`')
    ok(not labels['type:V'], 'no host site for ipairs\'s V')
end)
-- (and a profile function taken as a VALUE is typed `fun(): <its returns>`: a return that is itself a function type is
-- parenthesized, or `vim.spairs`'s `fun(…):K, V` and its T read as three returns, V a fixed host site)
test('flowtype: a profile function value whose return is a function type keeps that type whole (CART-1828)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/main.lua'] = 'local sp = vim.spairs\nlocal it = sp({ a = 1 })\nlocal k, v = it({ a = 1 })\nreturn k, v\n',
        ['plugin/fx.lua'] = 'require("fx.main")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local labels = {}
    for _, x in ipairs(D.sites) do labels[#labels + 1] = x.label end
    ok(vim.tbl_contains(labels, 'type:(fun(table: table<K, V>, index?: K):K, V)'), 'the iterator is one type: ' .. table.concat(labels, ' '))
end)

-- ★ A GENERIC RETURN THROUGH A FUNCTION VALUE (CART-1830): a profile function taken as a value is typed with its
-- parameters, and a call through it binds a generic return to the argument — `vim.spairs` as a value returns its
-- table (T) and an iterator whose K / V are that table's keys / elements. Read as types they had been fixed host sites
-- (`type:T` in 110 results on the self tree), so `v:m()` reached nothing
test('flowtype: a generic return through a profile function value is its argument (CART-1830)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/main.lua'] = table.concat({
            'local A, B = {}, {}',
            'function A.m(self) return 1 end',
            'function B.m(self) return 2 end',
            'local sp = vim.spairs',
            'local t = { a = setmetatable({}, { __index = A }) }',
            'for k, v in sp(t) do v:m() end',
            'return B' }, '\n') .. '\n',
        ['plugin/fx.lua'] = 'require("fx.main")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and atr.sl(c.at) == 5 then v = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local labels = {}
    for _, x in ipairs(D.sites) do labels[x.label] = true end
    ok(not labels['type:T'] and not labels['type:K'] and not labels['type:V'], 'no generic host site')
    ok(whole(v, 'm') and tostring(v.targets[1]):match('A%.m'), 'v is t\'s element: ' .. vim.inspect(v))
end)
test('flowtype: a vararg generic is any of those arguments; an unbound generic is no host site (CART-1830)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/main.lua'] = table.concat({
            'local A, B = {}, {}',
            'function A.m(self) return 1 end',
            'function B.m(self) return 2 end',
            'local a = setmetatable({}, { __index = A })',
            'local x = vim.F.if_nil(nil, a)',                       -- (`...: T` -> T: one of its arguments)
            'x:m()',
            'local y = table.foreach({ 1 }, function (k, v) return v end)', -- (T is the callback's: unbound)
            'return B, y' }, '\n') .. '\n',
        ['plugin/fx.lua'] = 'require("fx.main")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and atr.sl(c.at) == 5 then v = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local labels = {}
    for _, x in ipairs(D.sites) do labels[x.label] = true end
    ok(whole(v, 'm') and tostring(v.targets[1]):match('A%.m'), 'if_nil returns its argument: ' .. vim.inspect(v))
    ok(not labels['type:T'], 'no host site for an unbound T')
end)

-- ★ A GENERIC CONTAINER RETURN (CART-1831): `vim.tbl_values(t: table<any, T>): T[]` is a NEW list of t's elements,
-- `vim.fn.sort(list: T[]): T[]` the list itself — not a host `T[]` whose element was a fixed `type:T`. The dump states
-- the new list's allocation and stores (the walker's own primitives), so it stays closed
test('flowtype: a generic container return is a list of the argument\'s elements (CART-1831)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/main.lua'] = table.concat({
            'local A, B = {}, {}',
            'function A.m(self) return 1 end',
            'function B.m(self) return 2 end',
            'local a = setmetatable({}, { __index = A })',
            'local vs = vim.tbl_values({ x = a })',
            'vs[1]:m()',
            'local l = vim.fn.sort({ a })',
            'l[1]:m()',
            'return B' }, '\n') .. '\n',
        ['plugin/fx.lua'] = 'require("fx.main")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at then v[atr.sl(c.at)] = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local labels = {}
    for _, x in ipairs(D.sites) do labels[x.label] = true end
    ok(whole(v[5], 'm') and tostring(v[5].targets[1]):match('A%.m'), 'tbl_values: t\'s elements: ' .. vim.inspect(v[5]))
    ok(whole(v[7], 'm') and tostring(v[7].targets[1]):match('A%.m'), 'fn.sort: the list itself: ' .. vim.inspect(v[7]))
    ok(not labels['type:T'] and not labels['type:T[]'], 'no generic host site: ' .. tostring(labels['type:T']) .. tostring(labels['type:T[]']))
    local C = require('cartograph.flowcheck').check(D)
    eq(0, C.failed, 'the new list has its writers in the dump: ' .. vim.inspect(C.failures or C):sub(1, 900))
end)
test('flowtype: `vim._ensure_list(x)` is x and a new list holding x - x is no element of itself (CART-1831)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/main.lua'] = 'local x = { "s" }\nlocal e = vim._ensure_list(x)\nreturn x, e\n',
        ['plugin/fx.lua'] = 'require("fx.main")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false, dump = true })
    vim.fn.delete(root, 'rf')
    local D = vim.json.decode(R.dump)
    local xs, hostl
    for _, s in ipairs(D.sites) do
        if s.label:match('^tbl:lua/fx/main%.lua:0:') then xs = s.id end
        if s.label:match('^tbl:host:vim#_ensure_list') then hostl = s.id end
    end
    local ls = {}
    for _, s in ipairs(D.sites) do if s.label:match('fx') or s.label:match('host') then ls[#ls + 1] = s.label end end
    ok(xs and hostl, 'x and the new list are sites: ' .. table.concat(ls, ' '))
    local self_el, holds = false, false
    local function cell(site, objs)
        for _, o in ipairs(objs) do
            if site == xs and o == xs then self_el = true end
            if site == hostl and o == xs then holds = true end
        end
    end
    for _, h in ipairs(D.solution.h) do cell(h[1], h[3]) end
    for _, h in ipairs(D.solution.hdyn or {}) do cell(h[1], h[2]) end -- (the `[]` cells)
    ok(holds, 'the new list holds x')
    ok(not self_el, 'x is no element of itself')
end)

-- (CART-1827: the wow profile types WoW's host calls — `debugstack()` and `strtrim(x)` hold a string, and a string
-- method on them is the string library's. Without a profile both are empty: an undefined global's call reached nothing)
test('flowtype: under the wow profile a WoW host call holds its declared type (CART-1827)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local function objs(profile)
        local root = tree({ ['m.lua'] = 's = debugstack(2)\nt = strtrim(" x ")\nu = t:upper()\nf = CreateFont("x")\n' })
        store.ingest(ts.extract(root))
        store.data.profile = profile
        local R = flowtype.solve(store, { open = false, ctx = false, explain = true })
        vim.fn.delete(root, 'rf')
        local o = {}
        for _, g in ipairs { 's', 't', 'u', 'f' } do o[g] = R.objs_of(R.port('g:' .. g)) end
        return o
    end
    local w, n = objs('wow'), objs(nil)
    eq({ 'type:string' }, w.s, 'debugstack() is a string')
    eq({ 'type:string' }, w.t, 'strtrim, an alias of string.trim, returns a string')
    eq({ 'type:string' }, w.u, 'and a string method on it is the string library\'s')
    eq({}, w.f, 'CreateFont returns a Font: no primitive, no claim')
    eq({}, n.s, 'no profile: nothing')
    eq({}, n.t, 'no profile: nothing')
end)

-- (CART-1829, flowpath FLOW-0042: the string-method hedge — a string method's result on an EMPTY receiver — is typed AND
-- tainted. Experiment sinf-untainted keeps the type and drops the taint: the hedge-free variant a certifying consumer
-- pairs with the default dump, promoting an answer whole where this one certifies)
test('flowtype: experiment sinf-untainted types the hedged result without tainting it (CART-1829)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local T, U = {}, {}', 'function T:upper() return 1 end', 'function U:upper() return 2 end', 'T:upper()', 'U:upper()',
        'local function f(n) local r = n:lower(); return r:upper() end', 'f(UNDEF)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local function v_of(exp)
        local R = flowtype.solve(store, { open = false, ctx = false, exp = exp })
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'r:upper' then return R.verdict(c), R end end
    end
    local d = v_of(nil)
    local u, R = v_of('sinf-untainted')
    vim.fn.delete(root, 'rf')
    ok(d and d.kind == 'string' and d.partial, 'default: the hedge answers, partial: ' .. vim.inspect(d))
    ok(u and u.kind == 'string' and not u.partial, 'hedge-free: the same answer, whole: ' .. vim.inspect(u))
    ok(R.exp and R.exp['sinf-untainted'] ~= nil, 'the solve records the experiment: ' .. vim.inspect(R.exp))
end)

-- (CART-1841, flowpath FLOW-0093: a context-instanced call raises what its callee raises — the instance's error port
-- reaches the caller's, as the shared binding's does (CART-1705); without it a pcall's second value misses the table)
test('flowtype: an instanced call carries what its callee raises to the caller (CART-1841)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local M = {}', 'local function sink(v) return v end', 'local function thrower(x) error({ x = x }) end',
        'function M.go(y) local ok, e = pcall(function () thrower(y) end); return sink(e) end', 'return M' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local AT = require 'cartograph.at'
    local cc, sinkc = {}, nil
    for _, c in ipairs(store.data.calls) do
        local to = c.at and AT.sl(c.at) == 3 and c.to or ''
        if to:match('::thrower@') then cc[c] = to end
        if to:match('::sink@') then sinkc = c end
    end
    local id = next(cc) and cc[next(cc)]
    local function tbl(R) for _, o in ipairs((R.arg_objs(sinkc, 1))) do if tostring(o):match('^tbl:') then return true end end return false end
    local off = flowtype.solve(store, { open = false, ctx = false, argprobes = true })
    local inst = flowtype.solve(store, { open = false, ctxfns = { [id] = true }, ctxcallee = cc, argprobes = true })
    vim.fn.delete(root, 'rf')
    ok(id ~= nil and sinkc ~= nil, 'the calls thrower(y) and sink(e) are in the graph')
    ok(tbl(off), 'one walk: e holds the raised table: ' .. vim.inspect((off.arg_objs(sinkc, 1))))
    ok(tbl(inst), 'instanced: e still holds it: ' .. vim.inspect((inst.arg_objs(sinkc, 1))))
end)

-- (CART-1842, flowpath FLOW-0093: a function nested in a context instance is a new object under the original's id — a
-- receiver holding two instances' closures has ONE target, exact, not narrowed {f, f})
test('flowtype: two instances of one nested function answer one target, exact (CART-1842)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local N, P = {}, {}', 'function N:run() return 0 end', 'local function mk(t) return { run = function () return t end } end',
        'local a = mk(1)', 'local b = mk(2)', 'local o = a; if N:run() then o = b end', 'o:run()',
        'function P:run() return 1 end', 'return N, P' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local AT = require 'cartograph.at'
    local cc, pc, id = {}, nil, nil
    for _, c in ipairs(store.data.calls) do
        if (c.to or ''):match('::mk@') then cc[c] = c.to; id = c.to end
        if AT.sl(c.at) == 6 then pc = c end
    end
    local v = flowtype.solve(store, { open = false, ctxfns = { [id] = true }, ctxcallee = cc }).verdict(pc)
    vim.fn.delete(root, 'rf')
    ok(id ~= nil and pc ~= nil, 'the calls mk(…) and o:run() are in the graph')
    eq('exact', v and v.kind, 'both instances\' run: ' .. vim.inspect(v))
    eq({ 'm.lua::run@2' }, v and v.targets, 'the one target')
end)

-- (CART-1845, flowpath FLOW-0122: the string-method rule decides on an EMPTY receiver, so it runs after open mode
-- seeds EXT into exported functions' parameters — an outside caller may pass s a table with its own upper)
test('flowtype: open mode\'s outside arguments come before the string-method rule (CART-1845)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = table.concat({
        'local M, T, U = {}, {}, {}', 'function T:lower() return 1 end', 'function U:lower() return 2 end',
        'function M.f(s) local r = s:upper(); return r:lower() end', 'return M' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local AT = require 'cartograph.at'
    local c
    for _, x in ipairs(store.data.calls) do if AT.sl(x.at) == 3 and AT.sc(x.at) > 40 then c = x end end
    local closed = flowtype.solve(store, { open = false, ctx = false }).verdict(c)
    local opened = flowtype.solve(store, { open = true, ctx = false }).verdict(c)
    vim.fn.delete(root, 'rf')
    ok(c ~= nil, 'the call r:lower() is in the graph')
    eq('string', closed and closed.kind, 'closed: no caller, s:upper() returned a string: ' .. vim.inspect(closed))
    ok(not (opened and opened.kind == 'string'), 'open: s may be any outside value, no string answer: ' .. vim.inspect(opened))
end)
