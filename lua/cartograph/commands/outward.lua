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


    -- ── HELM: a chart's values and templates (CART-0870, CART-0156) ──
    -- the template lines that read the values key under the cursor: what the user asked for — "quickly navigate into
    -- value use sites, so I can extend the helm chart there or here"
    cmd('CartographHelmUses', function ()
        local HP = require 'cartograph.helmprov'
        local buf = vim.api.nvim_get_current_buf()
        local file = vim.api.nvim_buf_get_name(buf)
        local chart = HP.chart_of(file)
        if not chart then return vim.notify('cartograph: not inside a Helm chart (no Chart.yaml above ' .. file .. ')', vim.log.levels.WARN) end
        local pos = vim.api.nvim_win_get_cursor(0)
        local path = HP.path_at(buf, pos[1] - 1, pos[2])
        if not path then return vim.notify('cartograph: no values key under the cursor', vim.log.levels.WARN) end
        local items, source = HP.use_items(chart, path)
        if #items == 0 then return vim.notify(('cartograph: no template reads .Values.%s (%s) — an orphan value?'):format(path, source), vim.log.levels.INFO) end
        vim.fn.setqflist({}, ' ', { title = ('helm: uses of .Values.%s (%s)'):format(path, source), items = items })
        vim.cmd('copen')
    end, { desc = 'cartograph: every template line reading the Helm values key under the cursor (quickfix)' })
    -- the chart's silent-success findings, each at the template line that produced it when helmprov attributes it
    cmd('CartographHelmLint', function (o)
        local HP = require 'cartograph.helmprov'
        local chart = o.args ~= '' and vim.fn.fnamemodify(o.args, ':p'):gsub('/$', '') or HP.chart_of(vim.api.nvim_buf_get_name(0))
        if not chart then return vim.notify('cartograph: no chart (pass a chart directory, or run inside one)', vim.log.levels.WARN) end
        local L = require 'cartograph.helmlint'
        local r = L.lint(chart)
        local items = {}
        for _, f in ipairs(r.findings) do
            items[#items + 1] = { filename = chart .. '/' .. f.file, lnum = f.line or 1, col = 1, text = f.lint .. ': ' .. f.msg }
        end
        -- the RENDERED findings (dangling references, selectors matching nothing), attributed through the render
        local s = require('cartograph.helm').binary() and require('cartograph.helm').attach(chart) or nil
        local prov = s and HP.render(chart) or nil
        for _, d in ipairs(s and s.soft and s.soft.dangling or {}) do
            local kind, name, target = d:match('^(%S+)/(%S+) .- names %S+/(%S+),')
            local at = prov and kind and HP.locate(prov, kind, name, target) or nil
            items[#items + 1] = { filename = at and (chart .. '/' .. at.file) or (chart .. '/Chart.yaml'), lnum = at and at.line or 1, col = at and at.col + 1 or 1, text = 'dangling-reference: ' .. d }
        end
        for _, d in ipairs(s and s.soft and s.soft.empty or {}) do items[#items + 1] = { filename = chart .. '/Chart.yaml', lnum = 1, col = 1, text = 'selector-matches-nothing: ' .. d } end
        -- the RENDERED objects against the API types' field schema, at the template line that wrote each (CART-1308)
        for _, f in ipairs(prov and require('cartograph.k8sschema').check_render(prov) or {}) do
            items[#items + 1] = { filename = chart .. '/' .. (f.file or 'Chart.yaml'), lnum = f.line or 1, col = 1, text = 'schema-' .. f.problem .. ': ' .. require('cartograph.k8sschema').text(f) }
        end
        if #items == 0 then return vim.notify('cartograph: helm lint — no finding', vim.log.levels.INFO) end
        vim.fn.setqflist({}, ' ', { title = 'helm lint: ' .. chart, items = items })
        vim.cmd('copen')
    end, { nargs = '?', complete = 'dir', desc = 'cartograph: a Helm chart\'s silent-success findings at their template lines (quickfix)' })

    -- WHERE A VALUE CAME FROM (CART-1307): the values key under the cursor (in a values file) or the `.Values.x` under it
    -- (in a template) -> which source won it, at its line, and every source it beat (quickfix, winner first)
    cmd('CartographHelmOrigin', function (o)
        local HP = require 'cartograph.helmprov'
        local file = vim.api.nvim_buf_get_name(0)
        local chart, scope = HP.root_of(file)
        if not chart then return vim.notify('cartograph: not inside a chart', vim.log.levels.WARN) end
        local files, sets, i = {}, {}, 1
        while i <= #o.fargs do
            local a = o.fargs[i]
            if (a == '-f' or a == '--values') and o.fargs[i + 1] then files[#files + 1] = vim.fn.fnamemodify(o.fargs[i + 1], ':p'); i = i + 2
            elseif a == '--set' and o.fargs[i + 1] then sets[#sets + 1] = o.fargs[i + 1]; i = i + 2
            else return vim.notify('cartograph: usage :CartographHelmOrigin [-f values.yaml]... [--set k=v]...', vim.log.levels.WARN) end
        end
        local path
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        local line = vim.api.nvim_get_current_line()
        for s, p, e in line:gmatch('()%.Values%.([%w_%.]+)()') do
            if col + 1 >= s and col + 1 < e then path = p end
        end
        if not path then
            path = HP.path_at(0, row - 1, col)
            if path and scope ~= '' then path = scope .. '.' .. path end
        elseif scope ~= '' then path = scope .. '.' .. path end
        if not path then return vim.notify('cartograph: no values key (or .Values.x) under the cursor', vim.log.levels.WARN) end
        local p, why = HP.render(chart, { origins = true, values = files, set = sets })
        if not p then return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN) end
        local r, rwhy = HP.origin(p, path)
        if not r then return vim.notify('cartograph: ' .. tostring(rwhy), vim.log.levels.WARN) end
        local msg = { r.removed_by and (path .. ' is REMOVED (null) by ' .. HP.site_text(r.removed_by))
            or (path .. ' = ' .. tostring(r.value) .. '   <- ' .. HP.site_text(r.from)) }
        for _, s in ipairs(r.over) do msg[#msg + 1] = '   over ' .. HP.site_text(s) end
        vim.notify(table.concat(msg, '\n'), vim.log.levels.INFO)
        local items = {}
        local function add(s, what)
            if s and s.file then items[#items + 1] = { filename = s.file, lnum = s.line or 1, col = 1, text = what .. ' ' .. path } end
        end
        add(r.from or r.removed_by, r.removed_by and 'removes' or 'sets (wins)')
        for _, s in ipairs(r.over) do add(s, 'sets (overridden)') end
        if #items > 1 then vim.fn.setqflist({}, ' ', { title = 'helm origin: ' .. path, items = items }) end
    end, { nargs = '*', complete = 'file', desc = 'cartograph: which values source won the key under the cursor, and what it overrode' })

    -- WHY DID THIS BLOCK (NOT) RENDER (CART-1309): the if / with / range at the cursor line (or the nearest one above
    -- it): what its condition evaluated to, which arm the values took, and the values source of every key it read
    cmd('CartographHelmBranch', function (o)
        local HP = require 'cartograph.helmprov'
        local file = vim.api.nvim_buf_get_name(0)
        local chart = HP.root_of(file)
        if not chart then return vim.notify('cartograph: not inside a chart', vim.log.levels.WARN) end
        local files, sets, i = {}, {}, 1
        while i <= #o.fargs do
            local a = o.fargs[i]
            if (a == '-f' or a == '--values') and o.fargs[i + 1] then files[#files + 1] = vim.fn.fnamemodify(o.fargs[i + 1], ':p'); i = i + 2
            elseif a == '--set' and o.fargs[i + 1] then sets[#sets + 1] = o.fargs[i + 1]; i = i + 2
            else return vim.notify('cartograph: usage :CartographHelmBranch [-f values.yaml]... [--set k=v]...', vim.log.levels.WARN) end
        end
        local p, why = HP.render(chart, { branches = true, origins = true, values = files, set = sets })
        if not p then return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN) end
        local rel = file:sub(#chart + 2)
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local best
        for _, d in ipairs(HP.branches(p)) do
            if d.file == rel and d.line <= row and (not best or d.line > best.line) then best = d end
        end
        if not best then return vim.notify('cartograph: no if / with / range at or above the cursor in this template', vim.log.levels.INFO) end
        vim.notify(('%s:%d  %s'):format(rel, best.line, HP.branch_text(best)), vim.log.levels.INFO)
        local items = {}
        for _, r in ipairs(best.reads) do
            if r.from and r.from.file then
                items[#items + 1] = { filename = r.from.file, lnum = r.from.line or 1, col = 1, text = (r.removed and 'removes ' or 'sets ') .. r.path .. ' (decides line ' .. best.line .. ')' }
            end
            for _, s in ipairs(r.over or {}) do
                if s.file then items[#items + 1] = { filename = s.file, lnum = s.line or 1, col = 1, text = 'overridden: ' .. r.path } end
            end
        end
        if #items > 0 then vim.fn.setqflist({}, ' ', { title = 'helm branch: ' .. rel .. ':' .. best.line, items = items }) end
    end, { nargs = '*', complete = 'file', desc = 'cartograph: why the if/with/range at the cursor took its arm — the condition\'s value and the source of every key it read' })

    -- WHAT `.` IS HERE (CART-1310): every action on the cursor line, and what `.` was when it ran — the rebinding
    -- `with` and `range` do, per iteration (the first few, and how many)
    cmd('CartographHelmDot', function (o)
        local HP = require 'cartograph.helmprov'
        local file = vim.api.nvim_buf_get_name(0)
        local chart = HP.root_of(file)
        if not chart then return vim.notify('cartograph: not inside a chart', vim.log.levels.WARN) end
        local files = {}
        for i = 1, #o.fargs do if o.fargs[i - 1] == '-f' then files[#files + 1] = vim.fn.fnamemodify(o.fargs[i], ':p') end end
        local p, why = HP.render(chart, { dots = true, values = files })
        if not p then return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN) end
        local rel = file:sub(#chart + 2)
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local ds = HP.dots_at(p, rel, row)
        if #ds == 0 then return vim.notify(('cartograph: no action on line %d ran in this render (an untaken arm, or no action here)'):format(row), vim.log.levels.INFO) end
        local msg = {}
        for _, d in ipairs(ds) do
            msg[#msg + 1] = ('col %d: . = %s%s'):format(d.col + 1, table.concat(d.values, ' | '), d.n > #d.values and ('  (%d executions)'):format(d.n) or '')
        end
        vim.notify(table.concat(msg, '\n'), vim.log.levels.INFO)
    end, { nargs = '*', complete = 'file', desc = 'cartograph: what `.` was at the actions on the cursor line (with / range rebind it)' })

    -- WHAT A VALUES CHANGE DOES (CART-1311): the chart rendered under two values sets, every changed field at the
    -- template line that wrote it and the values source that changed it — the blast radius before deploying.
    -- `[-f a.yaml --set k=v ...] -- [-f b.yaml ...]`; with no `--`, A is the chart's own values and every flag is B's
    cmd('CartographHelmDiff', function (o)
        local HP = require 'cartograph.helmprov'
        local chart = HP.root_of(vim.api.nvim_buf_get_name(0))
        if not chart then return vim.notify('cartograph: not inside a chart', vim.log.levels.WARN) end
        local sides, cur = { { values = {}, set = {} }, { values = {}, set = {} } }, nil
        local args = vim.deepcopy(o.fargs)
        local split = vim.tbl_contains(args, '--')
        cur = split and sides[1] or sides[2]
        local i = 1
        while i <= #args do
            local a = args[i]
            if a == '--' then cur = sides[2]; i = i + 1
            elseif (a == '-f' or a == '--values') and args[i + 1] then table.insert(cur.values, vim.fn.fnamemodify(args[i + 1], ':p')); i = i + 2
            elseif a == '--set' and args[i + 1] then table.insert(cur.set, args[i + 1]); i = i + 2
            else return vim.notify('cartograph: usage :CartographHelmDiff [-f a.yaml --set k=v ...] -- [-f b.yaml ...]', vim.log.levels.WARN) end
        end
        local rows, why = HP.diff(chart, sides[1], sides[2])
        if not rows then return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN) end
        if #rows == 0 then return vim.notify('cartograph: helm diff — the two values sets render identical objects', vim.log.levels.INFO) end
        local items = {}
        for _, r in ipairs(rows) do
            items[#items + 1] = { filename = chart .. '/' .. (r.file or 'Chart.yaml'), lnum = r.line or 1, col = 1, text = HP.diff_text(r) }
        end
        vim.fn.setqflist({}, ' ', { title = ('helm diff: %d change(s)'):format(#rows), items = items })
        vim.cmd('copen')
    end, { nargs = '*', complete = 'file', desc = 'cartograph: the objects two values sets render, field by field, at the template line and the values source of each change' })

    -- a chart's AUTHORED base against the plain manifests it should produce (CART-0873): where they vary and the
    -- chart hardcodes, at each template line
    cmd('CartographHelmBase', function (o)
        local HP = require 'cartograph.helmprov'
        local manifests = vim.fn.fnamemodify(o.fargs[1], ':p'):gsub('/$', '')
        local chart = o.fargs[2] and vim.fn.fnamemodify(o.fargs[2], ':p'):gsub('/$', '') or HP.chart_of(vim.api.nvim_buf_get_name(0))
        if not chart then return vim.notify('cartograph: no chart (pass it after the manifests directory, or run inside one)', vim.log.levels.WARN) end
        local B = require 'cartograph.helmbase'
        local r, why = B.diff(chart, manifests)
        if not r then return vim.notify('cartograph: helm base — ' .. tostring(why), vim.log.levels.WARN) end
        local items = B.items(chart, r)
        vim.notify(B.lines(r)[1], vim.log.levels.INFO)
        if #items == 0 then return end
        vim.fn.setqflist({}, ' ', { title = 'helm base: ' .. chart .. ' vs ' .. manifests, items = items })
        vim.cmd('copen')
    end, { nargs = '+', complete = 'dir', desc = 'cartograph: where the plain manifests vary and the chart hardcodes, at its template lines (quickfix)' })

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
