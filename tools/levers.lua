-- levers — "where's the biggest resolution win on THIS corpus?" The
-- D-measurement ([[cartograph-resolution-ceiling]]: local-inference ~26%, std
-- ~50%, B2 ~2.4%) was a hand analysis; this makes it a one-command, per-corpus
-- decision. It decomposes the UNRESOLVED calls by the census gate that stopped
-- each, groups the gates into strategic LEVERS, and ranks them by the
-- resolution points each would add if realized — so "what to work on next" is
-- data. (ablate.lua answers "is an existing pass worth keeping"; this answers
-- "which NEW capability buys the most".)
--
--   nvim --headless -u NONE -l tools/levers.lua [<corpus-name>|<dir>] [--top=N]
--
-- ★★★ THE GATE IS NOT THE ONLY AXIS, AND FOR THE LARGEST BLOCS IT IS THE WRONG
-- ONE (CART-0803). On both large JS corpora the single biggest bloc of
-- unresolved calls is the test framework, and this tool reported no such lever
-- from the day it shipped (2026-07-20) until now, because the bloc arrives
-- through TWO gates at once: `it` (9219
-- calls on ghost) is two characters long so it is refused `short` and files
-- under "name-match reach", while `expect` / `describe` / `calledOnce` land in
-- "stdlib-profile". THE TOOL BUILT TO RANK LEVERS COULD NOT SEE ITS OWN TOP
-- ONE, and a reader ranking JS work off its output would have picked the wrong
-- thing. Two additions, in order of how much they fix:
--
--   1. EVERY LEVER NOW SHOWS ITS TOP NAMES. A bucket that is only a number
--      cannot be checked by the reader, so a bloc of any size can hide inside
--      it. This is the general fix and it needs no new concept.
--   2. THE BLOC CUT, which reunifies what the gate axis splits. What these
--      calls actually share is not how they were refused but WHERE THEY LIVE —
--      and the honest way to say that is CO-OCCURRENCE, not a path convention:
--      a name joins the bloc of a bigger name when ≥80% of its call sites are
--      in files that bigger name also appears in. Measured, not declared. A
--      `tests|spec` dirname match would have been a convention in disguise and
--      would have LOST here: ghost keeps its specs in `test/` at the top level
--      while converse.js keeps them in `src/*/tests/` at four different depths.
--      The example file printed with each bloc lets the reader recognise it
--      without the tool having to name the convention.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local census = require 'cartograph.census'

local arg1, top = nil, 6
for i = 1, #(arg or {}) do
    local n = arg[i]:match('^%-%-top=(%d+)$')
    if n then top = tonumber(n) elseif not arg1 then arg1 = arg[i] end
end
local root = repo .. '/lua'
if arg1 then
    local ok, corpora = pcall(dofile, repo .. '/tools/corpora.lua')
    if ok and corpora[arg1] and corpora[arg1].root then root = corpora[arg1].root else root = arg1 end
end

-- gate (census `why` / dynamic) -> the LEVER that would catch it, and whether
-- it's statically reachable at all (dynamic = honest frontier, not a lever)
local LEVER = {
    ['no-def']    = { lever = 'stdlib-profile (external)', note = 'domain-dependent — the A4 lever' },
    ['vocab']     = { lever = 'pack / vocabulary', note = 'specaudit finds the pack' },
    ['exact-key'] = { lever = 'pack / vocabulary', note = 'string-key registry (greenspun)' },
    ['unknown']   = { lever = 'indirect / dispatch', note = 'VM / runtime tier' },
    ['prefix']    = { lever = 'name-match reach', note = 'prefix-gated' },
    ['short']     = { lever = 'name-match reach', note = 'short-name-gated' },
}
local function lever_of(why)
    local L = LEVER[why]
    return L and L.lever or ('other (' .. why .. ')'), L and L.note
end

