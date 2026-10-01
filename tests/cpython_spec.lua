-- cartograph.cpython (CART-1258): the facts of a CPython-shaped tree that need no running runtime — the fast-call frame
-- from an UNNAMED function type, a POINTER slot, NULL as the sentinel and the error helpers its throwers, PyMethodDef
-- rows with their METH_ flags and owner — and the representatives' honest GAP when no library is built. And the
-- compdb dry run on a BUILT make tree: what-if, never `-B` (which re-ran CPython's configure: CART-1263).
local FT = require 'cartograph.cinterp.facts'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local cached
local function facts()
    if cached then return cached end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(dofile(vim.fn.getcwd() .. '/tests/fixtures/cinterp/cpython.lua')) do
        local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close()
    end
    cached = FT.derive({ src = dir })
    return cached
end

test('cpython: the fast-call frame from an unnamed function type, a pointer slot, NULL and its throwers', function ()
    if not ready() then skip 'no C parser / gcc' end
    local g = facts().got
    eq({ 'array', 2, 3, 'PyObject *' }, { g.frame.kind, g.frame.arrayat, g.frame.countat, g.frame.slot }, '_PyCFunctionFast: the array at 2, the count at 3')
    eq({ 'PyObject *', true, '' }, { g.slot.type, g.layout.layout.scalar, (next(g.layout.layout.fields)) }, 'the slot a pointer word, read whole')
    eq({ 'sentinel', true, nil }, { g.result.kind, g.result.throwers.PyErr_Format, g.result.throwers._PyErr_SetRaisedException }, 'the NULL-returning helper is a thrower, the void store is not')
end)

test('cpython: PyMethodDef rows — the function through a cast macro, the METH_ flags named, the owner the module\'s name', function ()
    if not ready() then skip 'no C parser / gcc' end
    local R = facts().got.registrations
    local by = {}
    for _, e in ipairs(R.funcs) do by[e.owner .. '.' .. e.name] = e end
    eq({ 'builtin_len', true, 'builtin_hasattr', true }, { by['builtins.len'].cfn, by['builtins.len'].meth.O, by['builtins.hasattr'].cfn, by['builtins.hasattr'].meth.FASTCALL })
    local r = facts().rows.reps
    eq({ 'adapter', true }, { r.kind, (r.tried['reps-pylinked'] or ''):find('no static library', 1, true) ~= nil }, 'no library built: the linked probe is a gap, named')
end)

test('compdb-make on a BUILT tree: what-if every source were new — never -B, which remakes a makefile even under -n', function ()
    if vim.fn.executable('make') ~= 1 or vim.fn.executable('gcc') ~= 1 then skip 'no make / gcc' end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function w(name, text) local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    w('a.c', 'int a(void) { return 1; }\n')
    w('b.c', 'int b(void) { return 2; }\n')
    w('Makefile.in', 'x\n')
    -- (a makefile REMADE with $(MAKE) on the recipe line: under -n make still runs that line — the marker shows it)
    -- (and a GENERATED source made from it — CPython's Modules/config.c from Makefile.pre: `-B` remakes it even with the
    -- makefile held old)
    w('Makefile', 'all: libx.a\nlibx.a: a.o b.o gen.o\n\tar rcs libx.a a.o b.o gen.o\na.o: a.c\n\tgcc -c -DA=1 -o a.o a.c\nb.o: b.c\n\tgcc -c -o b.o b.c\n'
        .. 'gen.o: gen.c\n\tgcc -c -o gen.o gen.c\ngen.c: Makefile.in\n\ttouch REMADE; echo "int g(void) { return 3; }" > gen.c; $(MAKE) -q -f /dev/null || true\n'
        .. 'Makefile: Makefile.in\n\ttouch REMADE; $(MAKE) -f Makefile.in || true\n')
    assert(vim.system({ 'make' }, { cwd = dir }):wait().code == 0)
    os.remove(dir .. '/REMADE') -- (the real build made gen.c through that recipe)
    vim.uv.sleep(1100)
    w('Makefile.in', 'y\n') -- (now the makefile is OUT OF DATE)
    local d = dofile(vim.fn.getcwd() .. '/lua/cartograph/cinterp/facts/compdb-make.lua')
    local db = d.derive({ src = dir }, {})
    local files = {}
    for _, u in ipairs(db and db.units or {}) do files[#files + 1] = vim.fn.fnamemodify(u.file, ':t') end
    table.sort(files)
    eq({ 'a.c', 'b.c', 'gen.c' }, files, 'the built product\'s units')
    eq(nil, vim.uv.fs_stat(dir .. '/REMADE'), 'no makefile was remade')
end)
