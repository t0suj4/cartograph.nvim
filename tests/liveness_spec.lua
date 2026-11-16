-- CART-1927: the oracle-liveness collector over the matrix's cells (tools/liveness.lua). Every cell states the
-- population its oracle looked at; a verdict over nothing is SILENT, a verdict with no population UNSTATED, the same
-- population on corpora of very different size FLAT — and a decline is listed with its reason.

local live = dofile('tools/liveness.lua')

local function row(corpus, items, cells) return { corpus = corpus, items = items, cells = cells } end
local P = function (n, unit) return { n = n, unit = unit or 'fns' } end

test('liveness: spoke with its range, declined grouped by reason, SILENT, UNSTATED — and mem is no oracle (CART-1927)', function ()
    local rows = {
        row('a', 100, { rows = { s = 'OK', p = P(10) }, fold = { s = '--', d = { 'flow arrives FOLDED' } },
            silent = { s = 'OK', p = P(0, 'calls') }, xlang = { s = 'OK' }, mem = { s = 'OK' } }),
        row('b', 900, { rows = { s = 'FAIL', p = P(90) }, fold = { s = '--', d = { 'flow arrives FOLDED' } },
            silent = { s = 'OK', p = P(5, 'calls') }, xlang = { s = '--' }, mem = { s = 'OK' } }),
    }
    local lines, soft = live.render(rows, { 'rows', 'fold', 'silent', 'xlang', 'mem' })
    local by = {}
    for _, l in ipairs(lines) do local c = l:match('^  (%S+)'); if c then by[c] = l end end
    ok(by.rows:find('spoke 2 (10..90 fns)', 1, true), by.rows)
    ok(by.fold:find('declined 2 [flow arrives FOLDED]', 1, true), by.fold)
    ok(by.silent:find('SILENT: a', 1, true) and by.silent:find('spoke 1', 1, true), by.silent)
    ok(by.xlang:find('UNSTATED: a', 1, true) and by.xlang:find('[(no reason given)]', 1, true), by.xlang)
    eq(nil, by.mem, 'mem is a measurement of the run, not an oracle over a population')
    eq(true, soft, 'a SILENT or UNSTATED oracle makes the run soft-fail')
end)

test('liveness: FLAT — one population on 3+ corpora whose sizes differ 2x+ has not been exercised; a growing one has (CART-1927)', function ()
    local flat = { row('a', 100, { key = { s = 'OK', p = P(58, 'sites') } }), row('b', 800, { key = { s = 'OK', p = P(58, 'sites') } }),
        row('c', 5000, { key = { s = 'OK', p = P(58, 'sites') } }) }
    local lines, soft = live.render(flat, { 'key' })
    ok(lines[2]:find('FLAT: 58 sites on every corpus while they range 100..5000 items', 1, true), lines[2])
    eq(true, soft)
    local same_size = { row('a', 100, { key = { s = 'OK', p = P(58) } }), row('b', 120, { key = { s = 'OK', p = P(58) } }),
        row('c', 150, { key = { s = 'OK', p = P(58) } }) }
    eq(nil, (live.flat(live.collect(same_size, { 'key' }).key.spoke)), 'corpora of one size cannot show it')
    local grows = { row('a', 100, { key = { s = 'OK', p = P(5) } }), row('b', 800, { key = { s = 'OK', p = P(40) } }),
        row('c', 5000, { key = { s = 'OK', p = P(300) } }) }
    local _, soft2 = live.render(grows, { 'key' })
    eq(false, soft2, 'a population that grows with the corpus is alive')
end)
