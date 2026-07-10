-- DETAIL: page the flesh (argv/at/callee) for one file on demand by
-- re-parsing it — the "ride the skeleton, page the flesh" seam. Detail is
-- syntactic, so a re-parse reproduces it; here we prove calls_of returns a
-- function's call sites with their argument shapes after ingest.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local detail = require 'cartograph.detail'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

test('detail: calls_of reconstructs a function\'s call sites + argv', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local function helper(x) return x end',
        'local function run(cb)',
        '  helper(1)',
        '  helper(cb)',
        '  return process("SELECT 1", cb)',
        'end',
        'return { run = run, helper = helper }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))

    local runid
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'run' then runid = n.id end
    end
    ok(runid, 'run extracted')

    local calls = detail.calls_of(store, runid)
    local by = {}
    for _, c in ipairs(calls) do
        by[c.full or c.callee] = c
    end
    ok(by['helper'], 'helper() call paged back')
    ok(by['process'], 'process() call paged back')
    -- argv detail survives the round-trip: process's first arg is a literal
    local p = by['process']
    eq('lit', p.argv[1].k, 'the SQL literal arg shape reconstructed')
    eq('SELECT 1', p.argv[1].v)
    -- and every paged call is attributed to run (its fn)
    for _, c in ipairs(calls) do eq(runid, c.fn) end
    -- helper's OWN body has no calls — paging it returns nothing
    local hid
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'helper' then hid = n.id end
    end
    eq(0, #detail.calls_of(store, hid))
    vim.fn.delete(root, 'rf')
end)
