-- Data tracing: where do a parameter's values come from? Pure logic over the
-- store's call inventory (classified args), function params, and return
-- summaries — the UI drives it incrementally, expanding one origin at a time.
--
-- An ORIGIN is one classified value flowing somewhere, with enough context to
-- go further:
--   { v = <classified expr>,      -- {k='lit'|'param'|'local'|'call'|'field'|...}
--     fn = <owning function id>,  -- the function whose scope `v` lives in (nil at top level)
--     site = { file, line } }     -- where it flows from (0-based line)
--
-- expand() takes one origin and returns the next hop — or nil plus a reason,
-- the honest frontier: fields/globals (aliasing), dynamic calls, varargs.

local M = {}

local function site_of(call) return { file = call.file, line = call.line } end

--- Origins of parameter `i` of function `fn_id`: one entry per resolved call
--- site (the classified i-th argument). Sites that pass nothing for the
--- parameter report v = {k='absent'} — the parameter is nil there.
---@return table origins, string? note
function M.origins(store, fn_id, i)
    local calls = store.calls_to[fn_id]
    if not calls or #calls == 0 then
        return {}, 'no resolved call sites — dynamic dispatch (event handler?) or dead'
    end
    local argv = require 'cartograph.argv'
    local out = {}
    for _, c in ipairs(calls) do
        out[#out + 1] = {
            v    = argv.at(c, i) or { k = 'absent' },
            fn   = c.fn,
            site = site_of(c),
        }
    end
    table.sort(out, function (a, b)
        if a.site.file ~= b.site.file then return a.site.file < b.site.file end
        return a.site.line < b.site.line
    end)
    return out
end

