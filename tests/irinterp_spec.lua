-- cartograph.ir + cartograph.irinterp (CART-1259): an abstract interpreter over LLVM IR — C and C++ lowered by clang,
-- read with their semantics resolved by the compiler. Each fixture is compiled here (`clang -S -emit-llvm -O0`).
local IR = require 'cartograph.ir'
local II = require 'cartograph.irinterp'

local function ready() return vim.fn.executable('clang') == 1 and vim.fn.executable('clang++') == 1 end

local function compile(text, cpp)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local src = dir .. (cpp and '/t.cpp' or '/t.c')
    local fd = assert(io.open(src, 'w')); fd:write(text); fd:close()
    local r = vim.system({ cpp and 'clang++' or 'clang', '-S', '-emit-llvm', '-O0', '-o', dir .. '/t.ll', src }):wait()
    assert(r.code == 0, r.stderr)
    local mod = IR.read(dir .. '/t.ll')
    return II.analyzer({ mod = mod, fn = function (n) return mod:fn(n), mod end }), mod
end
local function rets(r)
    local l = {}
    for _, x in ipairs(r.returns) do for e in pairs(x.fset) do l[#l + 1] = e .. '=' .. II.key_of(II.at(x.v, e)) end end
    table.sort(l)
    -- (one element's equal returns once)
    local u, last = {}, nil
    for _, s in ipairs(l) do if s ~= last then u[#u + 1] = s end last = s end
    return table.concat(u, ' ')
end

test('irinterp: C — arithmetic, a struct returned by value, a call through a function pointer, a loop of known count', function ()
    if not ready() then skip 'no clang' end
    local A = compile([[
struct pt { int x; long y; };
int add(int a, int b) { return a + b; }
int sum(int n) { int s = 0; for (int i = 0; i < n; i++) s += i; return s; }
static struct pt mk(int a) { struct pt r; r.x = a; r.y = a * 2; return r; }
long usept(int a) { struct pt q = mk(a); return q.x + q.y; }
static int sq(int v) { return v * v; }
int viafp(int a) { int (*f)(int) = sq; return f(a); }
]])
    eq({ 'X=i42:32', 'X=i10:32', 'X=i21:64', 'X=i81:32' }, {
        rets(A.run('@add', { II.int(2, 32), II.int(40, 32) }, { X = true })), rets(A.run('@sum', { II.int(5, 32) }, { X = true })),
        rets(A.run('@usept', { II.int(7, 32) }, { X = true })), rets(A.run('@viafp', { II.int(9, 32) }, { X = true })) })
    local r = A.run('@sum', { nil }, { X = true })
    eq({ false, true }, { r.over, #r.returns > 0 }, 'an unknown bound: the loop head WIDENS and the run ends')
end)

test('irinterp: a value in memory that differs per ELEMENT partitions the branch; an unknown one takes both', function ()
    if not ready() then skip 'no clang' end
    local A = compile('int pos(int *p) { if (*p > 0) return 1; return 0; }\n')
    local mem = { arg = { cells = { [0] = { n = 4, v = { k = 'vec', by = { ['P@1'] = II.int(5, 32), ['Z@1'] = II.int(0, 32), ['N@1'] = II.int(-3, 32) } } } } } }
    eq('N@1=i0:32 P@1=i1:32 U@1=i0:32 U@1=i1:32 Z@1=i0:32', rets(A.run('@pos', { { k = 'p', r = 'arg', o = 0 } }, { ['P@1'] = true, ['Z@1'] = true, ['N@1'] = true, ['U@1'] = true }, mem)))
end)

test('irinterp: C++ — a class template\'s method, a struct with a count and an array read past its count', function ()
    if not ready() then skip 'no clang' end
    local A = compile([[
template <class T> struct Box { T v; T get() const { return v; } bool big() const { return v > 10; } };
struct Args { int argc; long *argv; long get(int i) const { return i < argc ? argv[i] : -1; } };
extern "C" int boxed(int a) { Box<int> b{a}; return b.big() ? b.get() : 0; }
extern "C" long nth(int argc, long *argv) { Args a{argc, argv}; return a.get(1); }
]], true)
    eq('L@1=i30:32 S@1=i0:32', rets(A.run('@boxed', { { k = 'vec', by = { ['S@1'] = II.int(3, 32), ['L@1'] = II.int(30, 32) } } }, { ['S@1'] = true, ['L@1'] = true })))
    local am = { argv = { cells = { [0] = { n = 8, v = II.int(100, 64) }, [8] = { n = 8, v = II.int(200, 64) } } } }
    eq('A@1=i18446744073709551615:64 A@2=i200:64', rets(A.run('@nth', { { k = 'vec', by = { ['A@1'] = II.int(1, 32), ['A@2'] = II.int(2, 32) } }, { k = 'p', r = 'argv', o = 0 } }, { ['A@1'] = true, ['A@2'] = true }, am)),
        'past the count: -1; within it: the array')
end)

test('ir: layout from the IR\'s own types — natural alignment, a packed struct none', function ()
    local mod = IR.read({ text = '%s = type { i8, i64, i32 }\n%p = type <{ i8, i64 }>\n' })
    eq({ 24, 9, 8 }, { IR.size(mod, { k = 'n', name = '%s' }), IR.size(mod, { k = 'n', name = '%p' }), (IR.field_offset(mod, { k = 'n', name = '%s' }, 2)) })
end)
