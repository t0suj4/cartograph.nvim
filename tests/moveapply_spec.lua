-- moveapply / extract-module: the founding write verb. Focus here = the
-- MODULE-LEVEL VARIABLE extension (constants move, function-locals don't) — the
-- capability the spec-module extraction needs ([[cartograph-spec-layering]]).

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local moveapply = require 'cartograph.moveapply'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

-- write a lua source, ingest it, return the store's node table
local function ingest(src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return store
end

local FIXTURE = table.concat({
    'local CFG = {',        -- a module-level constant (multi-line table)
    "    kind = 'demo',",
    '    limit = 3,',
    '}',
    '',
    'local function helper(x)',
    '    local scratch = x + CFG.limit', -- function-local var; references CFG
    '    return scratch',
    'end',
    '',
    'return { helper = helper }', -- CFG is NOT re-exported: private to helper
}, '\n')

local function node_by(st, name, kind)
    for _, n in ipairs(st.data.nodes) do
        if n.name == name and (not kind or n.kind == kind) then return n end
    end
end

test('moveapply: a MODULE-LEVEL constant is extractable', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local cfg = node_by(st, 'CFG', 'var')
    ok(cfg, 'CFG captured as a var node')
    local plan, err = moveapply.plan_extract_ids(st, { cfg.id }, 'sub/cfg.lua')
    ok(plan, 'plan built (not refused): ' .. tostring(err))
    -- the const's full declaration is in the move-set
    local moved
    for _, m in ipairs(plan and plan.moves or {}) do
        if m.name == 'CFG' then moved = m end
    end
    ok(moved, 'CFG is in the move-set')
    ok(moved and moved.lines.e >= moved.lines.s + 3,
        'the multi-line table range travels whole (>=4 lines)')
end)

test('moveapply: a function-local variable is REFUSED', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local scratch = node_by(st, 'scratch', 'var')
    if not scratch then
        skip('function-local vars are not minted as nodes (guard is defensive)')
    end
    local plan, err = moveapply.plan_extract_ids(st, { scratch.id }, 'sub/x.lua')
    ok(not plan, 'refused')
    ok(err and err:find('function%-local'), 'refusal names the reason: ' .. tostring(err))
end)

test('moveapply: functions still move (regression)', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    ok(helper, 'helper captured')
    local plan = moveapply.plan_extract_ids(st, { helper.id }, 'sub/h.lua')
    ok(plan and #plan.moves >= 1, 'function extract-module still plans')
end)

test('moveapply: close_moveset pulls in a PRIVATE captured constant, ordered', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local cfg = node_by(st, 'CFG', 'var')
    local set = moveapply.close_moveset(st, { helper.id }, 'sub/m.lua')
    local has = {}
    for _, id in ipairs(set) do has[id] = true end
    ok(has[cfg.id], 'CFG (private, read only by helper) was pulled into the set')
    -- ordered by source line: CFG (line 1) precedes helper (line ~6)
    eq(cfg.id, set[1])
end)

test('moveapply: plan lays moves out in SOURCE order', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local cfg = node_by(st, 'CFG', 'var')
    -- pass helper BEFORE cfg; the plan must still order them by source line
    local plan = moveapply.plan_extract_ids(st, { helper.id, cfg.id }, 'sub/m.lua')
    eq('CFG', plan.moves[1].name)   -- line 1
    eq('helper', plan.moves[2].name) -- line ~6
end)

test('moveapply: COPY leaves the original + discloses duplication', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local cfg = node_by(st, 'CFG', 'var')
    local plan = moveapply.plan_extract_ids(st, { helper.id, cfg.id }, 'sub/m.lua',
        { copy = { [cfg.id] = true } })
    local cfgmove
    for _, m in ipairs(plan.moves) do if m.name == 'CFG' then cfgmove = m end end
    eq('copy', cfgmove.mode)
    eq('move', (function () for _, m in ipairs(plan.moves) do if m.name == 'helper' then return m.mode end end end)())
    local dup = false
    for _, h in ipairs(plan.hazards) do if h:find('CFG is COPIED') then dup = true end end
    ok(dup, 'duplication disclosed')
end)

-- ── THE MODULE SCAFFOLD (CART-0542) ──────────────────────────────────────────
-- The witness is EXECUTION, not parsing: `function M.scan(x)` with no `local M`
-- COMPILES (M is a global at compile time) and only dies when the module is
-- first required. A parse-only assertion passes with and without the scaffold,
-- which is exactly why the hazard went unenforced.

local MODFIXTURE = table.concat({
    'local M = {}',
    '',
    'local function tiny(x) return x + 1 end',
    '',
    '-- doc for scan',
    'function M.scan(x)',
    '    return tiny(x) + 1',
    'end',
    '',
    'function M.stays(y)',
    '    return M.scan(y)',
    'end',
    '',
    'return M',
}, '\n')

-- the same file, except the moved body reaches a member that STAYS behind
local RESIDUAL = MODFIXTURE
    :gsub('    return tiny%(x%) %+ 1', '    return M.stays(x) + 1')

local function dest_text(st, plan)
    local _, after = require('cartograph.txn').dryrun(st, plan)
    return after and after[plan.dest]
end

local function haz(plan, pat)
    for _, h in ipairs(plan.hazards) do if h:find(pat) then return h end end
end

test('moveapply: an extracted module LOADS — scaffold written, not disclosed', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(MODFIXTURE)
    local scan = node_by(st, 'M.scan', 'function')
    ok(scan, 'M.scan captured')
    local plan, err = moveapply.plan_extract_ids(st, { scan.id }, 'sub/new.lua')
    ok(plan, 'plan built: ' .. tostring(err))
    local text = dest_text(st, plan)
    ok(text, 'dry-run produced the created file')
    -- THE WITNESS: run the chunk, the way `require` would
    local chunk, lerr = load(text, 'sub/new.lua')
    ok(chunk, 'the created module compiles: ' .. tostring(lerr))
    local okrun, mod = pcall(chunk)
    ok(okrun, 'the created module RUNS (this is what failed): ' .. tostring(mod))
    eq('table', type(mod))
    eq('function', type(okrun and mod.scan))
    -- and the shape is the idiom, not an accident
    eq('local M = {}', vim.split(text, '\n', { plain = true })[1])
    ok(text:find('\nreturn M\n'), 'the epilogue is written: ' .. text)
    -- the capture hazard is RETIRED: its instruction ("require it, or copy it")
    -- would alias the OLD module's table, which is now the wrong table
    ok(not haz(plan, '^capture: M%f[%W]'),
        'the M capture is written, so it is no longer disclosed')
end)

test('moveapply: a member left BEHIND stays disclosed (the scaffold is not a lie)', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(RESIDUAL)
    local scan = node_by(st, 'M.scan', 'function')
    local plan = moveapply.plan_extract_ids(st, { scan.id }, 'sub/new.lua')
    ok(plan and plan.scaffold, 'scaffold still written (the file must load)')
    local text = dest_text(st, plan)
    ok(select(1, pcall(load(text, 'd'))), 'and it does load')
    local h = haz(plan, 'M%.stays')
    ok(h, 'the residual member is named: ' .. table.concat(plan.hazards, ' | '))
    ok(h and h:find('created FRESH'), 'and it says WHY the reference is now dead')
end)

test('moveapply: a file with NO module idiom gets no guessed prologue', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE) -- `return { helper = helper }` — not the idiom
    local helper = node_by(st, 'helper', 'function')
    local plan = moveapply.plan_extract_ids(st, { helper.id }, 'sub/h.lua')
    ok(plan, 'plan built')
    eq(nil, plan.scaffold)
    local text = dest_text(st, plan)
    ok(not text:find('local M = {}'), 'nothing invented: ' .. text)
end)

test('moveapply: module_table reads the idiom, and refuses anything else', function ()
    if not ready() then skip('no lua parser') end
    local lines = vim.split(MODFIXTURE, '\n', { plain = true })
    eq('M', ts.module_table('m.lua', lines))
    eq(nil, ts.module_table('m.lua', vim.split(FIXTURE, '\n', { plain = true })))
    -- a language that declares no idiom writes nothing (absence = NOT DECLARED)
    eq(nil, ts.module_table('m.py', lines))
    eq(nil, ts.module_scaffold('m.py', 'M'))
end)
