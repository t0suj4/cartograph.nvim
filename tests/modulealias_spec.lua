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

-- THE BARE-EXPORT CASE, and the reason `tail[m] or exact[m]` was wrong. The two name
-- indexes are not alternatives: `tail` holds only RECEIVER-QUALIFIED defs (`X.m`), a
-- BARE `m` lives only in `exact`. Selecting one index by whether the tail list is empty
-- ANYWHERE IN THE CORPUS meant that the moment any unrelated file defined
-- `<anything>.m`, a module's own bare `m` became invisible to this pass — so the
-- correction above silently stopped happening. MEASURED on jquery: `jQuery.error(…)`
-- resolved to a foreign `find.error`. Here the module's export is bare and a foreign
-- file defines a QUALIFIED namesake, which is exactly that shape.
test('module-alias: a BARE module export is found even when a foreign file defines'
    .. ' <other>.m', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_dir {
        -- the module exports a BARE function (only in the `exact` index)
        ['logger.lua'] = 'local function warn(msg) return msg end\nreturn { warn = warn }\n',
        -- an unrelated namespace defines a QUALIFIED namesake (only in `tail`)
        ['cli.lua'] = 'local Cmd = {}\nfunction Cmd.warn(msg) return msg end\nreturn Cmd\n',
        ['caller.lua'] = 'local logger = require("logger")\n'
            .. 'local function run() return logger.warn("x") end\nreturn run\n',
    }
    local bare = node_in(data, 'logger.lua', '^warn$')
    ok(bare, 'logger.lua defines a bare warn')
    local c = call_in(data, 'caller.lua', 'logger.warn')
    ok(c, 'the call is recorded')
    -- the BINDING is authoritative: logger.warn is logger.lua's warn, whatever cli.lua
    -- happens to name its own method
    eq(bare, c.to)
end)

-- THE REGRESSION GUARD FOR THE FIX ITSELF. `fit_in_file` consults `tail` then `exact`,
-- and the obvious way to write that — `for _, l in ipairs({ tail[k], exact[k] })` — is
-- WRONG: ipairs stops at the first nil, and a nil tail list is the COMMON case (a
-- bare-named def is never tail-indexed). That hole cost the pass 845 of its 1054 fills
-- on zig while every gate still passed, because it only ever withheld resolutions.
--
-- To BITE, the fixture has to need this pass and nothing else: TWO files define a bare
-- `solo`, so the main resolver is ambiguous and refuses, and no file defines a qualified
-- `<x>.solo`, so the tail index is empty for it. Only the require BINDING can settle it,
-- and only through the `exact` index. (Written after the first attempt at this guard
-- passed against the nil-hole — a unique bare name is resolved by the main path, so the
-- pass was never the thing under test.)
test('module-alias: an AMBIGUOUS bare export is settled by the binding, via `exact`',
    function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_dir {
        ['left.lua'] = 'local function solo() return 1 end\nreturn { solo = solo }\n',
        ['right.lua'] = 'local function solo() return 2 end\nreturn { solo = solo }\n',
        ['caller.lua'] = 'local left = require("left")\n'
            .. 'local function run() return left.solo() end\nreturn run\n',
    }
    local want = node_in(data, 'left.lua', '^solo$')
    local other = node_in(data, 'right.lua', '^solo$')
    ok(want and other, 'both files define a bare solo')
    local c = call_in(data, 'caller.lua', 'left.solo')
    ok(c, 'the call is recorded')
    eq(want, c.to, 'the binding picks left.lua, not right.lua and not a refusal')
end)
