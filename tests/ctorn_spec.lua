-- CART-1084: C/C++ defs are torn by damaged CONTEXT, not by position after a file's first parse error.
-- Fixture: tests/fixtures/ctorn. blk.h opens with v8's instruction.h shape (a macro in the base clause makes error
-- recovery parse the class body as a FUNCTION body); everything after it used to be torn.

local ts = require 'cartograph.providers.treesitter'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/ctorn'
local memo
local function graph()
    if memo then return memo end
    local data = ts.extract(FIX)
    memo = { nodes = {}, calls = {} }
    for _, n in ipairs(data.nodes) do memo.nodes[n.id] = n end
    for _, c in ipairs(data.calls) do memo.calls[c.file .. ':' .. (c.line + 1) .. ':' .. c.callee] = c end
    return memo
end

test('ctorn: a free function, an out-of-class method and a macro AFTER an early parse error are indexed', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local g = graph()
    eq(nil, g.nodes['blk.h::freefn@8'].torn)
    eq(nil, g.nodes['blk.h::Blk2::meth@9'].torn)
    eq('blk.h::freefn@8', g.calls['use.cpp:3:freefn'].to)
    eq('blk.h::TMAC@10', g.calls['use.cpp:5:TMAC'].to)
end)

test('ctorn: an inline method whose class body was parsed as a FUNCTION body stays torn (its class is lost)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local g = graph()
    eq(true, g.nodes['blk.h::successors@4'].torn, 'nested in a bogus function_definition')
    eq(nil, g.calls['use.cpp:4:successors'].to, 'a torn def never answers a name match')
end)

test('ctorn: a macro defined inside a function body is still a file-scope macro (self-contained, not torn)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local g = graph()
    eq('blk.h::INNERMAC@12', g.calls['use.cpp:6:INNERMAC'].to)
end)

test('ctorn: an error INSIDE a function body does not tear it (its head, and so its name, is intact)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local g = graph()
    eq(nil, g.nodes['blk.h::bodyerr@15'].torn)
    eq('blk.h::bodyerr@15', g.calls['use.cpp:7:bodyerr'].to)
end)

test('ctorn: an error in a function\'s HEAD (its parameter list) tears it, as it always did', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local g = graph()
    eq(true, g.nodes['blk.h::headbad@19'].torn)
    eq(nil, g.calls['use.cpp:8:headbad'].to)
end)

test('ctorn: a macro whose has_error() is set with NO error node below (comments in a continued #define) is not torn', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local g = graph()
    eq(nil, g.nodes['blk.h::PHANTOM_MUL@20'].torn, 'luanti mini-gmp.c gmp_umul_ppmm, verbatim')
    eq('blk.h::PHANTOM_MUL@20', g.calls['use.cpp:10:PHANTOM_MUL'].to)
end)

test('ctorn: a def nested in a function body by preprocessor-split braces is kept when its name is QUALIFIED (v8 ppc LoadPC)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local g = graph()
    eq(nil, g.nodes['split.cpp::Qual::later@16'].torn, 'Qual::later names its own class, wherever the tree put it')
    eq(true, g.nodes['split.cpp::unqual_after@18'].torn, 'an unqualified name nested in a body may have lost its class')
end)

test('ctorn: the structural check spares a def cartograph NAMED with its class (v8 JSCallReducerAssembler::ReceiverInput)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local tsutil = require 'cartograph.spec.tsutil'
    local src = table.concat(vim.fn.readfile(FIX .. '/blk.h'), '\n')
    local root = vim.treesitter.get_string_parser(src, 'cpp'):parse()[1]:root()
    -- `int& successors()` on line 5 sits inside the class body that error recovery parsed as a FUNCTION body
    local d = root:named_descendant_for_range(4, 10, 4, 10)
    while d and d:type() ~= 'function_definition' do d = d:parent() end
    ok(d ~= nil, 'found the def')
    eq(true, tsutil.c_torn_context(d, 'successors'), 'unqualified: its class may be lost')
    eq(false, tsutil.c_torn_context(d, 'InstructionBlock::successors'), 'named with its class: identity intact')
end)
