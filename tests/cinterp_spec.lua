-- cartograph.cinterp — the engine itself, on C text alone (no facts runner, no compiler): what one construct evaluates to.
local CI = require 'cartograph.cinterp'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') end

local function engine(src)
    local u = CI.units({ { name = 'x.c', text = src } })
    u.layout = { fields = {} }; u.reps = { tag = {} }; u.noret = {}; u.frame = {}; u.sentinels = {}; u.builtins = {}
    local A = CI.analyzer(u)
    return u, function (f, args)
        local s = A.run(u.defs[f], args, {}, 1, { ['X@0'] = true }, false)
        local l = {}
        for _, r in ipairs(s.returns) do l[#l + 1] = CI.key_of(CI.at(r.v, 'X@0')) end
        table.sort(l)
        return table.concat(l, ' | ')
    end
end

test('cinterp: an AGGREGATE by value — a compound literal, nested and designated, its field read back, a join that keeps the fields both sides agree on', function ()
    if not ready() then skip 'no C parser' end
    local u, ret = engine([[
typedef union JSValueUnion { int int32; double float64; void *ptr; } JSValueUnion;
typedef struct JSValue { JSValueUnion u; long tag; } JSValue;
JSValue mk(int t, int v) { return (JSValue){ (JSValueUnion){ .int32 = v }, t }; }
JSValue pick(int c, int v) { if (c) return mk(6, 0); return mk(0, v); }
int tagof(int c, int v) { JSValue x = pick(c, v); return (int)x.tag; }
JSValue retag(int v) { JSValue x = mk(1, v); x.tag = 7; return x; }
JSValue br(int c, int v) { JSValue x; if (c) x = mk(6, 0); else x = mk(6, v); return x; }
]])
    eq({ 'u', 'tag' }, vim.tbl_map(function (x) return x.name end, u.aggregates.JSValue.fields), 'the members in declaration order')
    eq('gJSValue{tag=i6LL:32s;u.int32=i0LL:32s}', ret('mk', { CI._int(6), CI._int(0), n = 2 }), 'positional, then a nested designated member flattened to its path')
    eq('gJSValue{tag=i0LL:32s} | gJSValue{tag=i6LL:32s;u.int32=i0LL:32s}', ret('pick', { nil, nil, n = 2 }), 'an unknown member is left out, the known ones survive')
    eq({ 'i6LL:32s', 'i0LL:32s' }, { ret('tagof', { CI._int(1), CI._int(5), n = 2 }), ret('tagof', { CI._int(0), nil, n = 2 }) }, 'a field read of a local aggregate')
    eq('gJSValue{tag=i7LL:32s;u.int32=i3LL:32s}', ret('retag', { CI._int(3), n = 1 }), 'a field write is a functional update')
    eq('gJSValue{tag=i6LL:32s}', ret('br', { nil, nil, n = 2 }), 'two paths JOINED: the member they agree on kept, the other dropped')
end)

test('cinterp: an OUT-PARAMETER — `&local` handed to a callee that writes `*p` — is the callee\'s value after the call', function ()
    if not ready() then skip 'no C parser' end
    local _, ret = engine([[
int set(int *p, int v) { *p = v; return 0; }
int keep(int *p) { return *p; }
int outp(int c) { int x = 1; set(&x, 7); return x; }
int inp(int c) { int x = 3; return keep(&x); }
]])
    eq({ 'i7LL:32s', 'i3LL:32s' }, { ret('outp', { CI._int(0), n = 1 }), ret('inp', { CI._int(0), n = 1 }) }, 'written back; read through the cell')
end)

test('cinterp: `(v) && (x)` with v a VARIABLE is not a cast (tree-sitter reads one) — the unit is re-parenthesized', function ()
    if not ready() then skip 'no C parser' end
    local u, ret = engine([[
typedef long ssz;
int mis(int n) { if ((n) && (n) > 1) return 1; return 0; }
long cast(int n) { return (ssz)(n) + 1; }
]])
    eq({ 'i1LL:32s', 'i0LL:32s', 'i0LL:32s' }, { ret('mis', { CI._int(2), n = 1 }), ret('mis', { CI._int(1), n = 1 }), ret('mis', { CI._int(0), n = 1 }) })
    eq('i5LL:64s', ret('cast', { CI._int(4), n = 1 }), 'a cast to a typedef stays a cast')
    eq(true, u.typenames.ssz, 'every typedef name is a type name')
end)

test('cinterp: a word handed to a POINTER parameter is an address; a pointer member\'s pointee is its DECLARED type; &global is the runtime\'s', function ()
    if not ready() then skip 'no C parser' end
    local u = CI.units({ { name = 'x.c', text = [[
struct _m { long f; };
typedef struct _t { long flags; struct _m *m; } Ty;
typedef struct _o { Ty *type; } Ob;
extern Ty TT;
int chk(Ob *o) { return o->type->m->f == 5; }
int ist(Ob *o) { return o->type == &TT; }
]] } })
    local ffi = require 'ffi'
    local function I(n) return ffi.cast('int64_t', n) end
    u.layout = { fields = {} }; u.reps = { tag = {} }; u.noret = {}; u.frame = {}; u.sentinels = {}; u.builtins = {}
    -- (the oracle answers only "a pointer" for a pointer member, as the compiler's layout does)
    local OFF = { ['Ob\0type'] = 0, ['Ty\0flags'] = 0, ['Ty\0m'] = 8, ['struct _m\0f'] = 0 }
    u.layout_of = function (_, T, path)
        local off = OFF[T .. '\0' .. path]
        if not off then return nil end
        return { off = off, to = (path == 'f' or path == 'flags') and { k = 'i', w = 64, u = false } or { k = 'p' } }
    end
    u.memory = { [tostring(I(0x1000))] = '0000000000002000', [tostring(I(0x2008))] = '0000000000003000', [tostring(I(0x3000))] = '0000000000000005' }
    u.symaddr = { TT = { v = I(0x2000), type = 'Ty' } }
    local A = CI.analyzer(u)
    local function ret(f) local s = A.run(u.defs[f], { CI._int(0x1000, 64, true), n = 1 }, {}, 1, { ['X@0'] = true }, false, true, true); return CI.key_of(CI.at(s.returns[1].v, 'X@0')) end
    eq(true, CI.field_pointee(u, 'Ob', 'type') ~= nil, 'Ob.type points to Ty')
    eq({ 'i1LL:32s', 'i1LL:32s' }, { ret('chk'), ret('ist') }, 'o->type->m->f read through the memory; o->type compared with &TT')
end)

test('cinterp: a recursion whose argument changes every level is BOUNDED — an unknown call past the depth, not a stack overflow', function ()
    if not ready() then skip 'no C parser' end
    local _, ret = engine([[
int down(int n) { if (n == 0) return 0; return down(n - 1); }
int shallow(int c) { return down(3); }
int deep(int c) { return down(100000); }
]])
    eq('i0LL:32s', ret('shallow', { CI._int(0), n = 1 }), 'within the bound: exact')
    eq('?', ret('deep', { CI._int(0), n = 1 }), 'past it: unknown')
end)

test('cinterp: a PARENTHESIZED assignment target — a macro\'s `(ival) >>= SHIFT`, `++(n)` — is its inside', function ()
    if not ready() then skip 'no C parser' end
    local _, ret = engine([[
int digits(unsigned long x) { int n = 0; while ((x)) { (x) >>= 4; ++(n); } return n; }
]])
    eq('i3LL:32s', ret('digits', { CI._int(0x100, 64, true), n = 1 }), '0x100: three hex digits — the loop ends')
end)

-- (CART-1285..1289, found by CART-1284's Datalog join and arbitrated by the C compiler where values differ)
test('cinterp: C\'s integer types in ANY specifier order (cpp\'s own `long unsigned int` size_t) — CART-1285', function ()
    eq({ k = 'i', w = 64, u = true }, CI.ctype('long unsigned int', {}), 'cpp spells size_t this way')
    eq({ k = 'i', w = 16, u = true }, CI.ctype('short unsigned int', {}))
    eq({ k = 'i', w = 64, u = false }, CI.ctype('int long', {}))
    eq({ k = 'i', w = 64, u = true }, CI.ctype('long long unsigned int', {}))
    eq(nil, CI.ctype('long double', {}), 'not every word is an integer specifier: no type')
    eq(nil, CI.ctype('signed unsigned', {}), 'contradictory specifiers: no type')
end)

test('cinterp: integer constants EXACT past 2^53 (no double), C 6.4.4.1 types, a tree-sitter `-1` negated — CART-1286', function ()
    eq('i-49064778989728563LL:64u', CI.key_of(CI._literal('0xFF51AFD7ED558CCDull')), 'the murmur constant: every bit')
    eq('i-72057594037927936LL:64u', CI.key_of(CI._literal('0xff00000000000000ULL')))
    eq('i9007199254740991LL:64u', CI.key_of(CI._literal('0x001fffffffffffffULL')), '2^53-1 was exact before too')
    eq('i2147483648LL:32u', CI.key_of(CI._literal('0x80000000')), 'a hex constant past INT_MAX is unsigned int')
    eq('i-1LL:32s', CI.key_of(CI._literal('-1')), 'tree-sitter reads -1 as one literal: the magnitude negated')
    eq('i-2147483648LL:64s', CI.key_of(CI._literal('-2147483648')), '2147483648 does not fit int: long, then negated')
end)

test('cinterp: character constants with ESCAPES are values; a plain char is signed — CART-1287', function ()
    eq('i10LL:32s', CI.key_of(CI._charlit([['\n']])))
    eq('i0LL:32s', CI.key_of(CI._charlit([['\0']])))
    eq('i92LL:32s', CI.key_of(CI._charlit([['\\']])))
    eq('i65LL:32s', CI.key_of(CI._charlit([['\x41']])))
    eq('i-1LL:32s', CI.key_of(CI._charlit([['\xff']])), 'plain char is signed here')
    eq('?', CI.key_of(CI._charlit([['ab']])), 'a multi-character constant is not read')
    if not ready() then skip 'no C parser' end
    local _, ret = engine([[int nl(int c) { return c == '\n'; }]])
    eq({ 'i1LL:32s', 'i0LL:32s' }, { ret('nl', { CI._int(10), n = 1 }), ret('nl', { CI._int(32), n = 1 }) }, 'the escape read by eval itself')
end)

test('cinterp: ?: takes the common type of both arms; return converts to the return type; x++ stays in x\'s type — CART-1288/1289', function ()
    if not ready() then skip 'no C parser' end
    local _, ret = engine([[
typedef unsigned char u8;
typedef unsigned long u64;
int up(u8 c) { return (c >= 'a' && c <= 'z') ? c - 'a' + 'A' : c; }
u64 clamp(u64 r, u64 m) { return r > m ? 0 : r; }
u8 narrow(int x) { return x; }
int wrap8(int c) { u8 b = 255; b++; return b; }
]])
    eq('i66LL:32s', ret('up', { CI._int(66, 8, true), n = 1 }), 'the arm not taken still types the result: int, not u8')
    eq('i0LL:64u', ret('clamp', { CI._int(9, 64, true), CI._int(3, 64, true), n = 2 }), 'the literal 0 arm is u64')
    eq('i44LL:8u', ret('narrow', { CI._int(300), n = 1 }), '300 returned as u8 is 44')
    eq('i0LL:32s', ret('wrap8', { CI._int(0), n = 1 }), 'u8 255 incremented wraps to 0 in u8')
    -- (the case only ?: decides — the return conversion cannot mask it: an UNDECIDED condition over two arms equal in
    -- value and different in type is that value, because both arms convert to the common type first)
    local _, ret2 = engine([[int same(int b) { return b ? (unsigned char)5 : 5; }]])
    eq('i5LL:32s', ret2('same', { nil, n = 1 }), 'b unknown: both arms are int 5')
end)

test('cinterp: a DOUBLE is its bits — a call\'s memo tells 1.5 from -1.5, a signed zero survives a call, +0 and -0 do not join into one (CART-1322 follow-up)', function ()
    if not ready() then skip 'no C parser' end
    local _, ret = engine([[
static int sgn(double x) { return x < 0 ? -1 : 1; }
int both(int c) { return sgn(1.5) * 10 + sgn(-1.5); }
static int pos(double x) { return 1.0 / x > 0; }
int zeros(int c) { return pos(0.0) * 10 + pos(-0.0); }
int joined(int c) { double r = c ? 0.0 : -0.0; return 1.0 / r > 0; }
int nan_self(int c) { double n = 0.0 / 0.0; return (n == n) * 10 + (n != n); }
]])
    eq('i9LL:32s', ret('both', { CI._int(0), n = 1 }), 'two calls with different doubles are two summaries')
    eq('i10LL:32s', ret('zeros', { CI._int(0), n = 1 }), '1/+0 > 0, 1/-0 < 0: the sign reaches the callee')
    eq({ 'i1LL:32s', 'i0LL:32s', '?' }, { ret('joined', { CI._int(1), n = 1 }), ret('joined', { CI._int(0), n = 1 }), ret('joined', { n = 1 }) },
        'an unknown condition over +0 / -0 is an unknown sign, not one of them')
    eq('i1LL:32s', ret('nan_self', { CI._int(0), n = 1 }), 'NaN is not equal to itself (C), whatever the key says')
end)
