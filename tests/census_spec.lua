-- The honesty census: counts by trust tier + refusals grouped by rule (the
-- analyzer work-list). Pure over a data table.

local census = require 'cartograph.census'

local function data()
    return {
        schema = 1, root = '/x',
        nodes = {
            { id = 'm', name = 'm', kind = 'module', file = 'm.lua' },
            { id = 'f', name = 'f', kind = 'function', file = 'm.lua' },
            { id = 'g', name = 'g', kind = 'function', file = 'm.lua' },
            { id = 'x.js::lost@3', name = 'lost', kind = 'function',
                file = 'x.js', unparsed = true },
        },
        edges = {
            { from = 'f', to = 'g', kind = 'ref' },                    -- matched
            { from = 'g', to = 'f', kind = 'ref', inferred = true },   -- ~
            { from = 'f', to = 'g', kind = 'ref', proven = true },     -- proven
            { from = 'm', to = 'm2', kind = 'import' },
        },
        calls = {
            { fn = 'f', callee = 'g', to = 'g', file = 'm.lua', line = 1,
                prov = 'base' },
            { fn = 'f', callee = 'h', file = 'm.lua', line = 2,
                refused = { rule = 'ambiguous-name', n = 2 } },
            { fn = 'g', callee = 'h', file = 'm.lua', line = 5,
                refused = { rule = 'ambiguous-name', n = 2 } },
            { fn = 'g', callee = 'k', file = 'm.lua', line = 6,
                refused = { rule = 'dynamic-key' } },
            { fn = 'g', callee = 'print', file = 'm.lua', line = 7 },
            { fn = 'g', callee = 'q', to = 'g', file = 'm.lua', line = 8,
                prov = 'self', hedge = { rule = 'shadow-walkout' } },
        },
    }
end

test('census: counts by kind, tier, and rule', function ()
    local c = census.take(data())
    eq(4, c.nodes.total)
    eq(3, c.nodes.by_kind['function'])
    eq(1, c.nodes.unparsed)
    eq(4, c.edges.total)
    eq(3, c.edges.by_kind.ref)
    eq(1, c.edges.ref.proven)
    eq(1, c.edges.ref.inferred)
    eq(1, c.edges.ref.matched)
    eq(6, c.calls.total)
    eq(2, c.calls.resolved)
    eq(3, c.calls.refused)
    eq(1, c.calls.unresolved) -- print: outside the corpus, not refused
    eq(1, c.calls.hedged)
    eq(2, c.calls.rules['ambiguous-name'].n)
    eq(1, c.calls.rules['dynamic-key'].n)
    eq(1, c.calls.by_prov['base'])   -- the PROV rollup: one base, one self-pass
    eq(1, c.calls.by_prov['self'])
end)

test('census: the report ranks refusal rules by count', function ()
    local lines = table.concat(census.report(data()), '\n')
    ok(lines:find('refusals by rule'), 'work-list section present')
    -- ambiguous-name (2) must come before dynamic-key (1)
    ok(lines:find('ambiguous%-name.*dynamic%-key'), 'ranked by count')
    ok(lines:find('m.lua:3 h'), 'sample site (1-based line)')
    ok(lines:find('frontier: 1 unparsed'), 'frontier counted')
end)

test('census: disp() gives every call exactly one total disposition', function ()
    eq('resolved', census.disp({ to = 'g' }))
    -- to wins over everything else present
    eq('resolved', census.disp({ to = 'g', refused = { rule = 'x' } }))
    local d, why = census.disp({ refused = { rule = 'ambiguous' } })
    eq('refused', d); eq('ambiguous', why)
    eq('dynamic', census.disp({ dynamic = true }))
    d, why = census.disp({ ext = { disp = 'external', why = 'vocab' } })
    eq('external', d); eq('vocab', why)
    d, why = census.disp({ ext = { disp = 'noise', why = 'short' } })
    eq('noise', d); eq('short', why)
    d, why = census.disp({}) -- silent, untagged (indirect/traced)
    eq('external', d); eq('unknown', why)
end)

