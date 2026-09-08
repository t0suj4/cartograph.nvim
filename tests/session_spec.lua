-- The multi-band session: open ADDS a band, switching swaps the store lens
-- between bands with NO bleed, single-band stays byte-identical. The store
-- capture/restore round-trip is the load-bearing invariant.

local store = require 'cartograph.store'
local session = require 'cartograph.session'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function graph(root, fn)
    return {
        root = root,
        nodes = {
            { id = root .. '::m', name = 'm', kind = 'module', file = 'm.lua', range = R, order = 0 },
            { id = root .. '::' .. fn, name = fn, kind = 'function', file = 'm.lua', range = R, order = 0 },
        },
        edges = {}, calls = {},
    }
end

test('store: capture/restore round-trips per-band state, no bleed', function ()
    store.ingest(graph('/a', 'aaa'))
    local gen_a = store.generation
    local snap = store.capture()
    -- mutate the lens as if another band loaded
    store.ingest(graph('/b', 'bbb'))
    ok(store.node('/b::bbb'), 'lens now shows B')
    eq(nil, store.node('/a::aaa'), 'A is not visible while B is loaded')
    -- restore A
    store.restore(snap)
    ok(store.node('/a::aaa'), 'A restored')
    eq(nil, store.node('/b::bbb'), 'no B bleed after restoring A')
    eq(gen_a, store.generation, 'A\'s generation restored')
    eq('/a', store.data.root)
end)

test('session: open ADDS bands; switch swaps the lens without clobbering', function ()
    session.reset()
    -- open A
    session.begin('/a'); store.ingest(graph('/a', 'aaa'))
    eq('a', session.active)
    -- open B (begin freezes A first)
    session.begin('/b'); store.ingest(graph('/b', 'bbb'))
    eq('b', session.active)
    ok(store.node('/b::bbb') and not store.node('/a::aaa'), 'B active, A frozen')
    -- switch back to A — restored intact
    session.switch('a')
    ok(store.node('/a::aaa') and not store.node('/b::bbb'), 'A restored, no B bleed')
    eq('/a', store.data.root)
    -- and forward to B
    session.switch('b')
    ok(store.node('/b::bbb') and not store.node('/a::aaa'))
    -- the registry lists both, active flagged
    local names = {}
    for _, r in ipairs(session.list()) do names[r.name] = r.active end
    eq(false, names.a); eq(true, names.b)
end)

test('session: re-opening a root switches; owning routes by root containment', function ()
    session.reset()
    session.begin('/proj/a'); store.ingest(graph('/proj/a', 'aaa'))
    session.begin('/proj/b'); store.ingest(graph('/proj/b', 'bbb'))
    eq('a', session.by_root('/proj/a'))
    eq('a', session.owning('/proj/a/deep/file.lua'), 'file routes to its owning band')
    eq('b', session.owning('/proj/b/x.lua'))
    ok(session.switch_to_root('/proj/a'), 're-open of a registered root is a switch')
    eq('a', session.active)
    eq(nil, session.switch_to_root('/proj/never'), 'an unregistered root is not a switch')
end)

