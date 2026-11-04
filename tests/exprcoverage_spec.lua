-- The expression census's COVERAGE (CART-0430) — tools/exprcensus.lua M.coverage + COVERAGE_FLOOR.
--
-- ★ A GREEN ZERO OVER THE WRONG POPULATION. haskell's pin was `total = 0` and the matrix read OK — over 3 of 1696
-- subjects, two C fixtures and a python one, because expr.of refuses every .hs subject and nothing counted the
-- refusals. The `--` branch tested PRESENCE (`fns + methods == 0`), which any stray file dodges. Coverage is the
-- denominator that makes such a number readable, and the floor is what keeps it from being gated.

local ec = dofile('tools/exprcensus.lua')

test('coverage: names harvested / attempted and the refusals by reason, largest first', function ()
    local s, ratio = ec.coverage({ fns = 3, methods = 0, attempted = 1696,
        refused = { ['unsupported:haskell'] = 1693 } })
    eq('covers 3 of 1696 subjects (0.2%); refused unsupported:haskell=1693', s)
    ok(ratio < ec.COVERAGE_FLOOR, 'haskell is below the floor: ' .. ratio)
    local s2 = ec.coverage({ fns = 10, methods = 5, attempted = 17, refused = { raised = 1, ['no-function-node'] = 1 } })
    eq('covers 15 of 17 subjects (88.2%); refused no-function-node=1 raised=1', s2, 'ties sort by name')
end)

test('coverage: a corpus with nothing refused prints no refusal clause and covers 100%', function ()
    local s, ratio = ec.coverage({ fns = 395, methods = 0, attempted = 395, refused = {} })
    eq('covers 395 of 395 subjects (100.0%)', s)
    eq(1, ratio)
end)

test('coverage: the floor is a majority — a census must speak for most of its corpus to be gated', function ()
    eq(0.5, ec.COVERAGE_FLOOR)
    local _, at = ec.coverage({ fns = 50, methods = 0, attempted = 100, refused = { ['unsupported:x'] = 50 } })
    ok(not (at < ec.COVERAGE_FLOOR), 'exactly half is AT the floor, not below it')
end)

test('check: a subject expr.of refuses is COUNTED by reason, not dropped', function ()
    if not (parser_available('haskell') and parser_available('python')) then skip 'no haskell/python parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function put(rel, text) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close() end
    put('M.hs', 'module M where\nf :: Int -> Int\nf x = x + 1\ng :: Int -> Int\ng y = y * 2\n')
    put('h.py', 'def h(a):\n    return a + 1\n')
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local r = ec.check(store)
    vim.fn.delete(root, 'rf')
    eq(1, r.fns, 'the python function is harvested')
    ok(r.attempted >= 3, 'every function subject was attempted: ' .. tostring(r.attempted))
    eq(r.attempted - 1, r.refused['unsupported:haskell'], 'the haskell ones are refused BY NAME: ' .. vim.inspect(r.refused))
end)
