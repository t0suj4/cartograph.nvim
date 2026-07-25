-- User commands, registered at STARTUP from plugin/cartograph.lua so
-- invocation is painless: every :Cartograph* command exists (and
-- tab-completes) before any graph is open, answers with a pointer
-- instead of E492, and requires nothing heavy until it actually runs.
-- init.open() re-registers idempotently (the pcall-del pattern).
--
-- This module's top level must stay LEAN — it loads during startup.
-- All requires live inside callbacks.
--
-- The 69 registrations themselves live in cartograph/commands/<group>.lua,
-- one file per |cartograph-commands| group, so the help taxonomy and the code
-- agree. This file owns what they SHARE: the graph-needing guard, the
-- index-only guards, the scratch split, the txn-verb map, and the reveal.
-- Each group rebinds them as locals under the same names, so a callback
-- reads the same as when all 69 lived in one 1,238-line function.

local M = {}


-- the graph-needing guard: a command that acts on the open cockpit
-- answers helpfully when there is none
local function live()
    local store = require 'cartograph.store'
    if not (store.data and store.data.root) then
        vim.notify('cartograph: no graph open — :Cartograph [dir] first',
            vim.log.levels.WARN)
        return nil
    end
    return store
end

-- index-only: ensure a file's df/flow is materialized before a dataflow verb runs on it.
-- df/flow are local, so this is byte-faithful (unlike calls); no-op on a full graph (the
-- store guard sees df already present) or when not index-only. [[cartograph-thin-index]]
local function mat_df(store, file)
    if file and store.materialize_file_dataflow then store.materialize_file_dataflow(file) end
end

-- index-only honesty ([[cartograph-thin-index]]): a verb that needs the WHOLE-GRAPH call
-- fixpoint (call graph / effect PDG) can't run on the thin index — calls were never built.
-- Refuse with a pointer to the full open rather than produce a degraded/empty answer that
-- reads as a real "none" (the uniform-honesty invariant). df/flow-local verbs are exempt:
-- their inputs materialize per-file (mat_df). Returns the store, or nil after notifying.
local function whole_graph(store)
    if store.is_index_only and store.is_index_only() then
        vim.notify(('cartograph: this needs the call graph — index-only mode has none.'
            .. ' Run :Cartograph %s for the full graph'):format(store.data.root or '<dir>'),
            vim.log.levels.WARN)
        return nil
    end
    return store
end

-- the shared read-only bottom-split scratch (cartograph.ui.scratch); required
-- at call time to keep this module's top level lean (loads during startup)
local function scratch(lines, ft)
    return require('cartograph.ui').scratch(lines, ft)
end

local function txn_module()
    local st = require 'cartograph.store'
    local v = st.txn.verb
    if v == 'move' or v == 'extract-module' then return 'cartograph.moveapply' end
    if v == 'extract-helper' then return 'cartograph.cloneextract' end
    if v == 'reorder' then return 'cartograph.reorder' end
    if v == 'hoist-closure' then return 'cartograph.hoistclosure' end
    return 'cartograph.clonemerge'
end

local function cmd(name, fn, opts)
    pcall(vim.api.nvim_del_user_command, name)
    vim.api.nvim_create_user_command(name, fn, opts)
end

-- ── graph-aware lint → quickfix ─────────────────────────────────

-- ── safe-reorder: which of the focused fn's statements commute ───
-- A JUMPABLE lens: each statement / constraint row carries a source line, and
-- <CR> reveals it in the source pane (or opens the file when no cockpit pane
-- is live) — so the verdicts read against the code they judge.
-- Reveal ONE line in the def pane, falling back to a tab drop when no
-- cockpit pane is live. Shared by every jumpable lens (reorder, trace).
local function reveal_at(store, file, l0)
    if not (file and l0) then return end
    local src = require 'cartograph.panes.source'
    if src.buf and vim.api.nvim_buf_is_valid(src.buf)
        and src.win_top and vim.api.nvim_win_is_valid(src.win_top) then
        src.highlight { file = file, ranges = { {
            start = { line = l0, char = 0 }, ['end'] = { line = l0 + 1, char = 0 } } } }
        pcall(vim.api.nvim_set_current_win, src.win_top)
    else
        vim.cmd('tab drop ' .. vim.fn.fnameescape(store.abs(file)))
        pcall(vim.api.nvim_win_set_cursor, 0, { l0 + 1, 0 })
    end
end

function M.register()
    local H = { cmd = cmd, live = live, whole_graph = whole_graph,
        mat_df = mat_df, scratch = scratch, txn_module = txn_module,
        reveal_at = reveal_at }
    -- in |cartograph-commands| order. Required HERE, not at the top level, to
    -- keep that lean; and by LITERAL name, not a computed one, because
    -- cartograph resolves its own graph and a dynamic require would read as
    -- an unresolved edge in it.
    for _, group in ipairs({
        require 'cartograph.commands.open',
        require 'cartograph.commands.nav',
        require 'cartograph.commands.honesty',
        require 'cartograph.commands.analysis',
        require 'cartograph.commands.lint',
        require 'cartograph.commands.clones',
        require 'cartograph.commands.refactor',
        require 'cartograph.commands.txn',
        require 'cartograph.commands.outward',
    }) do group.register(H) end
end

return M
