-- wraptriage.lua — HARVEST CONFLICT TRIAGE for the wrap/decorator idiom
-- ([[cartograph-linker]] / [[graph-vm-type-resolution]]). Measure-first (2026-07-18,
-- AtlasLootFu 12/12) established that the `X = wrap(X, …)`-then-call idiom produces a
-- SYSTEMATIC cartograph-vs-lua-ls disagreement where CARTOGRAPH IS THE BETTER SIDE:
--   local function GetMainFrame() … end          -- the real logic
--   GetMainFrame = wrap(GetMainFrame, "…")        -- wrap is identity in prod, a profiler under DEBUG
--   … GetMainFrame() …                            -- cg → GetMainFrame (the def) ; luals → wrap (the FACTORY)
-- At runtime wrap is identity in the production path, so the value IS the original —
-- cartograph resolves the useful/correct target, lua-ls's value-flow lands on the
-- decorator factory. This is a bug on LUA-LS's side, not ours. The harvest counts these
-- as raw "conflicts"; this module NAMES the class so they stop reading as cartograph-suspect.
--
-- This is TRIAGE, not resolution: it changes no `.to`, mints no edge, needs no VERSION
-- bump. It reads a conflict + the file's reassignment sites and returns a verdict.

local M = {}

local function tail(name) return name and (name:match('([%w_]+)$')) or nil end
local function txt(n, src) return n and vim.treesitter.get_node_text(n, src) or '' end

--- Reassignment-to-CALL sites in a Lua source: statements `X = F(...)` that assign the
--- RESULT of calling F to name X (the wrap/decorator fingerprint; F is the FACTORY).
--- @return table[] { name, factory, line } (name/factory may be dotted; line is 1-based)
function M.reassigns(src)
    local out = {}
    local ok, p = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not ok then return out end
    local root = p:parse()[1]:root()
    local ok2, q = pcall(vim.treesitter.query.parse, 'lua', [[
        (assignment_statement
            (variable_list name: (_) @lhs)
            (expression_list value: (function_call name: (_) @factory))) @asg ]])
    if not ok2 then return out end
    for _, m in q:iter_matches(root, src, 0, -1, { all = true }) do
        local lhs, factory
        for id, nodes in pairs(m) do
            local cap = q.captures[id]
            local node = nodes[#nodes]
            if cap == 'lhs' then lhs = node elseif cap == 'factory' then factory = node end
        end
        if lhs and factory then
            out[#out + 1] = { name = txt(lhs, src), factory = txt(factory, src), line = lhs:start() + 1 }
        end
    end
    return out
end

--- Classify one cartograph-vs-lua-ls CONFLICT (both resolved, targets differ). Both classes
--- are the SAME family — lua-ls followed a REASSIGNMENT of the called name that cartograph
--- correctly did not (it kept the name's own top-level load-time def) — so they are lua-ls's
--- side, not a cartograph-suspect bug:
---   'wrap-passthrough'  lua-ls's target is the FACTORY the source reassigns the name from
---                       (`callee = wrap(...)`; wrap is identity/delegating -> cg is correct).
---   'nested-patch'      lua-ls's target is a NESTED (non-top) def of the same name — a runtime
---                       monkey-patch inside a function body (Skada `Skada.ReloadSettings =
---                       function` inside :ImportProfile); cartograph kept the top-level binding.
--- @param callee string      the called name (c.callee / tail of c.full)
--- @param cg_to_name string  NAME of cartograph's target node
--- @param ls_to_name string  NAME of lua-ls's target node
--- @param reassigns table[]  M.reassigns of the call's file (may be {} for the nested case)
--- @param ls_nested boolean|nil  true iff lua-ls's target is a cartograph node that is NOT top-level
--- @return string|nil the class, or nil (a conflict this triage does not explain — a real lead)
function M.classify(callee, cg_to_name, ls_to_name, reassigns, ls_nested)
    if not (callee and cg_to_name and ls_to_name) then return nil end
    local ct = tail(callee)
    -- cartograph resolved to a def OF the called name (the load-time binding it kept)
    if not ct or tail(cg_to_name) ~= ct then return nil end
    local lt = tail(ls_to_name)
    -- nested-patch: lua-ls followed a runtime reassignment (a non-top def of the same name)
    if lt == ct and ls_nested then return 'nested-patch' end
    -- wrap-passthrough: lua-ls's target is the factory the name is reassigned from
    for _, r in ipairs(reassigns or {}) do
        if tail(r.name) == ct and tail(r.factory) == lt then
            return 'wrap-passthrough'
        end
    end
    return nil
end

return M