local data = ts.extract(root)
-- names = true: the per-callee attribution the bloc cut needs. It is opt-in
-- because census also runs inside the corpus gates and inside sweeps, where a
-- table proportional to the unresolved population is not free.
local c = census.take(data, { names = true })
local total, resolved = c.calls.total, c.calls.resolved
local by_name = c.calls.outside.by_name or {}
local by_file = c.calls.outside.by_file or {}

-- fold the gate breakdown into levers
-- ⚠ THE NOTE IS A SET, NOT A SLOT. Two gates fold into `name-match reach`, and
-- assigning `notes[lever]` inside a `pairs` walk made the printed note whichever
-- gate the hash happened to yield last — a line that changed between runs of an
-- unchanged tool ([[the-harness-is-unguarded]]: order is output). Collected and
-- sorted, it also says more: the reader sees that this lever has two gates
-- under it, which is the very thing this ticket is about.
local by_lever, notes = {}, {}
for why, n in pairs(c.calls.outside.by_why or {}) do
    local name, note = lever_of(why)
    by_lever[name] = (by_lever[name] or 0) + n
    if note then
        local t = notes[name]; if not t then t = {}; notes[name] = t end
        t[note] = true
    end
end
local function note_of(lever)
    local t = notes[lever]; if not t then return '' end
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ' · ')
end
local dynamic = (c.calls.outside.by_disp or {}).dynamic or 0

