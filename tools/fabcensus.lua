-- FABRICATION CENSUS (CART-0605) — what fraction of the `inferred` tier names a
-- target the code CONTRADICTS?
--
--   nvim --headless -u NONE -l tools/fabcensus.lua <corpus|path> [--show <bucket>]
--     buckets: pinned · contradicted · suspect · undecided · hop-pinned · hop-contradicted
--
-- WHY THIS EXISTS. RESOLUTION's gate (CART-0598) is a PAIR — resolution% rises AND
-- the fabricated fraction falls — because roughly a tenth of the inferred tier is
-- wrong, so the honest fix LOWERS the headline before it raises it. A gate phrased
-- as "resolution up" alone would reward exactly the move that makes the graph worse.
-- But the second number had only ever been produced by HAND: 50 edges read by a
-- person in July, 35 correct / 15 wrong, extrapolated to ~10% (95% CI 6.4–14.7%).
-- Re-running that means re-judging 50 edges, so the gate could not be evaluated in
-- either direction, and the milestone was unfalsifiable.
--
-- ★ A NUMBER WITHOUT A DEFINITION CAN BE RIGHT BY ACCIDENT, so the definition is
-- printed with the figure and is stated here first:
--
--   An `inferred` cross-file ref edge is FABRICATED when the calling file's own code
--   names a target incompatible with the one it resolved into.
--
-- That is deliberately narrower than "wrong". It is a WITNESS test — one contradicting
-- binding is enough, and no judgement is involved — which is the only kind of claim
-- this tool is allowed to make. "Correct" is the promise-shaped direction and cannot be
-- witnessed at all, so the output never claims it: the pinned bucket says the binding
-- AGREES, not that the edge is right.
--
-- THE THREE-BUCKET SHAPE, and why the answer is a BAND rather than a figure:
--
--   PINNED        the call is `X.name(…)`, the calling file binds `X` to a module, and
--                 the edge resolved INTO that module's file. The receiver's identity is
--                 pinned by the binding; no judgement.
--   CONTRADICTED  same shape, but the edge resolved into a DIFFERENT file. The binding
--                 and the resolution cannot both be right, and the binding is the one
--                 written down. WITNESSED WRONG.
--   UNDECIDED     no import binding pins the receiver — a method call on a local, a
--                 bare call, a receiver bound to something other than a module. This
--                 tool says nothing about these, on purpose.
--
-- So fabrication is reported as an interval: at least CONTRADICTED/total (every one
-- witnessed), at most (CONTRADICTED+UNDECIDED)/total (if every undecided edge were also
-- wrong, which nobody believes). The July hand-sample is quoted inside it as a dated
-- observation, not as a competing measurement.
--
-- ★ THE TECHNIQUE WORTH REUSING, inherited from the July pass: SHRINK THE POPULATION
-- WITH A DECIDABLE TEST BEFORE SAMPLING ANYTHING. The import-binding proof was used
-- there only to remove edges that need no judgement; running it in BOTH directions
-- turns the same data into a wrongness oracle, which is what makes this reproducible
-- where the hand pass was not.
--
-- SUSPECT is reported and NOT counted as wrong. A method call whose name is a stdlib
-- member (`ln:match` resolving to a project `M.match`) is the largest named class in
-- the July residual, but deciding it needs the receiver's TYPE: if some object really
-- does have a `:find`, resolving to it is correct. Counting these as fabricated would
-- fabricate fabrication — a false witness is worse than a wide band, because it is the
-- phantom-fact class the concern layering rates below plain absence.
--
-- ── THE ONE-HOP PIN (CART-0615), the second decidable oracle ──────────────
-- This header used to say the band narrows only by another DECIDABLE oracle and
-- name two that were not built. This is one of them, built.
--
-- The import binding pins a LOCAL. A call site that passes that local into a
-- parameter pins the PARAMETER in the callee — the same fact, one edge further:
--
--     file F:  local store = require 'cartograph.store'   -- binding pins `store`
--     F calls: verb(store, id)                            -- argument carries it
--     in verb: store.node(…)                              -- parameter now pinned
--
-- ⚠ IT IS A WEAKER TEST THAN THE LOCAL PIN, AND THAT IS WHY IT GETS ITS OWN
-- BUCKETS. The local pin reads one file and is complete by construction. This one
-- assumes (a) the observed caller set is complete — a caller the graph missed could
-- pass a different module — (b) the parameter is not rebound inside the callee, and
-- (c) the caller edges it reads are themselves right: `incoming` is built from
-- resolved calls of ANY tier, so an inferred-wrong caller edge could mint a false
-- contradiction here. None of the three is checked. So hop-pinned/hop-contradicted never merge into
-- PINNED/CONTRADICTED, and the headline agreement figure is still computed on the
-- local pin alone; folding a weaker oracle into a stronger one's number would
-- quietly restate what the strong number means.
--
-- ★ IT DECIDES ONLY BY UNANIMITY. Two callers passing two different modules into
-- the same parameter leaves the row POLYMORPHIC and undecided — the tool never picks
-- one. That counter measured ZERO here, which is what makes the unanimous rule
-- affordable and removes the design's expensive half (no set-valued receiver, no
-- merge rule). It keeps printing anyway, so the day it stops being zero is VISIBLE
-- rather than silently resolved in favour of whichever caller was seen first.
--
-- ★ WHAT IT IS FOR IS DEFECTS, NOT THE BAND, and the measurement said so before
-- this was built. It pins ~130 of 8526 cross-file edges — 1.5 points, which is
-- nothing — while DOUBLING the witnessed fabrications on its first run and naming a
-- second wrong class (CART-0616: the unique-name rung choosing a TEST DOUBLE over
-- the production declaration). Hence the asymmetry in the output: contradictions
-- print by default, agreements only under --show.
--
-- ⚠⚠ THE LANGUAGE FENCE, and it is wider than it looks. BOTH oracles read
-- `edge.bind`, which comes from `spec.import_bind` — declared by ONE of the fifteen
-- language specs (lua). Probed 2026-08-29: ruby 98 import edges / 0 bound, php 894
-- / 0, python 0 / 0, jquery 0 / 0. So on every corpus but a Lua one this tool
-- decides nothing and reports [0.00%, 100.0%].
--
-- That is not a caveat about a tool, it is a hole in a MILESTONE GATE: RESOLUTION
-- (CART-0598) is gated on the fabricated fraction falling, and the fraction is
-- measurable on one language of fifteen. The gate is unfalsifiable everywhere else,
-- and it read as passing rather than as unmeasured. The runtime warning below is
-- the interim fix; declaring `import_bind` in more specs is the real one.
--
-- WHAT THIS DOES NOT MEASURE, stated because absence of a check is not evidence:
--   * arity. `f(a,b,c)` reaching a two-parameter def looks like a free wrongness oracle
--     and is not one in Lua — varargs, trailing optionals, the method/dot `self`
--     off-by-one, and `f(g())` spreading an unknown number of returns all make a
--     mismatch ordinary. The honest form (args > params, callee has no vararg) is worth
--     building; it is not built here, and until it is, these edges sit in UNDECIDED.
--   * a receiver REBOUND after its import (`local store = require …` then `store = x`).
--     Rare, and it would move an edge out of PINNED or CONTRADICTED into neither.
--   * anything about the tiers above `inferred`. This is a census of one rung.
--   * a parameter REBOUND inside its own callee, the one-hop analogue of the
--     rebound-receiver hole above, and untested for the same reason.
local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local tier = require 'cartograph.tier'

