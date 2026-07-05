-- Shared async LSP-oracle substrate. clangd and lua-ls both do the same
-- dance: start a headless server, open the files, wait for it to be ready,
-- fire a bounded-concurrency pool of resolution requests, then rebuild edges
-- from the answers. The dance is here; each oracle supplies only what differs
-- — the command, the files, the work items, the per-item request(s), and the
-- finalize that turns answers into edge upgrades.
--
-- Nothing blocks: init/readiness are non-blocking timers, requests are async
-- callbacks, and an overall deadline force-finishes (with partial answers) so
-- a hung server never dangles. on_done(stats|nil, why?) fires on the main loop.

local M = {}

--- spec = {
---   name, cmd = {bin,...}, root, settings?,      -- the server
---   files = { rel, ... }, lang_id = fn(rel)->id, -- what to didOpen
---   items = { ... }, concurrency? = 32,          -- the work
---   index_token?  = 'backgroundIndex',           -- set session.index_done
---   settle? = fn(session, proceed),              -- wait for readiness, then proceed()
---   query  = fn(session, item, step),            -- fire request(s); step() when the item is done
---   finalize = fn(session) -> stats,             -- mutate the graph; return stats
---   init_timeout? = 8000, deadline? = 90000,
--- }
--- session = { client, texts = {rel->content}, root, indexing, index_done }
function M.run(spec, on_done)
    local function done(stats, why)
        if on_done then vim.schedule(function () on_done(stats, why) end) end
    end
    if not (spec.cmd and spec.cmd[1]) then return done(nil, 'no server binary') end
    local root = spec.root
    local session = { texts = {}, root = root, indexing = false, index_done = false }
    local stopped, initialized = false, false

    local function stop()
        if session.client then pcall(function () session.client:stop() end) end
    end
    local function finish()
        if stopped then return end
        stopped = true
        local ok, stats = pcall(spec.finalize, session)
        stop()
        if ok then done(stats) else done(nil, 'finalize error: ' .. tostring(stats)) end
    end

    -- the bounded request pool: keep `concurrency` items in flight, refill as
    -- each completes, finish when the last one returns
    local function run_pool()
        if stopped then return end
        local items = spec.items
        if #items == 0 then return finish() end
        local i, inflight = 0, 0
        local MAX = spec.concurrency or 32
        local function pump()
            while inflight < MAX and i < #items do
                i = i + 1
                inflight = inflight + 1
                local it = items[i]
                local stepped = false
                local function step()
                    if stepped then return end -- a query must step exactly once
                    stepped = true
                    inflight = inflight - 1
                    if i >= #items and inflight == 0 then finish() else pump() end
                end
                local ok = pcall(spec.query, session, it, step)
                if not ok then step() end -- a throwing query drops its item
            end
        end
        pump()
    end

    local function after_open()
        if stopped then return end
        if spec.settle then spec.settle(session, run_pool) else run_pool() end
    end

    local handlers = {}
    if spec.index_token then
        handlers['$/progress'] = function (_, p)
            if tostring(p.token or ''):find(spec.index_token) then
                session.indexing = true
                if p.value and p.value.kind == 'end' then session.index_done = true end
            end
        end
    end

    local client_id = vim.lsp.start({
        name = spec.name,
        cmd = spec.cmd,
        root_dir = root,
        settings = spec.settings,
        handlers = handlers,
        on_init = function (c)
            initialized = true
            session.client = c
            for _, rel in ipairs(spec.files) do
                local fd = io.open(root .. '/' .. rel, 'r')
                if fd then
                    session.texts[rel] = fd:read('a'); fd:close()
                    c:notify('textDocument/didOpen', { textDocument = {
                        uri = vim.uri_from_fname(root .. '/' .. rel),
                        languageId = spec.lang_id(rel), version = 0,
                        text = session.texts[rel] } })
                end
            end
            after_open()
        end,
    }, { attach = false })
    if not client_id then return done(nil, (spec.name or 'lsp') .. ' failed to start') end
    session.client = session.client or vim.lsp.get_client_by_id(client_id)

    -- fail fast if the server never initializes
    vim.defer_fn(function ()
        if not stopped and not initialized then
            stopped = true; stop()
            done(nil, (spec.name or 'lsp') .. ' init timeout')
        end
    end, spec.init_timeout or 8000)
    -- overall deadline: never leave the job dangling on a hung/slow server —
    -- force-finish with whatever the pool has collected so far
    vim.defer_fn(function ()
        if not stopped then finish() end
    end, spec.deadline or 90000)
end

return M
