-- THE T3 HOST (CART-0144) — lua/cartograph/agent.lua behind tools/mcpserve.lua.
-- What these specs fence is the property the whole agent surface exists for, now
-- carried over a wire instead of a return value:
--
--   ABSENT, REFUSED, FRONTIER AND UNAVAILABLE MUST RENDER DIFFERENTLY, AND A
--   CAPABILITY REFUSAL MUST BE REACHABLE BY A CALLER.
--
-- The second half is not decoration. agentq shipped a `thin-index` refusal that
-- no caller could reach through its interface (CART-0580), so one of the two
-- refusals the honesty contract rests on could neither be demonstrated nor
-- fenced. Here `--index-only` is a documented server mode and the refusal is
-- driven over stdio below.
--
-- TWO LAYERS, the same split agentq_spec uses. The verb table is exercised IN
-- PROCESS (pure, fast, and it is where the envelope invariant lives); the server
-- is exercised END TO END, because "newline-delimited JSON-RPC on stdout and
-- nothing else" is a property of the PROCESS and cannot be asserted any other
-- way. The end-to-end half drives it with this project's own MCP CLIENT
-- (lua/cartograph/mcp.lua) — the client and the server are now two ends of one
-- wire, so the spec is also their parity test.

local agent = require 'cartograph.agent'
local mcp = require 'cartograph.mcp'
local store = require 'cartograph.store'
local tier = require 'cartograph.tier'
local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

-- ── the fixture root: one file per absence bucket ────────────────────────────

-- ABSENT (`genuinely_dead`): a file-local nothing mentions. Also the live pair
-- `M.caller` -> `M.pub`, which is the one real ref edge in the root.
local M_LUA = [[
local M = {}
local function genuinely_dead(y) return y end
function M.pub(z) return z end
function M.caller() return M.pub(1) end
return M
]]

-- REFUSED (`walk`): the same-named nested helper twice, so `walk(...)` cannot be
-- bound to one of them and each reads as callerless while being perfectly alive.
local W_LUA = [[
local M = {}
function M.a()
    local function walk(t) return t end
    return walk({})
end
function M.b()
    local function walk(t) return t end
    return walk({})
end
return M
]]

-- FRONTIER (`handler`): the name occurs a second time in a construct that
-- produced no call record, so nothing was looked at there.
local F_LUA = [[
local M = {}
-- handler is wired up by the engine, not called from lua
local function handler(x) return x end
function M.go() return 1 end
return M
]]

local FIXTURE = { ['m.lua'] = M_LUA, ['w.lua'] = W_LUA, ['f.lua'] = F_LUA }

local function mkfixture()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for name, src in pairs(FIXTURE) do
        local fd = assert(io.open(root .. '/' .. name, 'w'))
        fd:write(src); fd:close()
    end
    return root
end

-- ── layer 1: the verb table, in process ──────────────────────────────────────

local function ingest(root)
    local data = ts.extract(root)
    data.root = data.root or root
    store.ingest(data)
    return store
end