local target = arg[1]
if not target then
    print('usage: nvim --headless -u NONE -l tools/fabcensus.lua <corpus|path> [--show pinned|contradicted|suspect|undecided|hop-pinned|hop-contradicted]')
    os.exit(2)
end
local show
for i = 2, #(arg or {}) do if arg[i] == '--show' then show = arg[i + 1] end end

local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then
    print('not a directory: ' .. root)
    os.exit(2)
end

--- The host's own stdlib member names, read from the running interpreter rather than
--- typed into a list here. The corpus is Lua and so are we, so this is an oracle and
--- not a guess — and a list would go stale against the very runtime it describes.
local function stdlib_members()
    local out = {}
    for _, mod in ipairs({ 'string', 'table', 'math', 'os', 'io' }) do
        local t = _G[mod]
        if type(t) == 'table' then
            for k in pairs(t) do if type(k) == 'string' then out[k] = true end end
        end
    end
    return out
end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)

local byid, files = {}, {}
for _, n in ipairs(data.nodes) do
    byid[n.id] = n
    if n.file then files[n.file] = true end
end

--- A dotted call whose receiver is an INLINE require — `require('a.b').name(…)` —
--- carries its own pin: the module path is written at the call site, so no import
--- edge is needed and no binding can shadow it. This is the strongest form of the
--- test and it was invisible to a receiver pattern that only matched identifiers;
--- 1574 of the population had a shape the first cut filed as "other", and inline
--- requires are the bulk of them.
--- Returns the path FRAGMENT the module name implies, or nil.
local function inline_require(full)
    if not full then return nil end
    local mod = full:match("^require%s*%(?%s*['\"]([%w%._%-]+)['\"]%s*%)?%.[%w_]+$")
    if not mod then return nil end
    return (mod:gsub('%.', '/')) .. '.lua'
