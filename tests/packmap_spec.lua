-- cartograph.luajs.packmap (CART-1211 leaf 2) on FIXTURES: the registration reader (LuaJIT's lib_*.c as its own
-- buildvm_lib.c reads it), the message join (a LuaJIT message ASSEMBLED from a pack unit's literals), and the pack
-- side's string reader (javascript's grammar, not a quote regex). The real map over LuaJIT is a tool measurement
-- (tools/packmap.lua), not a spec: it needs the oracle's LuaJIT source.
local PM = require 'cartograph.luajs.packmap'

local function fixture(files)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(files) do local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    return dir
end

test('packmap registrations: modules, CF/ASM/ASM_/LUA, the module prefix stripped, NOREG unregistered, #if gates, LJ_LIB_REG names', function ()
    local dir = fixture {
        ['lualib.h'] = '#define LUA_MYLIBNAME\t"mylib"\n',
        ['lib_my.c'] = table.concat({
            '#define LJLIB_MODULE_mylib',
            'LJLIB_CF(mylib_alpha)',
            '{ return 0; }',
            'LJLIB_ASM(mylib_beta)\t\tLJLIB_REC(.)',
            'LJLIB_ASM_(mylib_gamma)',
            'LJLIB_NOREG LJLIB_CF(mylib_hidden)',
            'LJLIB_CF(other_name)',
            '#if LJ_HASFFI',
            'LJLIB_CF(mylib_ffionly)',
            '#endif',
            'LJLIB_PUSH("x") LJLIB_SET(version)',
            '#define LJLIB_MODULE_mylib_method',
            'LJLIB_CF(mylib_method_m)',
            'int luaopen_my(lua_State *L) {',
            '  LJ_LIB_REG(L, NULL, mylib_method);',
            '  LJ_LIB_REG(L, LUA_MYLIBNAME, mylib);',
            '}',
        }, '\n'),
    }
    local reg = PM.registrations(dir, { LJ_HASFFI = false })
    local by = {}
    for _, f in ipairs(reg.funcs) do by[f.cname] = f end
    eq('alpha', by.mylib_alpha.name)
    eq('lj_cf_mylib_alpha', by.mylib_alpha.cfn)
    eq({ 'ASM', 'lj_ffh_mylib_beta' }, { by.mylib_beta.kind, by.mylib_beta.cfn })
    eq({ 'ASM_', nil }, { by.mylib_gamma.kind, by.mylib_gamma.cfn }, 'a VM-only function has no C body')
    ok(by.mylib_hidden.noreg and not by.mylib_alpha.noreg and not by.other_name.noreg, 'NOREG marks only the NEXT function')
    eq('other_name', by.other_name.name, 'the prefix is stripped only when it IS the module\'s')
    eq(nil, by.mylib_ffionly, 'an #if LJ_HASFFI block is skipped when the oracle has no FFI')
    eq('m', by.mylib_method_m.name)
    eq('mylib', reg.modules.mylib.regname, 'the run-time name through the header macro')
    eq(false, reg.modules.mylib_method.regname, 'a NULL registration: a method table')
    eq('version', reg.values[1].name)
    local with = {}
    for _, f in ipairs(PM.registrations(dir, { LJ_HASFFI = true }).funcs) do with[f.cname] = true end
    ok(with.mylib_ffionly, 'and read when it has')
end)

test('packmap message join: a LuaJIT message ASSEMBLES from a pack unit\'s literals — parts, composition with LuaJIT\'s own fillers — and generic pieces never match', function ()
    local fillers = { 'call', 'concatenate', 'perform arithmetic on' }
    -- the pack builds it from parts; LuaJIT's is one text
    ok(PM.assembles("'for' initial value must be a number", { "'for' ", 'initial value', ' must be a number' }, fillers))
    -- LuaJIT COMPOSES: "attempt to %s a %s value" with OPCALL's "call"
    ok(PM.assembles('attempt to %s a %s value', { 'attempt to call a ', ' value' }, fillers))
    -- a slot-free text inside the pack's composed literal
    ok(PM.assembles('perform arithmetic on', { 'attempt to perform arithmetic on a ' }, fillers))
    -- the NAMED form is not the unnamed one's text (CART-1207: LuaJIT names the variable, the pack does not)
    ok(not PM.assembles("attempt to %s %s '%s' (a %s value)", { 'attempt to call a ', ' value' }, fillers))
    -- too little fixed text to mean anything
    ok(not PM.assembles("'%s' expected", { ' expected' }, fillers))
    ok(not PM.assembles('attempt to compare %s with %s', { 'attempt to ' }, fillers))
end)

test('packmap kinds (CART-1235): a pack entry is transliterated only when its OWN text names a generated binding — reaching one through a shared helper is not; and a registered function absent from the pack takes no C-side kind', function ()
    local static = { generated = { SCAN = 'strscan' }, host = {} }
    local seen = { SCAN = true, coerce = true }
    local texts = { 'function coerce(v) { return SCAN.tonum(v); }' }
    eq('hand-written', (PM.kind_of(static, seen, texts, '(a, b) => coerce(a) & coerce(b)')), 'bit.band reaches the scanner only through its argument coercion')
    eq({ 'transliterated', 'strscan' }, { PM.kind_of(static, seen, texts, '(v) => SCAN.tonum(v)') })
    eq(nil, PM.row_kind(false, nil, 'transliterated'), 'absent from the pack: no kind')
    eq('host', PM.row_kind(true, 'host', 'partial'))
    eq('refused', PM.row_kind(true, 'refused', 'transliterated'))
    eq('partial', PM.row_kind(true, 'hand-written', 'partial'), 'present and hand-written by the pack\'s reading: the C side decides')
end)

test('packmap: a pack unitt\'s string literals are read by javascript\'s grammar — an apostrophe in a comment does not shift them', function ()
    local s = PM.js_strings("const f = x => { // LuaJIT's rule\n  throw new LuaError('attempt to concatenate a ' + t + ' value'); };")
    eq({ 'attempt to concatenate a ', ' value' }, s)
    -- a bare arrow function (a function's toString) is read as an expression
    eq({ '__index' }, PM.js_strings("(t, k) => meta(t, '__index')"))
    -- an ANONYMOUS function expression is no statement — the grammar recovers and still yields its literals
    eq({ '__call', 'x' }, PM.js_strings("function (f) { return meta(f, '__call') || 'x'; }"))
end)