-- defs of local `name` reaching the use at `line0` (0-based). SHADOW
-- DISAMBIGUATION, df-strangler step-5 fine half: sourced from flow's CFG
-- REACHING (flow.reaching_cfg) — the def ROWS that actually reach this use,
-- scope-correctly. This RETIRES the df+`defr` binder-tag scheme: reaching now
-- masks a shadowing inner AND restores the enclosing def after the block (the
-- INC B′ scoped-kill/restore fix), so a shadowed name resolves to its OWN
-- binder without cached tags — and flow is FINE, so the def points at the
-- precise decl line, not the coarse compound. No use anchor / no reaching edge
-- ⇒ every def row of `name`. Fns WITHOUT flow (haskell etc.) fall back to
-- name-matched df stmts (no shadow filter — rare non-imperative langs).
local function local_defs(_store, fn, name, line0)
    local flow = require 'cartograph.flow'
    if flow.present(fn) then
        local fl = flow.record(fn)
        local rc = flow.reaching_cfg(fl)
        local want = line0 and (line0 + 1) or nil -- flow .l is 1-based
        local from
        for _, e in ipairs(rc) do
            if e.var == name and (not want or fl.stmts[e.at].l == want) then
                from = e.from
                if want then break end
            end
        end
        local out = {}
        if from then
            for _, r in ipairs(from) do
                if r ~= 0 then out[#out + 1] = fl.stmts[r] end -- 0 = param/entry (up-call)
            end
        end
        if #out == 0 then -- no reaching anchor: every def row of `name`
            for _, s in ipairs(fl.stmts) do
                for _, d in ipairs(s.def) do
                    if d == name then out[#out + 1] = s; break end
                end
            end
        end
        return out
    end
    -- no flow: name-matched df stmts (before the use, else all)
    local stmts = require('cartograph.df').stmts(fn)
    if #stmts == 0 then return {} end
    local before, all = {}, {}
    for _, s in ipairs(stmts) do
        for _, d in ipairs(s.def) do
            if d == name then
                all[#all + 1] = s
                if line0 and s.l <= line0 + 1 then before[#before + 1] = s end
                break
            end
        end
    end
    return #before > 0 and before or all
end

--- Expand one origin into its next hop. Returns (children, nil) on success,
--- (nil, reason) at a frontier. Children are origins again, so expansion
--- composes — the UI recurses only where the user asks.
function M.expand(store, origin)
    local v, k = origin.v, origin.v.k

    if k == 'param' then
        -- the value is the enclosing function's own parameter: go up-call
        if not origin.fn then return nil, 'parameter of an unknown function' end
        local kids, note = M.origins(store, origin.fn, v.i)
        if #kids == 0 then return nil, note end
        return kids
    end

    if k == 'local' then
        -- where the local got its value: its def statement(s) in the data flow
        if not origin.fn then return nil, 'local at top level — no data-flow info' end
        local fn = store.node(origin.fn)
        local defs = local_defs(store, fn, v.name, origin.site and origin.site.line)
        if #defs == 0 then return nil, 'no def found in the data flow' end
        local kids = {}
        for _, s in ipairs(defs) do
            kids[#kids + 1] = {
                v    = { k = 'def', name = v.name, use = s.use },
                fn   = origin.fn,
                site = { file = fn.file, line = s.l - 1 },
            }
        end
        return kids
    end

    if k == 'def' then
        -- a def statement: trace each local it read (its data-flow parents).
        -- Reading nothing usually means a LITERAL assignment: extract it
        -- from the source line — it is the answer, and pinnable.
        if not v.use or #v.use == 0 then
            local fn = store.node(origin.fn)
            local lit
            if fn and origin.site then
                -- store.content: the cached, stale-aware, multi-root-safe
                -- read seam (a raw root-join here read WRONG paths on
                -- labelled/self:// graphs — traces lost their answers)
                local lines = store.content(fn)
                local line = lines and lines[origin.site.line + 1] or ''
                lit = line:match([=[=%s*['"]([%w_:%.%-\\]+)['"]]=])
            end
            if lit then
                return { { v = { k = 'lit', v = lit }, fn = origin.fn,
                    site = origin.site } }
            end
            return nil, 'reads no locals — literal or external'
        end
        local fn = store.node(origin.fn)
        local params = (fn and fn.params) or {}
        local kids = {}
        for _, name in ipairs(v.use) do
            local pi
            for idx, p in ipairs(params) do if p == name then pi = idx end end
            kids[#kids + 1] = {
                v    = pi and { k = 'param', name = name, i = pi }
                        or { k = 'local', name = name },
                fn   = origin.fn,
                site = origin.site,
            }
        end
        return kids
    end

    if k == 'call' then
        -- the value is another function's return: trace through its returns
        if not v.to then
            return nil, ('call to %s — not a workspace function'):format(v.callee or '?')
        end
        local target = store.node(v.to)
        if not target or not target.rets or #target.rets == 0 then
            return nil, ('%s has no return statements'):format(v.callee or '?')
        end
        local kids = {}
        for _, r in ipairs(target.rets) do
            for _, val in ipairs(r.vals) do
                kids[#kids + 1] = {
                    v    = val,
                    fn   = v.to,
                    site = { file = target.file, line = r.l },
                }
            end
        end
        return kids
    end

    -- honest frontiers
    local REASON = {
        lit    = false, -- terminal, not a frontier: it IS the answer
        absent = false,
        ['nil'] = false,
        field  = 'a table field — writes can alias from anywhere (not statically traceable)',
        global = 'a global — assigned from anywhere',
        table  = 'a table constructed in place',
        func   = 'a function value',
        vararg = '... — forwarded varargs',
        expr   = 'a computed expression',
    }
    local r = REASON[k]
    if r == false then return nil end -- terminal: nothing further, and that's the answer
    return nil, r or 'unrecognized value kind'
end

--- Origins of LOCAL `name` in `fn_id` at `line0`: its defining statements,
--- flattened one level where a def is just a literal assignment — those
--- literals ARE the candidates. The dispatch-trace entry for non-params.
function M.origins_local(store, fn_id, name, line0)
    local root = { v = { k = 'local', name = name },
        fn = fn_id, site = { file = (store.node(fn_id) or {}).file, line = line0 } }
    local defs, note = M.expand(store, root)
    if not defs then return {}, note end
    -- flatten defs that assign a LITERAL to the traced name on their line
    -- (`$h = 'scale'` even inside a one-line branch): the literal is the
    -- candidate. Anything else stays a def row and expands as usual.
    local fn = store.node(fn_id)
    -- same seam as expand()'s literal read: cached + multi-root-safe
    local lines = fn and store.content(fn) or nil
    local out = {}
    for _, d in ipairs(defs) do
        local lit
        if d.v.k == 'def' and lines and d.site then
            local line = lines[d.site.line + 1] or ''
            lit = line:match('%$?' .. name .. [=[%s*=%s*['"]([%w_:%.%-\\]+)['"]]=])
        end
        if lit then
            out[#out + 1] = { v = { k = 'lit', v = lit }, fn = fn_id, site = d.site }
        else
            out[#out + 1] = d
        end
    end
    return out
end

-- short display name for a function id
local function short(store, fn_id)
    local n = fn_id and store.node(fn_id)
    return n and n.name or (fn_id and fn_id:match('::(.-)@') or 'top level')
end

--- Compact one-line description of an origin's value, for display. Returns
--- (text, expandable, kind-class) — the class picks a highlight: 'lit' for
--- answers, 'dim' for frontiers, nil for traceable values. The owning function
--- is NOT in the text (the pane shows it as location virtual text).
function M.describe(_store, origin)
    local v, k = origin.v, origin.v.k
    if k == 'lit' then
        local val = type(v.v) == 'string' and ("'" .. v.v .. "'") or tostring(v.v)
        return val, false, 'lit'
    end
    if k == 'nil' then return 'nil', false, 'lit' end
    if k == 'absent' then return '(not passed — nil here)', false, 'dim' end
    if k == 'param' then return ('param %s'):format(v.name or '?'), true end
    if k == 'local' then return ('local %s'):format(v.name or '?'), true end
    if k == 'def' then
        local from = (v.use and #v.use > 0) and ('  ← ' .. table.concat(v.use, ', ')) or ''
        return ('%s = …%s'):format(v.name or '?', from), v.use and #v.use > 0
    end
    if k == 'call' then return ('%s() →'):format(v.callee or '?'), v.to ~= nil end
    if k == 'field' then return ('field %s'):format(v.path or '?'), false, 'dim' end
    if k == 'global' then return ('global %s'):format(v.name or '?'), false, 'dim' end
    if k == 'table' then return '{…} constructed here', false, 'dim' end
    if k == 'func' then return 'function value', false, 'dim' end
    if k == 'vararg' then return '...', false, 'dim' end
    return 'expression', false, 'dim'
end

M.short = short

return M
