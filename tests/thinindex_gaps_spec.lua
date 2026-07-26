-- RED TESTS — the measured thin-index-vs-fat-session gaps, written as tests so the fix
-- has a target and the gap cannot be quietly forgotten.
--
-- The two `RED` tests FAIL when their `skip` line is removed; the skip is there ONLY so
-- the commit fence stays green while the fix lands, and each one names the defect it is
-- waiting on. DELETE THE SKIP, don't weaken the assertion — a red test made green by
-- lowering the bar is worse than no test. To see them fail as intended, remove the one
-- `skip` line at the top of the body.
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

-- small enough to materialize ENTIRELY, which is the point of both red tests: the
-- claims are about a thin index that has been filled in completely. Every file here
-- CONTAINS CALLS, so every materialization takes the re-ingest path.
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

-- RED #1 — THE COVERAGE LEDGERS DO NOT ACCUMULATE.
-- materialize_file_calls ends with `M._calls_materialized[rel] = true`, set AFTER its
-- internal M.ingest(M.data) because ingest's reset_indexes() clears the ledgers by
-- design (a new graph invalidates them, and ingest cannot tell its own caller's
-- re-ingest from a fresh open). But only the CURRENT file is re-set, so every
-- successful materialization ERASES the record of every earlier one. Measured on a
-- 3-file tree: calls returned true for two files, and calls_materialized() then
-- reported ONLY the third — the one that had no calls and never materialized at all.
-- This is not cosmetic bookkeeping: these two functions are the coverage API a
-- coverage-aware whole_graph() guard has to consult (see RED #2), and
-- idpass_materialized() is ALREADY user-visible — :CartographMentions reports per-file
-- coverage from it, so it under-reports today.
test('RED thin index: coverage ledgers lose every earlier file', function ()
    if not ready() then skip 'no lua parser' end
    skip 'KNOWN RED: ingest resets the ledgers; only the current file is re-set'
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

-- RED #2 — THE MARKER NEVER CLEARS.
-- materialize_file_calls' comment says it does not clear index_only because "one
-- file's calls is not a call graph" — true per file, and refusing while coverage is
-- partial is the uniform-honesty invariant working as designed. But when EVERY file's
-- calls and id pass have been materialized, the graph IS a call graph, and the marker
-- still says otherwise. commands.lua's whole_graph() reads this exact predicate, so 10
-- verbs (4 in analysis.lua, 6 in honesty.lua) refuse a graph that can answer them. The
-- guard should ask COVERAGE; the marker is what makes that impossible today.
test('RED thin index: a FULLY materialized graph is still marked index-only', function ()
    if not ready() then skip 'no lua parser' end
    skip 'KNOWN RED: index_only never clears, so whole_graph() refuses a full graph'
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
    ok(not store.is_index_only(),
        'total per-file coverage should retire the index-only marker')
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
