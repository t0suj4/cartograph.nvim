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

test('references: a read inside a CONDITION is counted once, not twice',
    function ()
    -- ★★ CART-0634. A row that has a condition also carries that condition in `rhs`,
    -- so walking both counted every read inside an `if` TWICE. It surfaced as a port
    -- worklist that did not reconcile with the files: `global.donecrashsite` reported
    -- 3 reads against 2 in the source, and each of the seven `global.*` names was
    -- over by exactly its number of conditions.
    local store = require 'cartograph.store'
    local ts = require 'cartograph.providers.treesitter'
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\n'
        .. 'function M.f()\n'
        .. '  if glob.done then return end\n'   -- ONE read, in a condition
        .. '  glob.other = 1\n'                 -- one read, on the lhs
        .. 'end\n'
        .. 'function M.g()\n'
        .. '  glob.pair = glob.pair or {}\n'    -- TWO reads on ONE row, both real
        .. 'end\n'
        .. 'return M\n')
    fd:close()
    store.ingest(ts.extract(root))
    local refs = require('cartograph.externals').references(store)
    eq(1, refs.names['glob.done'], 'a condition read counts ONCE')
    eq(1, refs.names['glob.other'])
    -- ⚠ AND THE OBVIOUS FIX WOULD HAVE BROKEN THIS. Collapsing repeats within a row
    -- reads as the same bug fixed more simply, and it is wrong: `x = x or {}` is two
    -- real occurrences on one line, and it is why two of Von-Neumann's seven names
    -- already reconciled before the change.
    eq(2, refs.names['glob.pair'],
        'two occurrences on one row stay two — a per-row dedupe would undercount')
    vim.fn.delete(root, 'rf')
end)

test('references: a loop header is two rows and its read counts once',
    function ()
    -- ★★ CART-0641. `for k, v in pairs(t) do` emits a PRE-LOOP init row (df needs the
    -- init to run before the head) AND the `for_statement` control row (CFG needs it),
    -- both carrying the same expression because the header IS the init. Neither row is
    -- wrong — a set-based consumer like reaching-definitions is idempotent over the
    -- repeat. AN OCCURRENCE COUNTER IS NOT, and this is one.
    local store = require 'cartograph.store'
    local ts = require 'cartograph.providers.treesitter'
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\n'
        .. 'function M.f()\n'
        .. '  for k, v in pairs(glob.zoom) do\n'   -- ONE read, TWO rows
        .. '    glob.other[k] = v\n'               -- one read, a different row
        .. '  end\n'
        .. 'end\n'
        .. 'return M\n')
    fd:close()
    store.ingest(ts.extract(root))
    local refs = require('cartograph.externals').references(store)
    eq(1, refs.names['glob.zoom'], 'the loop iterable counts once, not twice')
    eq(1, refs.names['glob.other'], 'and an ordinary row in the body is untouched')
    vim.fn.delete(root, 'rf')
end)

test('references: a binding in ANOTHER file marks a read, it does not delete it',
    function ()
        if not ready() then skip 'no lua parser' end
        -- ★ THE SHAPE OF CART-0649, BY HAND. railloader's spec/EntityQueue_spec.lua
        -- assigns `global`, and that one line in a file no entry point reaches took
        -- the port report's read surface from 8 LOST names to 1. Von Neumann's
        -- `local script = require('k-lib')()` in one scenario file silenced all 41
        -- `script.*` reads in the other 33. Both are one project-wide veto.
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        -- a stub file BINDS the name …
        write(root, 'stub.lua', table.concat({
            'global = {}',
            'return global',
        }, '\n'))
        -- … and an unrelated file READS through it. That read is the port worklist.
        write(root, 'main.lua', table.concat({
            'local function tick()',
            '  local a = global.ghosts',
            '  local b = global.queue',
            '  return a, b',
            'end',
            'return { tick = tick }',
        }, '\n'))
        store.ingest(ts.extract(root))
        local refs = externals.references(store)

        -- KEPT: the read survives the other file's binding …
        assert(refs.names['global.ghosts'] == 1,
            'a read must survive a binding made in a DIFFERENT file, got '
            .. tostring(refs.names['global.ghosts']))
        assert(refs.names['global.queue'] == 1, 'both reads must survive')
        -- … and it says WHERE the competing binding is, so the hedge is checkable
        local sh = (refs.shadowed or {})['global.ghosts']
        assert(sh and #sh == 1 and sh[1] == 'stub.lua',
            'the read must name the file that also binds its root, got '
            .. vim.inspect(sh))
    end)

test('references: a binding in the SAME file still silences that file\'s reads',
    function ()
        if not ready() then skip 'no lua parser' end
        -- The other half, and it is why the fix is not "never suppress": Von Neumann's
        -- cage.lua really does rebind `script` for itself, and cage.lua's OWN reads do
        -- go through that wrapper. Suppression is right there and wrong everywhere else.
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        write(root, 'one.lua', table.concat({
            'local shim = require("k-lib")()',
            'local function go()',
            '  return shim.on_event',
            'end',
            'return { go = go }',
        }, '\n'))
        store.ingest(ts.extract(root))
        local refs = externals.references(store)
        assert(refs.names['shim.on_event'] == nil,
            'a read rooted at a name THIS file binds is internal, got '
            .. tostring(refs.names['shim.on_event']))
        assert((refs.shadowed or {})['shim.on_event'] == nil,
            'a silenced read must not also be reported as a hedge')
    end)
