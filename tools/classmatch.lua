-- SHAPE-MATCH MEASUREMENT (CART-0590) — the harness that produces the numbers
-- lua/cartograph/classmatch.lua's premise rests on, over a real corpus.
--
--   nvim --headless -u NONE -l tools/classmatch.lua [<corpus|path>] [--show N]
--        [--only determined|ambiguous|zero|no-shape] [--exclude-known]
--   nvim --headless -u NONE -l tools/classmatch.lua --answer-key   (no corpus)
--
-- THE ANALYSIS LIVES IN lua/cartograph/classmatch.lua AND THIS READS IT — one
-- implementation, so the probe's numbers and the verb's display cannot diverge
-- (the rule extractapply follows for its splice). What lives here is the
-- measurement: the corpus sweep, the population filters stated out loud, and the
-- comparison against the RECORDED run.
--
-- ★ THE RECORDED RUN IS PART OF THE OUTPUT, not a comment. CART-0590's premise
-- was measured on four 2.0 mods (~/work/factorio-mods, 21082 calls) against the
-- 2.0.72 export, and those numbers are the specification. This harness prints
-- them beside the ones it computes, so a SILENT DIVERGENCE is impossible: an
-- implementation that quietly moved the population would otherwise report a
-- plausible table nobody could compare to anything.
--
-- ⚠ COLD BY CONSTRUCTION. The extract passes `cold`, so this never reads or
-- writes the corpus cache: a probe must not poison a shared cache, and a
-- re-distilled profile artifact has moved the validity stamp anyway.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()

local cm = require 'cartograph.classmatch'
local externals = require 'cartograph.externals'

-- the RECORDED premise run (CART-0590 note, 2026-08-27), for comparison only
local RECORDED = {
    corpus = 'factorio', calls = 21082, bases = 256, zero = 74, zero_far = 66,
    buckets = { [1] = { 106, 182 }, [2] = { 59, 67 }, [3] = { 37, 39 }, [5] = { 21, 22 } },
}

local args = { corpus = 'factorio', show = 25 }
do
    local i = 1
    while arg and arg[i] do
        local a = arg[i]
        if a == '--show' then i = i + 1; args.show = tonumber(arg[i]) or 25
        elseif a == '--only' then i = i + 1; args.only = arg[i]
        elseif a == '--exclude-known' then args.exclude_known = true
        elseif a == '--answer-key' then args.answer_key_only = true
        elseif not a:match('^%-%-') then args.corpus = a end
        i = i + 1
    end
end

local function hdr(s) io.write('\n=== ' .. s .. ' ===\n') end

-- ── the DECLARED-shape answer key: needs no corpus ──────────────────────────
hdr('answer key (declared shapes — every documented class against itself)')
for _, l in ipairs(cm.answer_key_report()) do io.write(l .. '\n') end
if args.answer_key_only then return end

-- ── the corpus sweep ────────────────────────────────────────────────────────
local data = bench.extract(args.corpus, { cold = true })
require('cartograph.store').ingest(data)
local store = require 'cartograph.store'
local surf = externals.surface(store)

local rows, sum = cm.of_surface(surf, nil)
if not rows then io.write('UNAVAILABLE: ' .. tostring(sum) .. '\n'); os.exit(2) end

hdr('population')
io.write(('  corpus %s — %d calls: %d resolved, %d external(~), %d internal-multi,'
    .. ' %d cross-scope, %d stdlib-tail, %d unread\n'):format(args.corpus, surf.total,
    surf.resolved, surf.external, surf.internal_multi, surf.cross_scope,
    surf.stdlib_tail, surf.unread))
io.write(('  %d external bases judged (KNOWN builtin bases INCLUDED — `table`, `string`,'
    .. ' … are exactly where a match is expected to be WRONG, so they are flagged,'
    .. ' not hidden)\n'):format(sum.bases))
local m = sum.meta or {}
io.write(('  class table: %d classes from %s (%s, api v%s)\n'):format(sum.classes,
    tostring(m.artifact), tostring(m.version), tostring(m.api_version)))

hdr('outcomes')
io.write(('  determined %4d bases / %6d calls\n'):format(sum.determined, sum.calls.determined))
io.write(('  ambiguous  %4d bases / %6d calls\n'):format(sum.ambiguous, sum.calls.ambiguous))
io.write(('  no-class   %4d bases / %6d calls   (%d UNRELATED: no class within one'
    .. ' member that shares anything = not an API object)\n')
    :format(sum.zero, sum.calls.zero, sum.zero_far))
