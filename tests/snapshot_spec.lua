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
