-- Unit tests for the untangle lens: partitioning statements into independent
-- concerns and measuring interleaving. Pure; operates on a `df`-shaped table.

local untangle = require 'cartograph.untangle'
local flow = require 'cartograph.flow'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local tsspec = ts.spec

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'lua')
end

local FN_TYPES = { function_definition = true, function_declaration = true }

-- parse `code` (verbatim) and return the first function-like node + src
local function parse_fn(code, lang)
    lang = lang or 'lua'
    local root = vim.treesitter.get_string_parser(code, lang):parse()[1]:root()
    local fn
    local function rec(n)
        if fn then return end
        if FN_TYPES[n:type()] then fn = n; return end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    return fn, code
end

-- build the fine flow record for the first fn in `code` (lua)
local function build_flow(code)
    local fn, src = parse_fn(code, 'lua')
    return flow.build(fn, src, { pfield = tsspec.lua.params_field, regime = tsspec.lua.regime })
end

-- build a df from a list of {dep = {fromIdx, ...}} (only deps matter to analyze)
local function df(deplists)
    local stmts = {}
    for _, deps in ipairs(deplists) do
        local dep = {}
        for _, from in ipairs(deps) do dep[#dep + 1] = { from = from, var = 'x' } end
        stmts[#stmts + 1] = { l = #stmts + 1, def = {}, use = {}, dep = dep }
    end
    return { inputs = {}, stmts = stmts }
end

test('untangle: two interleaved chains -> 2 concerns, positive tangle', function ()
    -- #1 a, #2 x, #3 b<-a, #4 y<-x   => comps [A,B,A,B]
    local a = untangle.analyze(df { {}, {}, { 1 }, { 2 } })
    eq(2, a.ncomp)
    eq(3, a.switches)       -- A B A B  -> 3 switches
    eq(2, a.tangle)         -- excess over the minimal (ncomp-1 = 1)
    eq({ 0, 1, 0, 1 }, a.comp)
end)

test('untangle: the same two chains, grouped -> tangle 0', function ()
    -- #1 a, #2 b<-a, #3 x, #4 y<-x   => comps [A,A,B,B]
    local a = untangle.analyze(df { {}, { 1 }, {}, { 3 } })
    eq(2, a.ncomp)
    eq(1, a.switches)
    eq(0, a.tangle)         -- perfectly grouped
    eq({ 0, 0, 1, 1 }, a.comp)
end)

test('untangle: one linear chain -> single concern, no tangle', function ()
    local a = untangle.analyze(df { {}, { 1 }, { 2 }, { 3 } })
    eq(1, a.ncomp)
    eq(0, a.tangle)
    eq(1, a.maxspan)        -- each dep is one step back
end)

test('untangle: maxspan is the largest def->use statement distance', function ()
    -- #4 depends on #1  => span 3
    local a = untangle.analyze(df { {}, {}, {}, { 1 } })
    eq(3, a.maxspan)
end)

test('untangle: empty body is inert', function ()
    local a = untangle.analyze(nil)
    eq(0, a.ncomp)
    eq(0, a.tangle)
end)

-- ── INC 1: analyze_flow (fine rows + reaching_cfg data deps) ─────────────────

test('untangle_flow: two independent chains -> 2 concerns', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- 4 flat single-def statements: def a / use a / def x / use x. `print` is a
    -- free global (reaches nothing) so it adds no edge.
    local fl = build_flow([[
local function f()
  local a = 1
  print(a)
  local x = 2
  print(x)
end]])
    local r = untangle.analyze_flow(fl)
    eq(4, r.n)
    eq(2, r.ncomp)
    eq({ 0, 0, 1, 1 }, r.comp)
    eq(0, r.tangle)          -- perfectly grouped
    eq(1, r.maxspan)         -- each use is one row after its def
end)

test('untangle_flow: redefinition couples all writes+reads of a var (RAW+WAW)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- def x / use x / redef x / use x. reaching_cfg links the 2nd use to the
    -- REDEF (row 3, nearest def — not df's first-def-wins), and WAW couples the
    -- two writes (reordering them changes what the reads see). So all four rows
    -- are one coupled concern — you couldn't extract half without renaming x.
    local fl = build_flow([[
local function f()
  local x = 1
  print(x)
  x = 2
  print(x)
end]])
    local r = untangle.analyze_flow(fl)
    eq(4, r.n)
    eq(1, r.ncomp)                    -- WAW(row3,row1) + RAW closes the loop
end)

test('untangle_flow: one linear chain -> single concern', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fl = build_flow([[
local function f()
  local a = 1
  local b = a + 1
  local c = b + 1
  return c
end]])
    local r = untangle.analyze_flow(fl)
    eq(1, r.ncomp)
    eq(0, r.tangle)
end)

test('untangle_flow: flat single-def fn matches the coarse df lens (parity)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- on a flat, single-def function fine==coarse and reaching==first-def-wins,
    -- so the fine lens reproduces the shipped coarse one exactly. (flow.coarse
    -- returns the stmts LIST; wrap it in the df shape analyze expects.)
    local fl = build_flow([[
local function f()
  local a = 1
  print(a)
  local x = 2
  print(x)
end]])
    local fine = untangle.analyze_flow(fl)
    local coarse = untangle.analyze({ stmts = (flow.coarse(fl)) })
    eq(coarse.n, fine.n)
    eq(coarse.comp, fine.comp)
    eq(coarse.ncomp, fine.ncomp)
end)

test('untangle_flow: empty/nil flow is inert', function ()
    eq(0, untangle.analyze_flow(nil).ncomp)
    eq(0, untangle.analyze_flow({ stmts = {} }).ncomp)
end)

-- ── INC 2: control + output (WAW) dependencies ──────────────────────────────

test('untangle_flow: a branch body joins its guard (control dep)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- g() has NO data dep to `cond`; without control deps it would be its own
    -- bogus concern. INC 2 makes it control-dependent on the if row, so the
    -- if+body is ONE concern, separate from the a-chain -> 2 concerns total.
    local fl = build_flow([[
local function f()
  local a = 1
  print(a)
  if cond then
    g()
  end
end]])
    local r = untangle.analyze_flow(fl)
    eq(2, r.ncomp)
    -- rows: 1 local a, 2 print(a), 3 if, 4 g()  -> concerns {1,2} and {3,4}
    eq(r.comp[3], r.comp[4])          -- body shares the guard's concern
    ok(r.comp[1] ~= r.comp[3], 'the a-chain is a distinct concern from the if')
end)

test('untangle_flow: two defs of a fn-scoped var couple (WAW)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- no RAW edge between the two writes, but reordering them changes what a
    -- later reader sees -> output-dependent -> one concern.
    local fl = build_flow([[
local function f()
  local x = 1
  x = 2
end]])
    local r = untangle.analyze_flow(fl)
    eq(2, r.n)
    eq(1, r.ncomp)                    -- WAW couples the two writes
end)

test('untangle_flow: a reused BLOCK-local does NOT falsely couple (scope-gated WAW)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- `i` is block-scoped to each loop; the first def dies at its block exit, so
    -- it never reaches the second -> no WAW edge -> the two loops stay separate.
    local fl = build_flow([[
local function f()
  for i = 1, 3 do print(i) end
  for i = 1, 3 do use(i) end
end]])
    local r = untangle.analyze_flow(fl)
    ok(r.ncomp >= 2, 'the two independent loops are not merged by reused `i`')
end)

test('untangle_flow: extra_edges couple otherwise-independent rows (INC 2b seam)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- 4 independent single-statement rows; a synthetic effect edge {1,3} merges
    -- those two into one concern (the pure seam analyze_flow exposes).
    local fl = build_flow([[
local function f()
  print(1)
  print(2)
  print(3)
  print(4)
end]])
    local base = untangle.analyze_flow(fl)
    eq(4, base.ncomp)                              -- all independent w/o effects
    local coupled = untangle.analyze_flow(fl, { { 1, 3 } })
    eq(3, coupled.ncomp)                           -- rows 1 & 3 merged
    eq(coupled.comp[1], coupled.comp[3])
end)

test('untangle_flow: effect_edges couples two world-writing calls (INC 2b)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local function noisy() print("x") end',
        'local function noisy2() print("y") end',
        'local function target()',
        '  local a = 1',       -- 1: pure
        '  local b = a + 1',   -- 2: RAW dep on 1
        '  noisy()',           -- 3: world
        '  noisy2()',          -- 4: world (conflicts w/ 3)
        'end',
        'return { target, noisy, noisy2 }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local id, tnode
    for _, node in ipairs(store.data.nodes) do
        if node.name == 'target' then id, tnode = node.id, node end
    end
    ok(id, 'found target')
    local fl = flow.record(tnode)
    local base = untangle.analyze_flow(fl)
    local fx = untangle.effect_edges(store, id, fl)
    ok(#fx >= 1, 'reorder found a world/state conflict to couple')
    local withfx = untangle.analyze_flow(fl, fx)
    ok(withfx.ncomp < base.ncomp, 'the two world calls collapse into one concern')
end)

-- ── INC 3: safety verdict + honesty ─────────────────────────────────────────

test('untangle_flow: opaque rows downgrade the safety verdict (INC 3)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fl = build_flow([[
local function f()
  print(1)
  print(2)
end]])
    local clean = untangle.analyze_flow(fl)                 -- no opaque supplied
    ok(clean.certified, 'nothing opaque -> the partition is certified')
    local hedged = untangle.analyze_flow(fl, nil, { 2 })    -- row 2 opaque (synthetic)
    ok(not hedged.certified, 'a single opaque row uncertifies the whole partition')
    ok(hedged.hedged[hedged.comp[2]], "the opaque row's concern is flagged ~")
    ok(not untangle.concern_safe(hedged, hedged.comp[2]), 'that concern is not safe')
end)

test('untangle_flow: effect_edges surfaces opaque calls; clean fn is certified (INC 3)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local function target()',
        '  local a = 1',
        '  MYSTERY()',            -- opaque: unresolved call, unknown effects
        'end',
        'local function clean(x)',
        '  local a = x + 1',      -- pure, fully modeled
        '  return a',
        'end',
        'return { target, clean }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local tid, tnode, cid, cnode
    for _, node in ipairs(store.data.nodes) do
        if node.name == 'target' then tid, tnode = node.id, node end
        if node.name == 'clean' then cid, cnode = node.id, node end
    end
    -- target: the opaque call uncertifies AND the verdict breaks down WHY
    local tfl = flow.record(tnode)
    local te, topaque = untangle.effect_edges(store, tid, tfl)
    ok(#topaque >= 1, 'MYSTERY is opaque')
    ok(topaque[1].reason, 'the opaque entry carries a reason string')
    local tres = untangle.analyze_flow(tfl, te, topaque)
    ok(not tres.certified, 'opaque call -> uncertified')
    local why = untangle.why_unsafe(tres)
    ok(#why >= 1, 'the verdict breaks down WHY it cannot certify')
    ok(why[1]:match('^L%d'), 'each blocker names its source line')
    -- clean: fully modeled -> certified safe
    local cfl = flow.record(cnode)
    local ce, copaque = untangle.effect_edges(store, cid, cfl)
    eq(0, #copaque)
    ok(untangle.analyze_flow(cfl, ce, copaque).certified, 'a fully-modeled fn is certified')
end)

test('untangle: extract_plan hands a contiguous concern off; refuses a scattered one', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local function inc(n) return n + 1 end',  -- pure, resolved -> certified
        'local function contig()',                 -- two RAW chains, each contiguous
        '  local a = inc(1)',
        '  local b = inc(a)',                       -- A: uses a
        '  local c = inc(2)',
        '  local d = inc(c)',                       -- B: uses c
        'end',
        'local function scattered()',              -- same chains, interleaved
        '  local a = inc(1)',
        '  local c = inc(2)',
        '  local b = inc(a)',                       -- A: uses a (scattered from row1)
        '  local d = inc(c)',                       -- B: uses c
        'end',
        'return { inc, contig, scattered }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local cid, cnode, sid, snode
    for _, node in ipairs(store.data.nodes) do
        if node.name == 'contig' then cid, cnode = node.id, node end
        if node.name == 'scattered' then sid, snode = node.id, node end
    end
    -- contiguous: distinct concerns, and the first reaches extract.plan (not scattered)
    local cfl = flow.record(cnode)
    local ce, cop = untangle.effect_edges(store, cid, cfl)
    local cres = untangle.analyze_flow(cfl, ce, cop)
    ok(cres.ncomp >= 2, 'state.a and other.b are distinct concerns (different state keys)')
    local cplan = untangle.extract_plan(store, cid, cres, cres.comp[1])
    ok(not cplan.scattered, 'a contiguous concern reaches extract.plan')
    -- scattered: the same concern is interleaved -> refused pending gather/reorder
    local sfl = flow.record(snode)
    local se, sop = untangle.effect_edges(store, sid, sfl)
    local sres = untangle.analyze_flow(sfl, se, sop)
    local splan = untangle.extract_plan(store, sid, sres, sres.comp[1])
    ok(splan.scattered, 'a scattered concern is refused pending gather/reorder')
end)

-- ── inter-function untangle (module clustering) ─────────────────────────────

local function comp_of(res, name)
    for k, node in ipairs(res.fns) do
        if res.names[node.id] == name then return res.comp[k] end
    end
end

local function ingest_file(lines)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat(lines, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' then return n.file end
    end
end

test('untangle_module: independent shared-state groups form separate clusters', function ()
    if not ready('lua') then skip 'no lua parser' end
    local file = ingest_file {
        'local sa = {}', 'local sb = {}',
        'local function a1() sa.x = 1 end',      -- writes sa
        'local function a2() return sa.x end',   -- reads sa -> coupled to a1
        'local function b1() sb.y = 1 end',      -- writes sb
        'local function b2() return sb.y end',   -- reads sb -> coupled to b1
        'return { a1, a2, b1, b2 }',
    }
    local res = untangle.analyze_module(store, file)
    eq(4, res.n)
    eq(2, res.ncomp)
    eq(comp_of(res, 'a1'), comp_of(res, 'a2'))
    eq(comp_of(res, 'b1'), comp_of(res, 'b2'))
    ok(comp_of(res, 'a1') ~= comp_of(res, 'b1'), 'sa-group and sb-group are distinct')
end)

test('untangle_module: calls couple; a read-only const does NOT', function ()
    if not ready('lua') then skip 'no lua parser' end
    local file = ingest_file {
        'local K = 5',                                  -- read-only const (never written)
        'local function helper() return K end',
        'local function caller() return helper() + K end', -- calls helper -> coupled
        'local function lonely() return K end',         -- only READS K -> not coupled
        'return { helper, caller, lonely }',
    }
    local res = untangle.analyze_module(store, file)
    eq(comp_of(res, 'helper'), comp_of(res, 'caller'))  -- call edge couples
    ok(comp_of(res, 'lonely') ~= comp_of(res, 'helper'),
        'a read-only shared const does not force togetherness')
end)

test('untangle_module: a clean file certifies each cluster as extractable (INC 2)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local file = ingest_file {
        'local sa = {}', 'local sb = {}',
        'local function a1() sa.x = 1 end',
        'local function a2() return sa.x end',
        'local function b1() sb.y = 1 end',
        'local function b2() return sb.y end',
        'return { a1, a2, b1, b2 }',
    }
    local res = untangle.analyze_module(store, file)
    ok(res.certified, 'no unmodeled coupling -> certified')
    ok(untangle.module_safe(res, comp_of(res, 'a1')), 'the sa cluster is safe to extract')
end)

test('untangle_module: a dynamic dispatch uncertifies + names the blocker (INC 2)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local file = ingest_file {
        'local H = {}',
        'local function reg() H.x = function () end end',
        'local function dispatch(k) H[k]() end',   -- dynamic call -> can reach any fn
        'return { reg, dispatch }',
    }
    local res = untangle.analyze_module(store, file)
    ok(not res.certified, 'a dynamic dispatch could reach any fn -> not certified')
    local found
    for _, rows in pairs(res.why) do
        for _, w in ipairs(rows) do if w.reason:match('dynamic') then found = true end end
    end
    ok(found, 'the breakdown names the dynamic-dispatch blocker')
end)

test('untangle: report renders concerns + verdict + why breakdown (INC 4)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local function target()',
        '  local a = 1',
        '  print(a)',
        '  MYSTERY()',        -- opaque -> uncertified + a why line
        'end',
        'return { target }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local id
    for _, node in ipairs(store.data.nodes) do
        if node.name == 'target' then id = node.id end
    end
    local lines = untangle.report(store, id)
    local joined = table.concat(lines, '\n')
    ok(lines[1]:match('^untangle: target'), 'header names the fn')
    ok(joined:match('NOT certified'), 'the verdict is surfaced')
    ok(joined:match('MYSTERY'), 'the breakdown names the blocking call')
end)
