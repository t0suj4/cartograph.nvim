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

-- write `lines` as a single lua file, ingest it, return its relpath (shared by the
-- module + block tests, hence defined up here before the first user)
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

-- ── community detection (modularity refinement of the components) ────────────

test('communities: a single clique is one community', function ()
    -- triangle 1-2-3: every pair linked -> one cohesive group, no seam
    local c = untangle.communities(3, { { 1, 2 }, { 2, 3 }, { 1, 3 } })
    eq(1, c.ncomp)
    eq(0, c.cut)
end)

test('communities: two cliques joined by a bridge split into 2 (with the seam)', function ()
    -- {1,2,3} clique + {4,5,6} clique + one bridge edge 3-4. Connected-components
    -- would call this ONE blob; modularity finds the 2 cohesive groups and the
    -- single bridge edge is the seam (cut cost 1).
    local c = untangle.communities(6, {
        { 1, 2 }, { 2, 3 }, { 1, 3 },      -- clique A
        { 4, 5 }, { 5, 6 }, { 4, 6 },      -- clique B
        { 3, 4, kind = 'data' },           -- the bridge
    })
    eq(2, c.ncomp)
    eq(1, c.cut)                            -- exactly the bridge edge
    eq(1, #c.crossing)
    eq('data', c.crossing[1].kind)
    ok(c.comp[1] == c.comp[2] and c.comp[2] == c.comp[3], 'clique A stays together')
    ok(c.comp[4] == c.comp[5] and c.comp[5] == c.comp[6], 'clique B stays together')
    ok(c.comp[1] ~= c.comp[4], 'the two cliques are distinct communities')
end)

test('communities: disconnected nodes never merge (refinement of components)', function ()
    -- edge 1-2 only; node 3 isolated. Merging across a zero-edge gap lowers Q, so
    -- 3 stays its own community -> matches (never coarser than) the components.
    local c = untangle.communities(3, { { 1, 2 } })
    eq(2, c.ncomp)
    ok(c.comp[1] == c.comp[2], 'the linked pair is one community')
    ok(c.comp[3] ~= c.comp[1], 'the isolated node is its own community')
end)

test('communities: weight (repeated edges) strengthens coupling', function ()
    -- 1-2 linked 3× vs 2-3 once: the strong pair coheres, the weak edge is the seam
    local c = untangle.communities(3, {
        { 1, 2 }, { 1, 2 }, { 1, 2 }, { 2, 3 },
    })
    ok(c.comp[1] == c.comp[2], 'the triple-weight pair coheres')
end)

test('communities: empty graph is inert', function ()
    eq(0, untangle.communities(0, {}).ncomp)
    local c = untangle.communities(3, {})
    eq(3, c.ncomp)                          -- no edges -> all singletons
    eq(0, c.cut)
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

test('untangle_flow: communities refine a connected concern into cohesive groups', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- one connected data-flow chain (components = 1 concern), but two dense
    -- clusters joined by a single bridge assignment -> modularity finds the seam.
    local fl = build_flow([[
local function f()
  local a = 1
  local b = a + 1
  local c = a + b
  local x = c
  local y = x + 1
  local z = x + y
  return z
end]])
    local r = untangle.analyze_flow(fl)
    eq(1, r.ncomp)                                  -- connected: ONE concern (sound)
    ok(r.communities.ncomp >= 2, 'modularity refines the blob into sub-groups')
    ok(r.communities.ncomp > r.ncomp, 'communities are strictly finer than components')
    ok(#r.communities.crossing >= 1, 'the seam has a real (nonzero) cut cost')
    -- rows 2 (b<-a) and 6 (z<-x,y) live in different sub-groups
    ok(r.communities.comp[2] ~= r.communities.comp[6], 'the two clusters are distinct communities')
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

-- ── nested-block extract-candidates ─────────────────────────────────────────

-- find the candidate rooted at the given kind (first match in source order)
local function cand_kind(cands, kind)
    table.sort(cands, function (a, b) return (a.line or 0) < (b.line or 0) end)
    for _, c in ipairs(cands) do if c.kind == kind then return c end end
end

local function fn_id(name)
    for _, node in ipairs(store.data.nodes) do
        if node.name == name then return node.id end
    end
end

test('extract_candidates: a clean nested loop with its interface (params/returns)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest_file {
        'local function f(xs)',
        '  local total = 0',
        '  for _, x in ipairs(xs) do',
        '    total = total + x',        -- writes total (live-out: read after)
        '  end',
        '  return total',
        'end',
        'return { f }',
    }
    local cands = untangle.extract_candidates(store, fn_id('f'))
    local loop = cand_kind(cands, 'for_in_statement') or cand_kind(cands, 'for_statement')
    ok(loop, 'the for loop is a candidate')
    ok(not loop.escape, 'no control escape -> cleanly extractable')
    local function has(t, v) for _, x in ipairs(t) do if x == v then return true end end end
    -- `total` is a body local read+reassigned in the loop -> in-out (param + return).
    -- `xs` is an enclosing-fn PARAM (upvalue) -> captured by the helper closure, not
    -- passed (matches extract.plan's convention), so it's NOT in params.
    ok(has(loop.params, 'total'), 'total (defined before the loop, used inside) is a live-in param')
    ok(not has(loop.params, 'xs'), 'xs is a captured upvalue, not a helper param')
    ok(has(loop.returns, 'total'), 'total is defined inside and read after -> a return')
end)

test('extract_candidates: a return inside a block flags a control escape', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest_file {
        'local function f(xs)',
        '  for _, x in ipairs(xs) do',
        '    if x < 0 then return nil end',   -- return exits the whole fn
        '  end',
        '  return true',
        'end',
        'return { f }',
    }
    local cands = untangle.extract_candidates(store, fn_id('f'))
    local loop = cand_kind(cands, 'for_in_statement') or cand_kind(cands, 'for_statement')
    ok(loop.escape and loop.escape:match('return'), 'the enclosed return blocks extraction')
end)

test('extract_candidates: a break stays with its own loop, escapes an inner branch', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest_file {
        'local function f(xs, target)',
        '  local found',
        '  for _, x in ipairs(xs) do',
        '    if x == target then found = x; break end',  -- break targets the for
        '  end',
        '  return found',
        'end',
        'return { f }',
    }
    local cands = untangle.extract_candidates(store, fn_id('f'))
    local loop = cand_kind(cands, 'for_in_statement') or cand_kind(cands, 'for_statement')
    local branch = cand_kind(cands, 'if_statement')
    ok(not loop.escape, 'extracting the WHOLE loop keeps the break with its loop -> clean')
    ok(branch and branch.escape and branch.escape:match('break'),
        'extracting just the inner branch would orphan the break -> escape')
end)

test('extract_candidates: sub-clauses (elseif) are not standalone candidates', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest_file {
        'local function f(x)',
        '  if x == 1 then',
        '    print("a")',
        '  elseif x == 2 then',
        '    print("b")',
        '  end',
        'end',
        'return { f }',
    }
    local cands = untangle.extract_candidates(store, fn_id('f'))
    for _, c in ipairs(cands) do
        ok(c.kind ~= 'elseif_statement' and c.kind ~= 'else_statement',
            'an elseif/else clause is part of its if, not its own candidate')
    end
    ok(cand_kind(cands, 'if_statement'), 'the whole if IS a candidate')
end)

test('extract_candidates: report renders candidates, marks sweet spots + escapes', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest_file {
        'local function f(xs)',
        '  local total = 0',
        '  for _, x in ipairs(xs) do',
        '    total = total + x',
        '    print(total)',
        '  end',
        '  return total',
        'end',
        'return { f }',
    }
    local joined = table.concat(untangle.report_blocks(store, fn_id('f')), '\n')
    ok(joined:match('extract%-blocks: f'), 'header names the fn')
    ok(joined:match('%-> %(total%)'), 'the loop candidate shows total as a return')
    ok(joined:match('cleanly extractable'), 'summarizes the clean count')
end)

test('extract_candidates: a straight-line fn has no control blocks', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest_file {
        'local function f(a, b)',
        '  local c = a + b',
        '  return c',
        'end',
        'return { f }',
    }
    eq(0, #untangle.extract_candidates(store, fn_id('f')))
    ok(table.concat(untangle.report_blocks(store, fn_id('f')), '\n'):match('no control blocks'))
end)

-- ── inter-function untangle (module clustering) ─────────────────────────────

local function comp_of(res, name)
    for k, node in ipairs(res.fns) do
        if res.names[node.id] == name then return res.comp[k] end
    end
end

-- the community (sub-group) index of a named fn, for the modularity tests
local function comp_of_c(res, name)
    for k, node in ipairs(res.fns) do
        if res.names[node.id] == name then return res.communities.comp[k] end
    end
end

local function ingest_files(filemap)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local rels = {}
    for name, lines in pairs(filemap) do
        local fd = assert(io.open(root .. '/' .. name, 'w'))
        fd:write(table.concat(lines, '\n')); fd:close()
        rels[#rels + 1] = name
    end
    store.ingest(ts.extract(root))
    return rels
end

test('untangle_scope: clusters span a multi-file scope; independent files stay apart (INC 4)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest_files {
        ['a.lua'] = { 'local function fa() return 1 end', 'return { fa }' },
        ['b.lua'] = { 'local function fb() return 2 end', 'return { fb }' },
    }
    local res = untangle.analyze_scope(store, { 'a.lua', 'b.lua' })
    eq(2, res.n)                        -- fa + fb, across two files
    eq(2, res.ncomp)                    -- no cross-file coupling -> separate
end)

test('untangle_scope: the sharing-model seam decides whether shared state couples (INC 4)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local file = ingest_file {
        'local sa = {}',
        'local function a1() sa.x = 1 end',
        'local function a2() return sa.x end',
        'return { a1, a2 }',
    }
    -- default sharing model: written state couples a1 & a2
    eq(1, untangle.analyze_module(store, file).ncomp)
    -- a sharing model that shares NOTHING (e.g. a sandboxed ecosystem) -> uncoupled
    eq(2, untangle.analyze_module(store, file, { shared = function () return false end }).ncomp)
end)

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

test('untangle_module: extract_module plans a cluster into a new module (INC 3)', function ()
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
    local plan, err = untangle.extract_module(store, res, comp_of(res, 'a1'), 'out_a.lua')
    ok(plan, 'a certified cluster hands off to a moveapply plan: ' .. tostring(err))
    eq(2, #plan.moves)                       -- the sa cluster = a1, a2
    local moved = {}
    for _, m in ipairs(plan.moves) do moved[m.name] = true end
    ok(moved.a1 and moved.a2, 'both sa-cluster functions are in the move-set')
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

test('untangle_scope: communities split a connected god-file into sub-modules', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- two mutually-recursive triplets joined by ONE bridge call (a3 -> b1). The
    -- call graph is fully connected (components = 1 cluster), but modularity finds
    -- the two cohesive sub-modules + the single bridge as the seam.
    local file = ingest_file {
        'local a1, a2, a3, b1, b2, b3',
        'function a1() return a2() end',
        'function a2() return a3() end',
        'function a3() return a1() + b1() end',   -- bridge into the B triplet
        'function b1() return b2() end',
        'function b2() return b3() end',
        'function b3() return b1() end',
        'return { a1, a2, a3, b1, b2, b3 }',
    }
    local res = untangle.analyze_module(store, file)
    eq(6, res.n)
    eq(1, res.ncomp)                                -- connected via the bridge
    ok(res.communities.ncomp >= 2, 'modularity finds the two sub-modules')
    ok(comp_of_c(res, 'a1') == comp_of_c(res, 'a2'), 'the A triplet coheres')
    ok(comp_of_c(res, 'b1') == comp_of_c(res, 'b2'), 'the B triplet coheres')
    ok(comp_of_c(res, 'a1') ~= comp_of_c(res, 'b1'), 'A and B are distinct communities')
end)

test('untangle: report surfaces cohesive sub-groups + the cut cost', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local function f()',
        '  local a = 1',
        '  local b = a + 1',
        '  local c = a + b',      -- dense cluster {a,b,c}
        '  local x = c',          -- bridge
        '  local y = x + 1',
        '  local z = x + y',      -- dense cluster {x,y,z}
        '  return z',
        'end',
        'return { f }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local id
    for _, node in ipairs(store.data.nodes) do
        if node.name == 'f' then id = node.id end
    end
    local joined = table.concat(untangle.report(store, id), '\n')
    ok(joined:match('cohesive sub%-groups'), 'the seam suggestion is surfaced')
    ok(joined:match('breaks %d+ dependency edge'), 'the cut cost is spelled out')
    ok(joined:match('%[%a%]'), 'rows carry a sub-group letter tag')
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
