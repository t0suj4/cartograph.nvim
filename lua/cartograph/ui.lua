-- Shared cockpit UI primitives. First tenant: `scratch` — a read-only bottom
-- split (nofile/wipe) that renders `lines`, sizes to fit (capped at 20), and
-- binds the configured close key. Extracted from the byte-identical copies in
-- commands.lua and workspace.lua; the latter hardcoded 'q' for the close key,
-- so folding both onto config.keys.close also makes that binding honour a user
-- remap, like every other cockpit key.

local M = {}

--- A read-only scratch buffer in a bottom split. Returns the buffer handle so
--- the caller can layer its own keymaps (e.g. <CR> jumps) on top.
---@param lines string[]
---@param ft string?  optional filetype for the scratch buffer
function M.scratch(lines, ft)
    vim.cmd('botright new')
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile
        = 'nofile', 'wipe', false
    -- A tenant rendering SOURCE-DERIVED text can hand us a line containing a
    -- newline (a Lua `[[…]]` literal, a docstring), and nvim_buf_set_lines fails
    -- the WHOLE call on it — one blob in one field takes down an entire report,
    -- which is how :CartographPrototypes died on Von-Neumann's storyText. A line
    -- here is one line by definition, so fold embedded breaks rather than let a
    -- renderer slip become an unusable command. Folding (not splitting) preserves
    -- the 1:1 line↔item indexing that callers layer their <CR> keymaps on.
    local safe = {}
    for i, l in ipairs(lines) do safe[i] = (l:gsub('[\r\n]+', '↵')) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, safe)
    vim.bo[buf].modifiable = false
    if ft then vim.bo[buf].filetype = ft end
    vim.api.nvim_win_set_height(0, math.min(#lines + 1, 20))
    vim.keymap.set('n', require('cartograph.config').keys.close,
        '<cmd>close<cr>', { buffer = buf })
    return buf
end

return M
