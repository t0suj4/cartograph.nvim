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

--- Largest constructor table still treated as a table of CONSTANTS rather than DATA.
--- The knee of a measured bimodal distribution, not a taste call — see literal_index.
M.MAX_CONST_FIELDS = 20

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
--- ★ TABLE-OF-CONSTANTS, both forms (CART-0355). A key may be a bare name OR a DOTTED
--- PATH — `C.SHIFT` for `local C = { SHIFT = 2 }` (constructor) and for a module-scope
--- `C.SHIFT = 2` (build-up). The census that motivated this counted, per corpus, the
--- module-scope bindings of each idiom; the table form holds 3.1x more constants than
--- bare scalars on this tree (180 -> 565) and +57%/+68% on two WoW batches, ALL same-file.
---
--- ★ THE SIZE CAP IS NOT A HEURISTIC, IT SEPARATES TWO POPULATIONS. Constructor tables are
--- bimodal: small named-constant tables (CTRL, ASSIGN_OP, KNOWN — the class the one real
--- row-drift finding came from) and large DATA tables. On 50 WoW addons the raw field count
--- is 17510, of which ~15000 live in nine tables: seven Atlas locale tables (~1305 each),
--- a 1871-entry recipe flag map and a 1754-entry spell table. Nobody hardcodes a copy of a
--- localisation string by accident, and indexing them costs memory the row tier already
--- cannot afford (CART-0356). `max_fields` is the knee measured on that distribution.
---
--- ★ WHAT "CONSTANT" HERE DOES NOT COVER, stated because the name overclaims otherwise:
--- set-once is checked at MODULE SCOPE ONLY. A name assigned inside a function body — a
--- `local count = 0` that some function increments — is an upvalue write this index never
--- sees, and it will sit here as though it were the constant 0. No consumer has produced a
--- false finding from it yet (row_drift additionally requires a matching twin statement),
--- but the honest close is the WRITE AXIS, which already knows which names are written.
--- The dotted form inherits exactly this limit: `C.SHIFT = 3` inside a function is invisible.
---
--- ★ AND IT IS LUA-SHAPED UNTIL CART-0357 CLOSES. expr's TABLE set holds only the Lua
--- constructor spellings, so a JS `{ SHIFT: 2 }` / python dict / ruby hash harvests as the
--- honest-unknown `?` and contributes NOTHING here. The zero is a detector gap, not an
--- absence — closing 0357 extends this index to those languages for free.
---@param store table
---@param opts table|nil  { max_fields = 20 }
---@return table { [file] = { [name or dotted path] = any } }
function M.literal_index(store, opts)
    local expr = require 'cartograph.expr'
    local max_fields = (opts and opts.max_fields) or M.MAX_CONST_FIELDS
    local out = {}
    -- SCALARS ONLY. expr.eval refuses tables/calls outright, but a bare `local t`
    -- evaluates to the NIL SENTINEL, which is a table and would sit in the index as
    -- though it were a value. A nil binding is not a constant — it is a declaration —
    -- and nothing can be a hardcoded copy of it. (Measured: 33 such entries on 50 WoW
    -- addons, every one a nil declaration.)
    local function scalar(e)
        local known, v = expr.eval(e)
        local ty = type(v)
        if not known or (ty ~= 'string' and ty ~= 'number' and ty ~= 'boolean') then return nil end
        return v
    end
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'module' and n.file then
            local ok, mo = pcall(expr.of_module, store, n.id)
            local stmts = ok and mo and mo.fl and mo.fl.stmts
            if stmts then
                local cd, poisoned, deadbase = out[n.file] or {}, {}, {}
                out[n.file] = cd
                -- set-once, uniformly: a key already holding a DIFFERENT value is dead and
                -- never recovers, and so is a key whose binding does not evaluate.
                local function put(key, v)
                    if poisoned[key] then return end
                    if v == nil then poisoned[key] = true; cd[key] = nil
                    elseif cd[key] == nil then cd[key] = v
                    elseif cd[key] ~= v then poisoned[key] = true; cd[key] = nil end
                end
                -- a table REBOUND at module scope invalidates every field it ever held:
                -- `C.SHIFT` is only a constant while C is the same table.
                local function kill_base(base)
                    deadbase[base] = true
                    local pre = base .. '.'
                    for k in pairs(cd) do
                        if k:sub(1, #pre) == pre then poisoned[k] = true; cd[k] = nil end
                    end
                end
                local bound = {}
                for _, s in ipairs(stmts) do
                    local lhs, rhs = (s.expr and s.expr.lhs) or {}, (s.expr and s.expr.rhs) or {}
                    if s.def and #s.def == 1 and #rhs == 1 and #lhs <= 1 then
                        -- single-name single-value bindings only: a torn multi-assign
                        -- (`local a, b = f()`) has no per-name literal to speak of
                        local name, e = s.def[1], rhs[1]
                        if bound[name] then kill_base(name) end
                        bound[name] = true
                        if e.k == 'table' then
                            -- (b1) CONSTRUCTOR. Collected first, then applied — a table
                            -- over the cap must contribute NOTHING, not its first 20 fields.
                            local fields, nf = {}, 0
                            for _, kid in ipairs(e.kids or {}) do
                                if kid.k == 'pair' and kid.key and kid.key.k == 'lit' then
                                    local v = scalar(kid.val)
                                    if v ~= nil then nf = nf + 1; fields[tostring(kid.key.v)] = v end
                                end
                            end
                            if nf <= max_fields and not deadbase[name] then
                                for k, v in pairs(fields) do put(name .. '.' .. k, v) end
                            end
                            put(name, nil) -- the table itself is not a scalar constant
                        else
                            put(name, scalar(e))
                        end
                    elseif #lhs == 1 and #rhs == 1 and lhs[1].k == 'field' then
                        -- (b2) BUILD-UP `T.F = v` at module scope. On one WoW batch this
                        -- form outnumbered the constructor 986 to 270, so it is not a corner.
                        local path = expr.dotted(lhs[1])
                        local base = path and path:match('^([^.]+)')
                        if path and base and not deadbase[base] then put(path, scalar(rhs[1])) end
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
