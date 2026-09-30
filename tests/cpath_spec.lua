-- cartograph.luajs.cpath (CART-1240 leaf 2) on a FIXTURE tree shaped like LuaJIT's: its own tags, setters and tvis*
-- predicates (the representatives come from the compiler), a checker that jumps into its raise, an optionality one of
-- its parameters turns, a value callee (lua_type's shape), a count-dispatched body, a slot WRITE, a loop over the
-- arguments — each rule of the path reading pinned, none of it knowing a checker's name.
local P = require 'cartograph.luajs.cpath'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local FILES = {
    ['lua.h'] = '#define LUA_TNONE (-1)\n#define LUA_TNIL 0\n#define LUA_TBOOLEAN 1\n#define LUA_TNUMBER 3\n#define LUA_TSTRING 4\n#define LUA_TTABLE 5\n',
    ['lj_def.h'] = '#define LJ_NORET __attribute__((noreturn))\n#define LJ_FUNC_NORET extern LJ_NORET\n',
    ['lj_lib.h'] = '#define FFH_RETRY 0\n#define FFH_RES(n) ((n)+1)\n',
    ['lj_obj.h'] = table.concat({
        '#include <stdint.h>',
        '#include "lj_def.h"',
        '#include "lua.h"',
        'typedef union TValue { uint64_t u64; double n; int64_t it64; struct { uint32_t lo; uint32_t it; }; } TValue;',
        'typedef struct MRef { uint64_t ptr64; } MRef;',
        '#define mref(r, t) ((t *)(void *)(r).ptr64)',
        '#define setmref(r, p) ((r).ptr64 = (uint64_t)(void *)(p))',
        'typedef struct lua_State { TValue *base, *top; MRef stack; } lua_State;',
        '#define LJ_TNIL (~0u)',
        '#define LJ_TFALSE (~1u)',
        '#define LJ_TTRUE (~2u)',
        '#define LJ_TSTR (~4u)',
        '#define LJ_TTAB (~11u)',
        '#define LJ_TNUMX (~13u)',
        '#define LJ_TISNUM LJ_TNUMX',
        '#define LJ_TISPRI LJ_TTRUE',
        '#define itype(o) ((uint32_t)((o)->it64 >> 47))',
        '#define setpriV(o, x) ((o)->it64 = (int64_t)~((uint64_t)~(x)<<47))',
        '#define setnumV(o, x) ((o)->n = (x))',
        'static inline void setgcVraw(TValue *o, void *v, uint32_t it) { o->u64 = ((uint64_t)(uintptr_t)v & (((uint64_t)1 << 47) - 1)) | ((uint64_t)it << 47); }',
        'typedef void GCobj;',
        '#define tvisnil(o) ((o)->it64 == -1)',
        '#define tvisstr(o) (itype(o) == LJ_TSTR)',
        '#define tvistab(o) (itype(o) == LJ_TTAB)',
        '#define tvisnumber(o) (itype(o) <= LJ_TISNUM)',
        'LJ_FUNC_NORET void lj_err_argt(lua_State *L, int narg, int tt);',
    }, '\n') .. '\n',
    ['lj_obj.c'] = table.concat({
        '#include "lj_obj.h"',
        'const char *const lj_obj_itypename[] = {',
        '  "nil", "boolean", "boolean", "userdata", "string", "upval", "thread",',
        '  "proto", "function", "trace", "cdata", "table", "userdata", "number"',
        '};',
    }, '\n') .. '\n',
    ['lib_x.c'] = table.concat({
        '#include "lj_obj.h"',
        'double x_checknum(lua_State *L, int narg)',
        '{',
        '  TValue *o = L->base + narg-1;',
        '  if (o >= L->top) goto bad;',
        '  if (tvisnumber(o)) return o->n;',
        'bad:',
        '  lj_err_argt(L, narg, LUA_TNUMBER);',
        '  return 0;',
        '}',
        'double x_opt(lua_State *L, int narg, int def)',
        '{',
        '  TValue *o = L->base + narg-1;',
        '  if (o >= L->top && def >= 0) return def;',
        '  return x_checknum(L, narg);',
        '}',
        'static int x_type(lua_State *L, int idx)',
        '{',
        '  TValue *o = L->base + idx - 1;',
        '  if (o >= L->top) return LUA_TNONE;',
        '  if (tvistab(o)) return LUA_TTABLE;',
        '  return LUA_TBOOLEAN;',
        '}',
        'int lj_cf_x_istable(lua_State *L) { if (x_type(L, 1) != LUA_TTABLE) lj_err_argt(L, 1, LUA_TTABLE); return 1; }',
        'int lj_cf_x_disp(lua_State *L) { int n = (int)(L->top - L->base); if (n == 2) x_checknum(L, 2); return 1; }',
        'int lj_cf_x_write(lua_State *L) { TValue *o = L->base; setnumV(o, 1.0); if (!tvisnumber(o)) lj_err_argt(L, 1, LUA_TNUMBER); return 1; }',
        'int lj_cf_x_sum(lua_State *L) { int i, n = (int)(L->top - L->base); for (i = 1; i <= n; i++) x_checknum(L, i); return 1; }',
        'static int x_isnum(lua_State *L, int narg) { return tvisnumber(L->base + narg - 1); }',
        'int lj_cf_x_ab(lua_State *L) { int a = x_isnum(L, 1); if (!x_isnum(L, 2)) lj_err_argt(L, 2, LUA_TNUMBER); return a; }',
        'int lj_cf_x_wait(lua_State *L) { while (tvisnil(L->base + 1)) { } x_checknum(L, 1); return 1; }',
        'int lj_cf_x_late(lua_State *L) { if (tvisstr(L->base)) goto ok; return 0; ok: return 7; }',
        -- (the stack MOVES: lua_settop's fill loop steps L->top; a reallocation rebases every stack pointer)
        'static void x_settop(lua_State *L, int n) { TValue *t = L->base + n; while (L->top < t) setpriV(L->top++, LJ_TNIL); L->top = t; }',
        'int lj_cf_x_pad(lua_State *L) { x_settop(L, 2); if (!tvisnil(L->base + 1)) x_checknum(L, 2); return 1; }',
        'void *x_realloc(void *p);',
        'static void x_grow(lua_State *L)',
        '{',
        '  TValue *st, *oldst = mref(L->stack, TValue);',
        '  long delta;',
        '  st = (TValue *)x_realloc(oldst);',
        '  setmref(L->stack, st);',
        '  delta = (char *)st - (char *)oldst;',
        '  L->base = (TValue *)((char *)L->base + delta);',
        '  L->top = (TValue *)((char *)L->top + delta);',
        '}',
        'int lj_cf_x_grow(lua_State *L) { x_grow(L); x_checknum(L, 1); return 1; }',
        'static void x_rec(lua_State *L, int n) { if (tvisstr(L->base)) x_rec(L, n); if (n > 5) L->top = L->base; }',
        'int lj_cf_x_rec(lua_State *L) { x_rec(L, 1); x_checknum(L, 1); return 1; }',
        'lua_State *x_mainthread(void);',
        'static void x_other(lua_State *co, lua_State *L) { co->top = co->base; }',
        'int lj_cf_x_fin(lua_State *L) { x_other(x_mainthread(), L); x_checknum(L, 1); return 1; }',
        'static int x_fact(int n) { return n <= 1 ? 1 : n * x_fact(n - 1); }',
        'int lj_cf_x_sw(lua_State *L) { switch (x_type(L, 1)) { case LUA_TTABLE: return 1; case LUA_TNONE: break; default: lj_err_argt(L, 1, LUA_TTABLE); } return 0; }',
        'int lj_cf_x_count(lua_State *L) { int i = 0; while (tvisnil(L->base + 1)) i++; x_checknum(L, 1); return i; }',
        'int lj_cf_x_spin(lua_State *L) { int i = 0; while (++i && tvisnil(L->base + 1)) { } x_checknum(L, 1); return i; }',
        'void x_note(void);',
        'int lj_cf_x_sum2(lua_State *L) { int i, n = (int)(L->top - L->base); for (i = 1; i <= n; i++) { if (tvisnil(L->base + i - 1)) x_note(); x_checknum(L, i); } return 1; }',
        'TValue *x_ptr(void);',
        'int lj_cf_x_lose(lua_State *L) { L->top = x_ptr(); x_checknum(L, 1); return 1; }',
    }, '\n') .. '\n',
}

local cached
local function setup()
    if cached then return cached end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(FILES) do local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    local ctx = P.context(dir, {})
    local tn = P.typenames(dir, ctx.reps)
    for name, n in pairs(ctx.numof) do tn[name] = tn[n] end
    cached = { dir = dir, ctx = ctx, tn = tn }
    return cached
end
local function read(fn, args, pos)
    local c = setup()
    local A = P.analyzer(c.ctx)
    local acc, _, rets = P.acceptance(A, c.ctx, c.ctx.defs[fn], args, pos, pos + 2)
    return P.reading(acc, c.tn), acc, rets
end
local L = { k = 'L' }

test('cpath premises: the representatives are the compiler\'s, built with the tree\'s own setters; its predicates over them are exact', function ()
    if not ready() then skip 'no C parser / gcc' end
    local R = setup().ctx.reps
    eq({ 1, 0, 0 }, { R.matrix.tvisnumber.NUMX, R.matrix.tvisnumber.STR, R.matrix.tvisnumber.NIL })
    eq({ 1, 0 }, { R.matrix.tvisnil.NIL, R.matrix.tvisnil.FALSE }, 'nil is it64 == -1: its setter, not a tag word')
    eq({ 1, 0 }, { R.matrix.tvisstr.STR, R.matrix.tvisstr.TAB })
end)

test('cpath: a checker that JUMPS into its raise accepts exactly its type; a no-return raiser rejects the path; absence rejects', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r, acc = read('x_checknum', { L, P._int(1), n = 2 }, 1)
    eq({ 'number' }, r.accepted)
    eq({ 'never', 'never' }, { acc.STR, acc.ABSENT })
end)

test('cpath: an optionality one of its OWN parameters turns — required at def = -1, optional at def = 1 (the call site decides)', function ()
    if not ready() then skip 'no C parser / gcc' end
    local _, a1 = read('x_opt', { L, P._int(1), P._int(-1), n = 3 }, 1)
    local _, a2 = read('x_opt', { L, P._int(1), P._int(1), n = 3 }, 1)
    eq({ 'never', 'always' }, { a1.ABSENT, a2.ABSENT })
end)

test('cpath: a VALUE callee (lua_type\'s shape) decides by its return: only a table passes', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r = read('lj_cf_x_istable', { L, n = 1 }, 1)
    eq({ 'table' }, r.accepted)
end)

test('cpath: the argument COUNT is concrete — a count-dispatched check binds only at its count; a loop over the arguments is RUN', function ()
    if not ready() then skip 'no C parser / gcc' end
    local _, d = read('lj_cf_x_disp', { L, n = 1 }, 2)
    eq({ 'always', 'content', 'always' }, { d.NUMX, d.STR, d.ABSENT }, 'n == 2 checks, n == 3 does not')
    local r, s, rets = read('lj_cf_x_sum', { L, n = 1 }, 3)
    -- (absent may REJECT too: the loop still checks arguments 1 and 2, unknown here — what makes it optional is that
    -- it may RETURN)
    eq({ { 'number' }, 'never' }, { r.accepted, s.STR })
    ok(s.ABSENT ~= 'never', 'a missing third argument is not an error: ' .. tostring(s.ABSENT))
    ok(#rets > 0 and rets[1].v == 1, 'its result count: the literal return')
    eq({ offset = 1, retry = 0 }, P.result_rule(setup().dir), 'FFH_RES / FFH_RETRY from lj_lib.h')
end)

test('cpath: a callee\'s summary is keyed by its ARGUMENTS — isnum(L, 1) and isnum(L, 2) on the same path (a predicate: it narrows nothing) are two facts', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r = read('lj_cf_x_ab', { L, n = 1 }, 2)
    eq({ 'number' }, r.accepted, 'reusing isnum(L, 1)\'s summary would never test the second argument')
end)

test('cpath: a loop whose condition NO tag decides (it reads another argument) takes the joined form — its exits are not lost', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r = read('lj_cf_x_wait', { L, n = 1 }, 1)
    eq({ 'number' }, r.accepted)
end)

test('cpath: a goto to a label PAST a return revives the path there — the label\'s return is one of the function\'s', function ()
    if not ready() then skip 'no C parser / gcc' end
    local _, _, rets = read('lj_cf_x_late', { L, n = 1 }, 1)
    local seen = {}
    for _, v in ipairs(rets) do if v then seen[tonumber(v.v)] = true end end
    eq({ [0] = true, [7] = true }, seen)
end)

test('cpath: a WRITE to the slot makes its tag unknown after it — a string passed in is not rejected by a test on the written value', function ()
    if not ready() then skip 'no C parser / gcc' end
    local _, w = read('lj_cf_x_write', { L, n = 1 }, 1)
    ok(w.STR ~= 'never', 'reading the old tag after setnumV would reject it: ' .. tostring(w.STR))
end)

test('cpath: L->top is a VALUE of the path — lua_settop\'s fill loop steps it and ends (a missing second argument becomes nil)', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r, p = read('lj_cf_x_pad', { L, n = 1 }, 2)
    eq({ { 'nil', 'number' }, 'never' }, { r.accepted, p.STR })
    ok(p.ABSENT ~= 'never', 'settop filled it: ' .. tostring(p.ABSENT))
end)

test('cpath: a REALLOCATED stack keeps every index — the pointers rebased by the difference of two origins are the same slots', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r, g = read('lj_cf_x_grow', { L, n = 1 }, 1)
    eq({ { 'number' }, 'never' }, { r.accepted, g.ABSENT })
end)

test('cpath: a RECURSIVE stack writer\'s guess leaves the stack where it was — a missing argument still reads as missing after it', function ()
    if not ready() then skip 'no C parser / gcc' end
    local _, g = read('lj_cf_x_rec', { L, n = 1 }, 1)
    eq({ 'always', 'never' }, { g.NUMX, g.ABSENT })
end)

test('cpath: a lua_State * is THE thread only when the caller hands it — a write to another thread\'s stack does not move ours', function ()
    if not ready() then skip 'no C parser / gcc' end
    local _, g = read('lj_cf_x_fin', { L, n = 1 }, 1)
    eq('always', g.NUMX)
end)

test('cpath: stack-free is a property of the call CLOSURE, derived from the tree — a self-recursive helper is stack-free, a reader\'s caller is not', function ()
    if not ready() then skip 'no C parser / gcc' end
    local c = setup()
    local A = P.analyzer(c.ctx)
    local D = c.ctx.defs
    eq({ true, false, false, false }, { A.stackfree(D.x_fact), A.stackfree(D.x_isnum), A.stackfree(D.lj_cf_x_ab), A.stackfree(D.lj_cf_x_pad) })
end)

test('cpath: a SWITCH sends each element down every case it may equal — default takes only those no case surely equals', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r, s = read('lj_cf_x_sw', { L, n = 1 }, 1)
    eq({ { 'table' }, 'always', 'always', 'never' }, { r.accepted, s.TAB, s.ABSENT, s.STR })
end)

test('cpath: a loop whose state never repeats (a counter under a condition no tag decides) WIDENS at its head and ends', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r = read('lj_cf_x_count', { L, n = 1 }, 1)
    eq({ 'number' }, r.accepted)
    local s = read('lj_cf_x_spin', { L, n = 1 }, 1)
    eq({ 'number' }, s.accepted, 'a loop that is ONE node (its head): only the head widens it')
end)

test('cpath: paths that split and REJOIN inside a loop body keep their iteration — the argument loop stays exact past the join', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r = read('lj_cf_x_sum2', { L, n = 1 }, 3)
    eq({ 'number' }, r.accepted)
end)

test('cpath: an UNKNOWN L->top stays unknown in a callee — it is not re-derived from the argument count', function ()
    if not ready() then skip 'no C parser / gcc' end
    local _, g = read('lj_cf_x_lose', { L, n = 1 }, 1)
    ok(g.ABSENT ~= 'never', 'a missing argument under an unknown top: ' .. tostring(g.ABSENT))
end)

test('cpath compare: nil is optionality\'s, `any` every first-class type; a difference is NAMED (finer / narrower / optional)', function ()
    local first = { ['nil'] = true, number = true, string = true, table = true }
    eq(nil, P.compare({ 'nil', 'number', 'string', 'table' }, false, { 'any' }, false, first))
    eq('finer: also accepts string', P.compare({ 'number', 'string' }, false, { 'number' }, false, first))
    eq(nil, P.compare({ 'nil', 'number' }, true, { 'number' }, true, first), 'an optional checker accepts nil too')
    eq('optional: path false / checker true', P.compare({ 'nil', 'table' }, false, { 'table' }, true, first))
end)
