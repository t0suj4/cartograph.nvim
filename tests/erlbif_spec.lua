-- cartograph.erlbif (CART-1248) on a FIXTURE tree shaped like erts: Eterm a scalar tagged word, BIF_ARG_n an argument
-- ARRAY, BIF_ERROR's status field + sentinel, a TRAP, the generated BIF and atom tables, the guard BIFs — every fact
-- derived (cartograph.cinterp.facts), every rule of the reading pinned, none of it knowing a BIF's name.
local E = require 'cartograph.erlbif'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local FILES = {
    ['sys.h'] = table.concat({
        '#ifndef SYS_H', '#define SYS_H', 'typedef unsigned long Uint;', 'typedef Uint Eterm;',
        '#if defined(__GNUC__)', '#  define __noreturn __attribute__((noreturn))', '#endif',
        'void __noreturn erts_exit(int n, const char *fmt, ...);', '#endif',
    }, '\n') .. '\n',
    ['erl_term.h'] = table.concat({
        '#include "sys.h"',
        '#define _TAG_PRIMARY_SIZE 2', '#define _TAG_PRIMARY_MASK 0x3',
        '#define TAG_PRIMARY_HEADER 0x0', '#define TAG_PRIMARY_LIST 0x1', '#define TAG_PRIMARY_BOXED 0x2', '#define TAG_PRIMARY_IMMED1 0x3',
        '#define _TAG_IMMED1_SIZE 4', '#define _TAG_IMMED1_MASK 0xF',
        '#define _TAG_IMMED1_IMMED2 ((0x2 << _TAG_PRIMARY_SIZE) | TAG_PRIMARY_IMMED1)',
        '#define _TAG_IMMED1_SMALL ((0x3 << _TAG_PRIMARY_SIZE) | TAG_PRIMARY_IMMED1)',
        '#define _TAG_IMMED2_SIZE 6', '#define _TAG_IMMED2_MASK 0x3F',
        '#define _TAG_IMMED2_ATOM ((0x0 << _TAG_IMMED1_SIZE) | _TAG_IMMED1_IMMED2)',
        '#define _TAG_IMMED2_NIL ((0x3 << _TAG_IMMED1_SIZE) | _TAG_IMMED1_IMMED2)',
        '#define NIL ((~((Uint) 0) << _TAG_IMMED2_SIZE) | _TAG_IMMED2_NIL)',
        '#define make_small(x) (((Uint)(x) << _TAG_IMMED1_SIZE) + _TAG_IMMED1_SMALL)',
        '#define is_small(x) (((x) & _TAG_IMMED1_MASK) == _TAG_IMMED1_SMALL)',
        '#define is_integer(x) is_small(x)',
        '#define make_atom(x) ((Eterm)(((x) << _TAG_IMMED2_SIZE) + _TAG_IMMED2_ATOM))',
        '#define is_atom(x) (((x) & _TAG_IMMED2_MASK) == _TAG_IMMED2_ATOM)',
        '#define is_nil(x) ((x) == NIL)',
        '#define make_list(x) ((Uint)(x) + TAG_PRIMARY_LIST)',
        '#define is_list(x) (((x) & _TAG_PRIMARY_MASK) == TAG_PRIMARY_LIST)',
        '#define is_not_list(x) (!is_list((x)))',
        '#define list_val(x) ((Eterm*) ((x) - TAG_PRIMARY_LIST))',
        '#define CAR(x) ((x)[0])',
        '#define THE_NON_VALUE (TAG_PRIMARY_HEADER)',
    }, '\n') .. '\n',
    ['error.h'] = '#define EXC_ERROR 3\n#define EXC_BADARG ((3 << 8) | EXC_ERROR)\n#define BADARG EXC_BADARG\n#define TRAP (1 << 8)\n#define EXC_CASE_CLAUSE ((4 << 8) | EXC_ERROR)\n',
    ['bif.h'] = table.concat({
        '#include "erl_term.h"', '#include "error.h"',
        'typedef struct process { Uint freason; Uint arity; } Process;', 'typedef const void *ErtsCodePtr;',
        '#define BIF_RETTYPE Eterm', '#define BIF_P A__p',
        '#define BIF_ALIST Process* A__p, Eterm* BIF__ARGS, ErtsCodePtr A__I',
        '#define BIF_ALIST_1 BIF_ALIST', '#define BIF_ALIST_2 BIF_ALIST',
        '#define BIF_ARG_1 (BIF__ARGS[0])', '#define BIF_ARG_2 (BIF__ARGS[1])',
        '#define BIF_RET(x) return (x)',
        '#define BIF_ERROR(p,r) do { \\', '    (p)->freason = r; \\', '    return THE_NON_VALUE; \\', '} while(0)',
        '#define ERTS_BIF_PREP_TRAP(Proc, Arity) do { \\', '    (Proc)->arity = (Arity); \\', '    (Proc)->freason = TRAP; \\', '} while(0)',
        '#define BIF_TRAP1(p, A0) do { \\', '    ERTS_BIF_PREP_TRAP((p), 1); \\', '    return THE_NON_VALUE; \\', '} while(0)',
        '#define CaseClause(p) do { (p)->freason = EXC_CASE_CLAUSE; } while(0)',
    }, '\n') .. '\n',
    ['erl_atom_table.h'] = table.concat({
        '#define am_false make_atom(0)', '#define am_true make_atom(1)', '#define am_erlang make_atom(2)', '#define am_lists make_atom(3)',
        '#define am_hd make_atom(4)', '#define am_is_atom make_atom(5)', '#define am_is_integer make_atom(6)', '#define am_is_list make_atom(7)',
        '#define am_member make_atom(8)', '#define am_id make_atom(9)', '#define am_later make_atom(10)', '#define am_undefined make_atom(11)',
        '#define am_bool make_atom(12)', '#define am_is_boolean make_atom(13)', '#define am_len make_atom(14)', '#define am_flaky make_atom(15)', '#define am_alloc make_atom(16)', '#define am_undef make_atom(17)', '#define am_fill make_atom(18)',
    }, '\n') .. '\n',
    ['erl_atom_table.c'] = 'char* erl_atom_names[] = {\n  "false", "true", "erlang", "lists", "hd", "is_atom", "is_integer", "is_list", "member", "id", "later", "undefined", "bool", "is_boolean", "len", "flaky", "alloc", "undef", "fill",\n};\n',
    ['erl_bif_table.c'] = table.concat({
        '#include "bif.h"', '#include "erl_atom_table.h"',
        'typedef struct { Eterm module; Eterm name; int arity; void *f; void *g; int kind; } BifEntry;',
        'Eterm hd_1(BIF_ALIST_1); Eterm is_atom_1(BIF_ALIST_1); Eterm is_integer_1(BIF_ALIST_1); Eterm is_list_1(BIF_ALIST_1);',
        'Eterm is_boolean_1(BIF_ALIST_1); Eterm lists_member_2(BIF_ALIST_2); Eterm id_1(BIF_ALIST_1); Eterm later_1(BIF_ALIST_1); Eterm bool_1(BIF_ALIST_1); Eterm len_1(BIF_ALIST_1); Eterm flaky_1(BIF_ALIST_1); Eterm alloc_1(BIF_ALIST_1); Eterm undef_1(BIF_ALIST_1); Eterm fill_1(BIF_ALIST_1);',
        'BifEntry bif_table[] = {',
        '  {am_erlang, am_hd, 1, hd_1, hd_1, 0},', '  {am_erlang, am_is_atom, 1, is_atom_1, is_atom_1, 0},',
        '  {am_erlang, am_is_integer, 1, is_integer_1, is_integer_1, 0},', '  {am_erlang, am_is_list, 1, is_list_1, is_list_1, 0},',
        '  {am_erlang, am_is_boolean, 1, is_boolean_1, is_boolean_1, 0},',
        '  {am_lists, am_member, 2, lists_member_2, lists_member_2, 0},', '  {am_erlang, am_id, 1, id_1, id_1, 0},',
        '  {am_erlang, am_later, 1, later_1, later_1, 0},', '  {am_erlang, am_bool, 1, bool_1, bool_1, 0},', '  {am_erlang, am_len, 1, len_1, len_1, 0},', '  {am_erlang, am_flaky, 1, flaky_1, flaky_1, 0},', '  {am_erlang, am_alloc, 1, alloc_1, alloc_1, 0},', '  {am_erlang, am_undef, 1, undef_1, undef_1, 0},', '  {am_erlang, am_fill, 1, fill_1, fill_1, 0},',
        '};',
    }, '\n') .. '\n',
    ['bifs.c'] = table.concat({
        '#include "bif.h"', '#include "erl_atom_table.h"',
        'BIF_RETTYPE hd_1(BIF_ALIST_1) { if (is_not_list(BIF_ARG_1)) { BIF_ERROR(BIF_P, BADARG); } BIF_RET(CAR(list_val(BIF_ARG_1))); }',
        'BIF_RETTYPE is_atom_1(BIF_ALIST_1) { if (is_atom(BIF_ARG_1)) BIF_RET(am_true); BIF_RET(am_false); }',
        'BIF_RETTYPE is_integer_1(BIF_ALIST_1) { if (is_integer(BIF_ARG_1)) BIF_RET(am_true); BIF_RET(am_false); }',
        'BIF_RETTYPE is_list_1(BIF_ALIST_1) { if (is_list(BIF_ARG_1) || is_nil(BIF_ARG_1)) BIF_RET(am_true); BIF_RET(am_false); }',
        'BIF_RETTYPE is_boolean_1(BIF_ALIST_1) { if (BIF_ARG_1 == am_true || BIF_ARG_1 == am_false) BIF_RET(am_true); BIF_RET(am_false); }',
        'BIF_RETTYPE lists_member_2(BIF_ALIST_2) { if (is_nil(BIF_ARG_2)) BIF_RET(am_false); if (is_not_list(BIF_ARG_2)) BIF_ERROR(BIF_P, BADARG); BIF_RET(am_true); }',
        'static Eterm check_atom(Process *p, Eterm a) { if (!is_atom(a)) BIF_ERROR(p, BADARG); return a; }',
        'BIF_RETTYPE id_1(BIF_ALIST_1) { return check_atom(BIF_P, BIF_ARG_1); }',
        'BIF_RETTYPE later_1(BIF_ALIST_1) { if (is_small(BIF_ARG_1)) BIF_TRAP1(BIF_P, BIF_ARG_1); BIF_RET(BIF_ARG_1); }',
        'BIF_RETTYPE bool_1(BIF_ALIST_1) { switch (BIF_ARG_1) { case am_true: BIF_RET(am_false); case am_false: BIF_RET(am_true); } BIF_ERROR(BIF_P, BADARG); }',
        'static Eterm len_helper(Process *p, Eterm *args) { if (!is_list(args[0]) && !is_nil(args[0])) BIF_ERROR(p, BADARG); return args[1]; }',
        'BIF_RETTYPE len_1(BIF_ALIST_1) { Eterm args[2]; args[0] = BIF_ARG_1; args[1] = make_small(0); return len_helper(BIF_P, args); }',
        'static Eterm flaky(Process *p, Eterm a, Eterm *x) { if (x[5]) { p->freason = BADARG; a = THE_NON_VALUE; } return a; }',
        'static Eterm flaky2(Process *p, Eterm a, Eterm *x) { return flaky(p, a, x); }',
        'BIF_RETTYPE flaky_1(BIF_ALIST_1) { return flaky2(BIF_P, BIF_ARG_1, (Eterm *) A__I); }',
        'static void filler(Eterm *a, Eterm *x) { a[0] = x[7]; }',
        'BIF_RETTYPE fill_1(BIF_ALIST_1) { Eterm a[1]; a[0] = BIF_ARG_1; filler(a, (Eterm *) A__I); if (is_atom(a[0])) BIF_RET(am_true); BIF_ERROR(BIF_P, BADARG); }',
        'BIF_RETTYPE undef_1(BIF_ALIST_1) { if (BIF_ARG_1 == am_undefined) BIF_RET(am_true); BIF_ERROR(BIF_P, BADARG); }',
        'BIF_RETTYPE alloc_1(BIF_ALIST_1) { if (!is_atom(BIF_ARG_1)) BIF_ERROR(BIF_P, BADARG); if (((Eterm *) A__I)[3]) erts_exit(1, "oom"); BIF_RET(BIF_ARG_1); }',
    }, '\n') .. '\n',
}

