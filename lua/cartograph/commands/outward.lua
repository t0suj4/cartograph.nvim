-- :Cartograph command group — running systems and other toolchains (|cartograph-cmd-outward|)
--
-- Registered by cartograph.commands, which owns the shared helpers and passes
-- them in: this module rebinds them as locals under the SAME names, so every
-- callback body reads exactly as it did when they all lived in one function.

local M = {}

function M.register(H)
    local cmd, live, whole_graph, mat_df, scratch, txn_module, reveal_at =
        H.cmd, H.live, H.whole_graph, H.mat_df, H.scratch, H.txn_module,
        H.reveal_at
    -- not every group uses every helper; keep the binding uniform
    local _ = cmd and live and whole_graph and mat_df and scratch

    -- the running dead-biter web canvas (server + live MCP client), if any
    local canvas = nil


    -- ── the running system vs the static model ──────────────────────
    cmd('CartographLive', function ()
        local store = live() if not store then return end
        local lines, why = require('cartograph.live').check(store)
        if not lines then
            return vim.notify('cartograph: live check failed — ' .. tostring(why),
                vim.log.levels.WARN)
        end
        require('cartograph.panes.symbols').render() -- states view gains ◉
        scratch(lines)
    end, { desc = 'cartograph: check the RUNNING system against the static model (MCP oracle)' })

    -- ── generate compile_commands.json for clangd ──────────────────
    cmd('CartographCompileCommands', function (o)
        local clangd = require 'cartograph.providers.clangd'
        local store = require 'cartograph.store'
        local root = (store.data and store.data.root) or vim.fn.getcwd()
        local plan = clangd.compile_plan(root, o.args ~= '' and o.args or nil)
        if not plan then
            return vim.notify('cartograph: no recognized build system at ' .. root
                .. ' — need CMakeLists.txt or meson.build (plain make: run `bear -- make` yourself)',
                vim.log.levels.WARN)
        end
        if vim.fn.executable(plan.need) ~= 1 then
            return vim.notify(('cartograph: %s not found — install it (e.g. pkgit -if %s), then retry')
                :format(plan.need, plan.need), vim.log.levels.WARN)
        end
        local shown = plan.cmdline or table.concat(plan.argv, ' ')
        if plan.builds and not o.bang then
            return vim.notify(('cartograph: this runs a FULL build via `%s` (slow, writes objects). '
                .. 'Re-run as :CartographCompileCommands! to proceed.'):format(shown),
                vim.log.levels.WARN)
        end
        vim.notify('cartograph: generating compile_commands.json — ' .. shown .. ' …',
            vim.log.levels.INFO)
        clangd.run_compile_plan(root, plan, function (okr, output)
            if not okr then
                scratch(vim.split('cartograph: compile_commands generation FAILED\n\n' .. output,
                    '\n', { plain = true }))
                return
            end
            vim.notify('cartograph: compile_commands.json ready at ' .. output
                .. '/ — clangd now has cross-file eyes', vim.log.levels.INFO)
            -- restart the demand session so the open C/C++ graph resolves against
            -- the new db, and re-resolve whatever is focused right now
            if store.data then
                local has_c = false
                for _, n in ipairs(store.data.nodes) do
                    if n.kind == 'module' and n.file:match('%.[ch]p?p?$') then has_c = true break end
                end
                if has_c then
                    clangd.start_session(store.data)
                    local n = store.focused and store.node(store.focused)
                    if n and (n.kind == 'function' or n.kind == 'method') and not n.decl then
                        local gen = store.generation -- see the on_focus hook: stale answers drop
                        clangd.resolve_focused(n, function (edges)
                            if store.generation ~= gen then return end
                            store.set_callers(n.id, edges) store.redraw()
                        end)
                    end
                    vim.notify('cartograph: clangd session restarted — focus a function to resolve it',
                        vim.log.levels.INFO)
                end
            end
        end)
    end, { nargs = '?', bang = true, complete = 'dir',
        desc = 'cartograph: generate compile_commands.json (cmake/meson configure; ! allows a full bear build)' })

    -- ── browse the state machine ────────────────────────────────────
    cmd('CartographStates', function ()
        local store = live() if not store then return end
        local symbols = require 'cartograph.panes.symbols'
        -- pivot to the spec var first: <C-o> returns here, and the
        -- source pane anchors on the spec while browsing states
        local v = symbols.fsm_anchor()
        if v then store.pivot(v.id) end
        symbols.show('states')
    end, { desc = 'cartograph: browse the state machine (states -> entry points -> code)' })

    -- ── project the browser view into a Factorio world ──────────────
    cmd('CartographProject', function (o)
        local store = live() if not store then return end
        local tp = require 'cartograph.textplates'
        if o.bang then -- live: reproject on every navigation until stopped
            local L, why = tp.attach()
            if not L then
                return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN)
            end
            return vim.notify('cartograph: live projection ON — the world tracks the view.'
                .. ' :CartographProjectStop to detach', vim.log.levels.INFO)
        end
        local client, io = tp.connect()
        if not client then
            return vim.notify('cartograph: ' .. tostring(io), vim.log.levels.WARN)
        end
        local cfg = require('cartograph.config').factorio or {}
        local view = require('cartograph.panes.symbols').projection(cfg.max_rows)
        local opts = vim.tbl_extend('force', cfg, { selected = view.selected })
        local ok, delta = pcall(tp.project, io, view.labels, opts)
        pcall(function () client:close() end)
        if not ok then
            return vim.notify('cartograph: projection failed — ' .. tostring(delta), vim.log.levels.WARN)
        end
        local msg = ('cartograph: projected %d row(s) — %d built, %d re-lettered, %d removed')
            :format(#view.labels, #delta.create, #delta.revary, #delta.destroy)
        local level = vim.log.levels.INFO
        if delta.verified == false then -- read-back caught writes that didn't land
            msg = msg .. (' — ⚠ %d cell(s) did not land'):format(tp.delta_count(delta.drift))
            level = vim.log.levels.WARN
        end
        vim.notify(msg, level)
    end, { bang = true,
        desc = 'cartograph: project the current view into Factorio (! = live, reproject on navigation)' })

    cmd('CartographProjectStop', function ()
        require('cartograph.textplates').detach()
        vim.notify('cartograph: live projection detached', vim.log.levels.INFO)
    end, { desc = 'cartograph: stop the live Factorio projection' })

    cmd('CartographProjectStatus', function ()
        local s = require('cartograph.textplates').status()
        if not s.live then
            return vim.notify('cartograph: no live projection (:CartographProject! starts one)',
                vim.log.levels.INFO)
        end
        local when = s.last_sync and os.date('%H:%M:%S', s.last_sync) or 'never'
        if not s.connected then
            return vim.notify('cartograph: projection STALE — wire lost; world frozen as of '
                .. when, vim.log.levels.WARN)
        end
        vim.notify(('cartograph: projection live — last synced %s%s'):format(when,
            (s.drift or 0) > 0 and (', ⚠ %d cell(s) adrift'):format(s.drift) or ', in sync'),
            (s.drift or 0) > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
    end, { desc = 'cartograph: the live Factorio projection\'s honesty state (synced / stale / drift)' })

    -- ── the dead-biter brush: paint a raster into Factorio as corpses ───
    cmd('CartographBrush', function (o)
        local tp = require 'cartograph.textplates'
        local brush = require 'cartograph.brush'
        local client, io = tp.connect() -- reuse the factorio MCP transport
        if not client then
            return vim.notify('cartograph: ' .. tostring(io), vim.log.levels.WARN)
        end
        -- input: a file argument, else the current buffer's lines (draw in nvim)
        local lines
        if o.args ~= '' then
            local okr, r = pcall(vim.fn.readfile, vim.fn.expand(o.args))
            if not okr then
                pcall(function () client:close() end)
                return vim.notify('cartograph: cannot read ' .. o.args, vim.log.levels.WARN)
            end
            lines = r
        else
            lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        end
        local cfg = require('cartograph.config').factorio or {}
        local opts = vim.tbl_extend('force', { surface = cfg.surface, anchor = cfg.anchor },
            cfg.brush or {})
        local ok, delta = pcall(brush.project, io, lines, opts)
        pcall(function () client:close() end)
        if not ok then
            return vim.notify('cartograph: brush failed — ' .. tostring(delta), vim.log.levels.WARN)
        end
        local msg = ('cartograph: brushed — %d corpse(s) placed, %d cleared')
            :format(#delta.create, #delta.destroy)
        local level = vim.log.levels.INFO
        if delta.verified == false then
            msg = msg .. (' — ⚠ %d cell(s) did not land'):format(brush.delta_count(delta.drift))
            level = vim.log.levels.WARN
        end
        vim.notify(msg .. ' (corpses decay — re-run to refresh)', level)
    end, { nargs = '?', complete = 'file',
        desc = 'cartograph: paint the current buffer (or a file) into Factorio as biter corpses' })

    -- ── the LIVE web canvas: draw in a browser, project as corpses ──────
    cmd('CartographCanvas', function ()
        if canvas then
            return vim.notify('cartograph: canvas already running at http://' .. canvas.url
                .. ' (:CartographCanvasStop to end)', vim.log.levels.INFO)
        end
        local tp = require 'cartograph.textplates'
        local brush = require 'cartograph.brush'
        local web = require 'cartograph.webserver'
        local client, io = tp.connect() -- one live MCP connection for the session
        if not client then
            return vim.notify('cartograph: ' .. tostring(io), vim.log.levels.WARN)
        end
        local cfg = require('cartograph.config').factorio or {}
        local bopts = vim.tbl_extend('force', { surface = cfg.surface, anchor = cfg.anchor },
            cfg.brush or {})
        -- debounce: a drag POSTs a burst; project only the latest grid
        local st = { grid = nil, gen = 0 }
        local function schedule()
            st.gen = st.gen + 1
            local mine = st.gen
            vim.defer_fn(function ()
                if not canvas or mine ~= st.gen or not client.alive or not st.grid then return end
                pcall(brush.project, io, st.grid, bopts)
            end, cfg.debounce or 200)
        end
        local srv, err = web.serve({ port = cfg.port or 8778, handler = function (req)
            if req.method == 'GET' and req.path == '/' then
                return 200, 'text/html', web.canvas_html()
            elseif req.method == 'POST' and req.path == '/paint' then
                st.grid = req.body; schedule()
                return 200, 'text/plain', 'ok'
            end
            return 404, 'text/plain', 'not found'
        end })
        if not srv then
            pcall(function () client:close() end)
            return vim.notify('cartograph: ' .. tostring(err), vim.log.levels.WARN)
        end
        canvas = { srv = srv, client = client, url = srv.host .. ':' .. srv.port }
        vim.notify('cartograph: dead-biter canvas live → open http://' .. canvas.url
            .. ' and draw. :CartographCanvasStop to end', vim.log.levels.INFO)
    end, { desc = 'cartograph: serve a browser canvas that paints into Factorio as biter corpses' })

    cmd('CartographCanvasStop', function ()
        if not canvas then
            return vim.notify('cartograph: no canvas running', vim.log.levels.INFO)
        end
        pcall(canvas.srv.close)
        pcall(function () canvas.client:close() end)
        canvas = nil
        vim.notify('cartograph: canvas stopped (the corpses stay — they decay on their own)',
            vim.log.levels.INFO)
    end, { desc = 'cartograph: stop the live web canvas' })
end

return M
