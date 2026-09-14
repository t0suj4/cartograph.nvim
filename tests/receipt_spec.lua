-- receipt: what a plan decided, INCLUDING what it decided silently (CART-0912).
--
-- USER: "maybe we should offer up for review the whole thing, including things
-- that go smoothly so they can be reviewed too".
--
-- ★★★ A HAZARD CARRIES ITS REASON; A SUCCESS CARRIED NOTHING. `rewrites = 0`
-- could mean NO CALLERS EXIST or NO CALLERS WERE RESOLVABLE, and nothing said
-- which — so a smooth run was indistinguishable from an unexamined one.

local rcm = require 'cartograph.receipt'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local moveapply = require 'cartograph.moveapply'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local function ingest_files(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(dir, 'p') end
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    store.ingest(ts.extract(root))
    return store
end

--- ★★★ `none` REQUIRES `by`. An instrument that found nothing must NAME ITSELF,
--- or its silence is indistinguishable from absence — which is the entire defect
--- this module exists to prevent, so it is enforced rather than documented.
test('receipt: a `none` row without an instrument is refused', function ()
    local r = rcm.new()
    local okc = pcall(function () r:none('captures') end)
    eq(false, okc, 'a `none` with no `by` must not be constructible')
    ok(pcall(function () r:none('captures', 'the free-name rung over 14 nodes') end))
end)

--- ⚠ THE THREE SILENCES ARE DIFFERENT ROWS. Collapsing `none` into `blind` — or
--- either into an absent row — is what made `slice` cost a runtime hole: its 26
--- call sites did not resolve, so "could not look" rendered as "nothing to do".
test('receipt: `none`, `partial` and `blind` are distinguishable, and two are unwarranted', function ()
    local r = rcm.new()
    r:did('symbols moved', 3)
    r:none('captures', 'the resolved-edge rung over 3 nodes')
    r:partial('free names', 12, 'one node could not be read')
    r:blind('module scaffold', 'this language declares no scaffold idiom')

    eq(4, #r.rows)
    local unw = r:unwarranted()
    eq(2, #unw, 'a clean run is not "no rows" — it is every row did-or-none')
    eq('partial', unw[1].warrant)
    eq('blind', unw[2].warrant)

    local text = table.concat(r:lines(), '\n')
    ok(text:find('looked: the resolved%-edge rung'), 'a `none` says what looked')
    ok(text:find('⚠ blind', 1, true), 'and a blind row is marked')
end)

--- ★ AND A REAL PLAN CARRIES ONE — with `rewrites = 0` split into the two rows
--- that field could never distinguish.
test('receipt: a move-set plan reports what it DID, not only what it refused', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest_files { ['m.lua'] = table.concat({
        'local M = {}',
        'local function h(x) return x end',
        'function M.f(x) return h(x) end',
        'function M.g(x) return M.f(x) end',   -- a call site that will NOT be rewritten
        'return M',
    }, '\n') }
    local n
    for _, x in ipairs(st.data.nodes) do if x.name == 'M.f' then n = x end end
    local plan = assert(moveapply.plan_moveset(st, { n.id }, 'sub/f.lua', { arm = false }))

    ok(plan.receipt and #plan.receipt > 0, 'the plan carries a receipt')
    -- ⚠ ROWS, NOT THE BUILDER: `journal.begin` serializes the plan
    eq('table', type(plan.receipt[1]))
    eq(nil, getmetatable(plan.receipt), 'plain data, so it survives the journal')

    local by = {}
    for _, row in ipairs(plan.receipt) do by[row.what] = row end
    eq('did', by['symbols moved'].warrant)
    ok(by['symbols moved'].n >= 1)
    -- the field that motivated the whole thing: an unrewritten site is PARTIAL,
    -- never an invisible zero
    ok(by['call sites requalified'], 'the rewrite decision is accounted for')
    ok(by['call sites requalified'].warrant ~= 'did'
        or by['call sites requalified'].n > 0, 'and it is not a bare zero')
end)
