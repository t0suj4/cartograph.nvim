-- The gate runner: a scope-model/extractor-change gate as ONE command.
--
--   nvim --headless -u NONE -l tools/gate.lua <corpus> [--save]
--
--   gate <corpus>         extract, check expected counts (corpora.lua), diff
--                         per-item against the saved baseline snapshot
--                         (graphdiff), print the census + timing. Exit 1 on
--                         any failure — CI-shaped.
--   gate <corpus> --save  extract and (re)write the baseline snapshot. Do
--                         this on a KNOWN-GOOD rev; the next plain run diffs
--                         against it.
--
-- "graphdiff empty on server" (scope-model step 1) is literally:
--   nvim -l tools/gate.lua server

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/gate%.lua$')
local bench = dofile(here .. '/bench.lua')
local snapshot = dofile(here .. '/snapshot.lua')

local name = arg and arg[1]
local save, parallel = false, false
for i = 2, #(arg or {}) do
    if arg[i] == '--save' then save = true end
    if arg[i] == '--parallel' then parallel = true end
end
if not name then
    print('usage: nvim --headless -u NONE -l tools/gate.lua <corpus>'
        .. ' [--save] [--parallel]')
    os.exit(2)
end

bench.bootstrap()
local gd = require 'cartograph.graphdiff'
local census = require 'cartograph.census'

-- corpus identity check BEFORE the (possibly one-minute) extract: a pinned
-- corpus whose checkout moved (or is dirty) can't answer the gate's question
-- — any diff would be corpus drift misread as extractor drift
local corpus = bench.corpus(name)
local now = corpus.git and corpus.git.rev
if corpus.rev then
    if not bench.same_rev(corpus.rev, now) then
        print(('GATE NOT APPLICABLE: corpus %s is pinned @ %s but the checkout'
            .. ' is @ %s — restore the rev, or recalibrate (--save + update'
            .. ' tools/corpora.lua)'):format(name, corpus.rev, now or '?'))
        os.exit(2)
    end
    if corpus.git.dirty then
        print(('GATE NOT APPLICABLE: corpus %s (@ %s) has uncommitted changes')
            :format(name, now))
        os.exit(2)
    end
end

-- --parallel runs the worker pipeline instead of the inline extract; the
-- baselines are INLINE extracts, so a passing per-item diff is the
-- "parallel == sequential, at scale" claim itself
local data, stats
if parallel then
    data, stats = bench.extract_parallel(name)
    -- step 2-live (CARTOGRAPH_MERGECOLS): the parent may hand back a columnar
    -- store instead of records (never materialized at the merge peak). The gate's
    -- census/validate/per-item dump are record-based, so materialize here — the
    -- store == records by construction, so a passing per-item diff still proves
    -- parallel == inline (now via the columnar merge path).
    if data._callstore then
        data.calls = require('cartograph.rescols').materialize(data._callstore)
        data._callstore = nil
    end
else
    -- ★ A GATE IS COLD, ALWAYS AND EXPLICITLY (CART-0429). bench honours
    -- $CARTOGRAPH_BENCH_WARM for the dev loop, so a developer who exported it in this shell
    -- must not have their GATE quietly verify a cached artifact instead of a fresh extract.
    -- Saying `cold` here beats the env; an opt-out that relies on nobody having opted in is
    -- not an opt-out. CART-0245 is why it matters: a warm graph once carried 4122 dangling
    -- edges into nodes that were never saved while the checks stayed green.
    data, stats = bench.extract(name, { cold = true })
end
print(bench.fmt(stats) .. (parallel and '  [parallel]' or ''))
if parallel then
    local w = require('cartograph.parallel')._last_workers
    if w and w.n > 0 then
        print(('workers: n=%d · peak MB p50=%.0f p95=%.0f max=%.0f · work ms'
            .. ' p50=%.0f max=%.0f · spawn overhead ms p50=%.0f')
            :format(w.n, w.hwm_mb.p50 or 0, w.hwm_mb.p95 or 0, w.hwm_mb.max or 0,
                w.wall_ms.p50 or 0, w.wall_ms.max or 0, w.spawn_ms.p50 or 0))
    end
