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

--- The ANALYSIS-TIME twin of the index above: every module-scope binding in the
--- store whose right-hand side EVALUATES to a known literal, of ANY type.
--- `{ [file] = { [name] = value } }`, where a value is whatever expr.eval yields
--- (a string with its quotes already stripped, a number, a boolean).
---
--- ★ WHY THIS IS NOT M.record's INDEX, and must not become it. That one is built
--- during extraction and its values are FOLDED INTO argv, which is why it is
--- string-only: `k='lit'` carries the contract that `v` is a string exactly as it
--- would be from a literal, and admitting numbers there would break every consumer
--- that trusts it. This index is READ-ONLY — nothing is folded, nothing is written
--- back into the graph — so it is free to carry numbers and booleans, which is the
--- whole point: the case that motivated it is `local RULE_SHIFT = 2`. (CART-0352)
---
--- Same set-once honesty as M.record: a name bound more than once at module scope
--- with differing values is POISONED and never recovers, because "the value of that
--- name here" is then a question we cannot answer. A binding whose RHS does not
--- evaluate (a call, a table, another name) is simply ABSENT — it is not a constant,
--- and absent is the honest record of that.
---
--- ★ WHAT "CONSTANT" HERE DOES NOT COVER, stated because the name overclaims otherwise:
--- set-once is checked at MODULE SCOPE ONLY. A name assigned inside a function body — a
--- `local count = 0` that some function increments — is an upvalue write this index never
--- sees, and it will sit here as though it were the constant 0. No consumer has produced a
--- false finding from it yet (row_drift additionally requires a matching twin statement),
--- but the honest close is the WRITE AXIS, which already knows which names are written.
---@param store table
---@return table { [file] = { [name] = any } }
function M.literal_index(store)
    local expr = require 'cartograph.expr'
    local out = {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'module' and n.file then
            local ok, mo = pcall(expr.of_module, store, n.id)
            local stmts = ok and mo and mo.fl and mo.fl.stmts
            if stmts then
                local cd, poisoned = out[n.file] or {}, {}
                out[n.file] = cd
                for _, s in ipairs(stmts) do
                    -- single-name single-value bindings only: a torn multi-assign
                    -- (`local a, b = f()`) has no per-name literal to speak of
                    if s.def and #s.def == 1 and s.expr and s.expr.rhs and #s.expr.rhs == 1
                        and #(s.expr.lhs or {}) <= 1 then
                        local name = s.def[1]
                        local known, v = expr.eval(s.expr.rhs[1])
                        -- SCALARS ONLY. expr.eval refuses tables/calls outright, but a
                        -- bare `local t` evaluates to the NIL SENTINEL, which is a table
                        -- and would sit in the index as though it were a value. A nil
                        -- binding is not a constant — it is a declaration — and nothing
                        -- can be a hardcoded copy of it. (Measured: 33 such entries on
                        -- 50 WoW addons, every one a nil declaration.)
                        local ty = type(v)
                        if ty ~= 'string' and ty ~= 'number' and ty ~= 'boolean' then
                            known = false; v = nil
                        end
                        if poisoned[name] then -- stays dead, never recovers
                        elseif not known or v == nil then
                            poisoned[name] = true; cd[name] = nil
                        elseif cd[name] == nil then cd[name] = v
                        elseif cd[name] ~= v then poisoned[name] = true; cd[name] = nil end
                    end
                end
            end
        end
    end
    return out
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
