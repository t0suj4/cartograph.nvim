-- FABRICATION CENSUS, BACKWARD (`tools/fabcensus.lua --backward`): refusals whose
-- receiver the calling file's own binding could speak to. The second direction of
-- CART-0605 ([[cartograph-bidirectional-instruments]]) — a WORK LIST, never a gate.
--
-- ★ WHAT THESE FENCE IS THE POPULATION AND THE BUCKETS, not a corpus number. Each
-- guard below was found by reading the first run's rows, and each would move a
-- count on cartograph's own tree without any test noticing:
--   · a method on a call's RESULT (`s.name():upper()`) is NOT pinned by the binding
--     on its root — 9 of 47 rows on our own tree were exactly this, all false
--   · a CHAIN names a nested member: `s.G.check` must not count the top-level
--     `M.check` in the bound file as a rival
--   · a dot call and one non-method def among a method of the same name settle
--     by SHAPE (receipt.lua's `M.unwarranted` beside `Receipt:unwarranted`)
--   · a `local function` in the bound file is not a member (exported == false)
--   · a re-export by assignment (`M.hash = hash`) IS a member, through n.altkeys
--   · `require('pkg')` is `pkg.lua` OR `pkg/init.lua`, matched at a path boundary —
--     a suffix test bound it to plugin/pkg.lua, an unrelated file
--   · without `--backward` the forward census prints what it always printed

local function fixture()
    local root = vim.fn.tempname()
    for _, d in ipairs({ 'plugin', 'lua/pkg', 'lua/other', 'lua/other/xpkg' }) do vim.fn.mkdir(root .. '/' .. d, 'p') end
    local files = {
        ['lua/pkg/a.lua'] = { 'local M = {}', 'function M.go() return 1 end', 'return M' },
        ['lua/pkg/b.lua'] = { 'local M = {}', 'function M.go() return 2 end', 'return M' },
        -- ends in `pkg/a.lua` but is NOT module pkg.a: a suffix test without a path
        -- boundary sees two answers for require('pkg.a') and drops the row
        ['lua/other/xpkg/a.lua'] = { 'local M = {}', 'function M.stop() return 0 end', 'return M' },
        -- a member assigned from a call's RESULT: no def node for `load` here
        ['lua/pkg/p.lua'] = { 'local M = {}', 'local function helper() return 0 end',
            'M.load = setmetatable({}, { __call = helper })', 'return M' },
        ['lua/other/q.lua'] = { 'local M = {}', 'function M.load() return 1 end',
            'function M.hidden() return 1 end', 'return M' },
        ['lua/other/r.lua'] = { 'local M = {}', 'function M.load() return 2 end',
            'function M.hidden() return 2 end', 'function M.hash() return 2 end',
            'function M.digest() return 2 end', 'return M' },
        ['lua/pkg/s.lua'] = { 'local M = {}', "function M.name() return 'x' end",
            "function M.check() return 'top' end",
            -- the receipt.lua shape: a module function and a METHOD of the same name
            'local Obj = {}', 'function Obj:pair() return M.pair(self) end',
            'function M.pair(x) return x end',
            'local function hidden() return 0 end',
            -- a SECOND file-local `hidden`. With ONE, `s.hidden()` RESOLVES to it —
            -- through the binding, onto a local that is not a member of the module
            -- (a fabricated edge, noted on the ticket) — so it never reaches the
            -- refused population. With two the resolver refuses, which is the row
            -- this guard needs.
            'local function wrap() local function hidden() return 1 end return hidden() end',
            'M.G = {}', 'M.G.check = function () return M.check() + hidden() end',
            'function M.twice() return 1 end', 'function M.twice() return 2 end', 'return M' },
        -- re-export by assignment: `hash` is a member only through its alt key
        ['lua/pkg/j.lua'] = { 'local M = {}', 'local function hash(s) return #s end',
            'M.hash = hash', 'M.digest = hash', 'return M' },
        ['lua/pkg/init.lua'] = { 'local M = {}', 'function M.setup() return true end', 'return M' },
        ['plugin/pkg.lua'] = { 'vim.g.loaded_pkg = 1' },
        -- the bound file lacks `stop`; a SIBLING in its directory defines it (the
        -- same-unit acquittal), and so does an unrelated file (so the call refuses)
        ['lua/pkg/p2.lua'] = { 'local M = {}', 'M.cfg = {}', 'return M' },
        ['lua/pkg/p3.lua'] = { 'local M = {}', 'function M.stop() return 3 end', 'return M' },
        ['lua/other/x.lua'] = { 'local M = {}', 'function M.setup() return 1 end',
            'function M.check() return 1 end', 'function M.upper() return 1 end',
            'function M.hash() return 1 end', 'function M.digest() return 1 end', 'return M' },
        ['lua/pkg/c.lua'] = { "local p = require 'pkg.p'", "local s = require 'pkg.s'",
            'local M = {}', 'function M.run()',
            "    require('pkg.a').go()",
            '    p.load()',
            '    s.name():upper()',
            '    s.twice()',
            '    s.G.check()',
            "    require('pkg').setup()",
            '    s.hidden()',
            '    s.pair(1)',
            "    require('pkg.j').hash('x')",
            "    require('pkg.j').digest('x')",
            "    local p2 = require 'pkg.p2'",
            '    p2.stop()',
            '    p2.cfg.stop()',
            'end', 'return M' },
    }
    for rel, lines in pairs(files) do write(root, rel, lines) end
    return root
end

local function run(root, flag)
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/fabcensus.lua'), root }
    if flag then cmd[#cmd + 1] = flag end
    local r = vim.system(cmd, { cwd = repo(), text = true }):wait()
    return (r.stdout or '') .. (r.stderr or '')
end

local OUT
local function out()
    if not OUT then
        local root = fixture()
        OUT = run(root, '--backward')
        vim.fn.delete(root, 'rf')
    end
    return OUT
end

test('fabcensus --backward: an inline require that NAMES its module settles an ambiguous refusal', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    -- (the census found CART-1113; the RESOLVER now settles all three — pkg.a, and pkg.j twice through re-exports —
    -- so the work list holds none of them: `require('m').f` reaches m's f through the import edge at its path)
    ok(not o:find('by inline require', 1, true), 'no inline require is left refused: ' .. o)
    ok(not o:find('pkg/a.lua::M.go', 1, true), 'pkg.a.go is resolved, not listed')
end)

test('fabcensus --backward: a method on a call RESULT is not pinned by the root binding', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    -- `s.name():upper()` is refused (x.lua and nobody else defines `upper`
    -- reachable) but `s` pins the receiver of `name`, never of `upper`
    ok(not o:find('upper', 1, true), 'no row may name upper: ' .. o)
    ok(o:match('population: %d+ refused call%(s%); 7 candidate'), -- (10 before CART-1113 resolved the 3 inline requires)
        'ten candidates, the call-result chain is not one: ' .. o)
end)

test('fabcensus --backward: a chain matches its member PATH, not its last segment', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    ok(o:find('=> lua/pkg/s.lua::M.G.check', 1, true),
        's.G.check settles to M.G.check — the top-level M.check is no rival: ' .. o)
end)

test('fabcensus --backward: a dot call beside a same-named METHOD settles by shape', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    ok(o:find('s.pair  bound -> lua/pkg/s.lua  [blocked]   => lua/pkg/s.lua::M.pair', 1, true),
        'M.pair, not Obj:pair: ' .. o)
end)

test('fabcensus --backward: a file-local def in the bound file is not a member', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    local lacks = o:match('── bound%-lacks, by import binding:.-\n\n') or o:match('── bound%-lacks, by import binding:.*$') or ''
    ok(lacks:find('s.hidden', 1, true), '`local function hidden` does not make s.hidden settle: ' .. o)
    ok(lacks:find('p.load', 1, true), 'and a member assigned from a call result lacks a def')
end)

test('fabcensus --backward: a sibling that defines the member acquits; one that only shares its last segment does not', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    ok(o:find('p2.stop  bound -> lua/pkg/p2.lua  [blocked]   => lua/pkg/p3.lua::stop', 1, true),
        'p3.lua, in the bound file\'s directory, defines stop: ' .. o)
    local lacks = o:match('── bound%-lacks, by import binding:.-\n\n') or o:match('── bound%-lacks, by import binding:.*$') or ''
    ok(lacks:find('p2.cfg.stop', 1, true),
        'p2.cfg.stop names a nested member nobody defines — p3\'s M.stop is no acquittal: ' .. o)
end)

test('fabcensus --backward: a re-export by assignment is a member through its alt key', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    -- (the RESOLVER now settles both through the alt key, CART-1113 — the census lists neither; the census's own
    -- alt-key index is what found them, and is still what reads a re-export if a refusal remains)
    ok(not o:find('pkg/j.lua.hash', 1, true), 'M.hash = hash is resolved, not listed: ' .. o)
    ok(not o:find('pkg/j.lua.digest', 1, true), 'M.digest = hash is resolved, not listed: ' .. o)
end)

test('fabcensus --backward: require(\'pkg\') never binds to an unrelated file with the same suffix', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    ok(not o:find('plugin/pkg.lua', 1, true), 'plugin/pkg.lua is not the module pkg: ' .. o)
end)

test('fabcensus --backward: several same-shape defs narrow and do not decide; the buckets partition', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local o = out()
    ok(o:find('s.twice  bound -> lua/pkg/s.lua  [blocked]   (2 defs there)', 1, true), o)
    ok(not o:find('PARTITION BROKEN', 1, true), 'every candidate lands in exactly one bucket')
    ok(o:find('WORK LIST, NOT A GATE', 1, true), 'the tool labels its own status')
end)

test('fabcensus: without --backward the forward census is what it was', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local root = fixture()
    local o = run(root)
    vim.fn.delete(root, 'rf')
    ok(o:find('FABRICATION CENSUS — ', 1, true), 'the forward header: ' .. o)
    ok(not o:find('BACKWARD', 1, true), 'and nothing of the reverse direction')
end)

-- (CART-1961: THE TYPED PIN. Java's inferred tier is instance calls on locals / params, spelled `T::m` with T the
-- receiver's declared type; the binding pin cannot speak to them. Over a CONSTRUCTED graph (--graph), so the oracle's
-- every branch is judged on the row shape it decides, whatever the extractor currently produces)
test('fabcensus: the typed pin decides a Java `T::m` edge by the declared type and the tree\'s hierarchy (CART-1961)', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function fn(file, cls, m, l) return { id = file .. '::' .. cls .. '::' .. m .. '@' .. l, name = cls .. '::' .. m, file = file, kind = 'method' } end
    local nodes = {
        fn('a/Base.java', 'Base', 'm', 1), fn('a/Sub.java', 'Sub', 'n', 1), fn('k/Key.java', 'Key', 'methodName', 1),
        fn('k/Key.java', 'Key', 'x', 2), fn('c/V.java', 'V', 'y', 1), fn('k/X.java', 'X', 'getMessage', 1),
        fn('c/U.java', 'U', 'run', 1),
    }
    local function call(file, full, to, line)
        return { file = file, fn = file .. '::U::run@1', full = full, callee = full:match('::(.*)$'), to = to, inferred = true, line = line }
    end
    local data = {
        nodes = nodes,
        edges = {
            { kind = 'import', from = 'c/U.java', to = 'a/Sub.java', bind = 'Sub' },
            { kind = 'import', from = 'c/U.java', to = 'a/Base.java', bind = 'Base' },
            { kind = 'import', from = 'c/U.java', to = 'c/Utils.java', bind = 'Descriptor' },
            { kind = 'import', from = 'c/U.java', to = 'a/P.java', bind = 'P' },
        },
        extends = { { file = 'a/Sub.java', child = 'Sub', parent = 'Base' },
            { file = 'a/P.java', child = 'P', parent = 'RuntimeException' } },
        calls = {
            call('c/U.java', 'Sub::m', 'a/Base.java::Base::m@1', 3),                     -- inherited: a supertype's file
            call('c/U.java', 'Base::n', 'a/Sub.java::Sub::n@1', 4),                      -- an override in a subtype
            call('c/U.java', 'Descriptor::methodName', 'k/Key.java::Key::methodName@1', 5), -- unrelated: witnessed
            call('c/V.java', 'V::x', 'k/Key.java::Key::x@2', 6),                         -- unqualified: refused
            call('c/U.java', 'P::getMessage', 'k/X.java::X::getMessage@1', 7),           -- the chain leaves the tree
        },
    }
    local g = root .. '/graph.json'
    local fd = assert(io.open(g, 'w')); fd:write(vim.json.encode(data)); fd:close()
    local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', repo('tools/fabcensus.lua'), root, '--graph', g },
        { cwd = repo(), text = true }):wait()
    o = (r.stdout or '') .. (r.stderr or '')
    vim.fn.delete(root, 'rf')
    ok(o:match('typed%-pinned%s+2%s'), 'a supertype\'s and a subtype\'s file both agree: ' .. o)
    ok(o:match('typed%-contra%s+1%s'), 'the unrelated class is witnessed: ' .. o)
    ok(o:find('Descriptor::methodName  ->  Key::methodName', 1, true), 'and printed as a defect')
    ok(o:match('1%s+T is a class of the calling file'), 'an unqualified-looking row is refused, not judged')
    ok(o:match('1%s+a supertype chain leaves the tree'), 'a chain past the tree is refused')
    ok(not o:find('BUCKET PARTITION BROKEN', 1, true), 'the partition holds')
end)
