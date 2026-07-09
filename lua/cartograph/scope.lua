-- ScopeModel: per-file lexical scope machinery — the promotion of the ad-hoc
-- receiver-typing memo into the one scope analysis (design: the scope-model
-- memo; this is step 1, mechanism only).
--
-- A model is born at parse and dies with the tree (same lifetime discipline
-- as the parse tree itself — scopes never outlive extraction, never enter the
-- graph; the graph gets what scope PROVES). Harvest is LAZY per scope,
-- memoized by node:id() — valid because the model is per-tree by
-- construction, so ids cannot alias across trees.
--
-- MECHANISM/POLICY SPLIT (load-bearing): resolve() returns lexical TRUTH —
-- every binder visible under the name, nearest first, shadowed ones after.
-- It never decides what an untyped binder means; that is the caller's policy
-- (see java_var_type's optimistic walk-out, pinned by the shadowedTally
-- test). When the resolve-but-mark policy lands (step 2), it changes the
-- caller, not this file.

local M = {}

--- Build a model over one file's source.
--- `spec` describes the language: node-type -> {
---   kind    = 'local'|'param'|'field',   -- what this scope binds
---   harvest = fn(scope_node, src, out),  -- fill out[name] = { ty=?, row=? }
--- }
--- A harvester records `row` when the language position-checks visibility
--- (a Java block local is not in scope before its declaration row); binders
--- without `row` are visible scope-wide (params, fields).
function M.model(src, spec)
    local cache = {} -- scope node:id() -> name -> binder
    local chain = {} -- reused resolve() result: zero alloc on the hot path
    local sm = {}

    local function symtab(node, entry)
        local id = node:id()
        local t = cache[id]
        if not t then
            t = {}
            entry.harvest(node, src, t)
            for _, b in pairs(t) do b.kind = entry.kind end
            cache[id] = t
        end
        return t
    end

    --- Every binder visible as `ident` at `from`, NEAREST FIRST (the ones
    --- after chain[1] are what chain[1] shadows). Position-checked binders
    --- declared after the use row are not visible, so not in the chain.
    --- `only` restricts to one binder kind (a `this.field` receiver can only
    --- be a field). Returns (chain, count); the chain array is REUSED across
    --- calls — consume it before the next resolve on this model.
    function sm.resolve(ident, from, only)
        local fromrow = select(1, from:range())
        local k, n = 0, from:parent()
        while n do
            local entry = spec[n:type()]
            if entry and (only == nil or entry.kind == only) then
                local b = symtab(n, entry)[ident]
                if b and (b.row == nil or b.row <= fromrow) then
                    k = k + 1
                    chain[k] = b
                end
            end
            n = n:parent()
        end
        return chain, k
    end

    return sm
end

return M
