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

local tsutil = require 'cartograph.spec.tsutil' -- (tsutil.parent: the memoized node:parent())
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
    --- be a field). The walk INCLUDES `from` itself — a no-op for leaf
    --- entries (call/identifier nodes are never scope types), but a
    --- position-based entry can land ON a scope node, whose own binders
    --- must count. `atrow` overrides the visibility row for such entries
    --- (a block's start row is not the query row). Returns (chain, count);
    --- the chain array is REUSED across calls — consume it before the next
    --- resolve on this model.
    -- scope node id -> { node, entry, up = the next scope out (the same record shape) | false }: the scopes above a
    -- scope are the same for every resolution under it, so the climb to the root (node:parent() re-descends from the
    -- root in tree-sitter, ~1.1 us a step) is paid once per SCOPE, not once per resolved name (_bound_value resolves
    -- every argument identifier: 143 K parent steps on an 80-file corpus)
    local outer = {}
    local pending = {} -- (iterative, not recursive: a deep tree overflowed a recursive walk's Lua stack, CART-1082)
    local function scope_rec(s, entry)
        local r = outer[s:id()]
        if r then return r end
        local np, top = 0, false
        while s do -- climb until a cached scope (or the root), queueing the uncached ones
            local id = s:id()
            local c = outer[id]
            if c then top = c break end
            np = np + 1
            pending[np] = { node = s, entry = entry, id = id }
            local p = tsutil.parent(s)
            while p and not spec[p:type()] do p = tsutil.parent(p) end
            s = p
            entry = p and spec[p:type()]
        end
        for i = np, 1, -1 do -- link outermost first
            local q = pending[i]
            pending[i] = nil
            local rec = { node = q.node, entry = q.entry, up = top }
            outer[q.id] = rec
            top = rec
        end
        return top
    end
    function sm.resolve(ident, from, only, atrow)
        local fromrow = atrow or select(1, from:range())
        local k, n = 0, from
        while n and not spec[n:type()] do n = tsutil.parent(n) end -- (to the nearest scope, `from` itself included)
        local r = n and scope_rec(n, spec[n:type()])
        while r do
            local entry = r.entry
            if only == nil or entry.kind == only then
                local b = symtab(r.node, entry)[ident]
                if b and (b.row == nil or b.row <= fromrow) then
                    k = k + 1
                    chain[k] = b
                end
            end
            r = r.up
        end
        return chain, k
    end

    --- the NEAREST binder of `ident` at `from`, and whether its scope is the file's OUTERMOST one -> b, top | nil (no
    --- binder: a global). A use inside its binder's own declaration — lua's `local x = x or {}` — reads the outer one
    --- (CART-1602's rule, as _bound_value applies it)
    function sm.binder(ident, from)
        local fromrow = select(1, from:range())
        local ub = select(3, from:start())
        local n = from
        while n and not spec[n:type()] do n = tsutil.parent(n) end
        local r = n and scope_rec(n, spec[n:type()])
        while r do
            local b = symtab(r.node, r.entry)[ident]
            if b and (b.row == nil or b.row <= fromrow) and not (b.ab and b.abe and ub >= b.ab and ub < b.abe) then
                return b, not r.up
            end
            r = r.up
        end
    end

    -- one scope's binders, harvested once per model: the extractor's mention walk reads every scope through this
    -- instead of harvesting it a second time (lua_locals ran 1.9x per block)
    sm.symtab = symtab
    return sm
end

return M
