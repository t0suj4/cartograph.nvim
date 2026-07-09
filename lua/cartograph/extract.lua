-- Extract-function ENGINE (pure). Given a function's data-flow (`df`), its source
-- lines, and a selected line range, compute the plan to pull those statements
-- into a new local function: the parameters (locals live-in), the return values
-- (locals live-out), the new function text, and the call that replaces the
-- selection. It computes; it does not touch files (the driver does, after a
-- preview + confirm).
--
-- Deliberately conservative — it operates on WHOLE top-level statements (the
-- granularity `df` resolves) and REFUSES anything it can't do soundly: a
-- selection that cuts a control-structure body, or one containing a control
-- escape. It cannot see non-local (table/global) state, so that risk is
-- disclosed as a hazard rather than silently assumed away.

local M = {}

local function leading_ws(line) return (line or ''):match('^%s*') or '' end

local function sorted(set)
    local o = {}
    for k in pairs(set) do o[#o + 1] = k end
    table.sort(o)
    return o
end

-- text guard: a control escape in the selection would change meaning if moved
-- into a called function. Word-boundary match; conservative (may fire on the
-- word inside a string/comment, which is the safe direction).
local function has_control_escape(lines)
    for _, l in ipairs(lines) do
        if l:match('%f[%w]return%f[%W]') or l:match('%f[%w]break%f[%W]') or l:match('%f[%w]goto%f[%W]') then
            return true
        end
    end
    return false
end

--- @param opts { df:table, sel:{first:integer,last:integer}, fn_start:integer, body_end:integer, file_lines:string[], name:string, resolve_binder:nil|fun(name:string,row0:integer):table? }
--- fn_start / body_end / sel are 1-based file line numbers. df.stmts[].l are too.
--- resolve_binder(name, row0) -> binder handle {row?} (0-based decl row; nil
--- row = param/field) or nil — the shadow-attribution service (binder_at).
--- @return table plan  { ok, reason?, name, params, returns, new_fn, call, replace, insert_before, hazards }
function M.plan(opts)
    local df, sel, name = opts.df, opts.sel, opts.name
    local lines = opts.file_lines
    if not df or not df.stmts or #df.stmts == 0 then
        return { ok = false, reason = 'no data-flow for this function' }
    end
    local stmts = df.stmts

    -- control escape first — it's the clearest reason and is independent of the
    -- statement-boundary analysis below.
    local sel_lines = {}
    for i = sel.first, sel.last do sel_lines[#sel_lines + 1] = lines[i] end
    if has_control_escape(sel_lines) then
        return { ok = false, reason =
            'the selection contains return/break/goto. Extracting it would change control flow — '
            .. 'the return/break would only exit the new function, not the original. Not supported.' }
    end

    -- statement i spans [stmts[i].l, end(i)]; end(i) is the line before the next
    -- statement, or the last body line.
    local function stmt_end(i)
        return (stmts[i + 1] and stmts[i + 1].l - 1) or opts.body_end
    end

    -- selected statement index range
    local firstIdx, lastIdx
    for i, s in ipairs(stmts) do
        if s.l >= sel.first and s.l <= sel.last then
            firstIdx = firstIdx or i
            lastIdx = i
        end
    end
    if not firstIdx then
        return { ok = false, reason =
            'the selection is nested inside a loop or branch. Extract works on whole TOP-LEVEL '
            .. 'statements of a function; it cannot yet reach inside control structures.' }
    end
    -- alignment: the selection must start and end exactly on statement boundaries,
    -- else it cuts into a loop/branch body the analysis cannot see.
    if sel.first ~= stmts[firstIdx].l or sel.last ~= stmt_end(lastIdx) then
        return { ok = false, reason =
            'the selection starts or ends inside a loop/branch body. Extract works on whole '
            .. 'top-level statements; it cannot split a control structure yet.' }
    end

    -- params = locals used in the selection whose reaching def is BEFORE it
    -- (upvalues/params of the enclosing fn have no dep — captured by closure).
    local params_set = {}
    for idx = firstIdx, lastIdx do
        for _, d in ipairs(stmts[idx].dep or {}) do
            if d.from < firstIdx then params_set[d.var] = true end
        end
    end
    -- returns = locals defined in the selection and used after it
    local returns_set = {}
    for j = lastIdx + 1, #stmts do
        for _, d in ipairs(stmts[j].dep or {}) do
            if d.from >= firstIdx and d.from <= lastIdx then returns_set[d.var] = true end
        end
    end

    -- SHADOW SAFETY (scope-model): df def entries carry binder tags
    -- (stmt.defr, aligned with stmt.def) when a name resolves to SEVERAL
    -- binders in this function. For such a name the name-keyed deps above
    -- can invent a RETURN — the selection defines one binder, the later
    -- use reads another — which generates junk code (a false `local x =
    -- f(...)` splitting the variable in two). With opts.resolve_binder
    -- the post-selection uses are attributed precisely: the return
    -- survives only when some use's binder matches an in-selection def's
    -- tag. Without a resolver, or when attribution fails, REFUSE — this
    -- engine's contract. Params stay name-based deliberately: a read-only
    -- live-in is a value copy equal to the closure read either way, and
    -- enclosing params pre-seed the dep map so a param shadow cannot
    -- reach the returns set.
    local tagvals = {}
    for _, s in ipairs(stmts) do
        if s.defr then
            for di, d in ipairs(s.def) do
                if s.defr[di] ~= nil then
                    tagvals[d] = tagvals[d] or {}
                    tagvals[d][s.defr[di]] = true
                end
            end
        end
    end
    for r in pairs(returns_set) do
        local n = 0
        for _ in pairs(tagvals[r] or {}) do n = n + 1 end
        if n >= 2 then
            if not opts.resolve_binder then
                return { ok = false, reason = ('`%s` is shadowed in this function '
                    .. '(several distinct binders) — the plan cannot attribute its '
                    .. 'defs and uses by name'):format(r) }
            end
            local sel_t = {}
            for idx = firstIdx, lastIdx do
                local s = stmts[idx]
                if s.defr then
                    for di, d in ipairs(s.def) do
                        if d == r and s.defr[di] ~= nil then sel_t[s.defr[di]] = true end
                    end
                end
            end
            local genuine, unknown = false, false
            for j = lastIdx + 1, #stmts do
                for _, u in ipairs(stmts[j].use) do
                    if u == r then
                        local b = opts.resolve_binder(r, stmts[j].l - 1)
                        if not b then
                            unknown = true
                        elseif sel_t[b.row or -1] then
                            genuine = true
                        end
                    end
                end
            end
            if unknown and not genuine then
                return { ok = false, reason = ('`%s` is shadowed and a use after '
                    .. 'the selection could not be attributed to a binder — '
                    .. 'refusing rather than guess'):format(r) }
            end
            if not genuine then returns_set[r] = nil end
        end
    end

    local params, returns = sorted(params_set), sorted(returns_set)

    -- a return that is also a param is a reassignment of an outer local (no
    -- `local` at the call site); mixing that with freshly-declared returns can't
    -- be one statement — refuse for now rather than emit wrong code.
    local reassigned, fresh = 0, 0
    for _, r in ipairs(returns) do
        if params_set[r] then reassigned = reassigned + 1 else fresh = fresh + 1 end
    end
    if reassigned > 0 and fresh > 0 then
        return { ok = false, reason = 'selection returns a mix of new and reassigned locals — not supported yet' }
    end

    -- assemble text
    local base = leading_ws(lines[opts.fn_start])
    local call_indent = leading_ws(lines[sel.first])
    local new_fn = { ('%slocal function %s(%s)'):format(base, name, table.concat(params, ', ')) }
    for _, l in ipairs(sel_lines) do new_fn[#new_fn + 1] = l end
    if #returns > 0 then new_fn[#new_fn + 1] = ('%s    return %s'):format(base, table.concat(returns, ', ')) end
    new_fn[#new_fn + 1] = base .. 'end'

    local call
    if #returns == 0 then
        call = ('%s%s(%s)'):format(call_indent, name, table.concat(params, ', '))
    elseif reassigned > 0 then
        call = ('%s%s = %s(%s)'):format(call_indent, table.concat(returns, ', '), name, table.concat(params, ', '))
    else
        call = ('%slocal %s = %s(%s)'):format(call_indent, table.concat(returns, ', '), name, table.concat(params, ', '))
    end

    return {
        ok = true,
        name = name,
        params = params,
        returns = returns,
        new_fn = new_fn,
        call = { call },
        replace = { first = sel.first, last = sel.last },
        insert_before = opts.fn_start,
        hazards = { 'non-local state (tables/globals) and side-effect ordering are not analyzed — verify by eye' },
    }
end

--- Apply a plan to a list of file lines, returning the new list. Pure.
function M.apply(plan, file_lines)
    local out = {}
    for i = 1, plan.insert_before - 1 do out[#out + 1] = file_lines[i] end
    for _, l in ipairs(plan.new_fn) do out[#out + 1] = l end
    out[#out + 1] = ''
    for i = plan.insert_before, plan.replace.first - 1 do out[#out + 1] = file_lines[i] end
    for _, l in ipairs(plan.call) do out[#out + 1] = l end
    for i = plan.replace.last + 1, #file_lines do out[#out + 1] = file_lines[i] end
    return out
end

return M
