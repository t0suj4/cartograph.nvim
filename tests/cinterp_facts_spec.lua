-- cartograph.cinterp.facts (CART-1248): the TABLE of an interpreter adapter's facts, each derived from the runtime's
-- own tree — the runner's rules (the first derivation that holds wins; a gap is ADAPTER, ENGINE, BLOCKED or ERROR),
-- and the make dry-run COMPDB (the product's units only, an include's unset variable derived, flags made absolute).
local FT = require 'cartograph.cinterp.facts'

local function write(root, files)
    for rel, text in pairs(files) do
        local d = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        vim.fn.mkdir(d, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
end

test('facts: the TABLE — the first derivation that holds wins; a gap is named by kind (adapter / engine / blocked / error)', function ()
    local dir = vim.fn.tempname()
    write(dir, {
        ['a.lua'] = "return { fact = 'x', derive = function () return 1 end }",
        ['b1.lua'] = "return { fact = 'y', needs = { 'x' }, derive = function () return nil, 'no evidence here' end }",
        ['b2.lua'] = "return { fact = 'y', needs = { 'x' }, derive = function (_, got) return got.x + 1 end }",
        ['c.lua'] = "return { fact = 'z', needs = { 'w' }, derive = function () return 0 end }",
        ['d.lua'] = "return { fact = 'e', derive = function () return nil, 'an array frame', 'engine' end }",
        ['f.lua'] = "return { fact = 'r', derive = function () error('boom') end }",
        ['g.lua'] = "return { fact = 'q', needs = { 'e' }, derive = function () return 0 end }",
    })
    local T = FT.derive({ src = dir }, { dir = dir })
    local r = T.rows
    eq({ 1, 'a' }, { r.x.value, r.x.by })
    eq({ 2, 'b2', 'no evidence here' }, { r.y.value, r.y.by, r.y.tried.b1 }, 'b1 refused on its evidence, b2 held')
    eq({ 'blocked', 'needs w' }, { r.z.kind, r.z.gap }, 'a fact nothing derives blocks the fact needing it')
    eq({ 'engine', 'an array frame' }, { r.e.kind, r.e.gap })
    eq('error', r.r.kind)
    ok(r.r.gap:find('boom', 1, true), r.r.gap)
    eq({ 'blocked', 'needs e' }, { r.q.kind, r.q.gap }, 'an engine gap blocks too')
    eq({ 2, 6 }, { T.derived, T.total }, 'six facts (w has no derivation: it is only NEEDED), two derived')
end)

test('facts compdb-make: a make DRY RUN — the product\'s units only, an include\'s unset variable derived from an ancestor, flags absolute', function ()
    if vim.fn.executable('make') ~= 1 then skip 'no make' end
    local root = vim.fn.tempname()
    write(root, {
        ['top/mk/rules.mk'] = 'X = 1\n',
        ['top/prj/Makefile'] = table.concat({
            'include $(TOPDIR)/mk/rules.mk',
            'all: libp.a tool',
            'libp.a: a.o b.o', '\tar rcs libp.a a.o b.o',
            'tool: tool.o', '\tgcc -o tool tool.o',
            'a.o: a.c', '\tgcc -DA=1 -Iinc -c a.c -o a.o',
            'b.o: b.c', '\tgcc -DB=2 -c -o b.o b.c',
            'tool.o: tool.c', '\tgcc -c tool.c -o tool.o',
        }, '\n') .. '\n',
        ['top/prj/a.c'] = 'int a;\n', ['top/prj/b.c'] = 'int b;\n', ['top/prj/tool.c'] = 'int main(void) { return 0; }\n',
    })
    local d = dofile(vim.api.nvim_get_runtime_file('lua/cartograph/cinterp/facts/compdb-make.lua', false)[1])
    local db, why = d.derive({ src = root .. '/top/prj' })
    ok(db, tostring(why))
    local prj = vim.fs.normalize(vim.fn.fnamemodify(root, ':p')):gsub('/$', '') .. '/top/prj'
    eq(vim.fs.normalize(vim.fn.fnamemodify(root, ':p')):gsub('/$', '') .. '/top', db.env.TOPDIR, 'the ancestor holding mk/rules.mk')
    local files = {}
    for _, u in ipairs(db.units) do files[#files + 1] = vim.fn.fnamemodify(u.file, ':t') end
    eq({ 'a.c', 'b.c' }, files, 'tool.c is the build\'s host tool, not the product')
    eq({ '-DA=1', '-I' .. prj .. '/inc' }, db.units[1].flags)
    eq({ '-DB=2' }, db.units[2].flags)
end)

test('facts compdb-plain: holds only for a tree with NO build description', function ()
    local d = dofile(vim.api.nvim_get_runtime_file('lua/cartograph/cinterp/facts/compdb-plain.lua', false)[1])
    local root = vim.fn.tempname()
    write(root, { ['x.c'] = 'int x;\n' })
    local db = d.derive({ src = root })
    eq(1, db and #db.units)
    write(root, { ['Makefile'] = 'all:\n' })
    local no, why = d.derive({ src = root })
    eq(nil, no)
    ok(why:find('Makefile', 1, true), why)
end)

-- ── THE CACHE (CART-1299): a derive call answered from the content-stamped store ──────────────────────────────────────
local SC = require 'cartograph.stampcache'
local function counted(dir, tree, opts)
    _G.FC = {}
    SC._forget() -- (the stamps are memoized per process: a run is a snapshot; this test edits between runs)
    local T = FT.derive({ src = tree, scope = opts and opts.scope }, { dir = dir, cache = opts and opts.cache })
    local runs = _G.FC
    _G.FC = nil
    return T, runs
end

test('facts cache: a stored value never points into ANOTHER tree — identical content elsewhere gets its OWN paths back (CART-1479)', function ()
    -- the content key is shared by identical trees; a compdb holds absolute paths. Before: tree B was handed tree A's
    -- paths, and with A deleted every derivation compiling a source failed on its cwd (ENOENT) — 15 erlbif tests, red
    -- only when two specs with the same fixture shared a test worker
    local dir, a, b = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
    for _, t in ipairs({ a, b }) do write(t, { ['x.h'] = '#define X 1\n' }) end
    write(dir, {
        ['where.lua'] = "return { fact = 'where', derive = function (t) FC.where = (FC.where or 0) + 1; return { cwd = t.src, file = t.src .. '/x.h', flags = { '-I' .. t.src .. '/inc', '-I' .. t.src .. '0' } } end }",
        ['text.lua'] = "return { fact = 'text', needs = { 'where' }, derive = function (_, got) FC.text = 1; local fd = io.open(got.where.file); local s = fd:read('a'); fd:close(); return s end }",
    })
    local T1 = counted(dir, a)
    eq(2, T1.cache.stored)
    vim.fn.delete(a, 'rf')
    local T2, runs = counted(dir, b)
    local B = vim.fn.fnamemodify(b, ':p'):gsub('/$', '')
    eq({}, runs, 'answered from the store: identical content')
    eq(B, T2.rows.where.value.cwd, 'the stored cwd is THIS tree\'s')
    eq(B .. '/x.h', T2.rows.where.value.file)
    -- (a path INSIDE a flag follows the tree; a SIBLING path `<A>0` is not inside A, so it is left exactly as derived)
    local A = vim.fn.fnamemodify(a, ':p'):gsub('/$', '')
    eq({ '-I' .. B .. '/inc', '-I' .. A .. '0' }, T2.rows.where.value.flags)
    eq('#define X 1\n', T2.rows.text.value)
end)

test('facts cache: a warm derive answers every call from the store, and each INPUT re-derives exactly what it reaches — tree, scope, code, a loaded sibling, a need', function ()
    local dir, tree = vim.fn.tempname(), vim.fn.tempname()
    write(tree, { ['a.h'] = '#define A 1\n', ['other.txt'] = 'x' })
    write(dir, {
        ['a.lua'] = "return { fact = 'a', derive = function (t) FC.a = 1; local fd = io.open(t.src .. '/a.h'); local s = fd:read('a'); fd:close(); return { text = s } end }",
        ['b.lua'] = "return { fact = 'b', needs = { 'a' }, derive = function (_, got) FC.b = 1; return got.a.text:upper() end }",
        ['h.lua'] = "return { fact = 'h', derive = function () FC.h = 1; return dofile(debug.getinfo(1, 'S').source:sub(2):gsub('[^/]+$', '') .. 's.lua').k end }",
        ['s.lua'] = "return { fact = 's', k = 5, derive = function () FC.s = 1; return 's' end }",
    })
    local T, runs = counted(dir, tree)
    eq({ a = 1, b = 1, h = 1, s = 1 }, runs)
    eq({ '#DEFINE A 1\n', 5, 0, 4 }, { T.rows.b.value, T.rows.h.value, T.cache.hits, T.cache.stored })
    T, runs = counted(dir, tree)
    eq({ {}, 4, '#DEFINE A 1\n', true }, { runs, T.cache.hits, T.rows.b.value, T.rows.b.cached }, 'warm: nothing derives, the values are the same')
    write(tree, { ['other.txt'] = 'y' })
    _, runs = counted(dir, tree)
    eq({ a = 1, b = 1, h = 1, s = 1 }, runs, 'ANY tree file is an input (a derivation may read any of them)')
    _, runs = counted(dir, tree, { scope = { '*.h' } })
    eq({ a = 1, b = 1, h = 1, s = 1 }, runs, 'the scope is an input')
    write(dir, { ['b.lua'] = "-- (edited)\nreturn { fact = 'b', needs = { 'a' }, derive = function (_, got) FC.b = 1; return got.a.text:upper() end }" })
    _, runs = counted(dir, tree)
    eq({ b = 1 }, runs, 'an edited derivation re-derives itself only')
    write(dir, { ['s.lua'] = "return { fact = 's', k = 6, derive = function () FC.s = 1; return 's' end }" })
    T, runs = counted(dir, tree)
    eq({ { h = 1, s = 1 }, 6 }, { runs, T.rows.h.value }, 'a sibling a derivation LOADS is its code too')
    write(dir, { ['a.lua'] = "-- (same value)\nreturn { fact = 'a', derive = function (t) FC.a = 1; local fd = io.open(t.src .. '/a.h'); local s = fd:read('a'); fd:close(); return { text = s } end }" })
    _, runs = counted(dir, tree)
    eq({ a = 1 }, runs, 'a need re-derived to the SAME value: its consumer still answers from the store (a need is keyed by its value)')
    write(dir, { ['a.lua'] = "return { fact = 'a', derive = function (t) FC.a = 1; local fd = io.open(t.src .. '/a.h'); local s = fd:read('a'); fd:close(); return { text = s .. '!' } end }" })
    T, runs = counted(dir, tree)
    eq({ { a = 1, b = 1 }, '#DEFINE A 1\n!' }, { runs, T.rows.b.value }, 'a need whose VALUE changed (the tree did not): its consumer re-derives')
    write(tree, { ['a.h'] = '#define A 2\n' })
    T, runs = counted(dir, tree)
    eq({ { a = 1, b = 1, h = 1, s = 1 }, '#DEFINE A 2\n!' }, { runs, T.rows.b.value })
    T, runs = counted(dir, tree, { cache = false })
    eq({ { a = 1, b = 1, h = 1, s = 1 }, nil }, { runs, T.cache }, 'cache = false derives everything')
end)

test('facts cache: what is NEVER stored — a gap, a raise, a value that is more than data, a derivation reading a fact it does not declare', function ()
    local dir, tree = vim.fn.tempname(), vim.fn.tempname()
    write(tree, { ['x'] = '1' })
    write(dir, {
        ['a.lua'] = "return { fact = 'a', derive = function () FC.a = 1; return 1 end }",
        ['g.lua'] = "return { fact = 'g', derive = function () FC.g = 1; return nil, 'no evidence' end }",
        ['r.lua'] = "return { fact = 'r', derive = function () FC.r = 1; error('boom') end }",
        ['f.lua'] = "return { fact = 'f', derive = function () FC.f = 1; return { lookup = function () end } end }",
        ['m.lua'] = "return { fact = 'm', derive = function () FC.m = 1; return setmetatable({}, { __index = {} }) end }",
        ['u.lua'] = "return { fact = 'u', needs = { 'g2' }, derive = function (_, got) FC.u = 1; return (got.a or 0) + got.g2 end }",
        ['v.lua'] = "return { fact = 'g2', derive = function () FC.v = 1; return 2 end }",
    })
    local T, runs = counted(dir, tree)
    eq({ a = 1, g = 1, r = 1, f = 1, m = 1, u = 1, v = 1 }, runs)
    eq(3, T.rows.u.value, 'the stray read still sees the fact')
    local refused = T.cache.refused
    eq({ 'a function', 'a table with a metatable' }, { refused.f, refused.m })
    ok((refused.u or ''):find('got.a', 1, true), tostring(refused.u))
    T, runs = counted(dir, tree)
    eq({ g = 1, r = 1, f = 1, m = 1, u = 1 }, runs, 'only a and g2 came from the store')
    eq({ 'adapter', 'error' }, { T.rows.g.kind, T.rows.r.kind })
end)

test('facts cache: a derivation that CHANGES its need (numbers-tvis adds variants to reps.tag) is never stored — re-run, its change re-applied, the need re-keyed for the facts after it', function ()
    local dir, tree = vim.fn.tempname(), vim.fn.tempname()
    write(tree, { ['x'] = '1' })
    local function n(x) return "return { fact = 'n', needs = { 'r' }, derive = function (_, got) FC.n = 1; got.r.tag.v = " .. x .. "; return 'n' end }" end
    write(dir, {
        ['a.lua'] = "return { fact = 'r', derive = function () FC.r = 1; return { tag = { base = 0 } } end }",
        ['n.lua'] = n(1),
        ['z.lua'] = "return { fact = 'c', needs = { 'r' }, derive = function (_, got) FC.c = 1; return got.r.tag.v or 'no variant' end }",
    })
    local T, runs = counted(dir, tree)
    eq({ { r = 1, n = 1, c = 1 }, 1 }, { runs, T.rows.c.value })
    ok((T.cache.refused.n or ''):find('changes its need r', 1, true), tostring(T.cache.refused.n))
    T, runs = counted(dir, tree)
    eq({ { n = 1 }, 1, 1 }, { runs, T.got.r.tag.v, T.rows.c.value }, 'warm: r and c from the store, n re-run — its variant is back in r')
    write(dir, { ['n.lua'] = n(2) })
    T, runs = counted(dir, tree)
    eq({ { n = 1, c = 1 }, 2 }, { runs, T.rows.c.value }, 'the change is part of r for c: c, needing only r, re-derives')
end)
