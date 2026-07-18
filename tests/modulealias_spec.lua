-- resolve_module_alias binding-over-name-match (v55): `alias.m` where
-- alias=require("M") resolves to M's OWN export, correcting a resolution that a
-- FOREIGN file's `alias.m = …` (a test mock / monkey-patch) wrongly won. Guards:
-- the mock must lose to the module def; an EXTENSION (member the module lacks) must
-- still resolve (the override must not over-fire).

local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

local function extract_dir(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, src in pairs(files) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close()
    end
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    return data
end

local function node_in(data, file, pat)
    for _, n in ipairs(data.nodes) do
        if n.file == file and n.name and n.name:match(pat) then return n.id end
    end
end
local function call_in(data, file, full)
    for _, c in ipairs(data.calls) do if c.file == file and c.full == full then return c end end
end

test('module-alias: alias.m resolves to the module export, NOT a foreign mock', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_dir {
        ['foo.lua'] = 'local M = {}\nfunction M.doit() return 1 end\nreturn M\n',
        -- a test/other file mocks the imported module's field (monkey-patch)
        ['mock.lua'] = 'local foo = require("foo")\nfoo.doit = function() return 2 end\n',
        ['caller.lua'] = 'local foo = require("foo")\nlocal function run() return foo.doit() end\nreturn run\n',
    }
    local real = node_in(data, 'foo.lua', 'doit$')
    local mock = node_in(data, 'mock.lua', 'doit$')
    ok(real, 'foo.lua M.doit exists')
    local c = call_in(data, 'caller.lua', 'foo.doit')
    ok(c, 'caller foo.doit call found')
    eq(real, c.to)                 -- the module's own export, NOT mock.lua's assignment
    ok(c.to ~= mock, 'never the foreign mock')
end)

test('module-alias: an EXTENSION (member the module lacks) still resolves — no over-fire', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_dir {
        ['baz.lua'] = 'local M = {}\nreturn M\n',                     -- module defines NO ext
        ['ext.lua'] = 'local baz = require("baz")\nfunction baz.ext() return 9 end\n', -- adds ext
        ['caller.lua'] = 'local baz = require("baz")\nlocal function run() return baz.ext() end\nreturn run\n',
    }
    local add = node_in(data, 'ext.lua', 'ext$')
    ok(add, 'ext.lua baz.ext (the extension) exists')
    local c = call_in(data, 'caller.lua', 'baz.ext')
    ok(c, 'caller baz.ext call found')
    -- baz.lua defines no `ext` → the override must NOT fire → the extension stands
    eq(add, c.to)
end)
