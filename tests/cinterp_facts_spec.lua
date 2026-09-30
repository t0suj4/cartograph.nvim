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
