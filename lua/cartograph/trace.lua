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
    local out = {}
    for _, c in ipairs(calls) do
        out[#out + 1] = {
            v    = (c.argv or {})[i] or { k = 'absent' },
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
local function local_defs(fn, name, line0)
    local df = fn and fn.df
    if not df then return {} end
    local before, all = {}, {}
    for _, s in ipairs(df.stmts) do
        for _, d in ipairs(s.def) do
            if d == name then
                all[#all + 1] = s
                if line0 and s.l <= line0 + 1 then before[#before + 1] = s end
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
        local defs = local_defs(fn, v.name, origin.site and origin.site.line)
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
        -- a def statement: trace each local it read (its data-flow parents)
        if not v.use or #v.use == 0 then return nil, 'reads no locals — literal or external' end
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

-- short display name for a function id
local function short(store, fn_id)
    local n = fn_id and store.node(fn_id)
    return n and n.name or (fn_id and fn_id:match('::(.-)@') or 'top level')
end

--- One-line description of an origin's value, for display.
function M.describe(store, origin)
    local v, k = origin.v, origin.v.k
    if k == 'lit' then
        local val = type(v.v) == 'string' and ("'" .. v.v .. "'") or tostring(v.v)
        return 'literal ' .. val, false
    end
    if k == 'nil' then return 'literal nil', false end
    if k == 'absent' then return 'not passed — parameter is nil here', false end
    if k == 'param' then
        return ('param #%d %s of %s'):format(v.i or 0, v.name or '?', short(store, origin.fn)), true
    end
    if k == 'local' then return ('local %s'):format(v.name or '?'), true end
    if k == 'def' then
        local from = (v.use and #v.use > 0) and ('  <- ' .. table.concat(v.use, ', ')) or ''
        return ('%s = ...%s'):format(v.name or '?', from), v.use and #v.use > 0
    end
    if k == 'call' then return ('return of %s()'):format(v.callee or '?'), v.to ~= nil end
    if k == 'field' then return ('field %s'):format(v.path or '?'), false end
    if k == 'global' then return ('global %s'):format(v.name or '?'), false end
    if k == 'table' then return 'table constructor', false end
    if k == 'func' then return 'function value', false end
    if k == 'vararg' then return '...', false end
    return 'expression', false
end

M.short = short

return M
