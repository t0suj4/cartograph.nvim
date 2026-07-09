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
else
    data, stats = bench.extract(name)
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
        if not bench.same_rev(meta.corpus_rev, now) then
            -- unpinned corpora reach here (pinned ones bailed above): the
            -- diff is still shown, but it may be the CORPUS that moved
            print(('  NOTE: corpus rev drift (baseline @ %s, now @ %s) — diffs'
                .. ' below may be corpus change, not extractor change')
                :format(meta.corpus_rev or '?', now or '?'))
        end
        local d = gd.diff(base, snapshot.slim(data))
        for _, l in ipairs(gd.report(d, { limit = 25 })) do print('  ' .. l) end
        failed = failed or not gd.empty(d)
    end
end

print(failed and 'GATE: FAIL' or 'GATE: PASS')
os.exit(failed and 1 or 0)
