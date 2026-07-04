-- cartograph.nvim — a dependency/definition cockpit for navigating a codebase's
-- symbol graph and staging multi-file function moves. Early / experimental.
--
-- The real machinery lives behind three seams (see README): a GraphProvider
-- (data in), an ImpactEngine (transforms), and the pane/store UI. This first
-- slice implements only: load a static dump → render the symbols + source panes
-- in one hardcoded layout. No hover-events beyond cursor→focus, no staging.

local M = {}

---@class cartograph.Config
---@field keys table<string, string>?  remap any binding (see cartograph/config.lua)
local defaults = {}

---@param opts cartograph.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', defaults, opts or {})
    require('cartograph.config').apply(opts)
end

--- Open the cockpit on a graph dump (neutral-schema JSON produced by the
--- provider). ONE hardcoded layout for now: symbols left, source right.
---@param dump_path string
---@param opts { subdirs:string[]? }?  subtree scope for directory extraction
function M.open(dump_path, opts)
    local store   = require 'cartograph.store'
    local symbols = require 'cartograph.panes.symbols'
    local source  = require 'cartograph.panes.source'
    local plan    = require 'cartograph.panes.plan'

    -- a DIRECTORY opens through the tree-sitter provider (any language with
    -- a parser); a file is a pre-extracted dump (the lua-ls CLI's output)
    local target = vim.fn.expand(dump_path)
    if vim.fn.isdirectory(target) == 1 then
        local data = require('cartograph.providers.treesitter').extract(target, opts)
        -- C/C++ roots get clangd resolution when available (config.clangd)
        local has_c = false
        for _, n in ipairs(data.nodes) do
            if n.kind == 'module' and n.file:match('%.[ch]p?p?$') then
                has_c = true
                break
            end
        end
        if has_c and require('cartograph.config').clangd ~= false then
            vim.notify('cartograph: resolving call graph with clangd…', vim.log.levels.INFO)
            local stats = require('cartograph.providers.clangd').enrich(data)
            if stats then
                vim.notify(('cartograph: clangd proved edges for %d functions')
                    :format(stats.resolved_fns), vim.log.levels.INFO)
            end
        end
        -- cross-language boundaries (string-key dispatch) — after clangd,
        -- so the oracle's edge rebuild can't drop the cross-language links.
        -- Registries the project invented for itself are DISCOVERED and
        -- linked the same way (config.discover = false disables).
        local x = require('cartograph.xlang').link(data,
            require('cartograph.xlang').effective_bindings(data))
        if x.links > 0 then
            vim.notify(('cartograph: linked %d cross-language call sites')
                :format(x.links), vim.log.levels.INFO)
        end
        store.ingest(data)
    else
        store.load(target)
    end
    -- manifest projects (WoW .toc): exact load order for the browser + linter
    require('cartograph.toc').attach(store)

    -- ONE hardcoded layout for now: the browser on the left, the source split
    -- taking the rest (the browser's descend covers uses/callers now, so the
    -- code gets the width; the trace pane opens its own split on demand), and
    -- a full-width plan bar along the bottom.
    vim.cmd('tabnew')
    local w_symbols = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_symbols, symbols.create())

    vim.cmd('rightbelow vsplit')
    local w_source = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_source, source.create())

    vim.api.nvim_win_set_width(w_symbols, 38)

    source.attach(w_source)

    -- full-width plan bar at the very bottom
    vim.cmd('botright split')
    local w_plan = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_plan, plan.create())
    vim.api.nvim_win_set_height(w_plan, 10)

    vim.api.nvim_set_current_win(w_symbols)
    symbols.attach(w_symbols)

    -- focus history, vim-jumplist style: back/back_alt everywhere, forward only
    -- where the cycle key (<Tab> = <C-i> in most terminals) isn't taken —
    -- symbols uses <Tab> for the file-view toggle, source for the lens.
    local keys = require('cartograph.config').keys
    for _, b in ipairs({ { symbols.buf }, { plan.buf, true }, { source.buf } }) do
        local buf, fwd = b[1], b[2]
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.keymap.set('n', keys.back,     store.back, { buffer = buf, desc = 'cartograph: back (previous pivot)' })
            vim.keymap.set('n', keys.back_alt, store.back, { buffer = buf, desc = 'cartograph: back (previous pivot)' })
            if fwd then
                vim.keymap.set('n', keys.forward, store.forward, { buffer = buf, desc = 'cartograph: forward' })
            end
        end
    end

    -- graph-aware lint -> quickfix
    local SEV = { warn = 'W', info = 'I' }
    pcall(vim.api.nvim_del_user_command, 'CartographLint')
    vim.api.nvim_create_user_command('CartographLint', function ()
        local findings = require('cartograph.lint').run(store)
        if #findings == 0 then return vim.notify('cartograph: no lint findings', vim.log.levels.INFO) end
        local qf = {}
        for _, f in ipairs(findings) do
            qf[#qf + 1] = { filename = f.file, lnum = f.line, col = 1,
                type = SEV[f.severity] or 'E',
                text = ('[%s] %s'):format(f.rule, f.message),
                user_data = f.fix }
        end
        vim.fn.setqflist({}, ' ', { title = 'cartograph lint', items = qf })
        vim.cmd('copen')
    end, { desc = 'cartograph: graph-aware lint (dead code, redundant requires, call cycles) -> quickfix' })

    -- apply the quick fix (an annotation line) of the CURRENT quickfix entry
    pcall(vim.api.nvim_del_user_command, 'CartographLintFix')
    vim.api.nvim_create_user_command('CartographLintFix', function ()
        local qf = vim.fn.getqflist({ idx = 0, items = 1 })
        local it = qf.items[qf.idx]
        local fix = it and it.user_data
        if type(fix) ~= 'table' or not fix.text then
            return vim.notify('cartograph: no quick fix on this finding', vim.log.levels.WARN)
        end
        -- insert above the target line, via the buffer so open edits are respected
        local buf = vim.fn.bufadd(fix.file)
        vim.fn.bufload(buf)
        local target = vim.api.nvim_buf_get_lines(buf, fix.line, fix.line + 1, false)[1] or ''
        local indent = target:match('^%s*') or ''
        vim.api.nvim_buf_set_lines(buf, fix.line, fix.line, false, { indent .. fix.text })
        vim.api.nvim_buf_call(buf, function () vim.cmd('silent noautocmd write') end)
        vim.notify(('cartograph: inserted `%s` at %s:%d — regenerate the graph to re-check'):format(
            fix.text, vim.fn.fnamemodify(fix.file, ':t'), fix.line + 1), vim.log.levels.INFO)
    end, { desc = 'cartograph: apply the annotation quick fix of the current quickfix entry' })

    -- why did registry discovery (not) find a verb?
    pcall(vim.api.nvim_del_user_command, 'CartographDiscover')
    vim.api.nvim_create_user_command('CartographDiscover', function (o)
        local g = require 'cartograph.greenspun'
        local xl = require 'cartograph.xlang'
        local deep = o.bang and { deep = true } or nil
        local lines = g.explain(store.data, o.args ~= '' and o.args or nil, deep)
        -- the bang is the BUTTON: apply what deep discovery found beyond
        -- the bindings already in force, then restore the exact location
        if o.bang and o.args == '' then
            local have = {}
            for _, b in ipairs(xl.effective_bindings(store.data)) do
                for _, v in ipairs(type(b.export.verb) == 'table'
                    and b.export.verb or { b.export.verb }) do
                    have[v] = true
                end
            end
            local fresh = {}
            for _, b in ipairs(g.registries(store.data, { deep = true })) do
                if not have[b.export.verb] then fresh[#fresh + 1] = b end
            end
            if #fresh > 0 then
                local loc = store.loc_provider and store.loc_provider.get()
                local stats = xl.link(store.data, fresh)
                store.ingest(store.data)
                require('cartograph.toc').attach(store)
                if loc and store.loc_provider then store.loc_provider.set(loc) end
                local names = {}
                for _, b in ipairs(fresh) do names[#names + 1] = b.export.verb end
                lines[#lines + 1] = ''
                lines[#lines + 1] = ('APPLIED %d deep binding(s): %s — %d handler(s) resolved, %d site(s) linked')
                    :format(#fresh, table.concat(names, ', '), stats.exports, stats.links)
            else
                lines[#lines + 1] = ''
                lines[#lines + 1] = 'deep discovery found nothing beyond the bindings already in force'
            end
        end
        vim.cmd('botright new')
        local buf = vim.api.nvim_get_current_buf()
        vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile
            = 'nofile', 'wipe', false
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.api.nvim_win_set_height(0, math.min(#lines + 1, 15))
        vim.keymap.set('n', require('cartograph.config').keys.close,
            '<cmd>close<cr>', { buffer = buf })
    end, { nargs = '?', bang = true,
        desc = 'cartograph: explain registry discovery; ! runs the deep tier and applies it' })

    -- browse the state machine (adapter: setup{ fsm = {...} })
    pcall(vim.api.nvim_del_user_command, 'CartographStates')
    vim.api.nvim_create_user_command('CartographStates', function ()
        -- pivot to the spec var first: <C-o> returns here, and the source
        -- pane anchors on the spec while browsing states
        local v = symbols.fsm_anchor()
        if v then store.pivot(v.id) end
        symbols.show('states')
    end, { desc = 'cartograph: browse the state machine (states -> entry points -> code)' })

    -- open the browser on the first file, and focus its first function
    -- explicitly (hover never focuses — pivots are conscious)
    symbols.show('file', store.files[1])
    for _, n in ipairs(store.by_file[store.files[1]] or {}) do
        if n.kind == 'function' or n.kind == 'method' then
            store.set_focus(n.id)
            break
        end
    end
end

return M