end
if data.ret_resolved then
    print(('return-type rounds: %d calls settled in %d round(s)')
        :format(data.ret_resolved, data.ret_rounds))
end

local c = census.take(data)
local ref = c.edges.ref
print(('nodes %d · edges %d · ref trust: proven %d / ~%d / matched %d · calls refused %d')
    :format(c.nodes.total, c.edges.total, ref.proven, ref.inferred,
        ref.matched, c.calls.refused))

local failed = false

-- the closed schema as an executable registry: unknown fields, dangling
-- endpoints, dup ids, malformed ranges all fail the gate (schema growth
-- means growing validate.lua's allowlists in the same commit)
local validate = require 'cartograph.validate'
local vr = validate.check(data)
print(validate.report(vr))
failed = failed or not vr.ok

-- memory budget (INLINE runs only — parallel peaks in workers): coarse,
-- calibrated at ~2x the observed fresh-process peak — a tripwire for
-- 2x regressions, not a 5%-noise gate. Wall time stays ungated (box
-- noise; the same-day-A/B discipline owns it).
if not parallel and stats.corpus.budget_mb and stats.peak then
    local mb = stats.peak / 2^20
    local okb = mb <= stats.corpus.budget_mb
    print(('memory: peak %.0f MB budget %d MB %s')
        :format(mb, stats.corpus.budget_mb, okb and 'OK' or 'FAIL'))
    failed = failed or not okb
end
local expected = stats.corpus.expected
if expected then
    local refs = c.edges.by_kind.ref or 0
    local okref = not expected.refs or refs == expected.refs
    local oknode = not expected.nodes or c.nodes.total == expected.nodes
    print(('expected counts: refs %d==%s %s · nodes %d==%s %s'):format(
        refs, tostring(expected.refs), okref and 'OK' or 'FAIL',
        c.nodes.total, tostring(expected.nodes), oknode and 'OK' or 'FAIL'))
    failed = failed or not (okref and oknode)
end

if save then
    local path = snapshot.save(name, data, { corpus = name,
        corpus_rev = now, corpus_dirty = corpus.git and corpus.git.dirty or nil })
    print('baseline saved: ' .. path)
else
    local base, meta = snapshot.load(name)
    if not base then
        print(meta .. '  (run with --save on a known-good rev to create it)')
    else
        print(('vs baseline (tool %s @ %s, corpus @ %s%s):'):format(
            meta.rev or '?', meta.when or '?', meta.corpus_rev or '?',
            meta.corpus_dirty and ' DIRTY' or ''))
        -- ── THE TOOL SIDE OF THE SAME QUESTION (CART-0502) ───────────────────
        -- Everything below asks whether the CORPUS held still. Nothing asked
        -- whether the TOOL did, and the failure that made this a P1 was on that
        -- side: 17 of 37 baselines predated three extraction changes, so every
        -- diff they printed was a MIXTURE while reading as attributable. The
        -- number that answers it is cache.VERSION -- the extraction-behaviour
        -- epoch a rev cannot stand in for, because most commits do not touch
        -- extraction and VERSION is exactly the ones that do.
        --
        -- ADVISORY ONLY, deliberately: a stale baseline is not a regression, it
        -- is an unreadable measurement, and the reader is the one who decides
        -- whether to resave. The gating logic below is untouched.
        local tv_epoch, tv_dirty = snapshot.tool_verdict(meta)
        if tv_dirty then print('  NOTE: ' .. tv_dirty) end
        if tv_epoch then print('  NOTE: ' .. tv_epoch) end
        -- Only PINNED-AND-MATCHING or UNPINNED corpora reach here (a pinned corpus
        -- whose checkout moved exited 2 above). For an unpinned one the baseline is a
        -- saved snapshot, so whether a diff is EVIDENCE depends on whether the corpus
        -- itself held still — and there are three cases, not two (CART-0219).
        --
        -- UNKNOWN is not DRIFT. same_rev(nil, nil) returns false, so a corpus with no
        -- recordable identity on either side was being reported as "drifted @ ? -> ?"
        -- and then FAILED. The factorio corpus is exactly that: a SYMLINK ASSEMBLY of
        -- four components — bravest-new-world (a live git repo) plus three unpacked mod
        -- directories that carry their version in the NAME
        -- (space-exploration_0.7.57, _0.7.5, space-exploration-scripts_2.8.1) and are
        -- not repos at all. The assembly has no rev to record, and never will.
        local unknown = not (meta.corpus_rev and now)
        local drifted = not unknown and not bench.same_rev(meta.corpus_rev, now)
        -- DIRTY DEFEATS A MATCHING REV. A rev names a commit, not a working tree, so an
        -- unpinned corpus that was dirty when the snapshot was taken — or is dirty now —
        -- cannot certify it held still even though same_rev says yes. gate.lua already
        -- treats dirty as disqualifying for a PINNED corpus (exit 2 above); this is the
        -- unpinned equivalent.
        -- MEASURED: this is what CART-0219 actually was. `bnw`'s own baseline records
        -- "corpus @ ce053a3d707e DIRTY" and the checkout carries 12 uncommitted changes,
        -- among them scenarios/bnw/control.lua and bnw-force.lua — precisely the files
        -- every one of the factorio corpus's ~985 ref-edge diffs sat in. Not extractor
        -- drift and not a stale tool baseline: uncommitted edits to a mod symlinked into
        -- the corpus.
        local dirty = (meta.corpus_dirty and true or false)
            or (corpus.git and corpus.git.dirty and true or false)
        if dirty and not (unknown or drifted) then
            print('  NOTE: corpus has UNCOMMITTED changes (baseline or now) — a rev names'
                .. ' a commit, not a working tree, so any diff below is CONTEXT')
        elseif unknown then
            print(('  NOTE: corpus identity UNRECORDABLE (baseline %s, now %s) — this'
                .. ' corpus cannot certify that it held still, so any diff below is'
                .. ' CONTEXT'):format(meta.corpus_rev or '?', now or '?'))
        elseif drifted then
            print(('  NOTE: corpus rev drift (baseline @ %s, now @ %s) — diffs'
                .. ' below may be corpus change, not extractor change')
                :format(meta.corpus_rev or '?', now or '?'))
        end
        local d = gd.diff(base, snapshot.slim(data))
        for _, l in ipairs(gd.report(d, { limit = 25 })) do print('  ' .. l) end
        if not gd.empty(d) then
            -- THE RULE corpora.lua has always documented and this file did not honour:
            -- "UNPINNED (no rev): living corpora … the gate surfaces rev drift as
            -- CONTEXT INSTEAD OF FAILING." It printed the note and then failed anyway.
            -- ADVISORY when the corpus cannot vouch for itself; a FAILURE when it can:
            -- an unpinned corpus whose rev is KNOWN and UNCHANGED and whose graph moved
            -- IS an extractor regression, and that signal is kept.
            -- A PINNED corpus NEVER goes advisory. Its rev was verified against the
            -- checkout above (mismatch exits 2), so its identity IS known regardless of
            -- what an OLD snapshot recorded — a meta.corpus_rev of nil there would
            -- otherwise flip a real gate to advisory silently, which is the exact
            -- failure mode this whole change exists to remove.
            if not corpus.rev and (unknown or drifted or dirty) then
                print('  ADVISORY: not a failure — the corpus could not certify it held'
                    .. ' still. Pin it (repo+rev+expected) to make diffs gate.')
            else
                failed = true
            end
        end
    end
end

print(failed and 'GATE: FAIL' or 'GATE: PASS')
os.exit(failed and 1 or 0)
