-- Unit tests for the untangle lens: partitioning statements into independent
-- concerns and measuring interleaving. Pure; operates on a `df`-shaped table.

local untangle = require 'cartograph.untangle'
local flow = require 'cartograph.flow'
local tsspec = require('cartograph.providers.treesitter').spec

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

test('untangle_flow: reaching picks the NEAREST def, not first-def-wins', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- def x / use x / redef x / use x — the 2nd use reaches the REDEF (row 3),
    -- so {1,2} and {3,4} are two concerns. df's first-def-wins would wrongly
    -- link the 2nd use back to row 1; the fine lens is more correct here.
    local fl = build_flow([[
local function f()
  local x = 1
  print(x)
  x = 2
  print(x)
end]])
    local r = untangle.analyze_flow(fl)
    eq(4, r.n)
    eq(2, r.ncomp)
    eq({ 0, 0, 1, 1 }, r.comp)
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
