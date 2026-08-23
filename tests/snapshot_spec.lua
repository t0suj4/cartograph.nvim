-- tools/snapshot: the faithfulness invariant — a slim snapshot must be
-- indistinguishable FROM THE INSTRUMENTS' POINT OF VIEW: graphdiff of the
-- original vs a save/load round-trip is empty, and the census matches.
-- (tools/ is dev tooling outside the plugin runtime; loaded via dofile.)

local snapshot = dofile('tools/snapshot.lua')
local gd = require 'cartograph.graphdiff'
local census = require 'cartograph.census'

local function fat_data()
    return {
        schema = 1, root = '/x', provider = 'treesitter',
        nodes = {
            { id = 'f', name = 'f', kind = 'function', file = 'm.lua',
                range = { start = { line = 3, char = 0 } }, df = { defs = {} } },
            { id = 'x.js::lost@3', name = 'lost', kind = 'function',
                file = 'x.js', unparsed = true },
        },
        edges = {
            { from = 'f', to = 'g', kind = 'ref', inferred = true,
                at = { start = { line = 4, char = 2 } } }, -- fat: at dropped
            { from = 'f', to = 'g', kind = 'ref', proven = true },
        },
        calls = {
            { fn = 'f', callee = 'g', to = 'g', file = 'm.lua', line = 4,
                args = { 'a' }, argv = { { k = 'lit' } } }, -- fat: args/argv dropped
            { fn = 'f', callee = 'h', file = 'm.lua', line = 5,
                refused = { rule = 'ambiguous', cands = { 'h1', 'h2' }, n = 2 } },
            { fn = 'f', callee = 'k', to = 'k', file = 'm.lua', line = 6,
                hedge = { rule = 'shadow-walkout', row = 2 } }, -- row is fat
        },
    }
end

test('snapshot: slim round-trip is instrument-faithful', function ()
    local data = fat_data()
    snapshot.dir = vim.fn.tempname()
    snapshot.save('spec', data)
    local back, meta = snapshot.load('spec')
    ok(back, 'loads')
    ok(meta and meta.when, 'stamped')
    ok(gd.empty(gd.diff(data, back)), 'graphdiff sees no difference')
    local ca, cb = census.take(data), census.take(back)
    eq(ca.edges.ref.inferred, cb.edges.ref.inferred)
    eq(ca.calls.refused, cb.calls.refused)
    eq(ca.calls.hedged, cb.calls.hedged)
    eq(1, cb.calls.hedged)
    eq(ca.calls.rules['ambiguous'].n, cb.calls.rules['ambiguous'].n)
    eq(ca.nodes.unparsed, cb.nodes.unparsed)
end)

test('snapshot: a missing or corrupt file is a clean miss', function ()
    snapshot.dir = vim.fn.tempname()
    local d, why = snapshot.load('nope')
    eq(nil, d)
    ok(why:find('no snapshot'), why)
    vim.fn.mkdir(snapshot.dir, 'p')
    local fd = assert(io.open(snapshot.dir .. '/bad.snapshot.mpack', 'wb'))
    fd:write('garbage') fd:close()
    local d2, why2 = snapshot.load('bad')
    eq(nil, d2)
    ok(why2:find('corrupt'), why2)
end)

-- ── THE TOOL SIDE OF A BASELINE'S IDENTITY (CART-0502) ────────────────────
-- Three of 37 gated corpora were red on clean main because their baselines
-- predated an extraction change and nothing said so. The corpus side of the
-- snapshot records rev + dirty and the gate has a note for each; these are the
-- two fields that give the TOOL side the same vocabulary.

test('snapshot: the meta records the EXTRACTION epoch, not just the git rev', function ()
    local data = fat_data()
    snapshot.dir = vim.fn.tempname()
    snapshot.save('spec', data)
    local _, meta = snapshot.load('spec')
    ok(meta, 'meta present')
    eq(require('cartograph.cache').VERSION, meta.cache_version)
    -- THE CONFLATION THIS GUARDS: the blob's own `version` is the SNAPSHOT
    -- FORMAT version (1) and has nothing to do with extraction behaviour. A
    -- reader that took the format version for the epoch would believe every
    -- baseline ever written came from v1.
    ok(meta.cache_version ~= 1 or require('cartograph.cache').VERSION == 1,
        'the epoch is not the format version')
    -- tool_dirty is TRI-STATE in the same sense as the corpus fields: absent
    -- means clean, and it must never be the string a shell would hand back
    ok(meta.tool_dirty == nil or meta.tool_dirty == true, 'boolean or absent')
end)

