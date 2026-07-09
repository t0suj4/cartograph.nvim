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
local save = false
for i = 2, #(arg or {}) do if arg[i] == '--save' then save = true end end
if not name then
    print('usage: nvim --headless -u NONE -l tools/gate.lua <corpus> [--save]')
    os.exit(2)
end

bench.bootstrap()
local gd = require 'cartograph.graphdiff'
local census = require 'cartograph.census'

local data, stats = bench.extract(name)
print(bench.fmt(stats))

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
    local path = snapshot.save(name, data, { corpus = name })
    print('baseline saved: ' .. path)
else
    local base, meta = snapshot.load(name)
    if not base then
        print(meta .. '  (run with --save on a known-good rev to create it)')
    else
        local d = gd.diff(base, snapshot.slim(data))
        print(('vs baseline (%s @ %s):'):format(meta.rev or '?', meta.when or '?'))
        for _, l in ipairs(gd.report(d, { limit = 25 })) do print('  ' .. l) end
        failed = failed or not gd.empty(d)
    end
end

print(failed and 'GATE: FAIL' or 'GATE: PASS')
os.exit(failed and 1 or 0)