end

--- Does any file in the corpus end with this fragment? A require naming a module
--- OUTSIDE the graph cannot contradict anything — there is nothing for it to have
--- resolved into — so the test only speaks when the module is present.
local function frag_in_corpus(frag)
    for f in pairs(files) do
        if f:sub(-#frag) == frag then return true end
    end
    return false
end

-- file -> { bind -> imported file }. An import edge carries the LOCAL NAME the
-- requiring file bound the module to, which is exactly the fact that pins a
-- dotted receiver. A file may bind the same name twice (two requires, one name);
-- that is a shadow we cannot order, so such a bind is dropped rather than guessed.
local binds, dupe = {}, {}
local n_import, n_import_bound = 0, 0
for _, e in ipairs(data.edges or {}) do
    if e.kind == 'import' then n_import = n_import + 1 end
    if e.kind == 'import' and e.bind then
        n_import_bound = n_import_bound + 1
        local b = binds[e.from]
        if not b then b = {}; binds[e.from] = b end
        if b[e.bind] and b[e.bind] ~= e.to then
            dupe[e.from .. '\0' .. e.bind] = true
        end
        b[e.bind] = e.to
    end
end
for k in pairs(dupe) do
    local f, nm = k:match('^(.-)%z(.*)$')
    if binds[f] then binds[f][nm] = nil end
end

-- callee id -> the calls that reach it. The one-hop pin reads a fn's ARGUMENTS
-- from its callers, so it needs the call index inverted; nothing else here does.
local incoming = {}
for _, call in ipairs(data.calls) do
    if call.to then
        local t = incoming[call.to]
        if not t then t = {}; incoming[call.to] = t end
        t[#t + 1] = call
    end
end

--- The module file a call's i-th argument names, if that argument is a local the
--- calling file bound to a module. Anything else (a literal, a field, an
--- expression, a local bound to a non-module) carries no pin and returns nil.
local function arg_module(call, i)
    local a = call.argv and call.argv[i]
    if not a or a.k ~= 'local' or not a.name then return nil end
    local b = binds[call.file]
    return b and b[a.name] or nil
end

-- why a dotted undecided row could NOT be decided one hop out. Printed, because a
-- decidable oracle that declines is reporting a FRONTIER, and a reader who cannot
-- see the shape of the decline cannot tell an exhausted oracle from a blind one.
local hop_why, n_hop_pop, n_shape_skip = {}, 0, 0

--- What module does the enclosing function's parameter `recv` carry, one hop out?
--- Returns the pinned file, or nil and the reason no answer is available.
local function hop_pin(call, recv)
    local fn = call.fn and byid[call.fn]
    if not fn then return nil, 'the call has no enclosing function' end
    local idx
    for i, p in ipairs(fn.params or {}) do
        if p == recv then idx = i; break end
    end
    if not idx then return nil, 'the receiver is not a parameter of it' end
    local callers = incoming[fn.id]
    if not callers then return nil, 'that function has no callers in this graph' end
    local seen, n = {}, 0
    for _, cc in ipairs(callers) do
        -- ARGUMENT POSITIONS ONLY LINE UP WHEN BOTH SIDES AGREE ABOUT `self`. A
        -- method invoked with dot syntax (or the reverse) shifts every index by
        -- one, and a shifted index reads the wrong argument rather than none --
        -- silently, and it would look exactly like evidence. Skip and count.
        if (not not cc.method) ~= (fn.kind == 'method') then
            n_shape_skip = n_shape_skip + 1
        else
            local m = arg_module(cc, idx)
            if m and not seen[m] then seen[m] = true; n = n + 1 end
        end
    end
    if n == 0 then return nil, 'no caller passes a module-bound local there' end
    if n > 1 then return nil, 'POLYMORPHIC: callers pass different modules' end
    return (next(seen))
end

local STD = stdlib_members()
local B = { pinned = {}, contradicted = {}, suspect = {}, undecided = {},
    ['hop-pinned'] = {}, ['hop-contradicted'] = {} }
local n_inferred, n_cross = 0, 0

for _, call in ipairs(data.calls) do
    if call.to and tier.of(call) == 'inferred' then
        n_inferred = n_inferred + 1
        local def = byid[call.to]
        if def and def.file and def.file ~= call.file then
            n_cross = n_cross + 1
            -- the receiver of a DOTTED call: `X.name(…)` -> X. A method call
            -- (`x:name`) is excluded here because its receiver is a value, not a
            -- module binding, so no import edge can speak to it.
            local recv = (not call.method) and call.full
                and call.full:match('^([%a_][%w_]*)%.[%w_]+$') or nil
            local bound = recv and binds[call.file] and binds[call.file][recv]
            local frag = (not call.method) and inline_require(call.full) or nil
            local row = { call = call, def = def, recv = recv or frag, bound = bound or frag }
            if frag then
                if def.file:sub(-#frag) == frag then
                    B.pinned[#B.pinned + 1] = row
                elseif frag_in_corpus(frag) then
                    B.contradicted[#B.contradicted + 1] = row
                else
                    B.undecided[#B.undecided + 1] = row -- the module is not in this graph
                end
            elseif bound and bound == def.file then
                B.pinned[#B.pinned + 1] = row
            elseif bound then
                B.contradicted[#B.contradicted + 1] = row
            elseif call.method and call.callee and STD[call.callee] then
                B.suspect[#B.suspect + 1] = row
            elseif recv then
                -- dotted, unbound: the population the one-hop pin can speak to
                n_hop_pop = n_hop_pop + 1
                local pin, why = hop_pin(call, recv)
                if pin then
                    row.hop = pin
                    local k = (pin == def.file) and 'hop-pinned' or 'hop-contradicted'
                    B[k][#B[k] + 1] = row
                else
                    hop_why[why] = (hop_why[why] or 0) + 1
                    B.undecided[#B.undecided + 1] = row
                end
            else
                B.undecided[#B.undecided + 1] = row
            end
        end
    end
end

local function pct(n) return n_cross > 0 and (100 * n / n_cross) or 0 end
local function line(label, n, note)
    print(('  %-14s %6d  %5.1f%%  %s'):format(label, n, pct(n), note))
end

print(('FABRICATION CENSUS — %s'):format(root))
print('')
print('DEFINITION: an `inferred` cross-file ref edge is FABRICATED when the calling')
print("file's own code names a target incompatible with the one it resolved into.")
print('A witness test — one contradicting binding is enough, no judgement involved.')
print('"Correct" is not claimed anywhere: it is promise-shaped and cannot be witnessed.')
print('')
print(('population: %d cross-file `inferred` edges (of %d inferred, %d calls, %d nodes)')
    :format(n_cross, n_inferred, #data.calls, #data.nodes))
line('PINNED', #B.pinned, "the receiver's binding names the file it resolved into")
line('CONTRADICTED', #B.contradicted, "the binding names a DIFFERENT file — WITNESSED WRONG")
line('SUSPECT', #B.suspect, 'a method call whose name is a stdlib member (undecided, see header)')
line('UNDECIDED', #B.undecided, 'no import binding pins the receiver')
print('')
print('ONE HOP OUT — the receiver is a PARAMETER and the callers agree what they pass.')
print('  A weaker test than the pin above (it assumes the caller set is complete and')
print('  the parameter is never rebound), so it is counted apart and never folded in.')
line('hop-pinned', #B['hop-pinned'], 'the callers pin it to the file it resolved into')
line('hop-contra', #B['hop-contradicted'], 'they pin it ELSEWHERE — witnessed one hop out')
if n_hop_pop > 0 then
    local decl = {}
    for why, n in pairs(hop_why) do decl[#decl + 1] = { why, n } end
    table.sort(decl, function (a, b) return a[2] > b[2] end)
    print(('  of %d dotted undecided rows it could speak to, it DECLINED %d:')
        :format(n_hop_pop, n_hop_pop - #B['hop-pinned'] - #B['hop-contradicted']))
    for _, d in ipairs(decl) do
        print(('    %6d  %s'):format(d[2], d[1]))
    end
    -- ★ ZERO POLYMORPHIC IS LOAD-BEARING, so it prints when it is zero. The
    -- unanimity rule is only affordable while no parameter carries two modules;
    -- an absent line would read as "not measured" instead of "measured, none".
    if not hop_why['POLYMORPHIC: callers pass different modules'] then
        print('         0  POLYMORPHIC: callers pass different modules')
    end
    if #B['hop-pinned'] + #B['hop-contradicted'] == 0 then
        print('  it decided NOTHING here: the breakdown above is the whole story, and')
        print('  a 0/0 is the oracle declining, not the corpus coming back clean.')
    end
    if n_shape_skip > 0 then
        print(('  (%d caller(s) skipped: dot/method shape differs, so argument positions')
            :format(n_shape_skip))
        print('   would not line up — a shifted index reads a WRONG argument, not none)')
    end
end
print('')
-- ★ THE DECIDABLE HEADLINE, and the number a gate should actually read. Over the
-- sub-population the code PINS, agreement is total or it is not — no band, no
-- sample. It is the strongest statement available and it locates the fabrication
-- rather than bounding it: whatever is wrong is not in here.
-- ★★ A ZERO FROM AN ORACLE THAT NEVER SPOKE IS NOT A CLEAN BILL, and this tool
-- printed one for weeks. On discourse it decides NOTHING — 718 edges, PINNED 0,
-- CONTRADICTED 0 — and the band then reads [0.00%, 100.0%], whose low end looks
-- like "no fabrication found" and means "no question was asked". The same shape
-- cost a day earlier this week on a monkey-patch census reporting 0 against a
-- corpus holding 249.
--
-- ⚠ AND THE REASON IS MEASURED, NOT GUESSED. The first version of this warning
-- blamed the LANGUAGE — "Ruby has no import that binds a name" — which is a story,
-- and the wrong one. Both oracles stand on `edge.bind`, which is populated from
-- `spec.import_bind`, and that is declared by ONE of the fifteen language specs.
-- The count below is read off the edges themselves so the message cannot drift
-- from the fact: N import edges, M carrying a bound name.
local decided = #B.pinned + #B.contradicted
if decided == 0 and n_cross > 0 then
    print('⚠ THE PIN TEST NEVER SPOKE ON THIS CORPUS — 0 of ' .. n_cross ..
        ' edges decided either way. Read the band below as UNMEASURED, not clean.')
    print(('  substrate: %d import edge(s), %d carrying a bound local name.')
        :format(n_import, n_import_bound))
    if n_import > 0 and n_import_bound == 0 then
        print('  Imports exist and NONE names its local, so this spec declares no')
        print('  `import_bind`. That is a gap in the language front-end, not a')
        print('  property of the corpus — and both oracles here are blind without it.')
    elseif n_import == 0 then
        print('  No import edges at all: nothing for either oracle to read.')
    end
    print(' ')
end
if decided > 0 then
    print(('AGREEMENT on the DECIDABLE sub-population: %d/%d = %.2f%%')
        :format(#B.pinned, decided, 100 * #B.pinned / decided))
    print('  where the code pins the receiver, the name-match is right this often.')
    print('  So fabrication is CONCENTRATED in the undecided remainder, not spread.')
    print('')
end
-- ⚠ THE STRICT BAND MUST NOT BENEFIT FROM THE WEAK ORACLE, and the first cut of
-- this let it: carving hop-pinned rows out of UNDECIDED narrowed the high end by
-- 1.5 points for free, which reads as the strict test having improved when nothing
-- about it changed. From the local pin's point of view a hop-pinned row is still
-- undecided, so it counts in this high end and is subtracted only in the band below.
local n_hop = #B['hop-pinned'] + #B['hop-contradicted']
local lo = pct(#B.contradicted)
local hi = pct(#B.contradicted + #B.suspect + #B.undecided + n_hop)
-- two decimals on the low end: a witnessed defect must never round to 0.0%.
print(('FABRICATED in [%.2f%%, %.1f%%]  — witnessed / witnessed+undecided (%d / %d edges)')
    :format(lo, hi, #B.contradicted, #B.contradicted + #B.suspect + #B.undecided + n_hop))
print('  the low end is proved; the high end assumes every undecided edge is wrong,')
print('  which nobody believes. What narrows it is another DECIDABLE oracle, never a')
print('  larger hand sample — the one-hop pin below is the first of those, built.')
if n_hop > 0 then
    local wit = #B.contradicted + #B['hop-contradicted']
    local lo2 = pct(wit)
    local hi2 = pct(#B.contradicted + #B.suspect + #B.undecided + #B['hop-contradicted'])
    print(('  WITH THE ONE-HOP PIN FOLDED IN: [%.2f%%, %.1f%%]  (%d / %d edges)')
        :format(lo2, hi2, wit, #B.contradicted + #B.suspect + #B.undecided + #B['hop-contradicted']))
    print('  — moves at BOTH ends: it witnesses more wrong AND believes more right,')
    print('  and it rests on the two assumptions named above. Quote the strict band')
    print('  unless you also state which oracle you allowed.')
end
print('  dated reference: ~10% hand-sampled on this tree in July (50 edges read,')
print('  35 correct / 15 wrong, 95% CI 6.4–14.7%). A point inside the band, not a rival.')
print('  ⚠ NOT DIRECTLY COMPARABLE: that pass pinned 4780 of 7199; this one pins fewer')
print('  of more. Either the tree moved or the two pin tests differ, and until that is')
print('  run down, treat the July figure as history and this band as the measurement.')

-- ★ THE PRODUCT PRINTS ITSELF. Every row here is a witnessed defect one hop out,
-- and the first run of this test produced three that were all real. Leaving them
-- behind a flag would make the tool's only actionable output opt-in.
if #B['hop-contradicted'] > 0 then
    print('')
    print(('── ONE-HOP CONTRADICTIONS (%d) — each is a defect, not a statistic ──')
        :format(#B['hop-contradicted']))
    for i, r in ipairs(B['hop-contradicted']) do
        if i > 40 then print(('  … %d more (--show hop-contradicted)'):format(#B['hop-contradicted'] - 40)); break end
        print(('  %s:%d  %s  ->  %s (%s)'):format(r.call.file, r.call.line,
            tostring(r.call.full), r.def.name, r.def.file))
        print(('      but `%s` is a parameter its callers pin to %s'):format(r.recv, r.hop))
    end
end

if show and B[show] then
    print('')
    print(('── %s (%d) ──'):format(show, #B[show]))
    for i, r in ipairs(B[show]) do
        if i > 60 then print(('  … %d more'):format(#B[show] - 60)); break end
        local pin = r.bound and ('   [%s binds -> %s]'):format(r.recv, r.bound)
            or r.hop and ('   [param %s pinned -> %s]'):format(r.recv, r.hop) or ''
        print(('  %s:%d  %s  ->  %s (%s)%s'):format(r.call.file, r.call.line,
            tostring(r.call.full), r.def.name, r.def.file, pin))
    end
elseif show then
    print(('no such bucket: %s'):format(show))
    os.exit(2)
end
