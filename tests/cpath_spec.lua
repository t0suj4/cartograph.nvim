-- cartograph.luajs.cpath (CART-1240 leaf 2) on a FIXTURE tree shaped like LuaJIT's: its own tags, setters and tvis*
-- predicates (the representatives come from the compiler), a checker that jumps into its raise, an optionality one of
-- its parameters turns, a value callee (lua_type's shape), a count-dispatched body, a slot WRITE, a loop over the
-- arguments — each rule of the path reading pinned, none of it knowing a checker's name.
local P = require 'cartograph.luajs.cpath'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local FILES = dofile(vim.fn.getcwd() .. '/tests/fixtures/cinterp/luajit.lua')

-- THE SAME TREE WITH ITS FRAME RENAMED: another thread type, other field names — a second consumer in miniature (the
-- interpreter names none of them; the adapter derives them from lua_gettop and the rebase)
local function renamed(text)
    return (text:gsub('lua_State', 'vm_T'):gsub('TValue %*base, %*top; MRef stack;', 'TValue *bp, *sp; MRef stk;')
        :gsub('%->top%f[^%w_]', '->sp'):gsub('%->base%f[^%w_]', '->bp'):gsub('%->stack%f[^%w_]', '->stk'))
end
local cached = {}
local function setup(variant)
    variant = variant or 'plain'
    if cached[variant] then return cached[variant] end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(FILES) do
        local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(variant == 'renamed' and renamed(text) or text); fd:close()
    end
    local ctx = P.context(dir)
    local tn = ctx.typenames
    cached[variant] = { dir = dir, ctx = ctx, tn = tn }
    return cached[variant]
end
local function read(fn, args, pos, variant)
    local c = setup(variant)
    local A = P.analyzer(c.ctx)
    local acc, _, rets = P.acceptance(A, c.ctx, c.ctx.defs[fn], args, pos, pos + 2)
    return P.reading(acc, c.tn), acc, rets
end
local L = P.thread()

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
    eq({ 1, 0 }, { setup().ctx.result.offset, setup().ctx.result.retry }, 'FFH_RES / FFH_RETRY from lj_lib.h')
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

test('cpath frame: derived from the tree — lua_gettop names the thread type and top / base, the stack\'s rebase names its origin', function ()
    if not ready() then skip 'no C parser / gcc' end
    eq({ thread = 'lua_State', top = 'top', base = 'base', origin = 'stack', origin_in = 'x_grow' }, setup().ctx.frame)
    eq({ thread = 'vm_T', top = 'sp', base = 'bp', origin = 'stk', origin_in = 'x_grow' }, setup('renamed').ctx.frame)
end)

test('cpath frame: the SAME tree with its frame RENAMED reads the same at every position — the interpreter names no field', function ()
    if not ready() then skip 'no C parser / gcc' end
    local cases = {
        { 'x_checknum', { L, P._int(1), n = 2 }, 1 }, { 'x_opt', { L, P._int(1), P._int(-1), n = 3 }, 1 }, { 'x_opt', { L, P._int(1), P._int(1), n = 3 }, 1 },
        { 'lj_cf_x_istable', { L, n = 1 }, 1 }, { 'lj_cf_x_disp', { L, n = 1 }, 2 }, { 'lj_cf_x_sum', { L, n = 1 }, 3 },
        { 'lj_cf_x_ab', { L, n = 1 }, 2 }, { 'lj_cf_x_wait', { L, n = 1 }, 1 }, { 'lj_cf_x_write', { L, n = 1 }, 1 },
        { 'lj_cf_x_pad', { L, n = 1 }, 2 }, { 'lj_cf_x_grow', { L, n = 1 }, 1 }, { 'lj_cf_x_rec', { L, n = 1 }, 1 },
        { 'lj_cf_x_fin', { L, n = 1 }, 1 }, { 'lj_cf_x_sw', { L, n = 1 }, 1 }, { 'lj_cf_x_spin', { L, n = 1 }, 1 },
        { 'lj_cf_x_lose', { L, n = 1 }, 1 }, { 'lj_cf_x_sum2', { L, n = 1 }, 3 },
    }
    local typed = 0
    for _, c in ipairs(cases) do
        local r1, a1 = read(c[1], c[2], c[3])
        local r2, a2 = read(c[1], c[2], c[3], 'renamed')
        eq(a1, a2, c[1] .. ' #' .. c[3])
        if not r1.untyped then typed = typed + 1 end
    end
    ok(typed >= 12, 'the comparison is not between two blind readings: ' .. typed .. ' typed')
end)

test('cpath: a BYTE view of the frame — (char *)L->top - (char *)L->base — counts bytes, the compiler\'s slot size: exactly two arguments pass', function ()
    if not ready() then skip 'no C parser / gcc' end
    local _, a = read('lj_cf_x_nargs', { L, n = 1 }, 2)
    eq({ 'never', 'content' }, { a.ABSENT, a.STR }, 'one argument is 8 bytes, not 16; two are (and three are not)')
end)

test('cpath compare: nil is optionality\'s, `any` every first-class type; a difference is NAMED (finer / narrower / optional)', function ()
    local first = { ['nil'] = true, number = true, string = true, table = true }
    eq(nil, P.compare({ 'nil', 'number', 'string', 'table' }, false, { 'any' }, false, first))
    eq('finer: also accepts string', P.compare({ 'number', 'string' }, false, { 'number' }, false, first))
    eq(nil, P.compare({ 'nil', 'number' }, true, { 'number' }, true, first), 'an optional checker accepts nil too')
    eq('optional: path false / checker true', P.compare({ 'nil', 'table' }, false, { 'table' }, true, first))
end)
