-- The development guards: seam-guard (config-declared representation
-- seams), multi-return truncation, require cycles (hedged).

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lint = require 'cartograph.lint'
local config = require 'cartograph.config'

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
