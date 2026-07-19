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
    'return { helper = helper, CFG = CFG }',
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
