-- cartograph.erlbif (CART-1248) on a FIXTURE tree shaped like erts: Eterm a scalar tagged word, BIF_ARG_n an argument
-- ARRAY, BIF_ERROR's status field + sentinel, a TRAP, the generated BIF and atom tables, the guard BIFs — every fact
-- derived (cartograph.cinterp.facts), every rule of the reading pinned, none of it knowing a BIF's name.
local E = require 'cartograph.erlbif'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local FILES = dofile(vim.fn.getcwd() .. '/tests/fixtures/cinterp/erts.lua')

local cached
local function setup()
    if cached then return cached end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(FILES) do local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    local rows, ctx = E.measure({ src = dir, bifs = { 'erlang:hd/1', 'erlang:is_atom/1', 'lists:member/2', 'erlang:id/1', 'erlang:later/1', 'erlang:bool/1', 'erlang:len/1', 'erlang:flaky/1', 'erlang:alloc/1', 'erlang:undef/1', 'erlang:fill/1', 'erlang:tuple_size/1', 'erlang:proper/1', 'erlang:byte_size/1', 'erlang:bin_to_list/1', 'erlang:hbfirst/1' } })
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

test('erlbif heap: a TUPLE and a FLOAT built with the tree\'s own heap constructors — their header words are MEMORY the checks read through', function ()
    if not ready() then skip 'no C parser / gcc' end
    local c = setup()
    eq({ 'tuple', 'float', 'list', 'list', 'list' }, { c.ctx.typenames.TUPLE, c.ctx.typenames.FLOAT, c.ctx.typenames.LIST1, c.ctx.typenames.IMPROPER, c.ctx.typenames.CONS })
    local t = c.rows['erlang:tuple_size/1'].pos[1]
    eq({ 'always', 'never', 'never', 'content' }, { t.by.tuple, t.by.float, t.by.list, t.by.boxed })
end)

test('erlbif heap: a list WALKED through its cells — [1] ends in [], [1|2] does not; an unknown cons stays content', function ()
    if not ready() then skip 'no C parser / gcc' end
    local c = setup()
    local CI = require 'cartograph.cinterp'
    local acc = E.acceptance(CI.analyzer(c.ctx), c.ctx, c.ctx.defs.proper_1, 1, 1)
    eq({ 'always', 'never', 'content', 'always', 'never' }, { acc.LIST1, acc.IMPROPER, acc.CONS, acc.NIL, acc.TUPLE })
end)

test('erlbif families: a minimal object of EVERY header kind and a word of every immediate kind the tree names — the guards say which are values', function ()
    if not ready() then skip 'no C parser / gcc' end
    local c = setup()
    local tn = c.ctx.typenames
    eq({ 'binary', 'map', 'pid', '-' }, { tn['HDR:HEAP_BIN'], tn['HDR:MAP'], tn['IMMED1:PID'], tn['HDR:MATCHSTATE'] }, 'a match state is no value: no guard claims it')
    local b = c.rows['erlang:byte_size/1'].pos[1]
    eq({ 'always', 'never', 'never', 'never' }, { b.by.binary, b.by.map, b.by.pid, b.by.tuple })
    ok(b.by['-'] == nil, 'a non-value is no element of a reading')
end)

test('erlbif families: a header defined through sizeof(struct) — the compiler sizes it; the tree\'s OWN HEADER_FUN makes a fun a function', function ()
    if not ready() then skip 'no C parser / gcc' end
    local c = setup()
    eq({ 'function', '-' }, { c.ctx.typenames['HEAD:HEADER_FUN'], c.ctx.typenames['HDR:FUN'] }, 'an arity-0 fun header is no fun: HEADER_FUN is exact')
    ok(vim.tbl_contains(c.ctx.typenames.subtypes.boolean or {}, 'atom'), 'boolean is under atom, from the same guard answers: ' .. vim.inspect(c.ctx.typenames.subtypes))
    eq(4, c.ctx.facts.rows.sizes.value['bifs.c'] and c.ctx.facts.rows.sizes.value['bifs.c']['ErlFunThing'] and c.ctx.facts.rows.sizes.value['bifs.c']['ErlFunThing'] / 8)
end)

test('erlbif layouts: a FIELD behind an address — ((ErlSubBin *) p)->bitsize — where the compiler lays it; a header-only stand-in keeps every bitsize', function ()
    if not ready() then skip 'no C parser / gcc' end
    local c = setup()
    local fl = c.ctx.layout_of('bifs.c', 'ErlSubBin', 'bitsize')
    eq({ 24, 'i', 64, true }, { fl and fl.off, fl and fl.to.k, fl and fl.to.w, fl and fl.to.u })
    eq(nil, c.ctx.layout_of('bifs.c', 'ErlSubBin', 'nosuchfield'), 'a field the compiler refuses is none')
    eq({ 'binary', 'bitstring' }, { c.ctx.typenames['HEAD:HEADER_SUB_BIN'], c.ctx.typenames['HEAD?:HEADER_SUB_BIN'] }, 'the zero-filled sub-binary is byte-aligned; the header-only one may not be')
    local b = c.rows['erlang:bin_to_list/1'].pos[1]
    eq({ 'always', 'content', 'never' }, { b.by.binary, b.by.bitstring, b.by.tuple })
    local a = c.ctx.layout_of('bifs.c', 'ErlHeapBin', 'data')
    eq({ true, 16, 'i' }, { a and a.array, a and a.off, a and a.elem and a.elem.k }, 'an ARRAY field: its storage and its element')
    eq('always', c.rows['erlang:hbfirst/1'].pos[1].by.binary, 'hb->data[0] reads the zero word behind the array field, not a pointer stored there')
end)

test('erlbif reading: the arity is fixed — lists:member/2 checks its SECOND argument, the first takes anything', function ()
    if not ready() then skip 'no C parser / gcc' end
    local m = setup().rows['lists:member/2']
    eq({ 'always', 'never' }, { m.pos[2].by.list, m.pos[2].by.integer })
    eq({ true, false }, { m.pos[1].untyped, m.pos[2].untyped }, 'the first argument decides nothing by its type: the second one\'s check rejects')
end)
