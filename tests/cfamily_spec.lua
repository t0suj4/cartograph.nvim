-- CART-1079: C and C++ are one linkage family in the name join. A bare call reaches a FREE function across the two;
-- a C++ function needs extern "C" evidence (its definition or a header prototype); a method and a namespaced function never. Fixture: tests/fixtures/cfamily.

local ts = require 'cartograph.providers.treesitter'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/cfamily'
local memo
local function calls()
    if memo then return memo end
    local data = ts.extract(FIX)
    memo = {}
    for _, c in ipairs(data.calls) do memo[c.file .. ':' .. (c.line + 1) .. ':' .. c.callee] = c end
    return memo
end

test('cfamily: a .cpp call through an extern "C" header reaches the .c definition (inferred tier)', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    local c = calls()['main.cpp:4:cfun']
    eq('lib.c::cfun@0', c.to)
    eq(true, c.inferred)
end)

test('cfamily: a .c call reaches an extern "C" free function defined in C++', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    eq('util.cpp::cppfree@1', calls()['main2.c:4:cppfree'].to)
end)

test('cfamily: a C++ METHOD and a NAMESPACED function are not callable from C', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    local c = calls()
    eq(nil, c['main2.c:5:draw'].to, 'Widget::draw is a method')
    eq(nil, c['main2.c:6:nsfun'].to, 'ns::nsfun has C++ linkage')
end)

test('cfamily: C linkage from a header prototype is enough; a plain C++ function with none is not callable from C', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    local c = calls()
    eq('util.cpp::cpp2@2', c['main2.c:7:cpp2'].to, 'declared in lib.h inside extern "C", defined plain')
    eq(nil, c['main2.c:8:cppplain'].to, 'no extern "C" anywhere: C++ linkage')
end)

test('cfamily: a .c definition has C linkage even when the header spells extern "C" through a MACRO (BEGIN_DECLS)', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    eq('raw.c::craw@0', calls()['main.cpp:6:craw'].to)
end)

test('cfamily: a QUALIFIED C++ call does not name a C function; a method in a HEADER is still a method', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    local c = calls()
    eq(nil, c['main.cpp:7:craw'].to, 'ns2::craw(5): a scope qualifier, C has none')
    eq(nil, c['main2.c:9:paint'].to, 'Canvas::paint is defined in canvas.h: the header shortcut is for free functions')
end)

test('cfamily: a C MEMBER call through a function pointer (s->cppfree) is not the C++ function of that name', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    eq(nil, calls()['main2.c:10:cppfree'].to)
end)

-- CART-1081: file-local by LINKAGE. Same-language C calls are the point here, not the bridge.
test('cfamily: a C `static` and a macro defined in a .c file resolve in their own file and nowhere else', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    local c = calls()
    eq('lib.c::hidden@1', c['lib.c:4:hidden'].to, 'same file')
    ok(c['lib.c:4:LOCALMAC'].to ~= nil, 'same file macro')
    eq(nil, c['other.c:3:hidden'].to, 'another C file cannot name a static')
    eq(nil, c['other.c:4:LOCALMAC'].to, 'a macro defined in lib.c does not exist in other.c')
    eq(nil, c['main.cpp:5:hidden'].to, 'nor can a C++ file, through the bridge')
end)

test('cfamily: a header static inline IS visible to its includers (textual inclusion)', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    eq('lib.h::inl@9', calls()['other.c:5:inl'].to)
end)

test('cfamily: a static MEMBER function has class linkage, not file linkage', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    local m = calls()['main.cpp:8:make']
    ok(m.to and m.to:find('Reg::make', 1, true), vim.inspect({ to = m.to, refused = m.refused }))
end)

test('cfamily: a UNITY build (a source file #included by another) is not file-local: its statics and macros are shared', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    local c = calls()
    eq('ustring.cpp::uhelper@1', c['uchecker.cpp:1:uhelper'].to, 'umain.cpp includes both files into one unit')
    eq('ustring.cpp::ULIT@0', c['uchecker.cpp:1:ULIT'].to)
end)

test('cfamily: confinement does not make a fit unique when the REAL definition is torn (v8 CHECK, scip SCIP_CALL)', function ()
    if not (parser_available('c') and parser_available('cpp')) then skip 'no c/cpp parser' end
    local c = calls()['caller.c:2:TCHECK']
    eq(nil, c.to, 'bigpriv.h is the only indexed survivor, but logging.h (the included one) is torn')
    eq('ambiguous', c.refused and c.refused.rule)
    eq({ 'bigpriv.h::TCHECK@0', 'logging.h::TCHECK@1' }, c.refused.cands)
    eq('d8.c::TCHECK@0', calls()['d8.c:2:TCHECK'].to, 'the file-local copy still answers its own file')
end)
