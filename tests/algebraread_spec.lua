-- THE LOSSLESS READER (CART-0961): source text → algebra term, and back.
--
-- ★★★ THE LAW IS THE TEST. A reader is lossless iff `cst_print(read(src)) == src`
-- byte for byte, and that is decidable on every file we own — so the first test
-- is not a sample, it is the definition run over all 231 files under `lua/`.
--
-- ⚠ AND IT IS A DEAD PIN FOR THE FAILURE THAT MATTERS MOST, which is why the
-- rest of this file exists. A tree-sitter MISSING node is zero-width: a term
-- built over a truncated source prints back to that source exactly, so identity
-- PASSES on input the reader did not understand. Identity proves the gaps are
-- placed right; it proves nothing about whether the tree was whole.

local alg = require 'cartograph.algebra'
local R = require 'cartograph.algebraread'

local function algebra()
    local A, why = alg.load()
    if not A then skip('the algebra is unavailable: ' .. tostring(why)) end
    return A
end

test('lossless reader: cst_print(read(src)) == src over every file in lua/', function ()
    algebra()
    local r = R.identity('lua')
    ok(r.files > 200, 'the corpus is the whole tree, not a sample: ' .. r.files .. ' files')
    local names = {}
    for i, b in ipairs(r.bad) do names[i] = ('%s — %s'):format(b[1], b[2]) end
    eq(0, #r.bad, 'files that do not round-trip:\n    ' .. table.concat(names, '\n    '))
    eq(r.files, r.ok, ('%d of %d files round-trip (%d KB)')
        :format(r.ok, r.files, math.floor(r.bytes / 1024)))
end)

--- ★★★ THE GAPS ARE THE WHOLE OF "LOSSLESS", and the corpus CANNOT SEE the
--- hardest ones. Leading and trailing whitespace lie outside the root node's own
--- range, so they are added around the root rather than between kids. MEASURED:
--- disable that handling and the test above still passes on all 231 files —
--- every file we own starts with a token and ends where the root ends, so the
--- whole-corpus law is silent on it. A fence describes its instances, not its
--- class; these nine cases are the class.
test('lossless reader: the shapes a tree-walk alone would lose', function ()
    local A = algebra()
    local cases = {
        { 'an empty file', '' },
        { 'whitespace only', '\n\n   \n' },
        { 'a leading comment and a gap', '-- hi\n\n\nlocal x = 1\n' },
        { 'no trailing newline', 'local x = 1' },
        { 'trailing blank lines', 'local x = 1\n\n\n' },
        { 'CRLF line endings', 'local x = 1\r\nlocal y = 2\r\n' },
        { 'a long-bracket string holding ]]', 'local s = [==[\nraw ]] text\n]==]\n' },
        { 'non-ASCII and tabs', 'local s = "h\195\169llo \226\128\148 ok"\t-- tab\n' },
        { 'a leading # line', '#!/usr/bin/env lua\nlocal x = 1\n' },
    }
    for _, c in ipairs(cases) do
        local t, why = R.read(c[2])
        ok(t ~= nil, c[1] .. ' reads: ' .. tostring(why))
        if t then eq(c[2], A.cst_print(t), c[1] .. ' round-trips') end
    end
end)

--- ★★★ THE ONE IDENTITY CANNOT SEE. `local s = "abc` makes tree-sitter insert a
--- MISSING `"` of width 0 — the term prints back to the source exactly, so a
--- reader that only checked the law would report this file as read. The read
--- must REFUSE, and it must refuse BY NAME rather than return a half-tree.
--- ⚠ PINNED ON THE OUTCOME, NOT ON WHICH FENCE FIRED. Today `has_error()`
--- catches it and the explicit `missing()` check is unreachable behind it; if an
--- nvim upgrade stops flagging the tree, the second fence takes over and this
--- test must still pass.
test('lossless reader: a truncated source REFUSES, though it would print clean', function ()
    local A = algebra()
    for _, src in ipairs { 'local s = "abc', 'if x then\n', 'local t = {\n', 'function f()\n' } do
        local t, why = R.read(src)
        eq(nil, t, ('%q must not read as a term'):format(src))
        ok(type(why) == 'string' and why ~= '', 'and it says why: ' .. tostring(why))
    end
    -- the trap itself, stated: the term a naive reader would build DOES satisfy
    -- the law, so the law can never be the guard for this case
    local whole = R.read('local s = "abc"')
    ok(whole ~= nil and A.cst_print(whole) == 'local s = "abc"',
        'the same source, terminated, reads and round-trips')
end)

--- ★ A NODE TYPE IS THE TERM'S KIND, so a grammar with a type named `pair` or
--- `name` would mint terms indistinguishable from the algebra's own. No grammar
--- bundled with Neovim collides, so the guard is pinned by adding a type `lua`
--- really produces — otherwise this fence would ship unexercised.
test('lossless reader: a node type colliding with an algebra kind REFUSES by name', function ()
    algebra()
    local saved = R.RESERVED.chunk
    R.RESERVED.chunk = true            -- `chunk` is lua's root node type
    local t, why = R.read('local x = 1\n')
    R.RESERVED.chunk = saved
    eq(nil, t, 'a colliding type must not mint a term')
    ok(type(why) == 'string' and why:find('chunk', 1, true),
        'and the refusal names the type: ' .. tostring(why))
    ok(type(why) == 'string' and why:find('collides', 1, true),
        'and says what it collided with: ' .. tostring(why))
    -- restored, so the guard is off again
    ok(R.read('local x = 1\n') ~= nil, 'the set is restored, not left mutated')
end)

--- ★★★ THE ACCEPTANCE CRITERION FOR THE WHOLE TICKET. `cartograph.algebra.origin`
--- lists `M.parsers.lua` as UNPORTED: without it the donor's `lua` grammar
--- answers nil and every operator reading a term from source is unavailable.
--- This is the assertion that the hook is wired, and it goes through the GRAMMAR
--- rather than the module, because the grammar is what the algebra's own
--- operators call.
test('lossless reader: the `lua` grammar parses through our hook', function ()
    local A = algebra()
    ok(type(A.parsers) == 'table' and type(A.parsers.lua) == 'function',
        'A.parsers.lua is installed')
    local g = A.grammars and A.grammars.lua
    ok(type(g) == 'table' and type(g.parse) == 'function', 'the grammar has a parse')
    local src = 'local function f(a)\n    return a + 1\nend\n'
    local t = g.parse(src)
    ok(t ~= nil, 'the grammar reads source')
    eq(src, A.cst_print(t), 'and what it reads prints back byte for byte')
end)

--- ⚠ AN ABSENT GRAMMAR IS UNAVAILABLE, NOT A CRASH AND NOT AN EMPTY TERM — the
--- same split the rest of the seam draws. `lang` is exposed but only `lua` is
--- audited, and this is what an unaudited caller gets when the parser is missing.
test('lossless reader: a language with no parser is named, not fatal', function ()
    algebra()
    local t, why = R.read('anything at all', 'no_such_language_xyz')
    eq(nil, t)
    ok(type(why) == 'string' and why:find('no tree-sitter parser', 1, true),
        'the reason names the absence: ' .. tostring(why))
end)
