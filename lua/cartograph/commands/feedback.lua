-- :Cartograph command group — feedback ABOUT CARTOGRAPH, anchored to the node
-- it happened on (|cartograph-cmd-feedback|, cartograph.feedback).
--
-- Deliberately does NOT use the shared `live()` helper: a complaint must be
-- fileable when the graph is broken, half-loaded or absent, which is exactly
-- when you most want to file one. Everything degrades to UNAVAILABLE; only the
-- expectation is required.

local M = {}

local function root_of(store)
    return (store and store.data and store.data.root) or vim.fn.getcwd()
end

-- The compose buffer: git-commit semantics, because that is the idiom for
-- "type prose, `:w` to commit it, `:q` to abandon it" and nobody needs to learn
-- it twice. Lines starting with '#' are stripped.
local function compose(fb, store, pane, sight, root)
    vim.cmd('botright new')
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype, vim.bo[buf].bufhidden = 'acwrite', 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'markdown'
    pcall(vim.api.nvim_buf_set_name, buf, 'cartograph://feedback')
    local subj = sight.subject or {}
    local where = subj.kind == 'node'
        and ('%s (%s)'):format(subj.name or '?', subj.file or '?')
        or 'a row with no node'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        '', '',
        '# Write what you EXPECTED. Lines starting with # are ignored.',
        '# :w files it · :q abandons it',
        '#',
        ('# The OBSERVED half is already captured: %s row(s), altitude %s,'):format(
            type(sight.after) == 'table' and #sight.after or 0,
            tostring(sight.altitude)),
        ('# gesture %s, subject %s.'):format(tostring(sight.gesture), where),
        '# You do not need to describe what you are looking at.',
    })
    vim.api.nvim_win_set_height(0, 10)
    pcall(vim.api.nvim_win_set_cursor, 0, { 1, 0 })
    vim.cmd 'startinsert'
    vim.api.nvim_create_autocmd('BufWriteCmd', {
        buffer = buf,
        callback = function ()
            local body = {}
            for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
                if not l:match('^%s*#') then body[#body + 1] = l end
            end
            sight.expected = vim.trim(table.concat(body, '\n'))
            local e, why = fb.entry(sight)
            if not e then
                -- nothing typed: an abandoned compose is not an error, and we
                -- must not leave a bookmark masquerading as a report
                vim.bo[buf].modified = false
                vim.notify('cartograph: feedback abandoned (' .. why .. ')',
                    vim.log.levels.WARN)
                return
            end
            local path, err = fb.write(root, e)
            vim.bo[buf].modified = false
            if not path then
                return vim.notify('cartograph: ' .. err, vim.log.levels.ERROR)
            end
            vim.notify(('cartograph: %s feedback filed — %s'):format(e.kind, path))
            vim.cmd 'bwipeout'
        end,
    })
end

function M.register(H)
    local cmd, scratch = H.cmd, H.scratch

    cmd('CartographFeedback', function (a)
        local fb = require 'cartograph.feedback'
        local ok_s, store = pcall(require, 'cartograph.store')
        store = ok_s and store or nil
        local root = root_of(store)

        if a.bang then
            local entries = fb.list(root)
            return scratch(fb.markdown(entries, root), 'markdown')
        end

        local pane
        local ok_p, p = pcall(require, 'cartograph.panes.symbols')
        if ok_p then pane = p end
        -- Captured BEFORE anything opens a window or you start typing: the
        -- observation is what was on screen when you complained, not what is
        -- there once the compose buffer has taken focus.
        local sight = fb.sight(store, pane)

        if a.args and vim.trim(a.args) ~= '' then
            sight.expected = a.args
            local e, why = fb.entry(sight)
            if not e then return vim.notify('cartograph: ' .. why, vim.log.levels.WARN) end
            local path, err = fb.write(root, e)
            if not path then return vim.notify('cartograph: ' .. err, vim.log.levels.ERROR) end
            return vim.notify(('cartograph: %s feedback filed — %s'):format(e.kind, path))
        end
        compose(fb, store, pane, sight, root)
    end, { nargs = '*', bang = true,
        desc = 'cartograph: file feedback ABOUT CARTOGRAPH, frozen at the node you are standing on — the rendered rows, the gesture you pressed and where it came from, the subject\'s source, the typed empty, call provenance and the environment facts that decide verdicts (parsers, profile, packs, index-only, cache VERSION). You type only what you EXPECTED; the observed half is captured. Works with no graph loaded and on a row with no node (an absence is the most useful report). ! = dump every entry for this root as pasteable markdown' })
end

return M
