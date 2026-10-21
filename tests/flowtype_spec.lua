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
        'local Obj = loadstring("return ...")(Reg)',
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
        'local t = { cb = function () end }', 'local f = load("return ...")', 'f(t)',
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
    for _, full in ipairs { 'g:m', 'h:m' } do ok(not N.verdict(at[full]), 'no model: ' .. full .. ' has no answer') end
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
    -- (a generic `T` of a `T[]` argument is its ELEMENT: vim.version.last({ b }) is b, not a fixed value named T)
    local g = verdict_of('local z = vim.version.last({ b })\nuse(z)', 'nvim', false)
    ok(g and g.kind == 'narrowed' and #g.targets == 2, 'vim.version.last gives b: {A.m, B.m}: ' .. vim.inspect(g))
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
