-- SUPPRESSING A FINDING, from the source it is about (exprlint.MARK is the reader;
-- this is the writer). The action behind the `lintact` compartment's "suppress" row.
--
-- Three decisions worth stating, because each rules out an obvious alternative:
--
--   * the marker goes TRAILING on the reported line, not on a comment line above
--     it. Inserting a line shifts every range below it, so the graph's node and
--     occurrence ranges would all be stale until re-extraction — a write that
--     invalidates the map it was issued from. Appending keeps every line number
--     true, which means the pane you pressed the key in is still correct after.
--   * the comment LEAD is per-language and UNKNOWN REFUSES. Guessing `--` into a
--     Ruby file writes a syntax error; a refusal costs the user one message.
--     Only line-comment leads are listed: for a block-comment-only language the
--     append trick is unsound, so those are simply absent and refuse.
--   * the write is JOURNALED, so `:CartographUndo` reverses it like every other
--     apply verb. A source edit that cannot be undone is not a cockpit action.
--
-- Appending is always syntactically safe for a line-comment language even when the
-- line ALREADY ends in a comment: the second lead falls inside the first comment,
-- and the reader looks for the marker by substring, so it still sees it. That is
-- why this does not try to detect an existing trailing comment — doing so would
-- mean deciding whether a `--` sits inside a string literal, which needs a parse.

local M = {}

-- line-comment lead by file extension. ABSENT = refuse (see the header).
M.LEAD = {
    lua = '--', hs = '--', sql = '--',
    py = '#', rb = '#', sh = '#', bash = '#', zsh = '#', pl = '#', yml = '#',
    js = '//', mjs = '//', cjs = '//', ts = '//', jsx = '//', tsx = '//',
    c = '//', h = '//', cpp = '//', hpp = '//', cc = '//', hh = '//',
    go = '//', rs = '//', java = '//', php = '//', zig = '//', odin = '//',
    scm = ';', ss = ';', el = ';',
}

--- The comment lead for a file, or nil + why.
function M.lead_for(file)
    local ext = (file or ''):match('%.([%w_]+)$')
    if not ext then return nil, ('no extension on %s — cannot tell how to comment'):format(file or '?') end
    local lead = M.LEAD[ext:lower()]
    if not lead then
        return nil, ('no line-comment syntax known for .%s — refusing to guess'):format(ext)
    end
    return lead
end

--- The text this would append (also what a preview shows).
function M.marker(lead, rule)
    return ('%s %s: %s'):format(lead, require('cartograph.exprlint').MARK, rule)
end

-- read a file's lines, or nil + why
local function read(abs)
    local fd = io.open(abs, 'r')
    if not fd then return nil, 'cannot read ' .. abs end
    local text = fd:read('a')
    fd:close()
    if not text then return nil, 'cannot read ' .. abs end
    return vim.split(text, '\n', { plain = true }), nil, text
end

--- What suppressing `rule` at 1-based `lnum` of `file` would do, WITHOUT doing it:
--- { file, lnum, before, after, marker }. Returns nil, why when it cannot.
function M.plan(store, file, lnum, rule)
    local lead, why = M.lead_for(file)
    if not lead then return nil, why end
    local lines, rerr = read(store.abs(file))
    if not lines then return nil, rerr end
    local before = lines[lnum]
    if not before then return nil, ('%s has no line %d'):format(file, lnum) end
    local marker = M.marker(lead, rule)
    if before:find('@cg%-ignore') then
        return nil, 'this line already carries a suppression marker'
    end
    return { file = file, lnum = lnum, before = before,
        after = before .. '  ' .. marker, marker = marker }
end

--- Apply a plan, journaled. Returns the plan, or nil + why.
function M.apply(store, plan)
    local abs = store.abs(plan.file)
    local lines, rerr, text = read(abs)
    if not lines then return nil, rerr end
    -- drift check: refuse rather than clobber a line that changed since the plan
    if lines[plan.lnum] ~= plan.before then
        return nil, 'the line changed since this was planned — refusing to write'
    end
    lines[plan.lnum] = plan.after
    local after_text = table.concat(lines, '\n')
    local journal = require 'cartograph.journal'
    local root = store.data and store.data.root
    local entry
    if root then
        entry = journal.begin(root, 'suppress',
            ('suppress at %s:%d'):format(plan.file, plan.lnum),
            { [plan.file] = text })
    end
    local fd = io.open(abs, 'w')
    if not fd then
        if entry then journal.abort(root, entry, 'cannot open for writing') end
        return nil, 'cannot write ' .. abs
    end
    fd:write(after_text)
    fd:close()
    if entry then journal.commit(root, entry, { [plan.file] = after_text }) end
    -- an open buffer on this file would otherwise overwrite the edit on its next
    -- write, and shows stale text meanwhile
    local buf = vim.fn.bufnr(abs)
    if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
        vim.api.nvim_buf_call(buf, function () vim.cmd('silent edit!') end)
    end
    return plan
end

--- Remove the marker from a line (the inverse action). Returns the plan or nil, why.
function M.unplan(store, file, lnum)
    local lines, rerr = read(store.abs(file))
    if not lines then return nil, rerr end
    local before = lines[lnum]
    if not before then return nil, ('%s has no line %d'):format(file, lnum) end
    local at = before:find('@cg%-ignore')
    if not at then return nil, 'no suppression marker on this line' end
    -- cut from the marker's comment LEAD if one immediately precedes it, so the
    -- line does not keep a dangling `--`
    local head = before:sub(1, at - 1)
    local lead = M.lead_for(file)
    if lead then
        local cut = head:match('^(.-)%s*' .. vim.pesc(lead) .. '%s*$')
        if cut then head = cut end
    end
    return { file = file, lnum = lnum, before = before,
        after = (head:gsub('%s+$', '')), marker = before:sub(at) }
end

return M
