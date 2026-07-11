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

-- defs of local `name` in fn's data flow at/before `line` (1-based df lines);
-- falls back to all defs when none precede the use site.
--
-- SHADOW DISAMBIGUATION (scope-model phase 1): when the provider can
-- resolve binders for this file, defs are filtered to the binder VISIBLE
-- AT THE USE SITE — a shadowed name no longer feeds another variable's
-- defs into the trace. A def statement is kept when its row resolves to
-- the same binder (identity), or when it CONTAINS the binder's own
-- declaration row (df is statement-granular: an inner decl inside a
-- compound statement reports the compound's row). Known residue: a
-- compound statement that both contains an inner shadow-decl and assigns
-- the outer binder stays conflated — that is df's granularity, phase 2's
-- binder tags own it. No binder info (dump graphs, no scope spec, stale
-- file) ⇒ exactly the old name-matched behavior.
local function local_defs(store, fn, name, line0)
    local df = fn and fn.df
    if not df then return {} end
    local ts = require 'cartograph.providers.treesitter'
    local abs = store.abs(fn.file)
    local use_b = line0 and ts.binder_at(abs, fn.file, name, line0) or nil
    local before, all = {}, {}
    for i, s in ipairs(df.stmts) do
        for di, d in ipairs(s.def) do
            if d == name then
                local keep = true
                if use_b then
                    local tag = s.defr and s.defr[di]
                    if tag then
                        -- phase 2: the def entry carries its binder's decl
                        -- row — node-precise at harvest, so the compound-
                        -- statement residue is gone
                        keep = tag == (use_b.row or -1)
                    else
                        local db = ts.binder_at(abs, fn.file, name, s.l - 1)
                        if db ~= use_b then
                            -- containment: the binder's own decl lives
                            -- inside this (compound) statement's row span
                            local nxt = df.stmts[i + 1]
                            local declrow1 = use_b.row and use_b.row + 1
                            keep = declrow1 ~= nil and declrow1 >= s.l
                                and (nxt == nil or declrow1 < nxt.l)
                        end
                    end
                end
                if keep then
                    all[#all + 1] = s
                    if line0 and s.l <= line0 + 1 then before[#before + 1] = s end
                end
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