local cached
local function setup()
    if cached then return cached end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(FILES) do local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    local rows, ctx = E.measure({ src = dir, bifs = { 'erlang:hd/1', 'erlang:is_atom/1', 'lists:member/2', 'erlang:id/1', 'erlang:later/1', 'erlang:bool/1', 'erlang:len/1', 'erlang:flaky/1', 'erlang:alloc/1', 'erlang:undef/1', 'erlang:fill/1' } })
    cached = { dir = dir, rows = rows, ctx = ctx }
    return cached
end

test('erlbif facts: the erts shapes DERIVE — an argument array, a scalar word, the status convention, the generated tables', function ()
    if not ready() then skip 'no C parser / gcc' end
    local ctx = setup().ctx
    eq({ 'array', 'BIF__ARGS' }, { ctx.frame.kind, ctx.frame.array })
    ok(ctx.layout.scalar, 'Eterm is read whole')
    eq({ 'status', 'freason', 'THE_NON_VALUE' }, { ctx.result.kind, ctx.result.field, ctx.result.sentinel.name })
    eq({ 'TRAP' }, vim.tbl_keys(ctx.result.codes), 'BADARG is an ERROR (the tree hands it to BIF_ERROR); TRAP an outcome of its own')
    eq({ module = 'lists', name = 'member', arity = 2, cfn = 'lists_member_2' }, ctx.registrations.byc.lists_member_2)
    eq({ true, true }, { ctx.facts.rows.noret.value.erts_exit, ctx.facts.rows.frame.by == 'frame-bifargs' })
end)

