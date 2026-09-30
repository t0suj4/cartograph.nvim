-- cartograph.luajs.csig (CART-1240 leaf 1) on a FIXTURE tree shaped like LuaJIT's: what each checker accepts, read
-- from its own body (a type its raise names, a coercion it tests, nil it accepts, an optionality one of its own
-- parameters turns, a type taken from a call-site argument; an unconditional raise is no checker); a signature read at
-- the call sites (literal, parenthesized, guarded by its own absence, a loop's position, a direct slot read); the
-- lua-ls normalizer; the join's rule; and the DYNAMIC WITNESS against the running LuaJIT, with a control it must catch.
local CS = require 'cartograph.luajs.csig'
local B = require 'cartograph.luajs.boundary'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local FILES = {
    ['lua.h'] = '#define LUA_TNONE (-1)\n#define LUA_TNIL 0\n#define LUA_TNUMBER 3\n#define LUA_TSTRING 4\n#define LUA_TTABLE 5\n',
    ['lj_def.h'] = '#define LJ_NORET __attribute__((noreturn))\n#define LJ_FUNC_NORET extern LJ_NORET\n',
    ['lj_obj.h'] = table.concat({
        '#include "lj_def.h"',
        '#include "lua.h"',
        'typedef struct TValue { unsigned it; double n; } TValue;',
        'typedef struct lua_State { TValue *base, *top; } lua_State;',
        '#define itype(o) ((o)->it)',
        '#define LJ_TNIL (~0u)',
        '#define LJ_TSTR (~4u)',
        '#define LJ_TNUMX (~13u)',
        '#define LJ_TISNUM LJ_TNUMX',
        '#define tvisnil(o) (itype(o) == LJ_TNIL)',
        '#define tvisstr(o) (itype(o) == LJ_TSTR)',
        '#define tvisnumber(o) (itype(o) <= LJ_TISNUM)',
        'LJ_FUNC_NORET void lj_err_argt(lua_State *L, int narg, int tt);',
        'int lua_type(lua_State *L, int idx);',
    }, '\n') .. '\n',
    ['lj_obj.c'] = table.concat({
        '#include "lj_obj.h"',
        'const char *const lj_obj_itypename[] = {',
        '  "nil", "boolean", "boolean", "userdata", "string", "upval", "thread",',
        '  "proto", "function", "trace", "cdata", "table", "userdata", "number"',
        '};',
    }, '\n') .. '\n',
    ['lj_lib.c'] = table.concat({
        '#include "lj_obj.h"',
        'double lj_lib_checknum(lua_State *L, int narg)',
        '{',
        '  TValue *o = L->base + narg-1;',
        '  if (!(o < L->top && (tvisnumber(o) || tvisstr(o))))',
        '    lj_err_argt(L, narg, LUA_TNUMBER);',
        '  return o->n;',
        '}',
        'double lj_lib_optnum(lua_State *L, int narg, double def)',
        '{',
        '  TValue *o = L->base + narg-1;',
        '  return (o < L->top && !tvisnil(o)) ? lj_lib_checknum(L, narg) : def;',
        '}',
        'int lj_lib_checkopt(lua_State *L, int narg, int def)',
        '{',
        '  double v = def >= 0 ? lj_lib_optnum(L, narg, 0) : lj_lib_checknum(L, narg);',
        '  return (int)v;',
        '}',
        'void lj_lib_checktype(lua_State *L, int narg, int tt)',
        '{',
        '  if (lua_type(L, narg) != tt)',
        '    lj_err_argt(L, narg, tt);',
        '}',
        'void lj_lib_fail(lua_State *L, int narg)',
        '{',
        '  lj_err_argt(L, narg, LUA_TSTRING);',
        '}',
    }, '\n') .. '\n',
    ['lib_x.c'] = table.concat({
        '#include "lj_obj.h"',
        'double lj_lib_checknum(lua_State *L, int narg);',
        'double lj_lib_optnum(lua_State *L, int narg, double def);',
        'int lj_lib_checkopt(lua_State *L, int narg, int def);',
        'void lj_lib_checktype(lua_State *L, int narg, int tt);',
        'int lj_cf_x_f(lua_State *L)',
        '{',
        '  double a = lj_lib_checknum(L, 1);',
        '  double b = lj_lib_optnum(L, (2), 0);',
        '  double c = (lua_type(L, (3)) <= 0) ? 7 : lj_lib_checknum(L, 3);',
        '  int d = lj_lib_checkopt(L, 4, -1) + lj_lib_checkopt(L, 5, 1);',
        '  lj_lib_checktype(L, 6, 5);',
        '  return (int)(a + b + c + d);',
        '}',
        'int lj_cf_x_loop(lua_State *L)',
        '{',
        '  int i; double s = 0;',
        '  for (i = 1; i <= 3; i++) s += lj_lib_checknum(L, i);',
        '  return (int)s;',
        '}',
        'int lj_cf_x_direct(lua_State *L)',
        '{',
        '  double a = lj_lib_checknum(L, 1);',
        '  if (L->base+3-1 < L->top) a += lj_lib_checknum(L, 3);',
        '  return (int)a;',
        '}',
    }, '\n') .. '\n',
}

local function tree()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(FILES) do local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    return dir
end

test('csig checkers: each checker\'s type is the one its own raise names (or the one it delegates to); it is optional when it accepts nil, or when one of its OWN parameters says so; a type may come from a call-site argument; an unconditional raise is no checker', function ()
    if not ready() then skip 'no C parser / gcc' end
    local dir = tree()
    local vocab = CS.vocabulary(dir)
    eq({ nil_ = 0, number = 3 }, { nil_ = vocab.luanil, number = (function () for n, t in pairs(vocab.luanum) do if t == 'number' then return n end end end)() })
    eq('number', vocab.tvis.tvisnumber, 'a tag defined as another tag (LJ_TISNUM) is followed')
    local C = CS.checkers(dir, vocab, B.noreturn(dir))
    eq({ { 'number' }, { 'string' }, false }, { C.lj_lib_checknum.types, C.lj_lib_checknum.coerces, C.lj_lib_checknum.opt or false })
    eq({ { 'number' }, true }, { C.lj_lib_optnum.types, C.lj_lib_optnum.opt }, 'delegates its type, accepts nil')
    eq({ param = 3 }, C.lj_lib_checkopt.opt, 'optional iff its third argument >= 0')
    eq(3, C.lj_lib_checktype.from_arg)
    eq(nil, C.lj_lib_fail, 'an unconditional raise is the rejection, not a check')
    eq(nil, C.lj_err_argt, 'a no-return raiser is not a checker')
end)

test('csig signature: literal and parenthesized positions, a check guarded by its own absence is OPTIONAL, a per-call optionality, a type from the call site; a loop position and a direct slot read make it partial and OPEN', function ()
    if not ready() then skip 'no C parser / gcc' end
    local dir = tree()
    local vocab = CS.vocabulary(dir)
    local C = CS.checkers(dir, vocab, B.noreturn(dir))
    local unit
    for _, s in ipairs(B.preprocess(dir, {})) do if s.name == 'lib_x.c' then unit = s.text end end
    local root = vim.treesitter.get_string_parser(unit, 'c'):parse()[1]:root()
    local q = vim.treesitter.query.parse('c', '(function_definition declarator: (function_declarator declarator: (identifier) @n)) @f')
    local fns, cur = {}, nil
    for id, node in q:iter_captures(root, unit, 0, -1) do
        if q.captures[id] == 'f' then cur = node else fns[vim.treesitter.get_node_text(node, unit)] = cur end
    end
    local f = CS.signature(unit, fns.lj_cf_x_f, C, {}, vocab)
    eq(true, f.complete, vim.inspect(f.partial))
    local P = f.params
    eq({ false, true, true, false, true }, { P[1].opt, P[2].opt, P[3].opt, P[4].opt, P[5].opt })
    eq({ 'table' }, P[6].types, 'luaL_checktype-shaped: the call site\'s type constant')
    local l = CS.signature(unit, fns.lj_cf_x_loop, C, {}, vocab)
    ok(not l.complete and l.partial[1]:find('not a literal', 1, true), vim.inspect(l.partial))
    local d = CS.signature(unit, fns.lj_cf_x_direct, C, {}, vocab)
    eq({ true, nil }, { d.open[3], d.open[4] }, '`L->base+3-1` is argument 3')
    eq(false, d.complete)
end)

test('csig lua-ls side: types as Lua\'s type() names (integer is number, a literal is a string, fun() a function, a generic any), aliases from the meta dir (a default `>` alternative, a `# comment`), an undefined name unresolved', function ()
    local meta = vim.fn.tempname()
    vim.fn.mkdir(meta, 'p')
    local fd = assert(io.open(meta .. '/io.lua', 'w'))
    fd:write('---@alias openmode\n---|>"r"   # read\n---| "w"   # write\n\n---@alias num2 integer|number\n')
    fd:close()
    local A = CS.aliases(meta)
    eq({ string = true }, CS.luals_type('openmode', A))
    eq({ number = true }, CS.luals_type('num2', A))
    eq({ number = true, string = true }, CS.luals_type('string|integer', A))
    eq({ ['function'] = true }, CS.luals_type('fun(a: T, b: T):boolean', A), 'a `|` inside fun(...) does not split')
    eq({ any = true }, CS.luals_type('T', A))
    local s, u = CS.luals_type('file*', A)
    eq({ nil, 'file*' }, { s, u })
end)

test('csig join rule: lua-ls may name the base type or the type with its coercions; optionality must match unless count-dispatched; an unstatable type is not compared', function ()
    local function kv(map) local k = vim.tbl_keys(map); table.sort(k); return { keys = k, o = map } end
    local function one(t, all, opt, dispatch) return kv({ ['1'] = kv({ t = t, all = all, opt = opt, dispatch = dispatch or false }) }) end
    local function ls(t, opt) return kv({ ['1'] = kv({ t = t, opt = opt }) }) end
    ok(CS.agree(one('string', 'number|string', false), ls('string', false)))
    ok(CS.agree(one('string', 'number|string', false), ls('number|string', false)), 'lua-ls wrote the coercion')
    ok(not CS.agree(one('string', 'number|string', false), ls('table', false)))
    ok(not CS.agree(one('any', 'any', false), ls('any', true)), 'required vs optional')
    ok(CS.agree(one('number', 'number', false, true), ls('number', true)), 'a count-dispatched position: an overload')
    ok(CS.agree(one('?', '?', false), ls('number', true)), 'a converted position is not compared')
    eq('optional: C false / lua-ls true', CS.cause(nil, nil, one('any', 'any', false), ls('any', true)))
end)

test('csig witness: the running LuaJIT names the expected type in its own words — a derived type it confirms, a wrong one it contradicts', function ()
    local errs = { BADARG = "bad argument #%d to '%s' (%s)", BADTYPE = '%s expected, got %s' }
    local W = CS.witness({
        { q = 'string.rep', params = { [1] = { types = { 'string' }, all = { 'number', 'string' }, opt = false }, [2] = { types = { 'number' }, all = { 'number', 'string' }, opt = false } } },
    }, errs)
    local byk = {}
    for _, p in ipairs(W['string.rep'].probes) do byk[p.k] = byk[p.k] or {}; table.insert(byk[p.k], p) end
    eq({ 1, 'string' }, { byk[1][1].at, byk[1][1].expected }, vim.inspect(W))
    eq({ 2, 'number' }, { byk[2][1].at, byk[2][1].expected })
    -- the CONTROL: a derivation saying argument 1 is a table is not what LuaJIT says
    ok(byk[1][1].expected ~= 'table', 'the witness separates a wrong type from a right one')
end)