test('session: back crosses bands after the local history is exhausted (S2)', function ()
    session.reset()
    -- band A: focus a1, pivot to a2 (a within-band history entry)
    session.begin('/a'); store.ingest(graph('/a', 'a2'))
    store.data.nodes[#store.data.nodes + 1] = { id = '/a::a1', name = 'a1',
        kind = 'function', file = 'm.lua', range = R, order = 1 }
    store.by_id['/a::a1'] = store.data.nodes[#store.data.nodes]
    store.set_focus('/a::a1'); store.pivot('/a::a2')
    eq('/a::a2', store.focused)
    -- cross to band B (records the crossing at a2)
    store.record_crossing(); session.begin('/b'); store.ingest(graph('/b', 'b1'))
    store.set_focus('/b::b1')
    eq('b', session.active)
    -- back in B: B has no within-band history -> cross back to A at a2
    store.back()
    eq('a', session.active, 'crossed back into band A')
    eq('/a::a2', store.focused, 'restored to where we left A')
    -- back again: A's own history (a2 <- a1)
    store.back()
    eq('/a::a1', store.focused, 'then walks A\'s within-band history')
end)

test('nav: single-band back is unchanged — no crossings, empty is a no-op', function ()
    session.reset()
    store.ingest(graph('/solo', 'x'))
    store.set_focus('/solo::x')
    store.back() -- no history, no crossings
    eq('/solo::x', store.focused)
    eq(0, #session.crossings)
end)

test('session: close drops a band and re-activates a survivor', function ()
    session.reset()
    session.begin('/a'); store.ingest(graph('/a', 'aaa'))
    session.begin('/b'); store.ingest(graph('/b', 'bbb'))
    local now = session.close('b') -- closing the active band
    eq('a', now, 'a survivor becomes active')
    ok(store.node('/a::aaa'), 'the survivor is live in the lens')
    eq(nil, session.bands.b, 'closed band is gone')
end)

-- ── ★★★ THE MODULE-LEVEL CACHES THAT SERVED THE WRONG BAND (CART-0822) ───────
-- store.BAND_TRANSIENT enumerated store.lua's OWN five caches and read as a
-- closed list for as long as bands have existed. Seven more generation-keyed
-- caches lived as module upvalues in six other modules, where capture()/restore()
-- — which iterate `pairs(store)` — cannot see them. `store.generation` is a
-- PER-BAND counter, so two fresh bands both reach generation 1 and each reads
-- the other's answer. THE COLLISION IS THE DEFAULT, not a forced state: no
-- fixture needs to arrange it, two ordinary opens produce it.
local CART_0822 = { '_diag', '_clone_idx', '_clone_relpost', '_field_reach',
    '_portflow', '_short_idx', '_var_idx' }

test('bands: every re-homed cache is DECLARED band-transient', function ()
    for _, k in ipairs(CART_0822) do
        ok(store.BAND_TRANSIENT[k], k .. ' must be declared in BAND_TRANSIENT')
    end
end)

test('bands: a re-homed cache is dropped by the SWITCH, which is the swap that matters', function ()
    -- ⚠ AND `begin` IS NOT THE PATH — I asserted it first and it was wrong.
    -- `session.begin` captures the OUTGOING band and then lets the caller
    -- ingest; it never clears the live store, so a warmed field is still there
    -- immediately afterwards. That is harmless: the ingest bumps the generation,
    -- so every generation-keyed reader recomputes. `restore` (the switch path)
    -- is what clears, and it is where a stale answer could otherwise be served.
    session.reset()
    session.begin('/a'); store.ingest(graph('/a', 'aaa'))
    for _, k in ipairs(CART_0822) do store[k] = { gen = store.generation, mark = 'A' } end
    session.begin('/b'); store.ingest(graph('/b', 'bbb'))
    for _, k in ipairs(CART_0822) do
        ok(store[k] == nil or store[k].gen ~= store.generation,
            k .. ' must not be readable at B\'s generation')
    end
    -- THE SWITCH: restore() clears every non-session field, so a BAND_TRANSIENT
    -- cache is gone and a snapshotted one would come back. Both are checked —
    -- the field must be absent, not merely stale.
    for _, k in ipairs(CART_0822) do store[k] = { gen = store.generation, mark = 'B' } end
    session.switch('a')
    for _, k in ipairs(CART_0822) do
        eq(nil, store[k], k .. ' survived a switch (declare it BAND_TRANSIENT)')
    end
end)

-- ★★★ THE PREMISE, MEASURED — AND IT CORRECTS THE TICKET THAT ASKED FOR IT.
-- CART-0822 says two bands' counters "COLLIDE", which reads as "immediately".
-- They do NOT: `begin` captures the outgoing band but never resets the counter,
-- so it keeps CLIMBING across opens — band A lands on 1 and band B on 2, and a
-- module cache from A is correctly invalidated in B. That is why nobody ever hit
-- this, and it is worth knowing before believing any report of it.
-- ⚠ THE COLLISION IS REACHABLE IN FIVE STEPS AND THE FIFTH IS ORDINARY: switch
-- BACK to A, re-ingest (any edit does it), and A's counter climbs to B's value.
-- Now the two bands are at the same generation and a module-level cache warmed
-- in one answers for the other.
test('bands: generations collide after a SWITCH-BACK, not on a fresh open', function ()
    session.reset()
    session.begin('/a'); store.ingest(graph('/a', 'aaa'))
    local a1 = store.generation
    session.begin('/b'); store.ingest(graph('/b', 'bbb'))
    local b1 = store.generation
    ok(a1 ~= b1, 'two FRESH bands do not collide: ' .. a1 .. ' vs ' .. b1)

    session.switch('a')
    eq(a1, store.generation, 'switching back restores A\'s own counter')
    store.ingest(graph('/a', 'aaa'))          -- any re-ingest in A
    local a2 = store.generation
    eq(b1, a2, 'ONE re-ingest in A puts it on B\'s generation')
    session.switch('b')
    eq(a2, store.generation,
        'and now the two bands are indistinguishable by generation alone')
    -- so keying on the generation is only sound where the CACHE ITSELF is
    -- per-band. That is the placement, not the key.
    ok(not store.SESSION_GLOBAL.generation,
        'generation is per-band, so capture/restore swaps it')
end)

test('bands: a PUBLIC reader answers about the active band after a swap', function ()
    -- ★★★ END TO END THROUGH A REAL ACCESSOR, ON THE EXACT INTERLEAVING THAT
    -- COLLIDES. `shortpath` is the one of the seven with a public entry point;
    -- the ticket's named instance `var_by_name` is reachable only from
    -- M.attach's keymap callback (a window + line state + the 'lit' view), so
    -- it rides on the placement test rather than on a test-only export
    -- invented to reach it.
    --
    -- ⚠⚠ AND THE SEQUENCE IS THE WHOLE TEST. My first version opened two bands
    -- with `begin` and PASSED against the old module-upvalue code — because a
    -- fresh open bumps the generation, so the stale cache self-invalidates and
    -- there was never a wrong answer to catch. It asserted the right outcome on
    -- a state that cannot exhibit the bug. The five steps below are what
    -- actually put two bands on one generation.
    local symbols = require 'cartograph.panes.symbols'
    local function tree(root, files)
        local g = { root = root, nodes = {}, edges = {}, calls = {} }
        for _, f in ipairs(files) do
            g.nodes[#g.nodes + 1] = { id = root .. '::' .. f, name = f,
                kind = 'module', file = f, range = R, order = 0 }
        end
        return g
    end
    local A = { 'x/init.lua' }                    -- unique basename  -> 'init.lua'
    local B = { 'x/init.lua', 'y/init.lua' }      -- colliding        -> 'x/init.lua'

    session.reset()
    session.begin('/a'); store.ingest(tree('/a', A))          -- (1) A at gen 1
    session.begin('/b'); store.ingest(tree('/b', B))          -- (2) B at gen 2
    session.switch('a')                                        -- (3) back to A, gen 1
    store.ingest(tree('/a', A))                                -- (4) A climbs to gen 2
    eq('init.lua', symbols.shortpath('x/init.lua'),            -- (5) WARM A's cache
        'band A: a unique basename is its own shortest label')
    session.switch('b')                                        -- (6) B, also gen 2
    -- (7) THE READ THAT WAS WRONG. Same file path, same generation number,
    -- different band: B has two init.lua so the honest label needs a parent
    -- segment. A cache carried over from A answers 'init.lua'.
    eq('x/init.lua', symbols.shortpath('x/init.lua'),
        'band B must not inherit band A\'s label at the same generation')
    -- and A is still A's, recomputed rather than resurrected
    session.switch('a')
    eq('init.lua', symbols.shortpath('x/init.lua'))
end)

-- ── ONE BAND IS NOT MULTI-BAND (CART-0823) ──────────────────────────────────
-- ⚠⚠ AND THIS CASE IS UNREACHABLE FROM tools/mcpserve.lua, WHICH IS WHY IT
-- NEEDED ITS OWN SPEC. A single-root host never calls `session.begin` at all, so
-- it has ZERO bands — and a mutation loosening the gate from `< 2` to `< 1`
-- passed every wire spec, because zero is below both. The state the gate
-- actually protects is the COCKPIT'S NORMAL ONE: `init.lua` always registers a
-- band, so an interactive session sits at exactly ONE, and its in-process agent
-- calls must not start advertising a `band` argument that can only ever name the
-- band you are already in.
test('bands: ONE registered band advertises no band argument', function ()
    local agent = require 'cartograph.agent'
    session.reset()
    session.begin('/a'); store.ingest(graph('/a', 'aaa'))
    eq(1, #session.list(), 'the cockpit\'s normal state: exactly one band')
    for _, verb in ipairs(agent.ORDER) do
        eq(nil, (agent.schema(verb).properties or {}).band,
            verb .. ' must not offer `band` when there is only one')
    end
    -- and the envelope still NAMES that band, because a session with a band has
    -- an answer to "which one" even when there is no choice to make
    local d = agent.answer(store, 'graph_info', {})
    eq('a', d.graph.band)

    -- TWO bands: now the question is real and the argument appears
    session.begin('/b'); store.ingest(graph('/b', 'bbb'))
    eq(2, #session.list())
    for _, verb in ipairs(agent.ORDER) do
        local band = (agent.schema(verb).properties or {}).band
        ok(band ~= nil, verb .. ' must offer `band` when there are two')
        eq(2, #(band.enum or {}), verb .. '.band enumerates the roster')
    end
    session.reset()
end)

-- ★★★ THE FENCE FOR THE NINTH CACHE, and it is the point of the whole exercise:
-- placement is now the DEFAULT-CORRECT choice, so the thing to forbid is the
-- default-wrong one. The anti-pattern is precise — a FILE-SCOPE local assigned
-- a value derived from `store.generation` — and it is what all seven sites had.
-- A function-scope local holding a record READ from the store is fine, and a
-- plan/envelope carrying a `generation` FIELD is not a cache at all.
-- ⚠ MY FIRST TRY FLAGGED SIXTEEN SITES AND WAS WRONG ABOUT FOURTEEN: it treated
-- any dotless assignment target as a module local, which catches every
-- `generation = store.generation` field inside a plan literal (agent, moveapply,
-- reorder, declare …) and every ordinary local. A fence with a 14/16 false
-- positive rate gets deleted by the next person, so it reads the DECLARATIONS.
-- ⚠⚠ AND THEN IT MISSED TWO, WHICH IS THE MORE USEFUL FAILURE (CART-0823). It
-- was written from seven instances that were all FILE-SCOPE LOCALS, so that is
-- the only shape it checked — and `agent.lua`'s `M._graph_cache` /
-- `M._refs_cache` are MODULE-TABLE FIELDS. ★ A FENCE DESCRIBES THE INSTANCES
-- THAT PROMPTED IT, not the class; the way to find the gap was to ask what
-- OTHER placement has the same property, not to re-read the same seven.
test('bands: no module outside store.lua keys a MODULE-LEVEL cache on store.generation', function ()
    local root = vim.fn.getcwd() .. '/lua/cartograph'
    local bad, scanned, declared, keyed = {}, 0, 0, 0
    local function walk(dir)
        for name, t in vim.fs.dir(dir) do
            local path = dir .. '/' .. name
            if t == 'directory' then walk(path)
            elseif name:sub(-4) == '.lua' then
                scanned = scanned + 1
                local fd = io.open(path, 'r')
                local src = fd and fd:read('a') or ''
                if fd then fd:close() end
                local rel = path:sub(#root + 2)
                if rel ~= 'store.lua' and src ~= '' then
                    local lines = vim.split(src, '\n')
                    local function code(l) return not l:match('^%s*%-%-') end
                    -- ── PASS 0: does this file read store.generation IN CODE?
                    -- ⚠ THE GATE MUST READ CODE, NOT PROSE. Gating on any mention
                    -- put escalate.lua back in scope purely because its header
                    -- COMMENT explains why it is exempt — a fence tripped by its
                    -- own documentation.
                    local uses = false
                    for _, line in ipairs(lines) do
                        if code(line) and line:find('store%.generation') then uses = true; break end
                    end
                    if uses then
                        keyed = keyed + 1
                        -- ── PASS 1: FILE-SCOPE locals (column 0, this repo's form)
                        local top = {}
                        for _, line in ipairs(lines) do
                            local names = line:match('^local ([%w_][%w_%s,]*)=')
                                or line:match('^local ([%w_][%w_%s,]*)$')
                            if names then
                                for nm in names:gmatch('[%w_]+') do
                                    top[nm] = true; declared = declared + 1
                                end
                            end
                        end
                        -- ── PASS 2: an assignment in either default-wrong placement
                        for lno, line in ipairs(lines) do
                            -- ⚠⚠ TWO SIGNALS, AND THE SECOND IS WHY CART-0823'S PAIR
                            -- ESCAPED THE FIRST VERSION. agent.lua reads
                            -- `local gen = store.generation` on ONE line and assigns
                            -- `M._graph_cache = { gen = gen, … }` on ANOTHER, so a
                            -- fence that demanded `store.generation` on the
                            -- assignment line could not see it. A record whose first
                            -- field is `gen` is the same cache by another spelling.
                            local sig = line:find('store%.generation')
                                or line:find('=%s*{%s*gen%s*=')
                            if sig and code(line) then
                                local lhs = line:match('^%s*([%w_][%w_%s,%.]-)%s*=[^=]')
                                if lhs and not lhs:find('%.') then
                                    for nm in lhs:gmatch('[%w_]+') do
                                        if top[nm] then
                                            bad[#bad + 1] = ('%s:%d %s'):format(rel, lno,
                                                (line:gsub('^%s+', '')))
                                            break
                                        end
                                    end
                                elseif lhs then
                                    -- `store.<field>` is the CORRECT placement, so the
                                    -- RECEIVER decides — `M.`/a module alias is a cache
                                    -- the band mechanism cannot reach.
                                    local recv = lhs:match('^([%w_]+)%.')
                                    if recv and recv ~= 'store' then
                                        bad[#bad + 1] = ('%s:%d %s'):format(rel, lno,
                                            (line:gsub('^%s+', '')))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    walk(root)
    -- guard the scan itself, three ways: a walk that found no files, a gate that
    -- admitted no files, or a declaration pass that matched nothing would all
    -- pass vacuously — the fence-that-never-fires shape this repo keeps
    -- rediscovering, and this fence has now failed that way TWICE
    ok(scanned > 50, 'scanned a plausible number of modules: ' .. scanned)
    ok(keyed > 5, 'modules that actually read store.generation in code: ' .. keyed)
    ok(declared > 20, 'file-scope locals to check against: ' .. declared)
    eq({}, bad, 'module-level generation caches (put them on the store instead)')
end)