io.write(('  no-shape   %4d bases / %6d calls   (bare calls only — no shape to match)\n')
    :format(sum.no_shape, sum.calls.no_shape))
io.write(('  of the determined, %d are on a RECOGNIZED builtin base (candidate wrongs)\n')
    :format(sum.known_determined))

hdr('discrimination — unique / matching >=1 class')
io.write('   n     this run              recorded 2026-08-27     call-weighted\n')
for _, b in ipairs(sum.buckets) do
    local rec = RECORDED.buckets[b.n]
    local recs = rec and ('%d/%d = %.1f%%'):format(rec[1], rec[2], rec[1] / rec[2] * 100)
        or '—'
    local agree = rec and (rec[1] == b.unique and rec[2] == b.matched) and ' ==' or
        (rec and ' DIVERGES' or '')
    io.write(('  >=%d  %4d/%-4d = %5.1f%%   %-18s%s   %5.1f%% (%d calls)\n')
        :format(b.n, b.unique, b.matched, b.pct, recs, agree, b.call_pct, b.calls))
end
-- ── RECONCILING THE POPULATION, out loud ────────────────────────────────────
-- The recorded run counted "candidate bases" as bases WITH A SHAPE and WITHOUT a
-- recognized-builtin flag. Both filters are stated here and both are applied to a
-- second set of counters, because a base count that silently means something else
-- turns an agreeing measurement into a divergent-looking one (and vice versa).
local ex = { bases = 0, zero = 0, far = 0, determined = 0, ambiguous = 0 }
for _, r in ipairs(rows) do
    if r.ev.n > 0 and not r.known then
        ex.bases = ex.bases + 1
        if r.ev.outcome == 'zero' then
            ex.zero = ex.zero + 1
            if cm.unrelated(r.ev) then ex.far = ex.far + 1 end
        elseif r.ev.outcome == 'determined' then ex.determined = ex.determined + 1
        elseif r.ev.outcome == 'ambiguous' then ex.ambiguous = ex.ambiguous + 1 end
    end
end
io.write(('\n  candidate bases (n>=1, KNOWN builtins excluded — the recorded population):\n'
    .. '    recorded  %d bases, %d no-class of which %d unrelated\n'
    .. '    this run  %d bases, %d no-class of which %d unrelated%s\n'):format(
    RECORDED.bases, RECORDED.zero, RECORDED.zero_far,
    ex.bases, ex.zero, ex.far,
    (ex.bases == RECORDED.bases and ex.zero == RECORDED.zero
        and ex.far == RECORDED.zero_far) and '   == recorded' or '   DIVERGES'))
io.write(('    (the full judged set is %d bases: +%d bare-only with no shape, +%d'
    .. ' recognized builtins)\n'):format(sum.bases, sum.no_shape,
    sum.bases - sum.no_shape - ex.bases))

-- ── the OBSERVED-shape answer key: the 9 declared globals, as this corpus uses them
hdr('answer key (observed shapes — how this corpus actually uses the 9 globals)')
local shapes = {}
for base, e in pairs(surf.bases) do shapes[base] = e.members end
local akrows, aksum = cm.answer_key(nil, nil, shapes)
if akrows then
    for _, l in ipairs(cm.answer_key_report { shapes = shapes }) do io.write(l .. '\n') end
    io.write(('  => %d/%d contain the declared class, %d unique, %d not observed here\n')
        :format(aksum.contains, aksum.n, aksum.unique, aksum.missing_shape))
else
    io.write('  UNAVAILABLE: ' .. tostring(aksum) .. '\n')
end

hdr(('bases (top %d by calls%s)'):format(args.show,
    args.only and (', only ' .. args.only) or ''))
local shown = 0
for _, r in ipairs(rows) do
    if not (args.only and r.ev.outcome ~= args.only)
        and not (args.exclude_known and r.known) then
        shown = shown + 1
        if shown > args.show then break end
        io.write(('  %-24s x%-5d %-7s %s\n'):format(r.base, r.calls,
            r.known and 'stdlib' or '', cm.line(r.ev)))
    end
end
