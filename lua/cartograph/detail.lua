-- DETAIL: page the flesh on demand. The fold ([[cartograph-fold]]) keeps
-- node-granularity topology resident and DROPS the sub-node detail —
-- argv (argument shapes: kwargs/spreads/typed-strings), per-occurrence
-- `at` ranges, the refusal candidate sets. This module reconstructs that
-- detail for ONE file by re-parsing it (~ms), which is the seam the whole
-- "ride the skeleton, page the flesh" design rests on and was, until now,
-- unbuilt. It unblocks:
--   * dropping the fat resident calls[] (the memo's 60%-of-heap tables) —
--     once the detail consumers (framework lints, sql miner, apertures,
--     trace, refs) read through here instead of resident tables;
--   * the graph-VM's escape hatch — visiting a function for a richer
--     transfer function than its summary ([[graph-vm-type-resolution]]).
--
-- Detail is SYNTACTIC (argv/at/callee are set in extract's main loop,
-- before resolution), so a single-file re-parse reproduces it exactly —
-- resolution (c.to) is NOT reconstructed here (that's the fold's job).
-- Node ids are deterministic from (file, name, line), so reconstructed
-- c.fn matches the resident node ids of an unchanged file.

local M = {}

-- all call sites in `file` (rel path), each { fn, callee/full, argv, at,
-- line, refused, ... } exactly as extract emits pre-resolution. One
-- re-parse; the id pass is skipped (detail needs no global name table).
function M.file_calls(store, file)
    local data = store.data
    local fileset = store._fileset
    if not fileset then
        fileset = {}
        for _, f in ipairs(store.files or {}) do fileset[f] = true end
    end
    local mini = require('cartograph.providers.treesitter').extract(
        data.root, { subdirs = { file }, fileset = fileset,
            skip_idpass = true, abs = data.abs })
    return mini.calls or {}
end

-- the call sites INSIDE function `fn_id` (with argv/at) — the on-demand
-- twin of the resident store.calls_by_fn[fn_id]
function M.calls_of(store, fn_id)
    local node = store.node(fn_id)
    if not node then return {} end
    local out, k = {}, 0
    for _, c in ipairs(M.file_calls(store, node.file)) do
        if c.fn == fn_id then k = k + 1; out[k] = c end
    end
    return out
end

return M
