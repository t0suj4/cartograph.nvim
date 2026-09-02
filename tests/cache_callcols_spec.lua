-- Cache × callcols (record-fold arc, brick 3). The cache saves PRE-INGEST
-- records; the columnar view installs at ingest AFTER a warm load. This pins the
-- production flow: save records → warm load → ingest with the flag on → the store
-- is the columnar view and every call reads back faithfully. (Saving POST-ingest
-- data is unsupported for BOTH flag states — fold accessors like n._flow carry
-- functions — so it is deliberately NOT exercised here.)

local store = require 'cartograph.store'
local cache = require 'cartograph.cache'
local callrec = require 'cartograph.callrec'
local config = require 'cartograph.config'

local R = { start = { line = 1, char = 0 }, ['end'] = { line = 1, char = 3 } }

local function sample_graph(root)
    return {
        schema = 1, root = root, provider = 'test',
        stamps = { ['a.lua'] = 'sA', ['b.lua'] = 'sB' },
        nodes = {
            { id = 'a.lua', name = 'a.lua', kind = 'module', file = 'a.lua', order = -1, range = R },
            { id = 'a.lua::f@1', name = 'f', kind = 'function', file = 'a.lua', order = 1, range = R },
            { id = 'b.lua', name = 'b.lua', kind = 'module', file = 'b.lua', order = -1, range = R },
            { id = 'b.lua::g@1', name = 'g', kind = 'function', file = 'b.lua', order = 1, range = R },
        },
        edges = { { from = 'a.lua::f@1', to = 'b.lua::g@1', kind = 'ref', at = { R } } },
        calls = {
            { fn = 'a.lua::f@1', callee = 'g', file = 'a.lua', line = 1, to = 'b.lua::g@1',
                at = R, prov = 'base', argv = { { k = 'lit', v = 'x' } } },
            { fn = 'a.lua::f@1', callee = 'mystery', file = 'a.lua', line = 2, at = R,
                refused = { rule = 'ambiguous', cands = { 'b.lua::g@1' }, n = 1 } },
        },
    }
end