test('erlbif types: the GUARD BIF is the type — is_list_1 holds for [] (is_list alone does not), true/false are boolean', function ()
    if not ready() then skip 'no C parser / gcc' end
    local tn = setup().ctx.typenames
    eq({ 'list', 'list', 'integer', 'boolean', 'boolean', 'atom' }, { tn.NIL, tn.CONS, tn['SMALL#1'], tn['ATOM:true'], tn['ATOM:false'], tn.ATOM })
end)

test('erlbif reading: a rejection is an ERROR stored in the status (BIF_ERROR), also through a helper; a boxed term is content', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r = setup().rows
    eq({ { 'boxed', 'list' }, 'never' }, { r['erlang:hd/1'].pos[1].accepted, r['erlang:hd/1'].pos[1].by.integer })
    eq('content', r['erlang:hd/1'].pos[1].by.boxed)
    eq({ 'always', 'never', 'never' }, { r['erlang:id/1'].pos[1].by.atom, r['erlang:id/1'].pos[1].by.integer, r['erlang:id/1'].pos[1].by.list }, 'check_atom set freason: the callee\'s status comes back')
    eq('always', r['erlang:is_atom/1'].pos[1].by.integer, 'a guard never rejects')
end)

test('erlbif reading: a TRAP is its own outcome; the atoms a switch names are elements (bool/1 takes exactly true | false)', function ()
    if not ready() then skip 'no C parser / gcc' end
    local r = setup().rows
    eq({ 'trap', 'always' }, { r['erlang:later/1'].pos[1].by.integer, r['erlang:later/1'].pos[1].by.atom })
    eq({ 'integer=trap' }, r['erlang:later/1'].pos[1].other)
    local b = r['erlang:bool/1'].pos[1]
    eq({ 'always', 'never' }, { b.by.boolean, b.by.atom })
    ok(#b.atoms == 2, 'the two atoms the switch compares: ' .. vim.inspect(b.atoms))
end)

test('erlbif reading: a LOCAL ARRAY carries the argument on — length/1\'s shape: args[0] = BIF_ARG_1, handed to a helper', function ()
    if not ready() then skip 'no C parser / gcc' end
    local l = setup().rows['erlang:len/1'].pos[1]
    eq({ 'always', 'never', 'never' }, { l.by.list, l.by.atom, l.by.integer })
end)

test('erlbif reading: a status WRITTEN on some paths is UNKNOWN after them — at a join and through two callees — never "unset", never an accept', function ()
    if not ready() then skip 'no C parser / gcc' end
    local f = setup().rows['erlang:flaky/1'].pos[1]
    eq({ 'content', 'content' }, { f.by.atom, f.by.integer })
end)

test('erlbif reading: a NO-RETURN call is a VM abort, not a type error — alloc/1 still takes every atom', function ()
    if not ready() then skip 'no C parser / gcc' end
    local a = setup().rows['erlang:alloc/1'].pos[1]
    eq({ 'always', 'never' }, { a.by.atom, a.by.integer })
end)

test('erlbif reading: an atom an EQUALITY names is an element of its own — undef/1 takes `undefined` and no other atom', function ()
    if not ready() then skip 'no C parser / gcc' end
    local u = setup().rows['erlang:undef/1'].pos[1]
    eq({ { 'ATOM:undefined' }, 'content', 'never' }, { u.atoms, u.by.atom, u.by.integer })
end)

test('erlbif reading: a local array handed to a callee is the CALLEE\'s to write — its elements are unknown after the call', function ()
    if not ready() then skip 'no C parser / gcc' end
    local f = setup().rows['erlang:fill/1'].pos[1]
    eq(true, f.untyped, 'the helper overwrote a[0]: reading the pre-call copy would type it: ' .. vim.inspect(f.by))
end)

test('erlbif reading: the arity is fixed — lists:member/2 checks its SECOND argument, the first takes anything', function ()
    if not ready() then skip 'no C parser / gcc' end
    local m = setup().rows['lists:member/2']
    eq({ 'always', 'never' }, { m.pos[2].by.list, m.pos[2].by.integer })
    eq({ true, false }, { m.pos[1].untyped, m.pos[2].untyped }, 'the first argument decides nothing by its type: the second one\'s check rejects')
end)
