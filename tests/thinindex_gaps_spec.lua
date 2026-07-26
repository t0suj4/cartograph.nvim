-- The thin-index-vs-fat-session gaps. The first two tests here were written RED, landed
-- skipped so the commit fence stayed green, and are now GREEN — they stand as the
-- regressions for two fixes that share one shape: A FIELD ANSWERING TWO QUESTIONS.
--   1. the coverage ledgers could not accumulate, because a materializer's own re-ingest
--      cleared them (reset_indexes could not tell a NEW graph from a re-index of the
--      same one). Fixed with an explicit keep_ledgers opt, not by inferring identity —
--      refresh also re-ingests in place and CAN remove a file.
--   2. index_only conflated PROVENANCE ("came from the index-only front end", which the
--      cache must respect forever) with CAPABILITY ("is there a call graph?", which
--      materialization can change). is_index_only() now answers capability; the field
--      stays for the cache. Same shape as the cbarg bug in reduce_mentions.
--
-- Compatibility as measured 2026-07-26 ([[cartograph-thin-index]],
-- [[cartograph-merging-strategies]]): demand materialization is site-for-site EXACT on
-- a homogeneous tree (lua/cartograph 2836/2836, ruby 486/486, the plugin's spec dir
-- 680/680) and diverges on the polyglot repo ROOT (880/936: 8 tier · 41 under · 7
-- over). Under-resolution is the safe direction; OVER-resolution is not. The gaps that
-- only reproduce at corpus scale are ratcheted in tools/demandcalls.lua, not here — a
-- root extract is ~6.6s and the root divergence needs that tool's particular file pick.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

-- small enough to materialize ENTIRELY, which is the point of the first two tests: the
-- claims are about a thin index that has been filled in completely. Every file here
-- CONTAINS CALLS, so every materialization takes the re-ingest path — the path that
-- used to wipe the ledgers.
local FILES = {
    ['lib/util.lua'] = [[
local function util_alpha(x) return x + 1 end
local function util_beta(x) return util_alpha(x) * 2 end
return { util_alpha = util_alpha, util_beta = util_beta }
]],
    ['app/main.lua'] = [[
local u = require 'lib.util'
local function main_run() return u.util_beta(1) end
local function main_helper() return main_run() end
return { main_run = main_run, main_helper = main_helper }
]],
}

local function build()
    local root = vim.fn.tempname()
    for rel, text in pairs(FILES) do
        local dir = rel:match('^(.*)/[^/]*$')
        vim.fn.mkdir(root .. (dir and '/' .. dir or ''), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text); fd:close()
    end
    return root
end

