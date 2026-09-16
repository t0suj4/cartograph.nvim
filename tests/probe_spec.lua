-- THE PROBE HARNESS WALKS TWO POPULATIONS (CART-0946).
--
-- It walked function/method bodies only until 2026-09-16, and the omission was
-- invisible because the header stated it truthfully: asked for php inclusion
-- calls EXHAUSTIVELY over 2095 of 2095 function nodes, it reported TWO
-- `require_api` sites in a corpus that has 825 — the other 823 sit at FILE
-- SCOPE. "Exhaustive over N of N function nodes" is a true sentence that
-- produces a false impression.
--
-- ⚠ END TO END, DELIBERATELY. probe.lua is a SCRIPT, not a module: the thing
-- under test is what a reader sees on stdout — the counts AND the scope line
-- that qualifies them — which is a property of the process, not of a function.
--
-- ⚠⚠ THE OPT-OUT IS TESTED TOO, AND IT IS THE SHARPER HALF. `--mods 0`
-- reproduces the old numbers, and the point is that it can no longer do so
-- SILENTLY: the same exclusion that used to print `[exhaustive]` now prints
-- `0 of N module node(s)` and `[ranked-open]`.

local function repo(rel)
    return vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h') .. '/' .. rel
end

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

local function run(root, ...)
    local out = vim.fn.system(vim.iter({ vim.v.progpath, '--headless', '-u', 'NONE',
        '-l', repo('tools/probe.lua'), root, ... }):flatten():totable())
    return out, vim.v.shell_error
end

--- a root with a call at MODULE level and a call inside a FUNCTION, so the two
--- populations are distinguishable in the output rather than summed blindly
local function mkroot()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'require("top_level_one")',
        'require("top_level_two")',
        'local function f()',
        '    require("in_a_function")',
        'end',
        'return f',
    }, '\n') .. '\n')
    fd:close()
    return root
end

local COUNT = 'if e.k == "call" and e.f and e.f.k == "name"'
    .. ' and tostring(e.f.n) == "require" then emit("require") end'

test('probe: module top level is walked, and the scope line names both populations', function ()
    if not ready() then skip 'no treesitter' end
    local out, rc = run(mkroot(), '--expr', COUNT)
    eq(0, rc, 'the probe exits 0')
    -- 2 module-level + 1 in the function. Walking functions alone answers 1,
    -- which is the shape of the 2-instead-of-825 miss.
    ok(out:find('3%s+require'), 'all three require sites are counted: ' .. out)
    ok(out:find('function/method', 1, true) and out:find('module node', 1, true),
        'the scope line names BOTH populations: ' .. out)
    ok(out:find('exhaustive', 1, true),
        'both populations were exhausted, so the verdict is exhaustive: ' .. out)
end)

test('probe: --mods 0 excludes modules and SAYS so instead of claiming exhaustive', function ()
    if not ready() then skip 'no treesitter' end
    local out, rc = run(mkroot(), '--mods', '0', '--expr', COUNT)
    eq(0, rc, 'the probe exits 0')
    ok(out:find('1%s+require'), 'only the in-function site is counted: ' .. out)
    ok(out:find('0 of 1 module node', 1, true),
        'the exclusion is VISIBLE in the scope line: ' .. out)
    ok(out:find('ranked%-open'),
        'an excluded population is not exhaustive: ' .. out)
end)

test('probe: a --row chunk can tell the two populations apart by node.kind', function ()
    if not ready() then skip 'no treesitter' end
    -- the migration contract for existing chunks: nothing new is needed to keep
    -- a function-only measurement, and the discriminator is already in hand
    -- ⚠ THE KEY IS PREFIXED BECAUSE THE SCOPE LINE ALSO SAYS "module". A bare
    -- `emit(node.kind)` and a bare `out:find('module')` passed with the module
    -- arm DISABLED — it was matching the header, not a counter. A test whose
    -- needle occurs in the frame is pinning the frame.
    local out, rc = run(mkroot(), '--row', 'emit("kind:" .. tostring(node.kind))')
    eq(0, rc, 'the probe exits 0')
    ok(out:find('kind:module', 1, true) and out:find('kind:function', 1, true),
        'both kinds reach the chunk: ' .. out)
end)
