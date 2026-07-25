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

--- Open a directory in INDEX-ONLY mode ([[cartograph-thin-index]]): the thin symbol
--- index — parse + DEF nodes only (no calls/df/flow), ~5-9x cheaper. Ingests it so the
--- Tier-0 LSP/nav path serves off it (workspace/symbol, documentSymbol, definition-on-a-
--- def, symbol hover — measured identical to a full open). The calls-dependent surface is
--- honestly WITHHELD, not faked: the LSP server doesn't advertise references / call-
--- hierarchy (so a client can't render an empty answer as an authoritative "none"), and
--- the whole-graph cockpit verbs (:CartographUntangle / Reorder / UntangleModule) refuse
--- with a pointer to the full open. df/flow-LOCAL verbs still work (per-file materialize).
--- Sync (the thin index is fast — no parallel/cache streaming). Attach with
--- :CartographLspAttach; a full :Cartograph open + re-attach restores every surface.
---@param root string?  directory (default cwd)
---@param opts table?
function M.open_index_only(root, opts)
    root = vim.fn.expand(root or vim.fn.getcwd())
    local store = require 'cartograph.store'
    if store.data and (next(store.moveset or {}) or store.txn) then
        error('cartograph: staged changes pending — apply or clear them first', 0)
    end
    -- WARM SYMBOL SERVING ([[cartograph-thin-index]]): reuse the persisted def shards
    -- instead of re-parsing when the tree is unchanged (~15x). A subtree slice bypasses
    -- the cache (a slice would poison the full-tree entry — same rule as the full open).
    local cache = require 'cartograph.cache'
    local sliced = opts and opts.subdirs
    local data, note
    if not sliced then data, note = cache.open_index_only(root) end
    if note then vim.notify('cartograph: ' .. note, vim.log.levels.INFO) end
    if not data then
        data = require('cartograph.providers.treesitter').index_only(root, opts)
        if not sliced then cache.save_bg(data) end -- persist the thin index for next time
    end
    store.ingest(data)
    require('cartograph.commands').register() -- idempotent; make :Cartograph* live
    return store.data
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
    local self_which = target:match('^self://(.+)$')

    -- SESSION (multi-band, [[cartograph-multiband-session]]): re-opening an
    -- already-open root is a SWITCH — repoint the cockpit, no re-extract; a NEW
    -- root ADDS a band, freezing the active one into its record so this open's
    -- ingest doesn't clobber it. Single-band sessions never switch, so the
    -- common path is unchanged.
    local session = require 'cartograph.session'
    if session.active then store.record_crossing() end -- <C-o> returns to where we were
    local existing = session.by_root(target)
    if existing then
        session.switch(existing)
        pcall(require('cartograph.panes.symbols').render)
        if store.focused and store.node(store.focused) then store.set_focus(store.focused) end
        store.redraw()
        return store.data
    end
    session.begin(target)

    -- streaming shared by the cold (parallel), warm (cached) and self://
    -- opens: all show module stubs at once and fill the real graph in as it
    -- arrives (incrementally, via store.begin_stream/ingest_step), so none
    -- blocks the editor. R0 is the stub's zero range.
    local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
    -- run `fn` (a full re-ingest) without losing nav history / cursor
    local function preserve(fn)
        local back, fwd = store._nav_back, store._nav_fwd
        local loc = store.loc_provider and store.loc_provider.get()
        local focused = store.focused
        fn()
        store._nav_back, store._nav_fwd = back or {}, fwd or {}
        if focused and store.node(focused) then store.set_focus(focused) end
        if loc and store.loc_provider then pcall(store.loc_provider.set, loc) end
    end
    -- stub the browser on a file roster (the streamed opens' first paint).
    -- `roots` (self://) rides along so abspath resolves labelled keys even
    -- while the modules are still stubs.
    local function stub_ingest(files, roots, provider)
        local stub = { schema = 1, root = target, provider = provider or 'treesitter',
            roots = roots, partial = { done = 0, total = #files },
            nodes = {}, edges = {}, calls = {}, stamps = {} }
        for _, f in ipairs(files) do
            stub.nodes[#stub.nodes + 1] = { id = f, name = f,
                kind = 'module', file = f, range = R0, order = -1 }
        end
        store.ingest(stub)
    end

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
    elseif self_which then
        -- the RUNNING instance as a graph: nvim_list_runtime_paths() is the
        -- loaded-plugin roster (manager-agnostic — a plugin joins rtp exactly
        -- when it loads), unioned under self://loaded so a require from your
        -- config into a plugin (or plugin→plugin) resolves in one graph. A
        -- session-scoped SAMPLE — not cached, the next launch may load a
        -- different set — streamed like the cold path so it never blocks.
        local selfp = require 'cartograph.providers.self'
        local roster, why = selfp.roster()
        if not roster then
            error('cartograph: self://' .. self_which .. ' — ' .. tostring(why), 0)
        end
        stub_ingest(roster.files, roster.roots, 'self')
        local par = require 'cartograph.parallel'
        local cfg = require 'cartograph.config'
        local nw = cfg.workers or par.default_workers()
        vim.notify(('cartograph: self — %d loaded roots, extracting %d files'
            .. ' with %d workers…'):format(vim.tbl_count(roster.roots),
            #roster.files, nw), vim.log.levels.INFO)
        par.extract(roster.root, {
            workers = nw, roots = roster.roots, files = roster.files,
            provider = 'self',
            on_note = function (m)
                vim.notify('cartograph: ' .. m, vim.log.levels.WARN)
            end,
            -- incremental streaming: repoint the store at acc, then fold in
            -- each chunk's delta (O(delta), not a full O(graph) re-ingest)
            on_start = function (acc) store.begin_stream(acc) end,
            on_chunk = function (done, total, acc)
                acc.partial = { done = done, total = total }
                store.ingest_step(acc)
            end,
            on_done = function (acc)
                acc.partial = nil -- extraction complete: no longer streaming
                acc.vimruntime = roster.vimruntime ~= '' and roster.vimruntime or nil
                -- attach the lazy $VIMRUNTIME node (present so edges into it
                -- land somewhere; extracted only when descended) and resolve
                -- the requires the labelled-key path-match couldn't
                local req = selfp.finalize(acc)
                preserve(function () store.ingest(acc) end)
                vim.notify(('cartograph: self ready — %d nodes, %d calls,'
                    .. ' %d requires resolved (+$VIMRUNTIME lazy — l to load)')
                    :format(#acc.nodes, #acc.calls, req.added), vim.log.levels.INFO)
            end,
        })
    elseif vim.fn.isdirectory(target) == 1 then
        local cfg = require 'cartograph.config'
        -- project shapes: markers at the root preset inert analysis
        -- hints (entry points, excludes) before extraction sees them
        for _, s in ipairs(require('cartograph.shapes').apply(target)) do
            vim.notify(('cartograph: %s detected (%s) — presets applied;'
                .. ' :CartographShapes explains'):format(s.name, s.evidence),
                vim.log.levels.INFO)
        end
        -- everything after extraction: clangd oracle, cross-language
        -- links, SQL entities, ingest (also the parallel path's on_done)
        local function finish(data)
            -- Open the graph NOW with tree-sitter's name-matched (~) edges. The
            -- ENRICHMENT below — cross-language DISCOVERY + link (seconds on a
            -- big graph, e.g. openmw), the framework loops, then the LSP
            -- oracles — is deferred off the open's critical path and runs in
            -- the first idle gap (idle_defer), so it can never freeze the open
            -- or a keystroke. It re-ingests to fold its edges in. This is why
            -- the open feels instant even when the linking is expensive.
            store.ingest(data)
          local function enrich()
            if store.data ~= data then return end -- graph moved on
            -- cross-language boundaries (string-key dispatch) run BEFORE the
            -- oracles — their edge rebuild preserves xlang refs (e.xlang).
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
            -- Symfony URL loop: yaml routes as entities, twig + code linked
            local sf = require('cartograph.symfony').attach(data)
            if sf and sf.routes > 0 then
                local audit = sf.partial
                    and (('%d refs unmatched (discovery PARTIAL: %d resource'
                        .. ' imports/generators unseen)'):format(
                        sf.unmatched, sf.imports))
                    or (('%d unregistered, %d unused, %d duplicate'):format(
                        #sf.unregistered, #sf.unused, #sf.duplicate))
                vim.notify(('cartograph: symfony — %d routes (%d wired,'
                    .. ' %d external), %d templates, %d links; %s'):format(
                        sf.routes, sf.controllers, sf.external, sf.templates,
                        sf.links, audit), vim.log.levels.INFO)
            end
            -- Ansible notify↔handler loop + include graph
            local an = require('cartograph.ansible').attach(data)
            if an and (an.handlers > 0 or an.includes > 0) then
                vim.notify(('cartograph: ansible — %d handlers, %d notifies'
                    .. ' (%d linked, %d no-op, %d dynamic), %d includes,'
                    .. ' %d vars (%d links, %d unused); %d dead handlers,'
                    .. ' %d broken includes'):format(
                        an.handlers, an.notifies, an.links, #an.noop, an.dynamic,
                        an.includes, an.vars, an.var_links, #an.unused_vars,
                        #an.dead, #an.broken), vim.log.levels.INFO)
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
            -- fold the enrichment edges in (deferred: preserve the user's place)
            preserve(function () store.ingest(data) end)

            -- lua-ls resolves the WHOLE lua graph in the background (small
            -- enough) and hot-swaps its proven edges in when done.
            local has_lua = false
            for _, n in ipairs(data.nodes) do
                if n.kind == 'module' and n.file:match('%.lua$') then has_lua = true; break end
            end
            if has_lua and cfg.luals ~= false then
                vim.notify('cartograph: resolving with lua-ls in the background…',
                    vim.log.levels.INFO)
                require('cartograph.providers.luals').enrich_async(data, {},
                    function (stats, why)
                        if store.data ~= data then return end -- graph moved on
                        if not stats then
                            if why and not (why:find('binary') or why:find('nothing')) then
                                vim.notify('cartograph: lua-ls skipped — ' .. why
                                    .. ' (graph stays ~)', vim.log.levels.WARN)
                            end
                            return
                        end
                        require('cartograph.refresh').hotswap()
                        vim.notify(('cartograph: lua-ls settled %d/%d defs (%d'
                            .. ' upgraded, %d refuted)'):format(stats.answered,
                            stats.asked, stats.upgraded, stats.cleared),
                            vim.log.levels.INFO)
                    end)
            end
            -- clangd is DEMAND-driven: C/C++ projects (openmw: 28k functions)
            -- are too large to resolve whole, so a PERSISTENT session resolves
            -- the FOCUSED function's callers on navigation (see the on_focus
            -- hook at module load, which drives cartograph.providers.clangd).
            local has_c = false
            for _, n in ipairs(data.nodes) do
                if n.kind == 'module' and n.file:match('%.[ch]p?p?$') then has_c = true; break end
            end
            if has_c and cfg.clangd ~= false then
                local clangd = require 'cartograph.providers.clangd'
                if not clangd.compile_dir(data.root) then
                    vim.notify('cartograph: clangd has no compile_commands.json —'
                        .. ' resolution is degraded. Run :CartographCompileCommands'
                        .. ' to generate it (or set setup{ clangd_compile_commands = ... })',
                        vim.log.levels.WARN)
                end
                local sess, serr = clangd.start_session(data)
                if sess then
                    -- subscribe ONCE: focusing a C/C++ function resolves its
                    -- callers against the live session and splices the proven
                    -- set in (uses the CURRENT session, so re-opens are fine)
                    if not M._clangd_hooked then
                        M._clangd_hooked = true
                        store.on_focus(function (id)
                            local cg = require 'cartograph.providers.clangd'
                            if not cg.session then return end
                            local n = store.node(id)
                            if n and (n.kind == 'function' or n.kind == 'method')
                                and not n.decl then
                                -- the resolve spans a wait: per the store's
                                -- reentrancy contract, a re-ingest in between
                                -- remaps ids — drop the stale answer (the next
                                -- focus re-resolves)
                                local gen = store.generation
                                cg.resolve_focused(n, function (edges)
                                    if store.generation ~= gen then return end
                                    store.set_callers(n.id, edges)
                                    store.redraw()
                                end)
                            end
                        end)
                    end
                    vim.notify('cartograph: clangd ready — the C/C++ call graph'
                        .. ' resolves as you focus functions', vim.log.levels.INFO)
                elseif serr then
                    vim.notify('cartograph: clangd — ' .. serr, vim.log.levels.WARN)
                end
            else
                -- opening a non-C graph: shut down any lingering clangd session
                require('cartograph.providers.clangd').stop_session()
            end
          end
          -- Chunk the enrichment across event-loop ticks so it never freezes:
          -- the coop.tick() calls inside greenspun.registries / xlang.link
          -- yield when a slice runs long, and coop.run resumes between ticks,
          -- yielding to input. Abort if the graph is swapped out from under us.
          require('cartograph.coop').run(enrich, {
              abort = function () return store.data ~= data end,
          })
        end

        -- incremental open: unchanged files come from the cache, only the
        -- diff re-extracts. A large cached corpus STREAMS (open_async: stub
        -- now, shards decode in the background) so it never blocks; a small
        -- one loads synchronously (no flicker). Subtree slices bypass the
        -- cache entirely (a slice would poison the full-tree entry).
        local data, note, warm_async
        if not (opts and opts.subdirs) then
            local cache = require 'cartograph.cache'
            if cache.warm_streamable(target) then
                -- a large cached corpus streams like the cold path: browser
                -- opens NOW on stubs, shards decode in the background, the
                -- splice brings it up to date, then finish() swaps it in.
                local began = false
                local started, why = cache.open_async(target, {
                    on_stub = function (files) stub_ingest(files) end,
                    -- incremental: fold each decoded shard-chunk's delta into
                    -- the indexes (O(delta)) instead of a full O(graph)
                    -- re-ingest per chunk — the same fix the cold path got
                    on_chunk = function (acc, done, total)
                        if not began then store.begin_stream(acc); began = true end
                        acc.partial = { done = done, total = total }
                        store.ingest_step(acc)
                    end,
                    on_done = function (acc, n)
                        acc.partial = nil -- streaming done; finish() is authoritative
                        if n then vim.notify('cartograph: ' .. n, vim.log.levels.INFO) end
                        preserve(function () finish(acc) end)
                        require('cartograph.toc').attach(store)
                        store.ws_resolve()
                    end,
                })
                warm_async = started
                note = (not started) and why or nil
            else
                data, note = cache.open(target)
            end
            if note then vim.notify('cartograph: ' .. note, vim.log.levels.INFO) end
        end
        if warm_async then
            -- streaming in the background; the layout below opens on the stub
        elseif data then
            finish(data)
        else
            local ts = require 'cartograph.providers.treesitter'
            -- ONE walk, both providers' file sets. Stack languages (forth,
            -- postscript) are a SEPARATE provider, not a merge: `provider` and
            -- `capabilities` are whole-graph claims — the token provider
            -- AGGREGATES word mentions into ref edges and says so
            -- (capabilities.calls='aggregated'), so folding its files into a
            -- tree-sitter graph would smear that claim over files it isn't true
            -- of. One root, one provider identity.
            local tsfiles, _, tokfiles = ts.list_files(target, opts and opts.subdirs)
            if #tokfiles > 0 and #tsfiles == 0 then
                local data2 = require('cartograph.providers.tokens')
                    .extract(target, { files = tokfiles })
                require('cartograph.cache').save_bg(data2)
                finish(data2)
                vim.notify(('cartograph: %d stack-language file(s) via the token'
                    .. ' provider — word mentions are ref EDGES, not call sites'
                    .. ' (capabilities.calls = aggregated), and a save does not'
                    .. ' re-extract'):format(#tokfiles), vim.log.levels.INFO)
            else
            -- a MIXED root opens as tree-sitter; the dialect files stay out
            -- rather than ride in under a claim that doesn't hold for them.
            -- Disclosed, never silent.
            if #tokfiles > 0 then
                vim.notify(('cartograph: %d forth/postscript file(s) are NOT in'
                    .. ' this graph — a mixed root opens through tree-sitter, and'
                    .. ' the two providers make different promises about calls.'
                    .. ' Open that subtree on its own to browse them')
                    :format(#tokfiles), vim.log.levels.WARN)
            end
            local files = not (opts and opts.subdirs) and cfg.parallel ~= false
                and tsfiles or {}
            if #files >= (cfg.parallel_threshold or 300) then
                -- streaming cold open: the browser opens NOW on module
                -- stubs; worker chunks fill the graph in as they land
                stub_ingest(files)
                local par = require 'cartograph.parallel'
                local nw = cfg.workers or par.default_workers()
                vim.notify(('cartograph: extracting %d files with %d workers…')
                    :format(#files, nw), vim.log.levels.INFO)
                par.extract(target, {
                    workers = nw,
                    on_note = function (m)
                        vim.notify('cartograph: ' .. m, vim.log.levels.WARN)
                    end,
                    -- incremental streaming: fold each chunk's delta into the
                    -- indexes (O(delta)) instead of a full re-ingest per chunk
                    on_start = function (acc) store.begin_stream(acc) end,
                    on_chunk = function (k, n, acc)
                        acc.partial = { done = k, total = n }
                        store.ingest_step(acc)
                    end,
                    on_done = function (acc)
                        acc.partial = nil -- extraction complete
                        require('cartograph.cache').save_bg(acc)
                        preserve(function () finish(acc) end)
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
            end -- tree-sitter root (vs the token-provider root above)
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
    -- taking the rest (the browser's descend covers uses/callers), and a
    -- full-width plan bar along the bottom.
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
