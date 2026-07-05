-- PLAN bar: the staging surface. A full-width strip along the bottom that reads
-- out the current move-set and its computed impact (via the ImpactEngine): which
-- symbols move where, which references must be rewritten, which requires to add,
-- and what hazards the move carries. Subscribes to the staging channel; staging
-- itself happens in the symbol list (marks live where the symbols are).

local store  = require 'cartograph.store'
local impact = require 'cartograph.impact'

local ns = vim.api.nvim_create_namespace('cartograph_plan_hl')

local M = {}

local function set_lines(buf, lines)
    for j, l in ipairs(lines) do
        if l:find('[\n\r]') then lines[j] = l:gsub('[\n\r]+', ' \u{B6} ') end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

-- record { row0, col0, col_end, hl } for a fragment to highlight after render
local function hl(marks, row, text, group)
    marks[#marks + 1] = { row = row, hl = group }
    return text
end

function M.render()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end
    local ids  = store.staged_ids()
    local dest = store.dest
    local lines, marks = {}, {}

    -- a staged TRANSACTION owns the bar: this preview IS the plan, and
    -- nothing is written until :CartographApply survives verification
    if store.txn then
        local t = store.txn
        if t.moves then
            lines[#lines + 1] = hl(marks, #lines,
                ('%s  %d symbol(s) → %s%s    :CartographDiff · :CartographApply · :CartographTxnClear')
                    :format(t.creates and 'EXTRACT' or 'MOVE', #t.moves,
                        t.dest, t.creates and ' (new file)' or ''), 'Title')
            for _, m in ipairs(t.moves) do
                lines[#lines + 1] = ('  %s   %s:%d-%d'):format(m.name, m.file,
                    m.lines.s + 1, m.lines.e + 1)
            end
            lines[#lines + 1] = ('  lands at %s:%d; touches %d file(s)')
                :format(t.dest, t.dest_at + 1, #t.touched)
        else
            lines[#lines + 1] = hl(marks, #lines,
                ('MERGE  %d clone(s) → %s    :CartographDiff · :CartographApply · :CartographTxnClear')
                    :format(#t.removed, t.survivor.name), 'Title')
            for _, r in ipairs(t.removed) do
                lines[#lines + 1] = ('  - %s   %s:%d-%d'):format(r.name, r.file,
                    r.lines.s + 1, r.lines.e + 1)
            end
            lines[#lines + 1] = ('  rewrites %d call site(s); touches %d file(s)')
                :format(#t.rewrites, #t.touched)
        end
        for _, h in ipairs(t.hazards) do
            lines[#lines + 1] = hl(marks, #lines, '  ⚠ ' .. h, 'DiagnosticWarn')
        end
        set_lines(M.buf, lines)
        for _, mk in ipairs(marks) do
            pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, mk.row, 0,
                { end_row = mk.row + 1, hl_group = mk.hl })
        end
        return
    end

    if #ids == 0 then
        set_lines(M.buf, {
            'PLAN  —  nothing staged',
            '',
            "  dd  cut a function into the move-set      (visual d cuts a selection)",
            "  p   paste — set the destination to the file under the cursor",
            "  u   unstage the last cut",
        })
        return
    end

    local plan = impact.compute(store, ids, dest)

    lines[#lines + 1] = hl(marks, #lines,
        ('PLAN  %d staged  →  %s'):format(#plan.moves, dest or '(no destination — press p on a file)'),
        'Title')

    -- staged symbols, grouped by source file
    local cur_from
    for _, m in ipairs(plan.moves) do
        if m.from ~= cur_from then
            cur_from = m.from
            lines[#lines + 1] = '  from ' .. m.from .. ':'
        end
        lines[#lines + 1] = '    ' .. m.name
    end

    if not dest then set_lines(M.buf, lines); return end

    -- rewrites
    if #plan.rewrites > 0 then
        local total = 0
        for _, r in ipairs(plan.rewrites) do total = total + r.total end
        lines[#lines + 1] = ('rewrite %d call site(s):'):format(total)
        for _, r in ipairs(plan.rewrites) do
            local parts = {}
            for _, s in ipairs(r.symbols) do parts[#parts + 1] = ('%s×%d'):format(s.name, s.count) end
            lines[#lines + 1] = ('    %s   (%s)'):format(r.file, table.concat(parts, ', '))
        end
    else
        lines[#lines + 1] = 'rewrite: none'
    end

    -- requires
    if #plan.requires_add > 0 then
        lines[#lines + 1] = 'add require ' .. dest .. ' to:  ' .. table.concat(plan.requires_add, ', ')
    end
    if #plan.dest_requires > 0 then
        lines[#lines + 1] = dest .. ' must require:  ' .. table.concat(plan.dest_requires, ', ')
    end

    -- hazards
    for _, h in ipairs(plan.hazards) do
        local mark = h.level == 'warn' and '  ⚠ ' or '  · '
        lines[#lines + 1] = hl(marks, #lines, mark .. h.kind .. ': ' .. h.msg,
            h.level == 'warn' and 'DiagnosticWarn' or 'Comment')
    end

    set_lines(M.buf, lines)
    for _, mk in ipairs(marks) do
        pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, mk.row, 0,
            { end_row = mk.row + 1, hl_group = mk.hl })
    end
end

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-plan'
    M.buf = buf
    store.on_plan(function () M.render() end)
    M.render()
    return buf
end

return M