local function sorted_files()
    local f = {}
    for rel in pairs(FILES) do f[#f + 1] = rel end
    table.sort(f)
    return f
end

-- WAS RED — the coverage ledgers did not accumulate.
-- materialize_file_calls ends with `M._calls_materialized[rel] = true`, set AFTER its
-- internal M.ingest(M.data) because ingest's reset_indexes() clears the ledgers (a NEW
-- graph invalidates them). Only the CURRENT file was re-set, so every successful
-- materialization erased the record of every earlier one. Measured on a 3-file tree:
-- calls returned true for two files and calls_materialized() then reported ONLY the
-- third — the one with no calls that never materialized at all; on this 2-file fixture
-- the ledger came back EMPTY. Not cosmetic: these two functions are the coverage API the
-- capability predicate consults (next test), and idpass_materialized() is user-visible
-- through :CartographMentions, which therefore under-reported.
-- Fixed by an explicit `keep_ledgers` opt on M.ingest, deliberately NOT inferred from
-- `data == M.data`: refresh mutates the graph in place and re-ingests it too, and it can
-- REMOVE a file — which would leave an entry claiming calls that are no longer there.
-- Only a caller that knows its splice was additive may keep them.
test('thin index: coverage ledgers ACCUMULATE across materializations', function ()
    if not ready() then skip 'no lua parser' end
    local root = build()
    store.ingest(ts.index_only(root))
    local files = sorted_files()
    local claimed = {}
    for _, rel in ipairs(files) do
        store.materialize_file_dataflow(rel)
        if store.materialize_file_calls(rel) then claimed[#claimed + 1] = rel end
        store.materialize_file_idpass(rel)
    end
    -- every file has calls, so every one reports that it materialized them
    eq(files, claimed)
    -- ... and the ledger must agree with what the calls returned
    eq(files, store.calls_materialized())
    eq(files, store.idpass_materialized())
    vim.fn.delete(root, 'rf')
end)

-- WAS RED — the marker never cleared.
-- Refusing while coverage is partial is the uniform-honesty invariant working as
-- designed. But once EVERY file's calls and id pass are materialized the graph IS a call
-- graph, and the marker still said otherwise — so commands.whole_graph(), which reads
-- this predicate, made 10 verbs (4 analysis, 6 honesty) refuse a graph that could answer
-- them. Verified by hand at the time: ladder.report and census.report both run on the
-- materialized fixture graph.
-- Fixed by splitting the two questions the one field was answering. What this test does
-- NOT claim: a fully materialized graph can still differ from a full extract in TIER,
-- and on a polyglot root in a few over-resolutions (the monotonicity ratchet in
-- tools/demandcalls.lua holds that). That is a quality gap, not the empty "none" the
-- refusal exists to prevent.
test('thin index: total coverage retires the index-only CAPABILITY, keeps provenance', function ()
    if not ready() then skip 'no lua parser' end
    local root = build()
    store.ingest(ts.index_only(root))
    ok(store.is_index_only(), 'starts thin (precondition)')
    for _, rel in ipairs(sorted_files()) do
        store.materialize_file_dataflow(rel)
        store.materialize_file_calls(rel)
        store.materialize_file_idpass(rel)
    end
    -- the demand graph now holds every call the full extract does
    eq(#(ts.extract(root).calls or {}), #(store.data.calls or {}))
    local cov = store.coverage()
    eq(cov.files, cov.calls)
    eq(cov.files, cov.idpass)
    ok(cov.complete, 'coverage reports complete')
    ok(not store.is_index_only(),
        'total per-file coverage should retire the index-only marker')
    -- ... and PROVENANCE survives, which is what keeps the fix safe: cache.lua reads
    -- data.index_only DIRECTLY (a thin cache must never be served to a full open, and a
    -- partial graph's self-type map must not overwrite a whole one). Capability is what
    -- the honesty guards ask; provenance is a fact about where the graph came from.
    eq(true, store.data.index_only)
    vim.fn.delete(root, 'rf')
end)

-- GREEN, and labelled honestly. The invariant that makes a partial graph SAFE to
-- serve: it may know LESS than the whole graph, never more. It is violated at corpus
-- scale — the repo root, 7 sites (all one nested 2-char `cb` in fsm.lua), and rust
-- with no carried self-type map, 1 site — and NEITHER has a fixture-scale
-- reproduction: a ruby poison fixture and two short-name fixtures were tried, and all
-- resolved correctly. So the RED version of this property is the FLOOR in
-- tools/demandcalls.lua; this stays as the fixture-scale guard, where attribution is
-- cheap if something breaks monotonicity this small.
test('thin index: demand resolution is MONOTONE — never resolves what full declines',
    function ()
    if not ready() then skip 'no lua parser' end
    local root = build()
    local full = ts.extract(root)
    local callrec = require 'cartograph.callrec'
    local function key(c)
        return ('%s\31%s\31%s\31%s'):format(tostring(callrec.file(c)),
            tostring(callrec.fn(c)), tostring(callrec.callee(c)),
            tostring(callrec.line(c)))
    end
    local oracle, collided = {}, {}
    for _, c in ipairs(full.calls or {}) do
        local k = key(c)
        if oracle[k] ~= nil then collided[k] = true else oracle[k] = c.to or false end
    end
    store.ingest(ts.index_only(root))
    for _, rel in ipairs(sorted_files()) do
        store.materialize_file_dataflow(rel)
        store.materialize_file_calls(rel)
    end
    local over, compared = {}, 0
    for _, c in ipairs(store.data.calls or {}) do
        local k = key(c)
        if oracle[k] ~= nil and not collided[k] then
            compared = compared + 1
            if c.to and oracle[k] == false then
                over[#over + 1] = ('%s:%s %s -> %s (full declined)'):format(
                    callrec.file(c), tostring(callrec.line(c)),
                    tostring(callrec.callee(c)), tostring(c.to))
            end
        end
    end
    ok(compared > 0, 'sites were actually compared (not a vacuous pass)')
    eq({}, over)
    vim.fn.delete(root, 'rf')
end)