-- ── the per-name view: each name's statically-reachable count, and its share
-- of each lever. A name is counted into a lever ONCE PER GATE it arrived
-- through, which is the whole point: `it` may be `short` here and `no-def`
-- there, and the split is a fact about the corpus, not a rounding choice.
local lever_names, ranked_names = {}, {}
for name, e in pairs(by_name) do
    local reach = 0
    for why, n in pairs(e.why) do
        if why ~= 'dynamic' then
            reach = reach + n
            local L = lever_of(why)
            local t = lever_names[L]; if not t then t = {}; lever_names[L] = t end
            t[#t + 1] = { name = name, n = n }
        end
    end
    e.reach = reach
    if reach > 0 then ranked_names[#ranked_names + 1] = { name = name, e = e, n = reach } end
end
table.sort(ranked_names, function (a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name -- an output field: order is output (CART-0790)
end)

-- ── THE BLOC CUT. Anchor on the largest remaining name, absorb every name
-- whose sites are ≥CONTAIN contained in the anchor's file set, repeat.
--
-- ⚠⚠ AND A NAME MUST BE LOCALISED TO TAKE PART AT ALL, which the first cut of
-- this got wrong and the smallest corpus said so immediately: run on our own
-- `lua/`, `ipairs` anchored a bloc of 111 names — the entire Lua stdlib — for
-- the reason that makes containment meaningless there. `ipairs` appears in 167
-- of the 167 files that hold an unresolved call, so EVERY other name is
-- trivially contained in its file set, and asymmetry (small-inside-big) does
-- not help: big-everywhere is what breaks it. A bloc is a LOCALITY claim, so a
-- name that spans most of the corpus is not evidence of one — it belongs to the
-- lever ranking above, which already names it correctly. Requiring both anchor
-- and member to sit in at most LOCAL of the corpus's files makes the instrument
-- DECLINE on a corpus with no bloc, which is the property worth having.
-- and a floor, because a bloc worth less than half a resolution point is not a
-- lever — converse.js otherwise reports a real, pure, 14-call bloc in one file
local CONTAIN, CONSIDER, LOCAL, PURE, MINPTS = 0.8, 120, 0.5, 0.5, 0.5
local nfiles_total = 0
do
    local seen = {}
    for _, r in ipairs(ranked_names) do
        for f in pairs(r.e.files) do
            if not seen[f] then seen[f] = true; nfiles_total = nfiles_total + 1 end
        end
    end
end
local function localised(e)
    return nfiles_total > 0 and (e.nfiles / nfiles_total) <= LOCAL
end
local blocs, claimed = {}, {}
for i = 1, math.min(#ranked_names, CONSIDER) do
    local a = ranked_names[i]
    if not claimed[a.name] and localised(a.e) then
        claimed[a.name] = true
        local bloc = { names = { a }, n = a.n, why = {} }
        for j = i + 1, math.min(#ranked_names, CONSIDER) do
            local b = ranked_names[j]
            if not claimed[b.name] and localised(b.e) then
                local inside = 0
                for f, k in pairs(b.e.files) do
                    if a.e.files[f] then inside = inside + k end
                end
                if b.n > 0 and inside / b.n >= CONTAIN then
                    claimed[b.name] = true
                    bloc.names[#bloc.names + 1] = b
                    bloc.n = bloc.n + b.n
                end
            end
        end
        for _, m in ipairs(bloc.names) do
            for why, n in pairs(m.e.why) do
                if why ~= 'dynamic' then
                    local L = lever_of(why)
                    bloc.why[L] = (bloc.why[L] or 0) + n
                end
            end
        end
        -- the bloc's own file count is the UNION, not the anchor's: a member
        -- may sit in files the anchor misses and still be 80% inside it
        local un, unn, denom = {}, 0, 0
        for _, m in ipairs(bloc.names) do
            for f in pairs(m.e.files) do
                if not un[f] then
                    un[f] = true; unn = unn + 1
                    local g = by_file[f]
                    if g then denom = denom + (g.n - g.dyn) end
                end
            end
        end
        bloc.files = unn
        -- ★★★ PURITY, AND IT IS THE MEASURE THAT MAKES THE CUT MEAN ANYTHING.
        -- Containment alone said our own `lua/` holds five blocs: on a corpus
        -- whose unresolved mass is one uniform population (the Lua stdlib),
        -- widely-spread names are trivially inside one another's file sets and
        -- the greedy chops that population into arbitrary slices. What separates
        -- a real bloc from a slice of one is whether its files are DEDICATED to
        -- it — of every statically-unresolved call in the bloc's files, how many
        -- belong to the bloc. ghost's spec files hold test-DSL names and little
        -- else; a file holding `type` also holds `ipairs`, `format` and
        -- `require`, none of which are in the bloc. Printed either way, so the
        -- reader judges rather than trusts the threshold.
        bloc.purity = denom > 0 and (bloc.n / denom) or 0
        -- the file the anchor is densest in: enough for a reader to recognise
        -- the bloc, and it is a site rather than a claim about a convention
        local best, bestn
        for f, n in pairs(a.e.files) do
            if not bestn or n > bestn or (n == bestn and f < best) then best, bestn = f, n end
        end
        bloc.eg = best
        blocs[#blocs + 1] = bloc
    end
end
-- ⚠ TIEBROKEN ON THE ANCHOR. Two blocs of equal size would otherwise print in
-- whatever order the greedy happened to build them from a `pairs` walk — the
-- same defect as the lever note below, and order is output (CART-0790).
table.sort(blocs, function (x, y)
    if x.n ~= y.n then return x.n > y.n end
    return x.names[1].name < y.names[1].name
end)

local function pct(x) return total > 0 and (x * 100 / total) or 0 end
local ranked = {}
local reachable = 0
for name, n in pairs(by_lever) do ranked[#ranked + 1] = { name = name, n = n } end
table.sort(ranked, function (a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
end)
for _, r in ipairs(ranked) do reachable = reachable + r.n end

print(('levers %s — resolution %.1f%% (%d/%d calls)'):format(root:gsub('.*/', ''), pct(resolved), resolved, total))
print(('  reachable ceiling (every lever but dynamic realized): %.1f%%  (+%.1f pts)'):format(
    pct(resolved + reachable), pct(reachable)))
print('')
print('  lever                        calls   +pts   note')
for _, r in ipairs(ranked) do
    print(('  %-26s %6d  %+5.1f   %s'):format(r.name, r.n, pct(r.n), note_of(r.name)))
    -- ★ THE NAMES, so a bucket can be checked rather than believed
    local t = lever_names[r.name] or {}
    table.sort(t, function (a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.name < b.name
    end)
    local parts, shown = {}, 0
    for _, m in ipairs(t) do
        if shown >= top then break end
        shown = shown + 1
        parts[#parts + 1] = ('%s %d'):format(m.name, m.n)
    end
    if #parts > 0 then
        print(('  %-26s   %s%s'):format('', table.concat(parts, ' · '),
            #t > shown and (' … %d more names'):format(#t - shown) or ''))
    end
end
if dynamic > 0 then
    print(('  %-26s %6d  %s'):format('── dynamic (opaque)', dynamic, '  honest frontier — not statically resolvable'))
end
print('  ranked by resolution points a fully-realized lever would add')

-- ── the second axis
local multi = 0
for _, b in ipairs(blocs) do
    if #b.names > 1 and b.purity >= PURE and pct(b.n) >= MINPTS then multi = multi + 1 end
end
print('')
print(('  BLOCS — names that co-occur in the same files (≥%d%% containment,'):format(CONTAIN * 100))
print(('  and each name in ≤%d%% of the %d files holding an unresolved call, so a')
    :format(LOCAL * 100, nfiles_total))
print('  corpus-wide name cannot pose as a bloc), whose files are DEDICATED to')
print(('  it — ≥%d%% of what they leave unresolved, and worth ≥%.1f pts. This is')
    :format(PURE * 100, MINPTS))
print('  the axis the gate breakdown above splits: a bloc spanning two levers')
print('  is one piece of work, not two.')
local nshown = 0
for i = 1, #blocs do
    local b = blocs[i]
    if nshown >= 5 then break end
    if #b.names > 1 and b.purity >= PURE and pct(b.n) >= MINPTS then
        nshown = nshown + 1
        local nm, shown = {}, 0
        for _, m in ipairs(b.names) do
            if shown >= top then break end
            shown = shown + 1
            nm[#nm + 1] = ('%s %d'):format(m.name, m.n)
        end
        local lv = {}
        for L, n in pairs(b.why) do lv[#lv + 1] = { L = L, n = n } end
        table.sort(lv, function (x, y)
            if x.n ~= y.n then return x.n > y.n end
            return x.L < y.L
        end)
        local lvs = {}
        for k = 1, math.min(#lv, 3) do lvs[#lvs + 1] = ('%s %d'):format(lv[k].L, lv[k].n) end
        print('')
        print(('  #%d  %6d calls  %+5.1f pts  %d names in %d files  %d%% of what those files leave unresolved')
            :format(nshown, b.n, pct(b.n), #b.names, b.files, b.purity * 100 + 0.5))
        print(('        %s%s'):format(table.concat(nm, ' · '),
            #b.names > shown and (' … %d more'):format(#b.names - shown) or ''))
        print(('        levers: %s'):format(table.concat(lvs, ' | ')))
        print(('        e.g. %s'):format(b.eg or '?'))
    end
end
if multi == 0 then
    print('  (none — no group of top names owns a file set of its own. On a corpus')
    print('   whose unresolved mass is one uniform population this is the correct')
    print('   answer, and the lever ranking above is the whole story.)')
end

-- ⚠ THE COLUMN THAT COULD FALSIFY THIS. The per-name histogram and the gate
-- histogram are built in the same loop from the same disposition, so they must
-- agree; if they ever do not, every number above the line is suspect and the
-- reader is told rather than left to trust it.
local nsum = 0
for _, r in ipairs(ranked_names) do nsum = nsum + r.n end
if nsum ~= reachable then
    print('')
    print(('  ⚠ per-name total %d ≠ gate total %d — the two histograms disagree')
        :format(nsum, reachable))
end
