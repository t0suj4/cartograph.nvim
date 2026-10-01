-- cartograph.qjs (CART-1258): QuickJS' built-ins read BY PATH, over a fixture tree shaped like QuickJS — every fact
-- derived (a counted argument array padded with undefined, a 16-byte JSValue by value, JS_Throw's sentinel and its
-- throwers, the JS_Is<X> predicates, typeof's default arm, JS_CFUNC_DEF tables), no runtime named in the engine.
local Q = require 'cartograph.qjs'
local AD = require 'cartograph.cinterp.adapter'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local cached
local function context()
    if cached then return cached end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(dofile(vim.fn.getcwd() .. '/tests/fixtures/cinterp/quickjs.lua')) do
        local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close()
    end
    cached = Q.context(dir)
    return cached
end
local function read(key)
    local rows = Q.measure({ ctx = context(), keys = { key } })
    return rows[key].pos[1]
end

test('qjs: the facts — a COUNTED array padded with undefined, the tag enum the units use, JS_Throw\'s sentinel and every thrower', function ()
    if not ready() then skip 'no C parser / gcc' end
    local ctx = context()
    eq({ 'counted', 4, 3, 'UNDEFINED' }, { AD.frame_kind(ctx.frame), ctx.frame.arrayat, ctx.frame.countat, ctx.padrep }, 'argv at 4, argc at 3, padded with undefined')
    eq({ 'SYMBOL', 'OBJECT', 'INT', 'BOOL', 'NULL', 'UNDEFINED', 'EXCEPTION', 'FLOAT64' }, ctx.reps.order, 'JS_TAG_ (not the larger BC_TAG_, named once), JS_TAG_FIRST dropped as an alias')
    eq({ 'JS_Throw', 'current_exception' }, { ctx.result.fn, ctx.result.field })
    eq({ true, true, true }, { ctx.throwers.JS_Throw ~= nil, ctx.throwers.JS_ThrowTypeError ~= nil, ctx.throwers.JS_ThrowTypeErrorNotAnObject ~= nil }, 'through a local, through a call')
    eq({ 'null', 'number', 'number', false, true }, { ctx.typenames.NULL, ctx.typenames.INT, ctx.typenames.FLOAT64, ctx.firstclass.EXCEPTION, ctx.firstclass.NULL },
        'null its own type (its predicate); the exception tag only typeof\'s default arm')
end)

test('qjs: readings — a tag check, MAGIC choosing the check, a padded absent argument, a count read', function ()
    if not ready() then skip 'no C parser / gcc' end
    local k = read('js_symbol_funcs:keyFor')
    eq({ 'always', 'never', 'never', 'never' }, { k.by.symbol, k.by.object, k.by.undefined, k.absent })
    local o, r = read('js_object_funcs:getPrototypeOf'), read('js_reflect_funcs:getPrototypeOf')
    eq({ 'always', 'never', 'never', 'never' }, { o.by.number, o.by.null, o.by.undefined, o.absent }, 'magic 0: only null and undefined are not objects enough')
    eq({ 'always', 'never', 'never' }, { r.by.object, r.by.number, r.absent }, 'magic 1: an object only')
    local a = read('js_array_funcs:isArray')
    eq({ 'always', 'always' }, { a.by.null, a.absent }, 'an absent argument is the undefined it is padded with')
    local n = read('js_global_funcs:needsArg')
    eq({ 'always', 'never' }, { n.by.undefined, n.absent }, 'a function reading its COUNT tells an absent argument from undefined')
end)

test('qjs: a run OVER its budget makes the callee that spent it an unknown call and runs again — the reading survives', function ()
    if not ready() then skip 'no C parser / gcc' end
    local ctx = context()
    ctx.budget = 100 -- (the helper alone spends ~180 steps; the function without it ~25)
    local ok, s = pcall(read, 'js_global_funcs:slow')
    ctx.budget = nil
    assert(ok, s)
    eq({ nil, 'always', 'never', 'never' }, { s.over, s.by.symbol, s.by.number, s.absent })
end)
