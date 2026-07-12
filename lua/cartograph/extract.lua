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

--- @param opts { df:table, sel:{first:integer,last:integer}, fn_start:integer, body_end:integer, file_lines:string[], name:string, reaching:nil|table[], flow_rows:nil|table[] }
--- fn_start / body_end / sel are 1-based file line numbers. df.stmts[].l are too.
--- reaching = flow.reaching_cfg edges ({at,var,from,hedged}, row indices into
--- flow_rows); flow_rows = flow.stmts (row → {l,def,...}). Together they attribute
--- a shadowed name's later use to a def by SCOPE-correct reaching instead of by
--- name (df-strangler step-5 fine half). Absent (no flow) ⇒ an ambiguous return
--- REFUSES rather than guess.
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

    -- SHADOW SAFETY (df-strangler step-5 fine half, pt 2): a name-keyed dep can
    -- invent a RETURN when the name is defined BOTH inside and outside the
    -- selection (a shadow, or a reused local) — the selection defines one binding
    -- but the later use reads another, so `local r = f(...)` would split the
    -- variable in two. Flow's CFG REACHING (scope-correct via INC B′) decides
    -- precisely, RETIRING the df.defr binder-tag scheme + binder_at:
    --   • a post-selection use reaches an in-selection def (exact) → KEEP (genuine)
    --   • it reaches one only via a conservative edge (~)          → REFUSE (unsure)
    --   • no post-use reaches any in-selection def                 → DROP (false)
    -- A return defined ONLY in the selection is unambiguous and kept as-is. Params
    -- stay name-based deliberately: a read-only live-in is a value copy equal to
    -- the closure read either way, and enclosing params cannot reach the returns
    -- set. Without reaching (flow absent) an ambiguous return REFUSES — never
    -- guessing. ([[cartograph-df-strangler]])
    local reaching = (opts.flow_rows and opts.reaching) or nil
    local rows = opts.flow_rows
    local function in_sel(l) return l ~= nil and l >= sel.first and l <= sel.last end
    -- is `r` defined anywhere OUTSIDE the selection? (the ambiguity signal — flow
    -- rows when present, else the coarse df stmts)
    local function defined_outside(r)
        if rows then
            for _, row in ipairs(rows) do
                if not in_sel(row.l) then
                    for _, d in ipairs(row.def or {}) do if d == r then return true end end
                end
            end
        else
            for idx, s in ipairs(stmts) do
                if idx < firstIdx or idx > lastIdx then
                    for _, d in ipairs(s.def or {}) do if d == r then return true end end
                end
            end
        end
        return false
    end
    for r in pairs(returns_set) do
        if defined_outside(r) then
            if not (rows and reaching) then
                return { ok = false, reason = ('`%s` is defined both inside and '
                    .. 'outside the selection (a shadow or reused local); with no '
                    .. 'reaching info to attribute its later use, refusing rather '
                    .. 'than guess'):format(r) }
            end
            -- genuine = a post-selection use reaches an in-selection def
            -- EXACTLY; uncertain = a post-use whose reach is unclear (only a
            -- conservative edge into the selection, or reaches nothing confident)
            -- — refuse rather than guess, mirroring the old resolver's
            -- unattributable case. A post-use that cleanly reaches only
            -- out-of-selection defs contributes to neither → the value is read
            -- from an outer binding, so the return is DROPPED.
            local genuine, uncertain = false, false
            for _, e in ipairs(reaching) do
                if e.var == r and rows[e.at] and rows[e.at].l > sel.last then
                    local reached = false
                    for _, dr in ipairs(e.from) do
                        if dr ~= 0 and rows[dr] then
                            reached = true
                            if in_sel(rows[dr].l) then
                                if e.hedged and e.hedged[dr] then uncertain = true
                                else genuine = true end
                            end
                        end
                    end
                    if not reached then uncertain = true end
                end
            end
            if not genuine then
                if uncertain then
                    return { ok = false, reason = ('`%s` is shadowed and a use after '
                        .. 'the selection could not be confidently attributed to a '
                        .. 'def (only a conservative reach) — refusing rather than '
                        .. 'guess'):format(r) }
                end
                returns_set[r] = nil
            end
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
