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

    -- same rule as refresh: a staged move-set pins the graph. Swapping
    -- graphs under it would strand the plan on dead ids — refuse until
    -- applied or cleared, never discard staged intent silently.
    if store.data and (next(store.moveset or {}) or store.txn) then
        error('cartograph: staged changes pending — apply or clear them'
            .. ' before opening another graph', 0)
    end

    -- a DIRECTORY opens through the tree-sitter provider (any language with
    -- a parser); a file is a pre-extracted dump (the lua-ls CLI's output)
    local target = vim.fn.expand(dump_path)
    local mcp_name = target:match('^mcp://(.+)$')
    if mcp_name then
        -- a server that STAMPS its keys is substrate: its scan caches and
        -- warm opens re-fetch only changed keys (one cheap stamps call).
        -- A stampless server is a sample: honest re-fetch per open.
        local cachem = require 'cartograph.cache'
        local data, note = cachem.open(target)
        if note then vim.notify('cartograph: ' .. note, vim.log.levels.INFO) end
        if not data then
            local err
            data, err = require('cartograph.providers.mcp').extract(mcp_name)
            if not data then
                error('cartograph: mcp://' .. mcp_name .. ' — ' .. tostring(err), 0)
            end
            cachem.save(data) -- persists iff the server supplied stamps
        end
        require('cartograph.xlang').link(data,
            require('cartograph.xlang').effective_bindings(data))
        require('cartograph.sql').attach(data)
        store.ingest(data)
    elseif vim.fn.isdirectory(target) == 1 then
        local cfg = require 'cartograph.config'
        -- everything after extraction: clangd oracle, cross-language
        -- links, SQL entities, ingest (also the parallel path's on_done)
        local function finish(data)
            -- C/C++ roots get clangd resolution when available (config.clangd)
            local has_c = false
            for _, n in ipairs(data.nodes) do
                if n.kind == 'module' and n.file:match('%.[ch]p?p?$') then
                    has_c = true
                    break
                end
            end
            if has_c and cfg.clangd ~= false then
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
            -- string-embedded SQL: tables become entities with usage sites
            local sq = require('cartograph.sql').attach(data)
            if sq.tables > 0 then
                vim.notify(('cartograph: %d SQL tables from %d embedded queries')
                    :format(sq.tables, sq.queries), vim.log.levels.INFO)
            end
            if x.links > 0 then
                vim.notify(('cartograph: linked %d cross-language call sites')
                    :format(x.links), vim.log.levels.INFO)
            end
            -- Django URL loop: routes as entities, templates linked in
            local dj = require('cartograph.django').attach(data)
            if dj and dj.routes > 0 then
                vim.notify(('cartograph: django — %d routes, %d templates,'
                    .. ' %d links; %d unregistered, %d unused, %d duplicate')
                    :format(dj.routes, dj.templates, dj.links,
                        #dj.unregistered, #dj.unused, #dj.duplicate),
                    vim.log.levels.INFO)
            end
            -- a configured database: its tables join the graph and the
            -- code's SQL entities link to them (session post-pass)
            local dbl, dberr = require('cartograph.dblink').attach(data)
            if dbl then
                vim.notify(('cartograph: db link — %d matched, %d missing,'
                    .. ' %d unused%s'):format(dbl.matched, #dbl.missing,
                    #dbl.unused,
                    dbl.prefix and (" (prefix '%s')"):format(dbl.prefix) or ''),
                    vim.log.levels.INFO)
            elseif dberr then
                vim.notify('cartograph: db link failed — ' .. dberr,
                    vim.log.levels.WARN)
            end
            store.ingest(data)
        end

        -- incremental open: unchanged files come from the cache, only the
        -- diff re-extracts. Subtree slices bypass it (a slice would poison
        -- the full-tree entry).
        local data, note
        if not (opts and opts.subdirs) then
            data, note = require('cartograph.cache').open(target)
            if note then vim.notify('cartograph: ' .. note, vim.log.levels.INFO) end
        end
        if data then
            finish(data)
        else
            local ts = require 'cartograph.providers.treesitter'
            local files = not (opts and opts.subdirs) and cfg.parallel ~= false
                and ts.list_files(target) or {}
            if #files >= (cfg.parallel_threshold or 300) then
                -- streaming cold open: the browser opens NOW on module
                -- stubs; worker chunks fill the graph in as they land
                local stub = { schema = 1, root = target, provider = 'treesitter',
                    partial = { done = 0, total = 0 },
                    nodes = {}, edges = {}, calls = {}, stamps = {} }
                local R0 = { start = { line = 0, char = 0 },
                    ['end'] = { line = 0, char = 0 } }
                for _, f in ipairs(files) do
                    stub.nodes[#stub.nodes + 1] = { id = f, name = f,
                        kind = 'module', file = f, range = R0, order = -1 }
                end
                store.ingest(stub)
                local par = require 'cartograph.parallel'
                local nw = cfg.workers or par.default_workers()
                vim.notify(('cartograph: extracting %d files with %d workers…')
                    :format(#files, nw), vim.log.levels.INFO)
                par.extract(target, {
                    workers = nw,
                    on_note = function (m)
                        vim.notify('cartograph: ' .. m, vim.log.levels.WARN)
                    end,
                    on_chunk = function (k, n, acc)
                        -- progressive view: arrived files real, rest stubs
                        local seen = {}
                        for _, nd in ipairs(acc.nodes) do
                            if nd.kind == 'module' then seen[nd.file] = true end
                        end
                        local view = {}
                        for key, v in pairs(acc) do view[key] = v end
                        view.partial = { done = k, total = n }
                        view.nodes = vim.list_extend({}, acc.nodes)
                        for _, f in ipairs(files) do
                            if not seen[f] then
                                view.nodes[#view.nodes + 1] = { id = f, name = f,
                                    kind = 'module', file = f, range = R0, order = -1 }
                            end
                        end
                        local back, fwd = store._nav_back, store._nav_fwd
                        local loc = store.loc_provider and store.loc_provider.get()
                        local focused = store.focused
                        store.ingest(view)
                        store._nav_back, store._nav_fwd = back or {}, fwd or {}
                        if focused and store.node(focused) then
                            store.set_focus(focused)
                        end
                        if loc and store.loc_provider then
                            pcall(store.loc_provider.set, loc)
                        end
                    end,
                    on_done = function (acc)
                        require('cartograph.cache').save_bg(acc)
                        local back, fwd = store._nav_back, store._nav_fwd
                        local loc = store.loc_provider and store.loc_provider.get()
                        finish(acc)
                        store._nav_back, store._nav_fwd = back or {}, fwd or {}
                        if loc and store.loc_provider then
                            pcall(store.loc_provider.set, loc)
                        end
                        require('cartograph.toc').attach(store)
                        store.ws_resolve() -- members arrive with their files
                        vim.notify(('cartograph: extraction complete — %d nodes, %d calls')
                            :format(#acc.nodes, #acc.calls), vim.log.levels.INFO)
                    end,
                })
            else
                data = ts.extract(target, opts)
                if not (opts and opts.subdirs) then
                    require('cartograph.cache').save_bg(data)
                end
                finish(data)
            end
        end
    else
        store.load(target)
    end
    -- manifest projects (WoW .toc): exact load order for the browser + linter
    require('cartograph.toc').attach(store)

    -- the working set: what the user marked as their current work,
    -- persisted per root as refs, resolved against this fresh graph
    local ws_notes = store.ws_load()
    if #ws_notes > 0 then
        vim.notify('cartograph: working set — ' .. table.concat(ws_notes, '; '),
            vim.log.levels.INFO)
    end

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

    -- every :Cartograph* command (plugin/cartograph.lua registers them
    -- at startup too; idempotent — this covers headless embeds that
    -- never source plugin files)
    require('cartograph.commands').register()

    -- live refresh: the graph follows saves (tree-sitter graphs only)
    local grp = vim.api.nvim_create_augroup('cartograph_refresh', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePost', {
        group = grp,
        callback = function (ev)
            if require('cartograph.config').refresh == false then return end
            local root = store.data and store.data.root
            if not root or store.data.provider ~= 'treesitter' then return end
            local abs = vim.api.nvim_buf_get_name(ev.buf)
            if abs:sub(1, #root + 1) ~= root .. '/' then return end
            local rel = abs:sub(#root + 2)
            vim.defer_fn(function ()
                local okr, stats, why = pcall(require('cartograph.refresh').file, rel)
                if okr and stats then
                    vim.notify(('cartograph: refreshed %s (%d nodes, %d relinked)')
                        :format(rel, stats.added, stats.relinked), vim.log.levels.INFO)
                elseif okr and why then
                    vim.notify('cartograph: refresh skipped — ' .. why, vim.log.levels.WARN)
                end
            end, 100)
        end,
    })

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