test('snapshot: the tool verdict names the era, and MISSING is not MISMATCHED', function ()
    local V = require('cartograph.cache').VERSION
    -- a baseline from this era vouches for itself: no sentence at all
    local e, d = snapshot.tool_verdict({ cache_version = V })
    eq(nil, e); eq(nil, d)
    -- an OLDER era: the diff is a mixture, and the sentence has to say so rather
    -- than let a reader call it extractor drift
    -- a LITERAL other era, not V-1: the test must exercise the mismatch branch
    -- without doing arithmetic on a live constant it does not own
    local e2 = snapshot.tool_verdict({ cache_version = 'v0' })
    ok(e2 and e2:find('MIXES'), tostring(e2))
    ok(e2:find('v0') and e2:find(tostring(V)), 'names both eras')
    -- ABSENT is the third case, and it must read as UNKNOWN: every baseline
    -- written before the field existed lacks it, so treating it as a mismatch
    -- would flag the entire 37-corpus roster at once
    local e3 = snapshot.tool_verdict({})
    ok(e3 and e3:find('no extraction VERSION'), tostring(e3))
    ok(not e3:find('MIXES'), 'unknown is not a mismatch')
    -- the dirty half is independent of the era half
    local e4, d4 = snapshot.tool_verdict({ cache_version = V, tool_dirty = true })
    eq(nil, e4)
    ok(d4 and d4:find('UNCOMMITTED'), tostring(d4))
    eq(nil, (snapshot.tool_verdict(nil)))
end)

