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

--- @param opts { df:table, sel:{first:integer,last:integer}, fn_start:integer, body_end:integer, file_lines:string[], name:string }
--- fn_start / body_end / sel are 1-based file line numbers. df.stmts[].l are too.
--- @return table plan  { ok, reason?, name, params, returns, new_fn, call, replace, insert_before, hazards }
function M.plan(opts)
    local df, sel, name = opts.df, opts.sel, opts.name
    local lines = opts.file_lines
    if not df or not df.stmts or #df.stmts == 0 then
        return { ok = false, reason = 'no data-flow for this function' }
    end
    local stmts = df.stmts

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
        return { ok = false, reason = 'selection covers no complete statement' }
    end
    -- alignment: the selection must start and end exactly on statement boundaries,
    -- else it cuts into a loop/branch body the analysis cannot see.
    if sel.first ~= stmts[firstIdx].l or sel.last ~= stmt_end(lastIdx) then
        return { ok = false, reason = 'selection must cover whole statements (not part of a loop/branch body)' }
    end

    local sel_lines = {}
    for i = sel.first, sel.last do sel_lines[#sel_lines + 1] = lines[i] end
    if has_control_escape(sel_lines) then
        return { ok = false, reason = 'selection contains a return/break/goto — cannot extract safely' }
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