test('cache × callcols: warm load then ingest with the flag on is faithful', function ()
    local root = vim.fn.tempname()
    local was = config.callcols_store
    local ok, err = pcall(function ()
        -- save PRE-INGEST records (the production save point)
        cache.save(sample_graph(root), nil)
        local loaded = cache.load(root)
        ok(loaded ~= nil, 'warm load returned a graph')
        eq(2, #loaded.calls)

        -- ingest the warm graph WITH the columnar store on
        config.callcols_store = true
        store.ingest(loaded)
        ok(store.data._callcols ~= nil, 'the columnar view installed on the warm graph')

        -- every call reads back faithfully through the seam
        local argv = require 'cartograph.argv'
        local c1, c2 = store.data.calls[1], store.data.calls[2]
        eq('g', callrec.callee(c1)); eq('b.lua::g@1', callrec.to(c1)); eq('base', callrec.prov(c1))
        eq('x', argv.str(c1, 1))                             -- argv survived cache + fold + proxy
        eq('mystery', callrec.callee(c2)); eq(nil, callrec.to(c2))
        eq('ambiguous', c2.refused.rule)                     -- residual table intact
    end)
    config.callcols_store = was
    cache.wipe(root)
    if not ok then error(err) end
end)

-- CART-0674. data.implements / data.extends were the only extraction outputs a
-- consumer still needed that the cache did not carry: they were scratch for
-- resolve_interface, which runs BEFORE the save. Measured on the java-liveness
-- fixture, implements went 2 cold -> 0 warm WITH THE NODE COUNT IDENTICAL.
--
-- ⚠ NOTHING CAUGHT IT, AND THIS TEST IS WHY: every existing oracle compares the
-- GRAPH, and the graph was already resolved when it was written. A vanished
-- INPUT is invisible to an output comparison until something re-derives from it.
-- So this asserts the INPUT survives, not that the output matches.
-- CART-0715. THE ORACLE, not just a fix: derive the field list from the
-- RESOLVE_PASSES source rather than from a declaration, so a NEW pass reading a
-- NEW `x.data` field fails here instead of silently losing it warm.
--
-- ⚠ AND FAIL LOUDLY WHEN THE FIXTURE STOPS COVERING A FIELD. A test that only
-- checks the fields the sample graph happens to populate passes vacuously
-- forever — the fence-that-never-fires shape. So an unhandled derived field is
-- an ERROR, and adding one to RESOLVE_PASSES forces a decision here.
test('cache: every resolver input the pass table reads survives the round trip', function ()
    local src = assert(io.open(vim.fn.getcwd()
        .. '/lua/cartograph/providers/treesitter.lua')):read('a')
    local body = assert(src:match('local RESOLVE_PASSES = (.-)\n}\n'),
        'could not find the RESOLVE_PASSES table — this test reads it, not a copy')
    local derived, seen = {}, {}
    for f in body:gmatch('x%.data%.([a-z_]+)') do
        if not seen[f] then seen[f] = true; derived[#derived + 1] = f end
    end
    ok(#derived > 5, 'scraped a plausible field list: ' .. #derived)

    -- fields that need no shard, each for a stated reason
    local EXEMPT = {
        edges = 'already persisted',
        root = 'already persisted (manifest)',
        beans = 'rides the implements row — no file of its own',
        -- store.lua sets selft_seed per call and clears it immediately: "never
        -- persist a resolution input onto the graph". The self-type map has its
        -- own channel (save_selft/load_selft), so persisting it would duplicate.
        selft_seed = 'a transient over the self-type map, which persists separately',
    }
    for _, f in ipairs(derived) do
        ok(cache.RESOLVER_INPUTS[f] ~= nil or EXEMPT[f] ~= nil,
            ('RESOLVE_PASSES reads x.data.%s and nothing persists it — add it to '
                .. 'cache.RESOLVER_INPUTS or exempt it here WITH A REASON'):format(f))
    end

    local root = vim.fn.tempname()
    local okr, err = pcall(function ()
        local g = sample_graph(root)
        -- populate EVERY registered field, in its declared shape
        for field, shape in pairs(cache.RESOLVER_INPUTS) do
            if shape == 'by_file' then
                g[field] = { ['a.lua'] = { probe = field }, ['b.lua'] = { probe = field } }
            else
                g[field] = { { probe = field, file = 'a.lua' },
                             { probe = field, file = 'b.lua' } }
            end
        end
        g.implements[1].child = 'A'; g.implements[2].child = 'B'
        g.beans = { A = 'aBean', B = true }
        cache.save(g, nil)
        local w = assert(cache.load(root), 'warm load returned a graph')
        for field, shape in pairs(cache.RESOLVER_INPUTS) do
            if shape == 'by_file' then
                ok(w[field] and w[field]['a.lua'] and w[field]['b.lua'],
                    field .. ' (by_file) came back for both files')
                eq(field, w[field]['a.lua'].probe)
            else
                eq(2, #(w[field] or {}), field .. ' (rows) came back')
                eq(field, w[field][1].probe)
            end
        end
        -- beans has no file of its own and must arrive via the implements row
        eq('aBean', (w.beans or {}).A, 'a named bean rode the implements row')
        eq(true, (w.beans or {}).B, 'a default-named bean did too')
    end)
    cache.wipe(root)
    if not okr then error(err) end
end)

test('cache: the inheritance rows survive the round trip, sharded by their own file', function ()
    local root = vim.fn.tempname()
    local ok, err = pcall(function ()
        local g = sample_graph(root)
        g.implements = {
            { child = 'A', iface = 'I', cintf = false, file = 'a.lua' },
            { child = 'B', iface = 'J', cintf = true, file = 'b.lua' },
        }
        g.extends = { { child = 'B', parent = 'A', file = 'b.lua' } }
        cache.save(g, nil)
        local w = cache.load(root)
        ok(w ~= nil, 'warm load returned a graph')
        eq(2, #(w.implements or {}), 'both implements rows came back')
        eq(1, #(w.extends or {}), 'the extends row came back')
        local byc = {}
        for _, r in ipairs(w.implements) do byc[r.child] = r end
        eq('I', byc.A.iface); eq('a.lua', byc.A.file)
        eq('J', byc.B.iface); eq(true, byc.B.cintf, 'the interface-extends arm is not flattened')
        eq('A', w.extends[1].parent)

        -- PER-FILE is the whole design: a partial save of one file must carry that
        -- file's rows and no others, so a changed file re-extracts its own and
        -- nothing goes stale. A flat manifest list could not do this.
        cache.save(g, { 'b.lua' })
        local w2 = cache.load(root)
        local files = {}
        for _, r in ipairs(w2.implements or {}) do files[r.file] = true end
        ok(files['a.lua'] and files['b.lua'], 'a dirty-subset save left the other file intact')
    end)
    cache.wipe(root)
    if not ok then error(err) end
end)

test('cache × callcols: build_shards materializes proxy calls (no unserializable __cc)', function ()
    -- a flow-LESS graph (no n._flow accessor) ingested with the flag on has proxy
    -- CALLS but serializable nodes — so build_shards must materialize the proxies
    -- (else pairs() over one captures its __cc column closures → cannot serialize).
    local root = vim.fn.tempname()
    local was = config.callcols_store
    local ok, err = pcall(function ()
        local g = {
            schema = 1, root = root, provider = 'test', stamps = { ['a.lua'] = 'sA' },
            nodes = {
                { id = 'a.lua', name = 'a.lua', kind = 'module', file = 'a.lua', order = -1, range = R },
                { id = 'a.lua::f@1', name = 'f', kind = 'function', file = 'a.lua', order = 1, range = R },
            },
            edges = {},
            calls = { { fn = 'a.lua::f@1', callee = 'g', file = 'a.lua', line = 1, to = 'x', at = R } },
        }
        config.callcols_store = true
        store.ingest(g)
        ok(rawget(store.data.calls[1], '__cc') ~= nil, 'the call is a proxy row')
        cache.save(store.data, nil)                 -- POST-ingest save: materialize kicks in
        local loaded = cache.load(root)
        ok(loaded ~= nil, 'reload after post-ingest save')
        eq('g', loaded.calls[1].callee); eq('x', loaded.calls[1].to)
    end)
    config.callcols_store = was
    cache.wipe(root)
    if not ok then error(err) end
end)
