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
