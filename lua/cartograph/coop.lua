-- Cooperative chunking: run a long pure computation across event-loop ticks so
-- it never blocks the editor. The work sprinkles M.tick() through its hot loops;
-- when the current slice has run past a small time budget, tick() yields, and
-- the driver resumes the coroutine on the next tick — after yielding to input.
--
-- Outside a coop.run coroutine, tick() is a no-op (coroutine.running() is the
-- main thread), so the SAME code runs synchronously in tests, commands, and any
-- other caller. Only enrichment that opts in (via coop.run) gets chunked.

local M = {}

local BUDGET_MS = 8          -- max uninterrupted work per slice
local QUIET_MS  = 80         -- don't resume within this of a keystroke
local MAX_HOLD  = 1200       -- but never stall a slice longer than this

local slice_start  -- hrtime when the current slice began (nil = not chunking)

--- Called by chunked work in its loops. Yields the coroutine when the current
--- slice has run past the budget; a no-op on the main thread (LuaJIT:
--- coroutine.running() is nil there), so callers outside coop.run are unaffected.
function M.tick()
    if not slice_start or coroutine.running() == nil then return end
    if (vim.uv.hrtime() - slice_start) / 1e6 >= BUDGET_MS then
        coroutine.yield()
    end
end

--- Run fn() chunked across ticks. opts.on_done() fires when it finishes;
--- opts.abort() (checked between slices) stops it early; opts.on_error(err)
--- handles a failure (defaults to notify). Returns immediately.
function M.run(fn, opts)
    opts = opts or {}
    local co = coroutine.create(fn)
    local last_input, held = 0, 0
    local okk, kid = pcall(vim.on_key, function () last_input = vim.uv.hrtime() end)
    local function stop() if okk then pcall(vim.on_key, nil, kid) end end
    local function step()
        if coroutine.status(co) == 'dead' then return end
        if opts.abort and opts.abort() then return stop() end
        -- yield to the user: hold the next slice for a beat after a keystroke,
        -- but never past MAX_HOLD (so a fast typist can't starve the work)
        local since = (vim.uv.hrtime() - last_input) / 1e6
        if since < QUIET_MS and held < MAX_HOLD then
            held = held + QUIET_MS
            return vim.defer_fn(step, QUIET_MS)
        end
        held = 0
        slice_start = vim.uv.hrtime()
        local ok, err = coroutine.resume(co)
        slice_start = nil
        if not ok then
            stop()
            if opts.on_error then opts.on_error(err)
            else vim.notify('cartograph: enrich failed — ' .. tostring(err),
                vim.log.levels.WARN) end
            return
        end
        if coroutine.status(co) == 'dead' then
            stop()
            if opts.on_done then opts.on_done() end
        else
            vim.defer_fn(step, 0) -- next slice on the next tick
        end
    end
    vim.defer_fn(step, 0)
end

return M
