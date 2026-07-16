-- Proper constant folding — ladder step 1 (same-file scalar constants).
--
-- The VALUE analog of the VM's return-type rounds: a call argument that is a
-- bare identifier is captured by the extractor as `argv = {k='local', name=…}`
-- (a deferred reference). This pass UPGRADES such a slot to a known literal
-- (`k='lit', v=…`) when the name provably folds to a set-once scalar constant
-- defined in the SAME file. The lift the stage-3 registry census measured
-- (LibStub:NewLibrary(MAJOR) where `local MAJOR = "AceGUI-3.0"`): 3.3% → 90.6%
-- of retrievals resolvable once the register side folds its key.
--
-- SOUND-ONLY (the honesty gate, [[cartograph-const-fold]] / [[cartograph-vision]]):
-- a name folds iff it has EXACTLY ONE string-literal binding in the file. Any
-- rebind, any non-string binding, or a torn (multi-assign cross-product) binding
-- POISONS the name (index value `false`) — a function/table/expr-valued or
-- reassigned local stays `k='local'`, honestly unfolded. String-only keeps the
-- `k='lit'` contract intact (its `v` is always a string, as from a literal).
--
-- The index is built at extraction time (treesitter handle_var) and the fold is
-- baked into `calls` before the graph is returned, so parallel workers and the
-- relink path inherit folded argv with no side-table merge.

local M = {}

--- Record one same-file binding into a const index, maintaining the set-once
--- gate. `sv` is the folded STRING value, or nil for a non-string / unfoldable
--- binding. Symmetric poisoning: first non-string binding, or any differing
--- rebind, sets the name to `false` (poisoned) and it never recovers.
---@param index table   { [file] = { [name] = string|false } }
---@param file string
---@param name string
---@param sv string|nil
function M.record(index, file, name, sv)
    local cd = index[file]
    if not cd then cd = {}; index[file] = cd end
    if cd[name] == nil then
        cd[name] = sv ~= nil and sv or false
    elseif cd[name] ~= sv then
        cd[name] = false
    end
end

--- Fold a call list's argv IN PLACE against a same-file const index.
--- Returns the number of argv slots folded (for measurement/provenance).
---@param calls table    the graph's call records (each with .file, .argv)
---@param index table    { [file] = { [name] = string|false } }
---@return integer folded
function M.fold(calls, index)
    local n = 0
    for _, c in ipairs(calls) do
        local consts = c.file and index[c.file]
        if consts and c.argv then
            for _, a in ipairs(c.argv) do
                if a.k == 'local' and a.name then
                    local v = consts[a.name]
                    if type(v) == 'string' then
                        a.k = 'lit'
                        a.v = v
                        a.name = nil
                        a.l = nil
                        a.cf = true -- provenance: value arrived by const-fold
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

return M
