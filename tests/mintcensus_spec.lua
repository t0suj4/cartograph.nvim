-- tools/mintcensus.lua's own guards (CART-0927 / CART-0926).
--
-- ★★★ WHAT IT MEASURES IS CHEAP TO GET WRONG IN THE FLATTERING DIRECTION. The
-- census subtracts the MINTED set from every function-typed node in the parse
-- tree; a bug that leaves something out of the minted set reports a gap that is
-- not there, and a bug in the walk reports no gap where there is one. ⚠ AND A
-- TEST THAT ONLY PINS THE POSITIVE CASES — "these shapes are unminted" — PASSES
-- JUST AS WELL FOR A CENSUS THAT REPORTS EVERYTHING. Both directions are pinned
-- below, which is the [[test-the-premise-not-the-consequence]] rule: pin a
-- predicate on BOTH sides or a dead one passes every negative test.
--
-- The seven positions came from a corpus (163 in this tree, 3031 on wow) and are
-- reproduced here as synthetic fixtures, so the pin does not depend on a corpus
-- the suite cannot see.

local census = dofile(vim.fn.getcwd() .. '/tools/mintcensus.lua')

--- one file, one root, so the parent chain in the row is unambiguous
local function only(src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(src); fd:close()
    -- ⚠ NO store.ingest HERE, DELIBERATELY. `positions` reads extraction's answer
    -- directly and never the store, so nothing carries between fixtures.
    return census.positions(root, 'lua')
end

--- the chain the census prints, minus the language column
local function chain(row) return (row.key:gsub('^%a+%s+', '')) end

--- ★ THE NEGATIVE HALF, AND IT IS THE HALF THAT MATTERS. Each of these is a
--- position one of the four `functions` clauses in spec/lua.lua DOES cover, so a
--- census reporting any of them is over-reporting — the direction that would make
--- every corpus number above meaningless.
test('mintcensus: a position the query DOES cover is not reported', function ()
    local covered = {
        ['function_declaration']   = 'function g() end\nreturn g\n',
        ['local function']         = 'local function l() end\nreturn l\n',
        ['assignment value']       = 'local M = {}\nM.h = function () end\nreturn M\n',
        ['local = function']       = 'local a = function () end\nreturn a\n',
        ['table field, bare key']  = 'local t = { k = function () end }\nreturn t\n',
        ['table field, [IDENT]']   = 'local K = 1\nlocal t = { [K] = function () end }\nreturn t\n',
        ['call argument']          = 'local function f(_) end\nf(function () end)\n',
    }
    for name, src in pairs(covered) do
        local rows, _, defs, unminted = only(src)
        ok(defs > 0, ('the %s fixture has a function-typed node at all'):format(name))
        eq(0, unminted, ('%s is MINTED, so the census reports nothing'):format(name)
            .. (rows[1] and ('  (got: ' .. chain(rows[1]) .. ')') or ''))
    end
end)

--- ★ THE POSITIVE HALF: the seven positions measured on real corpora. The chain
--- is asserted, not just the count — a census that finds the right NUMBER of gaps
--- under the wrong PARENT would send the fix to the wrong clause, which is
--- exactly how CART-0927's 2961 read as one cause when it was four.
test('mintcensus: each measured uncovered position is reported, by its chain', function ()
    local cases = {
        { 'return position',
          'local function t() end\nreturn function () return t() end\n',
          'return_statement < expression_list < function_definition' },
        { 'the IIFE',
          'local x = (function () return 1 end)()\nreturn x\n',
          'function_call < parenthesized_expression < function_definition' },
        -- ⚠ THE STRING-KEY AND NUMBER-KEY CASES USED TO BE HERE AND ARE NOW
        -- MINTED (CART-0927, cache v192). Their removal from this list is the
        -- record of the fix: this spec encoded them as expected gaps, and
        -- closing the gap broke the spec, which is the fence working.
        { 'table field, COMPUTED CALL key',
          'local function k(_) end\nlocal t = { [k(1)] = function () end }\nreturn t\n',
          'table_constructor < field < function_definition' },
        { 'table field, POSITIONAL',
          'local t = { function () end }\nreturn t\n',
          'table_constructor < field < function_definition' },
        { 'under a binary expression',
          'local d\nlocal f = d or function () end\nreturn f\n',
          'expression_list < binary_expression < function_definition' },
    }
    for _, c in ipairs(cases) do
        local rows, _, _, unminted = only(c[2])
        eq(1, unminted, ('%s is UNMINTED'):format(c[1]))
        eq(c[3], chain(rows[1]), ('%s reports its own parent chain'):format(c[1]))
    end
end)

--- ★★ TWO TABLE-FIELD CASES STILL SHARE ONE CHAIN AND ARE TWO DIFFERENT BUGS.
--- That is the finding this tool's numbers could not express: on wow ONE chain
--- held 2961 nodes and FOUR causes, separated only by matching the clause as a
--- template and reading the refusal (2904 `name:string`, 7 `name:number`, 26
--- positional, 24 a computed CALL key). Two are minted now; the remaining two
--- still render identically here. The census is honest about the conflation
--- rather than pretending to resolve it — this pins that the limitation is KNOWN,
--- so a later reader does not take the chain for a diagnosis.
test('mintcensus: one chain can hold several causes — the known limitation', function ()
    local shapes = {
        'local function k(_) end\nlocal t = { [k(1)] = function () end }\nreturn t\n',
        'local t = { function () end }\nreturn t\n',
    }
    local seen = {}
    for _, src in ipairs(shapes) do
        local rows = only(src)
        seen[chain(rows[1])] = (seen[chain(rows[1])] or 0) + 1
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    eq(1, distinct, 'two distinct causes render as ONE parent chain')
    eq(2, seen['table_constructor < field < function_definition'], 'both of them')
end)

--- The denominator is `ts.fn_types(lang)` — a DECLARED claim about what should be
--- a function — and never the extracted nodes. A file whose only function sits in
--- an unminted position has ZERO nodes, so a denominator taken from the nodes
--- would drop exactly the population under test (CART-0918's lesson).
test('mintcensus: a file with NO minted node is still counted', function ()
    local rows, files, defs, unminted = only('return function () end\n')
    eq(1, files, 'the file is walked')
    eq(1, defs, 'its function is counted in the denominator')
    eq(1, unminted, 'and reported as unminted')
    eq('return_statement < expression_list < function_definition', chain(rows[1]))
end)