local function idof(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

test('agent: an empty result NEVER arrives as a bare list — every verb names its absence', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    -- one call per verb that CAN come back empty, each aimed at a subject that
    -- makes it so. The envelope invariant is asserted uniformly: no result rows
    -- => an absence value AND a named premise, and never a rung.
    local cases = {
        { 'node_find', { query = 'nosuchnamexyz' } },
        { 'node_at', { file = 'f.lua', line = 2 } }, -- a comment line: inside no definition
        { 'edges_callers', { node = idof('genuinely_dead') } },
        { 'edges_callees', { node = idof('M.pub') } },
        { 'why', { file = 'f.lua', line = 2, col = 1 } }, -- the same comment line
        { 'lint_run', { rules = { 'truncation' } } },
    }
    for _, c in ipairs(cases) do
        local d, status = agent.answer(store, c[1], c[2])
        eq('ok', status, c[1] .. ' answers')
        eq(0, #d.result, c[1] .. ' was aimed at an empty answer')
        ok(d.absence ~= vim.NIL and type(d.absence) == 'string',
            ('%s returned an empty result with NO absence — a bare [] is the defect'):format(c[1]))
        ok(vim.tbl_contains({ 'absent', 'refused', 'frontier', 'unavailable' }, d.absence),
            ('%s invented the absence value %q'):format(c[1], tostring(d.absence)))
        ok(d.absence_why ~= vim.NIL and #d.absence_why.premise > 0,
            c[1] .. ' names the premise that failed')
        ok(#d.absence_why.why > 20, c[1] .. ' explains it: ' .. tostring(d.absence_why.why))
        eq(vim.NIL, d.tier, c[1] .. ' minted a rung for an answer that resolved nothing')
        -- and the value is one the verb DECLARED it could produce. `absences` is
        -- what graph_info publishes, so a verb that emits an undeclared value has
        -- made that surface a lie.
        ok(vim.tbl_contains(agent.VERBS[c[1]].absences, d.absence),
            ('%s emitted %q, which it does not declare in `absences`'):format(c[1], d.absence))
    end
    -- THE REFUSALS ARE REACHABLE TOO (CART-0580: a refusal a caller cannot reach
    -- is not a contract). These are the input-shaped ones; the CAPABILITY refusal
    -- is driven over the wire below.
    for _, c in ipairs({
        { 'node_at', { file = 'nosuchfile.lua', line = 1 }, 'unknown-file' },
        { 'edges_callers', {}, 'no-address' },
        { 'edges_callers', { node = 'no::such::id' }, 'unknown-node' },
        { 'edges_callers', { file = 'm.lua', line = 1 }, 'no-subject' },
    }) do
        local d, status = agent.answer(store, c[1], c[2])
        eq('refusal', status, c[1] .. ' must REFUSE, not answer')
        eq(c[3], d.refusal.rule)
        ok(#d.refusal.remedy > 10, c[3] .. ' says what to change')
        eq(vim.NIL, d.result, 'a refusal has no result at all — not an empty one')
        eq(vim.NIL, d.absence, 'and it is not an absence')
    end
    vim.fn.delete(root, 'rf')
end)

test('agent: tier_basis decides which side of the axis a NON-empty answer carries', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    -- a RESOLUTION verb: rows are ref edges, so the answer carries a real rung
    local callers = agent.answer(store, 'edges_callers', { node = idof('M.pub') })
    ok(#callers.result > 0, 'M.pub is called by M.caller')
    ok(tier.rank(callers.tier) ~= nil,
        'a resolution answer carries a tier.LADDER rung, got ' .. tostring(callers.tier))
    eq(vim.NIL, callers.absence, 'and no absence — exactly one side of the axis exists')
    for _, r in ipairs(callers.result) do
        ok(tier.rank(r.tier) ~= nil, 'every ROW carries its own rung too: ' .. tostring(r.tier))
    end
    -- an OBSERVATION verb: nothing was resolved, so there is no rung to report
    -- and the null means "this question has no rung", not "unknown"
    local found = agent.answer(store, 'node_find', { query = 'walk' })
    ok(#found.result >= 2, 'both walks are found')
    eq(vim.NIL, found.tier, 'an observation answer never mints a rung')
    eq(vim.NIL, found.absence, 'and a non-empty one carries no absence')
    eq('observation', agent.VERBS.node_find.tier_basis)
    eq('resolution', agent.VERBS.edges_callers.tier_basis)
    vim.fn.delete(root, 'rf')
end)

test('agent: callers-empty is classified by the SHIPPED alibi premises, not re-decided', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local got = {}
    for _, c in ipairs({ { 'absent', 'genuinely_dead' }, { 'refused', 'walk' },
                         { 'frontier', 'handler' } }) do
        local d = agent.answer(store, 'edges_callers', { node = idof(c[2]) })
        eq(0, #d.result, c[2] .. ' has no callers in this graph')
        got[c[1]] = d.absence
        eq(c[1], d.absence, ('callers of %s'):format(c[2]))
    end
    local seen = {}
    for _, a in pairs(got) do
        ok(not seen[a], ('two buckets both report %q — they render the same, which is the defect'):format(a))
        seen[a] = true
    end
    -- and an empty caller list is NOT a deletion licence: what else keeps it
    -- alive rides along, so the agent cannot misread the empty list
    local pub = agent.answer(store, 'edges_callers', { node = idof('M.a') })
    if #pub.result == 0 then
        local kinds = {}
        for _, n in ipairs(pub.notes) do kinds[n.kind] = true end
        ok(kinds['alive-otherwise'], 'an exported callerless fn says why it is still alive')
    end
    vim.fn.delete(root, 'rf')
end)

-- ── layer 2: the server, over stdio ──────────────────────────────────────────

local SERVERS = {}

--- a live client against a server on the fixture root (`thin` => --index-only).
--- Lazily spawned and shared: extraction is paid once per mode, and mcp.lua's
--- VimLeavePre hook kills any client a failing test left open.
local function client(thin)
    local key = thin and 'thin' or 'full'
    if SERVERS[key] then return SERVERS[key].c, SERVERS[key].root end
    local root = mkfixture()
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/mcpserve.lua'), root }
    if thin then cmd[#cmd + 1] = '--index-only' end
    local c, err = mcp.connect { cmd = cmd, timeout = 60000 }
    ok(c ~= nil, 'mcpserve did not come up: ' .. tostring(err))
    SERVERS[key] = { c = c, root = root }
    return c, root
end

test('mcpserve: the handshake completes and tools/list advertises every verb', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    eq('cartograph', c.server.name, 'initialize returned our serverInfo')
    local res, why = c:request('tools/list', vim.empty_dict())
    ok(res ~= nil, 'tools/list: ' .. tostring(why))
    local by = {}
    for _, t in ipairs(res.tools) do by[t.name] = t end
    for _, name in ipairs(agent.ORDER) do
        ok(by[name], 'advertised: ' .. name)
        eq('object', by[name].inputSchema.type, name .. ' carries a JSON Schema')
        ok(by[name].description:find('absence', 1, true),
            name .. "'s description states the envelope, so a client that never reads our docs still learns it")
    end
    -- the names a client may actually use: `.` is rejected by several clients
    for _, t in ipairs(res.tools) do
        ok(t.name:match('^[%w_-]+$'), ('tool name %q is not portable'):format(t.name))
    end
end)

test('mcpserve: a successful call returns the envelope, decoded, over the wire', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local found = c:call('node_find', { query = 'M.pub' })
    ok(found and found.ok, 'node_find answered: ' .. vim.inspect(found))
    ok(#found.result >= 1, 'M.pub is in the graph')
    eq('full', found.graph.index, 'every answer carries the graph it was read off')
    local ref = found.result[1].ref
    local callers = c:call('edges_callers', { node = ref })
    eq(true, callers.ok)
    ok(#callers.result >= 1, 'M.pub has a caller over the wire')
    ok(tier.rank(callers.tier) ~= nil, 'with a real rung: ' .. tostring(callers.tier))
    eq(vim.NIL, callers.absence, 'and no absence beside it')
    -- `why` is PORTED, not reimplemented: the shipped honesty record, verbatim
    local w = c:call('why', { file = 'm.lua', line = 4, col = 26 })
    eq(true, w.ok)
    ok(#w.result == 1, 'why answers about the position: ' .. vim.inspect(w))
    ok(w.result[1].kind == 'call' or w.result[1].kind == 'def',
        'and it is the shipped shape, got ' .. tostring(w.result[1].kind))
end)

test('mcpserve: the four absences survive the wire and stay distinguishable', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local seen = {}
    for _, case in ipairs({ { 'absent', 'genuinely_dead' }, { 'refused', 'walk' },
                            { 'frontier', 'handler' } }) do
        local f = c:call('node_find', { query = case[2] })
        ok(#f.result >= 1, 'found ' .. case[2])
        local d = c:call('edges_callers', { node = f.result[1].ref })
        eq(true, d.ok, 'an absence is an ANSWER, not a failure')
        eq(0, #d.result)
        eq(case[1], d.absence, ('callers of %s over the wire'):format(case[2]))
        ok(not seen[d.absence], 'the buckets render differently')
        seen[d.absence] = true
        ok(#d.absence_why.why > 20, 'and each says WHICH premise failed')
    end
end)

test('mcpserve: the thin-index CAPABILITY REFUSAL is reachable by a caller', function ()
    if not ready() then skip('no treesitter') end
    local c = client(true)
    -- graph_info is the negotiation surface: it says what may be asked at all
    local info = c:call('graph_info', vim.empty_dict())
    eq(true, info.ok)
    eq('index-only', info.graph.index, 'the server opened a thin graph')
    local by = {}
    for _, r in ipairs(info.result) do by[r.verb] = r end
    eq(false, by.edges_callers.available, 'and says so BEFORE the agent asks')
    ok(#by.edges_callers.unavailable_why > 20, 'with a reason')
    eq(true, by.node_find.available, 'while the observation verbs still serve')

    -- the refusal itself, over the wire — NOT an empty list, NOT an error
    local d, why, raw = c:call('edges_callers', { file = 'm.lua', line = 3 })
    ok(d ~= nil, 'a refusal must arrive as CONTENT the agent can read, not as a transport error: '
        .. tostring(why))
    eq(false, raw.isError, 'isError would flatten the refusal to a string and lose the remedy')
    eq(false, d.ok)
    eq('thin-index', d.refusal.rule, 'the refusal names its RULE')
    ok(#d.refusal.reason > 20, 'and its reason')
    ok(#d.refusal.remedy > 10, 'and a remedy, so the agent can fix the call')
    eq(vim.NIL, d.result, 'a refusal has no result at all — not an empty one')
    eq(vim.NIL, d.absence, 'and it is NOT an absence: nothing about the code was concluded')

    -- an observation verb is unaffected: a thin graph still has definitions
    local f = c:call('node_find', { query = 'genuinely_dead' })
    eq(true, f.ok)
    ok(#f.result >= 1, 'the thin index still answers what it CAN answer')
end)

test('mcpserve: a protocol fault is a JSON-RPC error, not an answer', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local d, why = c:call('nosuchtool', vim.empty_dict())
    eq(nil, d, 'an unknown tool is not an answer about the code')
    ok(tostring(why):find('unknown tool', 1, true), 'and says so: ' .. tostring(why))
    local d2, why2 = c:call('node_find', vim.empty_dict())
    eq(nil, d2, 'a missing required argument is a fault in the CALL')
    ok(tostring(why2):find('requires', 1, true), 'and names the argument: ' .. tostring(why2))
    local d3, why3 = c:call('node_find', { query = 'x', nosucharg = 1 })
    eq(nil, d3, 'an unknown argument is refused rather than silently ignored')
    ok(tostring(why3):find('nosucharg', 1, true), tostring(why3))
end)

test('mcpserve: lint findings carry what they are WORTH, and refusals ride along', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local d = c:call('lint_run', vim.empty_dict())
    eq(true, d.ok)
    if #d.result > 0 then
        for _, f in ipairs(d.result) do
            ok(type(f.rule) == 'string', 'a finding names its rule')
            ok(f.disposition ~= vim.NIL,
                ('%s carries no disposition — authoritative and suggestive would act alike'):format(f.rule))
        end
    else
        ok(type(d.absence) == 'string', 'an empty lint report is never a clean bill of health by default')
    end
end)

test('mcpserve: the servers shut down cleanly', function ()
    if not ready() then skip('no treesitter') end
    for _, s in pairs(SERVERS) do
        s.c:close()
        vim.fn.delete(s.root, 'rf')
    end
    SERVERS = {}
    ok(true)
end)