-- ★ THE OCCURRENCE COUNT IS A FENCED FACT (CART-0531). It was not, and the blind
-- spot had already hidden a real defect: v145 found every call site in the
-- affected languages recorded TWICE, and all 37 gates read "graphs are
-- identical" through it.
test('snapshot: an occurrence-count change is VISIBLE to the diff', function ()
    local a = fat_data()
    local b = fat_data()
    -- same endpoints, same kind, same trust — one more sighting
    -- a LIST of ranges, which is the contract (validate iterates ipairs(e.at));
    -- the fixture above writes edges[1].at as a single range, so slim it first
    a.edges[1].at = { { start = { line = 4, char = 2 }, ['end'] = { line = 4, char = 5 } } }
    b.edges[1].at = { { start = { line = 4, char = 2 }, ['end'] = { line = 4, char = 5 } },
        { start = { line = 9, char = 2 }, ['end'] = { line = 9, char = 5 } } }
    local d = gd.diff(snapshot.slim(a), snapshot.slim(b))
    ok(not gd.empty(d), 'a second occurrence of the same edge is a difference')
    eq(1, #d.edges.changed)
    ok(d.edges.changed[1]:find('x1') and d.edges.changed[1]:find('x2'),
        'the report names both counts: ' .. tostring(d.edges.changed[1]))
    -- and the identity is untouched: not reported as an add/remove
    eq(0, #d.edges.added)
    eq(0, #d.edges.removed)
end)

test('snapshot: NIL occurrences is not ZERO occurrences', function ()
    local a = fat_data()
    local b = fat_data()
    b.edges[2].at = {} -- has a list, and it is empty
    -- edges[2] carries no `at` at all in the fixture, so this is exactly the
    -- tri-state pair: absent vs present-and-empty. Collapsing them would hide an
    -- edge that LOST its last occurrence.
    local sa, sb = snapshot.slim(a), snapshot.slim(b)
    eq(nil, sa.edges[2].nat)
    eq(0, sb.edges[2].nat)
    ok(not gd.empty(gd.diff(sa, sb)), 'absent and empty are distinguishable')
end)

-- ★ THE CAP. providers/tokens.lua keeps at most 8 occurrences per edge and puts
-- the true total in e.atn. Counting the kept list there would read 8 for every
-- heavily-referenced edge in the four stack-language corpora and hide every
-- change above the cap — this fence, defeated one level down.
test('snapshot: a CAPPED occurrence list reports its true total, not the cap', function ()
    local a = fat_data()
    a.edges[1].at = { { start = { line = 1, char = 0 }, ['end'] = { line = 1, char = 3 } } }
    a.edges[1].atn = 41 -- seen 41 times, 1 kept
    eq(41, snapshot.slim(a).edges[1].nat)
    local b = fat_data()
    b.edges[1].at = a.edges[1].at
    b.edges[1].atn = 42
    ok(not gd.empty(gd.diff(snapshot.slim(a), snapshot.slim(b))),
        'a change ABOVE the cap is visible')
end)

-- ★ THE PROJECTION VERSION (CART-0531), and why it is a THIRD question. Adding
-- `nat` made every baseline written by the older projection diff as
-- `matched => matchedx1` on every edge with occurrences — 1103 phantom changes on
-- jquery — while the EPOCH note stayed silent, correctly, because the extractor
-- had not changed. Without this the reader sees thousands of differences and no
-- explanation, and concludes extractor regression.
test('snapshot: a stale PROJECTION is its own verdict, separate from the epoch', function ()
    local V = require('cartograph.cache').VERSION
    local _, _, proj = snapshot.tool_verdict({ cache_version = V,
        slim_version = snapshot.SLIM_VERSION })
    eq(nil, proj) -- current projection: silent
    local e2, d2, p2 = snapshot.tool_verdict({ cache_version = V, slim_version = 1 })
    ok(p2 and p2:find('DIFFERENT SET OF FIELDS'), tostring(p2))
    -- and it does NOT masquerade as either of the other two facts
    eq(nil, e2)
    eq(nil, d2)
    -- a baseline written before the field existed reads as v1, not as current
    local _, _, p3 = snapshot.tool_verdict({ cache_version = V })
    ok(p3 and p3:find('v1'), 'absent slim_version reads as the first projection')
end)

test('snapshot: save stamps the projection version', function ()
    snapshot.dir = vim.fn.tempname()
    snapshot.save('spec', fat_data())
    local _, meta = snapshot.load('spec')
    eq(snapshot.SLIM_VERSION, meta.slim_version)
end)

-- ★ THE WRITE AXIS IS FENCED (CART-0532). v147 gave python `rw` on 909 use edges
-- and moved 575 var labels from `unclassified` to `const`, and all 37 gates
-- printed "graphs are identical" — the projection carried no write facts at all.
test('snapshot: a write-axis change is VISIBLE to the diff', function ()
    local a = fat_data()
    local b = fat_data()
    b.edges[1].rw = 2 -- the same edge, now known to be a WRITE
    local d = gd.diff(snapshot.slim(a), snapshot.slim(b))
    ok(not gd.empty(d), 'gaining a write classification is a difference')
    eq(1, #d.edges.changed)
    -- ABSENT renders as `w-`, because "no classifier ran" is a different fact
    -- from "measured, and it reads"
    ok(d.edges.changed[1]:find('w-') and d.edges.changed[1]:find('w2'),
        d.edges.changed[1])
end)

test('snapshot: gp is TRI-STATE across the projection', function ()
    local a, b, c = fat_data(), fat_data(), fat_data()
    b.edges[1].gp = false -- computed, and the writes DISAGREED
    c.edges[1].gp = 2     -- computed, and every write agreed on param 2
    eq(nil, snapshot.slim(a).edges[1].gp)
    eq(false, snapshot.slim(b).edges[1].gp)
    eq(2, snapshot.slim(c).edges[1].gp)
    -- and all three are distinguishable, which `e.gp or nil` would have broken
    ok(not gd.empty(gd.diff(snapshot.slim(a), snapshot.slim(b))), 'nil vs false')
    ok(not gd.empty(gd.diff(snapshot.slim(b), snapshot.slim(c))), 'false vs 2')
end)

test('snapshot: the field map is fenced by CARDINALITY, not contents', function ()
    local a, b = fat_data(), fat_data()
    a.edges[1].flds = { [''] = 1 }            -- whole-var only
    b.edges[1].flds = { [''] = 1, name = 2 }  -- a NAMED field appeared
    eq(1, snapshot.slim(a).edges[1].nflds)
    eq(2, snapshot.slim(b).edges[1].nflds)
    ok(not gd.empty(gd.diff(snapshot.slim(a), snapshot.slim(b))),
        'field capture switching on is visible')
end)
