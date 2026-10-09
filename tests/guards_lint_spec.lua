-- The development guards: seam-guard (config-declared representation
-- seams), multi-return truncation, require cycles (hedged).

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lint = require 'cartograph.lint'
local config = require 'cartograph.config'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local function write(root, rel, text)
    local dir = root .. '/' .. (rel:match('^(.*)/[^/]*$') or '')
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w'))
    fd:write(text)
    fd:close()
end

test('guards: seam violations outside owners; owners exempt', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'consumer.lua',
        'local function f(r) return r.start.line end\nreturn { f }')
    write(root, 'owner/core.lua',
        'local function g(r) return r.start.line end\nreturn { g }')
    store.ingest(ts.extract(root))
    local saved = config.seams
    config.seams = { { name = 'at', patterns = { '%.start%.line' },
        owners = { '^owner/' } } }
    local fs = lint.run(store, { only = { ['seam-guard'] = true } })
    config.seams = saved
    eq(1, #fs, 'one violation: the consumer, not the owner')
    ok(fs[1].file:find('consumer', 1, true))
    ok(fs[1].message:find('at', 1, true) and fs[1].message:find('accessor', 1, true))
end)

test('guards: multi-return truncation flagged; clean forms pass', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'm.lua', table.concat({
        'local function f() return 1, 2 end',
        'local function bad(c)',
        '    local a, b = c and f() or nil',    -- THE bug
        '    return a, b',
        'end',
        'local function fine(c)',
        '    local a, b = f()',                 -- direct: both values
        '    local x = c and f() or nil',       -- single target: intended
        '    return a, b, x',
        'end',
        'return { f, bad, fine }',
    }, '\n'))
    store.ingest(ts.extract(root))
    local fs = lint.run(store, { only = { truncation = true } })
    eq(1, #fs, 'exactly the truncating form')
    eq(3, fs[1].line)
end)

test('guards: require cycles reported with the load-time hedge', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'a.lua', "local b = require 'b'\nreturn { b = b }")
    write(root, 'b.lua', "local a = require 'a'\nreturn { a = a }")
    write(root, 'solo.lua', "return {}")
    store.ingest(ts.extract(root))
    local fs = lint.run(store, { only = { ['require-cycle'] = true } })
    eq(1, #fs, 'one cycle')
    ok(fs[1].message:find('2 modules', 1, true))
    ok(fs[1].message:find('lazy requires break it', 1, true), 'the hedge is spoken')
end)

-- ⚠ A LAZY NAMESPACE IS A MODULE BINDING (CART-1619): nvim-dap's `local lazy = setmetatable({}, { __index =
-- function (_, key) return require('dap.' .. key) end })` makes `lazy.utils` the module dap.utils; its calls resolved
-- only by tail guess (lazy.utils.notify refused ambiguous beside another module's notify). A lazy require loads on
-- first use, so a cycle through it is no load-time cycle
test('guards: a LAZY NAMESPACE (__index requiring prefix .. key) binds N.k to its module, and closes no require cycle', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/dap', 'p')
    write(root, 'dap.lua', table.concat({
        "local lazy = setmetatable({}, { __index = function (_, key) return require('dap.' .. key) end })",
        -- (a FIXED module under a computed name is no namespace: the concatenation's tail is not the key)
        "local NAME = 'ui'",
        "local cfg = setmetatable({}, { __index = function (_, k) return require('dap.' .. NAME)[k] end })",
        "local M = {}",
        "function M.run() lazy.utils.notify('x'); cfg.utils.notify('y'); return lazy.ui:pick() end",
        "return M",
    }, '\n'))
    write(root, 'dap/utils.lua', "local dap = require('dap')\nlocal M = {}\nfunction M.notify(m) return dap, m end\nreturn M")
    write(root, 'dap/ui.lua', "local M = {}\nfunction M:pick() return self end\nfunction M.notify(m) return m end\nreturn M")
    store.ingest(ts.extract(root))
    local lz = {}
    for _, e in ipairs(store.data.edges) do if e.kind == 'import' and e.lazy then lz[e.bind] = e.to end end
    eq('dap/utils.lua', lz['lazy.utils'], 'N.k is the module prefix .. k')
    eq('dap/ui.lua', lz['lazy.ui'])
    eq(nil, lz['cfg.utils'], 'require(prefix .. <not the key>) makes no namespace')
    local cv = require('cartograph.callview').of(store.data)
    local to = {}
    for i = 1, cv.n do to[cv.get(i, 'full') or i] = cv.get(i, 'to') end
    ok(tostring(to['lazy.utils.notify']):match('^dap/utils%.lua::M%.notify'), 'the bound module answers an ambiguous tail')
    ok(tostring(to['lazy.ui:pick']):match('^dap/ui%.lua::'), 'a method call through it too')
    eq(0, #lint.run(store, { only = { ['require-cycle'] = true } }), 'dap -> utils is lazy: no load-time cycle')
end)