test('census: the outside bucket breaks the silent lump down by gate', function ()
    local c = census.take({
        nodes = {}, edges = {},
        calls = {
            { to = 'g' },                                    -- resolved
            { ext = { disp = 'external', why = 'vocab' } },  -- stdlib name
            { ext = { disp = 'external', why = 'vocab' } },
            { ext = { disp = 'external', why = 'no-def' } }, -- no def anywhere
            { ext = { disp = 'noise', why = 'short' } },     -- noise floor
            { dynamic = true },                              -- $fn()
            {},                                              -- untagged
        },
    })
    eq(6, c.calls.unresolved)
    eq(2, c.calls.outside.by_why['vocab'])
    eq(1, c.calls.outside.by_why['no-def'])
    eq(1, c.calls.outside.by_why['short'])
    eq(1, c.calls.outside.by_why['unknown'])
    eq(1, c.calls.outside.by_disp['dynamic'])
    eq(4, c.calls.outside.by_disp['external']) -- 2 vocab + no-def + unknown
    eq(1, c.calls.outside.by_disp['noise'])
    local lines = table.concat(census.report({ nodes = {}, edges = {},
        calls = { { ext = { disp = 'external', why = 'vocab' } } } }), '\n')
    ok(lines:find('outside by gate: vocab 1'), 'gate breakdown line')
end)

-- ── THE INSTRUMENT REPORTING ON ITS OWN CAP (CART-0682) ─────────────────────
-- A refusal keeps at most 8 candidate ids and records the true count as `n`.
-- Until this counter existed, the single number saying how much of the refusal
-- evidence is INCOMPLETE was not reachable from any verb — on an 8k-file Java
-- monorepo it was 21.6% of the refusals carrying a list, and the consumer
-- reading the capped copy was the premise deciding deletability.
test('census: counts the refusals that kept less than they saw', function ()
    local function d(calls)
        return { schema = 1, root = '/x', nodes = {}, edges = {}, calls = calls }
    end
    local c = census.take(d({
        -- kept 2 of 9: the list is a SAMPLE and the record says so
        { fn = 'f', callee = 'h', file = 'm.lua', line = 1,
            refused = { rule = 'ambiguous', cands = { 'a', 'b' }, n = 9 } },
        -- kept 2 of 2: complete, not truncated
        { fn = 'f', callee = 'i', file = 'm.lua', line = 2,
            refused = { rule = 'ambiguous', cands = { 'a', 'b' }, n = 2 } },
        -- a rule that carries no candidate list at all — nothing to truncate
        { fn = 'f', callee = 'j', file = 'm.lua', line = 3,
            refused = { rule = 'dynamic-key' } },
    }))
    eq(3, c.calls.refused)
    eq(1, c.calls.refusals_truncated, 'only the capped one counts')
    eq(1, c.calls.rules['ambiguous'].truncated, 'and it is attributed to its rule')
    eq(0, c.calls.rules['dynamic-key'].truncated)
    local lines = table.concat(census.report(d({
        { fn = 'f', callee = 'h', file = 'm.lua', line = 1,
            refused = { rule = 'ambiguous', cands = { 'a' }, n = 40 } },
    })), '\n')
    ok(lines:find('TRUNCATED'), 'the report says it out loud: ' .. lines)
    ok(lines:find('%(1 truncated%)'), 'and per rule')

    -- ⚠ AN UNCOUNTED LIST IS NOT A TRUNCATED ONE. providers/tokens.lua mints an
    -- `ambiguous` record from an UNCAPPED roster and records no `n`, so a
    -- consumer that reads a missing count as "capped" would report a defect
    -- that is not there. Neither predicate speaks about this record.
    local u = census.take(d({ { fn = 'f', callee = 'h', file = 'm.lua', line = 1,
        refused = { rule = 'ambiguous', cands = { 'a', 'b' } } } }))
    eq(0, u.calls.refusals_truncated, 'no count recorded is not a claim of truncation')
end)

test('census: truncated and complete are not negations of each other', function ()
    local tsutil = require 'cartograph.spec.tsutil'
    local capped = { rule = 'blocked', cands = { 'a', 'b' }, n = 9 }
    local whole  = { rule = 'blocked', cands = { 'a', 'b' }, n = 2 }
    local silent = { rule = 'blocked', cands = { 'a', 'b' } }
    local none   = { rule = 'samefile' }
    ok(tsutil.truncated(capped) and not tsutil.complete(capped))
    ok(tsutil.complete(whole) and not tsutil.truncated(whole))
    -- the third state, and the reason there are two predicates: a record with no
    -- count supports NEITHER argument. `truncated` must not block on it (it would
    -- invent a defect) and `complete` must not license on it (it would quantify
    -- over a list it cannot prove whole).
    ok(not tsutil.truncated(silent) and not tsutil.complete(silent))
    ok(not tsutil.truncated(none) and not tsutil.complete(none))
end)

