-- external-surface reading: an eligible reference that resolves to nothing in
-- the corpus is the BOUNDARY — surfaced with the shape inferred from its uses.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local externals = require 'cartograph.externals'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local function write(root, rel, text)
    local dir = root .. '/' .. (rel:match('^(.*)/[^/]*$') or '')
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w'))
    fd:write(text)
    fd:close()
end

test('external-surface: an untyped receiver surfaces with its used-member shape; stdlib tagged', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    -- `node` is used with methods but has no in-corpus definition (external
    -- type) → the boundary; its used members ARE its inferred shape. `table`
    -- is a recognized stdlib base. `handle_event` is a bare unresolved global.
    write(root, 'm.lua', table.concat({
        'local function walk(node)',
        '  local t = node:type()',
        '  local c = node:child(0)',
        '  node:field("name")',
        '  handle_event(t)',              -- bare unresolved global (no member)
        '  return table.concat({ t }, ",")',
        'end',
        'return { walk = walk }',
    }, '\n'))
    store.ingest(ts.extract(root))
    local s = externals.surface(store)

    local node = s.bases['node']
    ok(node, 'node surfaced as an external base')
    ok(not node.known, 'node is UNKNOWN (not a recognized builtin)')
    ok(node.members['type'], 'shape includes node:type')
    ok(node.members['child'], 'shape includes node:child')
    ok(node.members['field'], 'shape includes node:field')

    local tbl = s.bases['table']
    ok(tbl and tbl.known, 'table is TAGGED as a recognized stdlib base')

    local h = s.bases['handle_event']
    ok(h and h.bare > 0, 'a bare unresolved global surfaces (no member shape)')

    -- the report renders without error and leads with the header
    local lines = externals.report(store)
    ok(lines[1]:find('external surface', 1, true), 'report header present')
end)
