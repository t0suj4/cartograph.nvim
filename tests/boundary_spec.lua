-- cartograph.luajs.boundary (CART-1211 leaf 4) on a FIXTURE tree shaped like LuaJIT's: the GC object types derived
-- from the tree's own `#define GCHeader` (and a union holding one BY VALUE), the no-return raisers from its own
-- noreturn macros, and a probe that sorts functions into clean / boundary / cjs gap with their closures — each rule
-- pinned from both sides. The real map over LuaJIT is a tool measurement (tools/packmap.lua), not a spec.
local B = require 'cartograph.luajs.boundary'
local C = require 'cartograph.cjs'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local FILES = {
    ['lj_def.h'] = table.concat({
        '#define LJ_NORET __attribute__((noreturn))',
        '#define LJ_FUNC_NORET extern LJ_NORET',
    }, '\n') .. '\n',
    ['lj_obj.h'] = table.concat({
        '#include <stdint.h>',
        '#include "lj_def.h"',
        'typedef uint64_t GCRef;',
        '#define GCHeader GCRef nextgc; uint8_t marked; uint8_t gct',
        'typedef struct GCstr { GCHeader; uint32_t len; } GCstr;',
        'typedef struct lua_State { GCHeader; int top; } lua_State;',
        'typedef struct Plain { int a; uint8_t gct; } Plain;',           -- one GCHeader field is not the header
        'typedef union GCobj { GCstr str; lua_State th; } GCobj;',       -- holds a GC object BY VALUE
        'LJ_FUNC_NORET void lj_err_x(lua_State *L, int code);',
        'void *memset(void *p, int c, unsigned long n);',
    }, '\n') .. '\n',
    ['lj_obj.c'] = '#include "lj_obj.h"\nint lj_obj_dummy;\n',
    ['lj_err.c'] = table.concat({
        '#include "lj_obj.h"',
        'static int fmt_msg(int code) { return code * 10 + 1; }',          -- clean, but only on the RAISE path
        'void lj_err_x(lua_State *L, int code) { L->top = fmt_msg(code); for (;;) {} }',
    }, '\n') .. '\n',
    ['lib_x.c'] = table.concat({
        '#include "lj_obj.h"',
        'static uint32_t str_len(GCstr *s) { return s->len; }',
        'static int add3(int a) { return a + 3; }',
        'static int calls_len(GCstr *s) { return add3((int)str_len(s)); }',
        'static void wipe(char *p) { memset(p, 0, 4); }',
        'static int raising(lua_State *L, int x) { if (x < 0) lj_err_x(L, x); return add3(x); }',
        'int root_fn(GCstr *s, lua_State *L, char *p) { wipe(p); return calls_len(s) + raising(L, 1); }',
    }, '\n') .. '\n',
    ['ljamalg.c'] = '#include "lib_x.c"\n#include "lj_err.c"\n',
}

local function tree()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(FILES) do local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    return dir
end

test('boundary: the GC types ARE the structs holding every GCHeader field (read from the tree), and a union holding one by value; the no-return raisers come from the tree\'s own noreturn macros; an amalgamation unit is left out', function ()
    if not ready() then skip 'no C parser / gcc' end
    local dir = tree()
    local sources, skipped = B.preprocess(dir, {})
    local names = vim.tbl_map(function (s) return s.name end, sources)
    table.sort(names)
    eq({ 'lib_x.c', 'lj_err.c', 'lj_obj.c' }, names)
    ok(skipped[1] and skipped[1]:find('ljamalg.c', 1, true), vim.inspect(skipped))
    local gc, fields = B.gc_types(sources, dir)
    eq({ 'nextgc', 'marked', 'gct' }, fields)
    eq({ GCobj = true, GCstr = true, lua_State = true }, gc, 'Plain carries one header field, not the header')
    eq({ lj_err_x = true }, B.noreturn(dir), 'a #define of the macro is no declaration')
end)

test('boundary noreturn: a `#  define` indented after its `#` is a macro too (erts: sys.h), and a COMMENT naming the macro declares nothing (lj_err.c: "no LJ_NORET")', function ()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/sys.h', 'w'))
    fd:write(table.concat({
        '#if defined(__GNUC__)', '#  define __noreturn __attribute__((noreturn))', '#endif',
        'void __noreturn erts_exit(int n, const char *fmt, ...);',
        '/* Forwarders (no __noreturn). */', 'int lua_error_like(void *L);',
    }, '\n') .. '\n')
    fd:close()
    eq({ erts_exit = true }, B.noreturn(dir))
    eq({ erts_exit = true }, B.noreturn({ dir .. '/sys.h' }), 'a list of the files a build reads, the same answer')
end)

test('boundary probe: a GC field read is BOUNDARY (naming the type), a refused construct with no VM object is a cjs GAP, the rest CLEAN — and a clean function over a dirty callee names it', function ()
    if not ready() then skip 'no C parser / gcc' end
    local dir = tree()
    local sources = B.preprocess(dir, {})
    local gc = B.gc_types(sources, dir)
    local P = B.probe({ sources = sources, roots = { 'root_fn' }, gc = gc, templates = C.BUILTINS })
    local F = P.functions
    eq('boundary', F.str_len.own)
    ok(F.str_len.why[1]:find('GCstr', 1, true), vim.inspect(F.str_len.why))
    eq({ 'clean', false }, { F.add3.own, F.add3.dirty == true })
    eq({ 'clean', true, 'str_len' }, { F.calls_len.own, F.calls_len.dirty, F.calls_len.dirty_via })
    eq('gap', F.wipe.own, 'memset has no template: a construct cjs lacks, no VM object')
    eq('boundary', F.lj_err_x.own)
    -- without the opaque types, the same field read is emitted as a plain JS object read: nothing refuses
    local P2 = B.probe({ sources = sources, roots = { 'str_len' }, gc = {}, templates = C.BUILTINS })
    eq('clean', P2.functions.str_len.own, 'the premise: the boundary is the opaque set, not an emitter failure')
end)

test('boundary classify: covered = generated functions in the closure, cores = the maximal clean functions left; the closure stops at a no-return raiser (its clean formatter is the VM\'s, not the primitive\'s); the kind follows', function ()
    if not ready() then skip 'no C parser / gcc' end
    local dir = tree()
    local sources = B.preprocess(dir, {})
    local P = B.probe({ sources = sources, roots = { 'root_fn' }, gc = B.gc_types(sources, dir), templates = C.BUILTINS })
    local noret = B.noreturn(dir)
    local k = B.classify(P, 'root_fn', {}, nil, noret)
    eq({ { 'add3' }, {}, 'hand-written' }, { k.cores, k.covered, k.kind })
    eq(1, k.weight.add3)
    local through = B.classify(P, 'root_fn', {}, nil, nil)
    eq({ 'add3', 'fmt_msg' }, through.cores, 'without the stop, the raise path\'s formatter reads as the primitive\'s work')
    local done = B.classify(P, 'root_fn', { add3 = 'gen' }, nil, noret)
    eq({ { 'add3' }, {}, 'transliterated' }, { done.covered, done.cores, done.kind })
    eq('boundary', B.classify(P, 'str_len', {}, nil, noret).kind, 'nothing below the boundary: a boundary row')
end)