-- ── THE PER-NAME ATTRIBUTION, AND WHY IT IS OPT-IN (CART-0803) ────────────
-- `tools/levers.lua` ranked strategic levers by the census GATE that stopped
-- each unresolved call, and could not see its own largest lever on either big
-- JS corpus: ghost's test framework arrives through `short` (`it`, 9219 calls)
-- and `no-def` (`expect`, `describe`) at once, so one bloc showed up as two
-- unrelated buckets. The fix needs per-callee attribution, which is a table
-- proportional to the unresolved population — so it is asked for, not paid for
-- by the ten other consumers, several of which run inside the corpus gates.
local function twogate()
    return {
        schema = 1, root = '/x',
        nodes = {}, edges = {},
        calls = {
            -- ONE name, TWO gates, two files: the shape the ticket is about
            { fn = 'f', callee = 'it', file = 'test/a.js', line = 1,
                ext = { disp = 'external', why = 'short' } },
            { fn = 'f', callee = 'it', file = 'test/a.js', line = 2,
                ext = { disp = 'external', why = 'short' } },
            { fn = 'g', callee = 'it', file = 'test/b.js', line = 1,
                ext = { disp = 'external', why = 'no-def' } },
            { fn = 'g', callee = 'expect', file = 'test/b.js', line = 2,
                ext = { disp = 'external', why = 'no-def' } },
            -- a dynamic call has no gate at all
            { fn = 'g', callee = 'dyn', file = 'test/b.js', line = 3,
                dynamic = true },
            -- and neither a resolved nor a refused call is in the bucket
            { fn = 'f', callee = 'h', to = 'h', file = 'src/c.js', line = 1 },
            { fn = 'f', callee = 'k', file = 'src/c.js', line = 2,
                refused = { rule = 'ambiguous' } },
        },
    }
end

test('census: the per-name outside breakdown is opt-in', function ()
    local off = census.take(twogate())
    eq(nil, off.calls.outside.by_name, 'absent unless asked for')
    eq(nil, off.calls.outside.by_file)
    -- and the aggregate it sits beside is unchanged either way
    local on = census.take(twogate(), { names = true })
    eq(off.calls.unresolved, on.calls.unresolved)
    eq(off.calls.outside.by_why['short'], on.calls.outside.by_why['short'])
    ok(on.calls.outside.by_name, 'present when asked for')
end)

test('census: a name keeps its FULL gate histogram, not a first-seen gate', function ()
    local c = census.take(twogate(), { names = true })
    local it = c.calls.outside.by_name['it']
    eq(3, it.n)
    -- THE POINT OF THE TICKET: collapsing this to one `why` would rebuild in
    -- miniature the bug the ticket is about — a bloc split across two gates
    eq(2, it.why['short'])
    eq(1, it.why['no-def'])
    eq(2, it.nfiles)
    eq(2, it.files['test/a.js'])
    eq(1, it.files['test/b.js'])
    -- a dynamic call has no gate, so it is keyed by its DISPOSITION rather than
    -- dropped: the histogram stays total and the consumer excludes it the same
    -- way the lever ranking excludes `by_disp.dynamic`
    eq(1, c.calls.outside.by_name['dyn'].why['dynamic'])
    -- resolved and refused calls are not in this bucket at all
    eq(nil, c.calls.outside.by_name['h'])
    eq(nil, c.calls.outside.by_name['k'])
end)

test('census: by_file is the denominator, and it keeps the opaque share apart', function ()
    local c = census.take(twogate(), { names = true })
    local f = c.calls.outside.by_file
    eq(2, f['test/a.js'].n)
    eq(0, f['test/a.js'].dyn)
    -- b.js holds `it`, `expect` and one dynamic call
    eq(3, f['test/b.js'].n)
    eq(1, f['test/b.js'].dyn)
    -- ★ THE MEASURE THIS DENOMINATOR EXISTS FOR: co-occurrence alone said our
    -- own lua/ holds five blocs, because a uniformly-spread population is
    -- trivially self-contained. What tells a real bloc from a slice of one is
    -- whether its files are DEDICATED to it, and that needs a per-file total
    -- the per-name view cannot supply.
    eq(nil, f['src/c.js'], 'a file whose calls all resolved or were refused')
end)
