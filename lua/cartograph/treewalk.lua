-- cartograph.treewalk — SEVERAL WALKERS, ONE WALK. A walker is a VISITOR, not a recursive function: it names the node
-- types it handles, and the driver visits every node once, handing each node to the walkers that asked for its type.
-- Every module that used to walk a tree on its own re-materialized every node of it (a TSNode is a fresh userdata per
-- access): an extract + flowtype + lint of the 428-file corpus walked the trees ~14 times over (CART-1659). Adding a
-- walker here adds no pass.
--
--   local tw = require 'cartograph.treewalk'
--   tw.walk(root, { v1, v2, … })     one walk; returns nothing
--   tw.solo(root, v)                 the same, one visitor (a walker's own entry point stays a one-liner)
--
-- A visitor is a table:
--   enter = { [node type] = function (n, anc, d) … end }   a node of that type, BEFORE its children. `anc` is the
--           ANCESTOR STACK: anc[d] == n, anc[d - 1] its parent, anc[1] the root — an array read, where node:parent()
--           re-descends from the root (~1.1 us a call, vs 0.24 us for a child). Return `false` to PRUNE: this visitor
--           sees nothing below n (others still do).
--   leave = { [node type] = function (n, anc, d) … end }   the same node AFTER its children (not called for a node the
--           visitor pruned at, nor for anything below it)
--   any   = function (n, t, anc, d) … end                  every node (t its type), before the typed handler; `false`
--           prunes as above
--   tokens = true                                           visit anonymous children too (default: named only — 40%
--           of a Lua tree is punctuation and keywords, and no named-only walker needs them)
-- The driver names no node type: the types live with each walker (the language fence, tools/langaudit.lua).
-- ITERATIVE, not recursive: a deep tree (wine's 3177-deep comma chain, CART-1082) overflowed recursive walks, and a
-- loop is LuaJIT's strong shape where recursive tree walks are its weakest.
local M = {}

local function compose(visitors)
    local by_enter, by_leave, anys, tokens = {}, {}, {}, false
    for i, v in ipairs(visitors) do
        for t, f in pairs(v.enter or {}) do
            local l = by_enter[t]
            if not l then l = {}; by_enter[t] = l end
            l[#l + 1] = i; l[#l + 1] = f
        end
        for t, f in pairs(v.leave or {}) do
            local l = by_leave[t]
            if not l then l = {}; by_leave[t] = l end
            l[#l + 1] = i; l[#l + 1] = f
        end
        if v.any then anys[#anys + 1] = i; anys[#anys + 1] = v.any end
        if v.tokens then tokens = true end
    end
    return by_enter, by_leave, anys, tokens
end

function M.walk(root, visitors)
    if not root or #visitors == 0 then return end
    local by_enter, by_leave, anys, tokens = compose(visitors)
    local nv = #visitors
    local off = {} -- visitor index -> the depth it pruned at (inactive below it), nil = active
    local active = nv
    local anc, idx, cnt = {}, {}, {}
    local count = tokens and root.child_count or root.named_child_count
    local child = tokens and root.child or root.named_child

    -- enter n at depth d: the any-handlers, then the typed ones; a handler returning false prunes its visitor
    local function enter(n, d)
        local t = n:type()
        for k = 1, #anys, 2 do
            local i = anys[k]
            if not off[i] and anys[k + 1](n, t, anc, d) == false then off[i] = d; active = active - 1 end
        end
        local l = by_enter[t]
        if l then
            for k = 1, #l, 2 do
                local i = l[k]
                if not off[i] and l[k + 1](n, anc, d) == false then off[i] = d; active = active - 1 end
            end
        end
        return t
    end
    local types = {} -- depth -> the type of anc[d] (asked once, at enter)
    local function leave(n, d)
        local l = by_leave[types[d]]
        if l then
            for k = 1, #l, 2 do
                local i = l[k]
                if not off[i] then l[k + 1](n, anc, d) end
            end
        end
        -- (a visitor that pruned HERE is active again for n's siblings)
        for i = 1, nv do if off[i] == d then off[i] = nil; active = active + 1 end end
    end

    local d = 1
    anc[1], idx[1] = root, 0
    types[1] = enter(root, 1)
    cnt[1] = active > 0 and count(root) or 0
    while d > 0 do
        local i = idx[d]
        if i < cnt[d] then
            idx[d] = i + 1
            local c = child(anc[d], i)
            d = d + 1
            anc[d], idx[d] = c, 0
            types[d] = enter(c, d)
            cnt[d] = active > 0 and count(c) or 0 -- (every visitor pruned: nothing below is visited)
        else
            leave(anc[d], d)
            anc[d] = nil
            d = d - 1
        end
    end
end

function M.solo(root, visitor) return M.walk(root, { visitor }) end

return M
