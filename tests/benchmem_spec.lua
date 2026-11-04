-- The matrix's `mem` verdict over a whole ROW (CART-0425) — tools/bench.lua mem_verdict.
--
-- ★ THE COLUMN WAS BLIND, NOT MISCALIBRATED. It read the EXTRACT window's peak straight after extraction, so the
-- expr census, dfpar's re-extract and the cache warm-load ran after the only window it sampled: ghost's census at
-- 4256 MB against a 1600 MB budget read OK. budget_mb is an EXTRACT figure (~2x its peak), so it judges extraction;
-- a later phase over it has no budget of its own and must be REFUSED by name, never passed.

local bench = dofile('tools/bench.lua')
local MB = 2 ^ 20

test('mem verdict: extraction within budget and nothing after it rises above — OK', function ()
    local s, d = bench.mem_verdict(1600, 1000 * MB, { { 'expr', 1200 * MB }, { 'dfpar', 900 * MB } })
    eq('OK', s, vim.inspect(d))
    ok(d[2]:find('expr', 1, true), 'the row peak still names its phase: ' .. vim.inspect(d))
end)

test('mem verdict: a LATER phase over the extract budget is refused, named — not passed (RED IF it reads OK)', function ()
    local s, d = bench.mem_verdict(1600, 1160 * MB, { { 'counts', 1160 * MB }, { 'expr', 4256 * MB }, { 'cache', 2000 * MB } })
    eq('~', s, vim.inspect(d))
    ok(d[2]:find('4256 MB', 1, true) and d[2]:find('expr', 1, true), 'the census phase and its peak are named: ' .. d[2])
    ok(d[3]:find('CART-0425', 1, true), 'and why it is not gated')
end)

test('mem verdict: extraction itself over budget is a FAIL, whatever came after', function ()
    local s = bench.mem_verdict(1600, 1700 * MB, { { 'expr', 1800 * MB } })
    eq('FAIL', s)
end)

test('mem verdict: no later samples — the extract peak alone decides', function ()
    eq('OK', (bench.mem_verdict(1600, 1500 * MB, {})))
    eq('OK', (bench.mem_verdict(1600, 1500 * MB, nil)))
end)
