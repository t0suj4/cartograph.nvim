-- FABRICATION CENSUS (CART-0605) — what fraction of the `inferred` tier names a
-- target the code CONTRADICTS?
--
--   nvim --headless -u NONE -l tools/fabcensus.lua <corpus|path> [--show <bucket>]
--     buckets: pinned · contradicted · suspect · undecided
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
-- WHAT THIS DOES NOT MEASURE, stated because absence of a check is not evidence:
--   * arity. `f(a,b,c)` reaching a two-parameter def looks like a free wrongness oracle
--     and is not one in Lua — varargs, trailing optionals, the method/dot `self`
--     off-by-one, and `f(g())` spreading an unknown number of returns all make a
--     mismatch ordinary. The honest form (args > params, callee has no vararg) is worth
--     building; it is not built here, and until it is, these edges sit in UNDECIDED.
--   * a receiver REBOUND after its import (`local store = require …` then `store = x`).
--     Rare, and it would move an edge out of PINNED or CONTRADICTED into neither.
--   * anything about the tiers above `inferred`. This is a census of one rung.
local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local tier = require 'cartograph.tier'

local target = arg[1]
if not target then
    print('usage: nvim --headless -u NONE -l tools/fabcensus.lua <corpus|path> [--show pinned|contradicted|suspect|undecided]')
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
for _, e in ipairs(data.edges or {}) do
    if e.kind == 'import' and e.bind then
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

local STD = stdlib_members()
local B = { pinned = {}, contradicted = {}, suspect = {}, undecided = {} }
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
-- ★ THE DECIDABLE HEADLINE, and the number a gate should actually read. Over the
-- sub-population the code PINS, agreement is total or it is not — no band, no
-- sample. It is the strongest statement available and it locates the fabrication
-- rather than bounding it: whatever is wrong is not in here.
local decided = #B.pinned + #B.contradicted
if decided > 0 then
    print(('AGREEMENT on the DECIDABLE sub-population: %d/%d = %.2f%%')
        :format(#B.pinned, decided, 100 * #B.pinned / decided))
    print('  where the code pins the receiver, the name-match is right this often.')
    print('  So fabrication is CONCENTRATED in the undecided remainder, not spread.')
    print('')
end
local lo = pct(#B.contradicted)
local hi = pct(#B.contradicted + #B.suspect + #B.undecided)
print(('FABRICATED in [%.1f%%, %.1f%%]  — witnessed / witnessed+undecided'):format(lo, hi))
print('  the low end is proved; the high end assumes every undecided edge is wrong,')
print('  which nobody believes. What narrows it is another DECIDABLE oracle, never a')
print('  larger hand sample — see the header for the two named and not built.')
print('  dated reference: ~10% hand-sampled on this tree in July (50 edges read,')
print('  35 correct / 15 wrong, 95% CI 6.4–14.7%). A point inside the band, not a rival.')
print('  ⚠ NOT DIRECTLY COMPARABLE: that pass pinned 4780 of 7199; this one pins fewer')
print('  of more. Either the tree moved or the two pin tests differ, and until that is')
print('  run down, treat the July figure as history and this band as the measurement.')

if show and B[show] then
    print('')
    print(('── %s (%d) ──'):format(show, #B[show]))
    for i, r in ipairs(B[show]) do
        if i > 60 then print(('  … %d more'):format(#B[show] - 60)); break end
        print(('  %s:%d  %s  ->  %s (%s)%s'):format(r.call.file, r.call.line,
            tostring(r.call.full), r.def.name, r.def.file,
            r.bound and ('   [%s binds -> %s]'):format(r.recv, r.bound) or ''))
    end
elseif show then
    print(('no such bucket: %s'):format(show))
    os.exit(2)
end
