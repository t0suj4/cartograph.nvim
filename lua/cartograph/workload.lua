-- cartograph.workload — what the ONE-RUN discovery tactics share (CART-1444): a WORKLOAD (Lua source returning
-- `function (store)`; a toolbelt `@file` param reads one) and WRAPPING named functions of modules for its run, always
-- restored. memo-advisor, sort-ties, phase-profile, hot-callers and door-trap measure through it.
-- ⚠ A wrapper on a module FIELD sees only the calls made through the field: a caller that bound `local f = M.f` at
-- load is invisible (harness #47) — every tactic reports CALLS so a zero is told from "nothing happened".
local M = {}

--- the workload's function from its source -> fn | nil, why. The source returns `function (store)`, or
--- `{ setup = function () -> ctx, run = function (store, ctx) }`: SETUP RUNS HERE, before anything is wrapped or
--- profiled — what a measurement must not count (extracting and loading the graph a relink then runs on)
function M.load(src)
    local chunk, cwhy = load(src or '', 'workload', 't')
    if not chunk then return nil, 'the workload does not load: ' .. tostring(cwhy) end
    local okw, work = pcall(chunk)
    if okw and type(work) == 'table' and type(work.run) == 'function' then
        local ctx
        if work.setup then
            local oks, c = pcall(work.setup)
            if not oks then return nil, 'the workload setup raised: ' .. tostring(c) end
            ctx = c
        end
        local run = work.run
        return function (store) return run(store, ctx) end
    end
    if not okw or type(work) ~= 'function' then return nil, 'the workload must return function (store) or { setup, run }: ' .. tostring(work) end
    return work
end

--- the module function a target names ('module.fn'), the store's root on package.path first (a target may be a module
--- of the measured tree) -> M, fn name | nil, why
function M.resolve(target, store)
    local root = store and store.data and store.data.root
    if root and not package.path:find(root .. '/?.lua', 1, true) then package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path end
    local mod, fn = tostring(target):match('^(.*)%.([%w_]+)$')
    local okm, T = pcall(require, mod or '')
    if not (okm and type(T) == 'table' and type(T[fn]) == 'function') then return nil, 'no function ' .. tostring(target) end
    return T, fn
end

--- run `work(store)` with each target wrapped by `wrap(real, target) -> replacement`; every wrap undone after, whatever
--- the run did -> ok, err | nil, why (a target that does not resolve)
function M.run_wrapped(store, work, targets, wrap)
    local undo = {}
    for _, t in ipairs(targets) do
        local T, fn = M.resolve(t, store)
        if not T then for i = #undo, 1, -1 do undo[i]() end; return nil, fn end
        local real = T[fn]
        T[fn] = wrap(real, t)
        undo[#undo + 1] = function () T[fn] = real end
    end
    local okr, rerr = pcall(work, store)
    for i = #undo, 1, -1 do undo[i]() end
    return true, okr, rerr
end

--- a comma list -> its names
function M.list(s)
    local out = {}
    for t in tostring(s or ''):gmatch('[^,%s]+') do out[#out + 1] = t end
    return out
end

--- a call site as `file:line`, the file relative to `root` when inside it. ★ NOT short_src: that one TRUNCATES a long
--- path to `...tail` (LUA_IDSIZE), and a site a write tactic consumes must name its file exactly
function M.site(info, root)
    local src = info and info.source or '?'
    src = src:sub(1, 1) == '@' and vim.fn.fnamemodify(src:sub(2), ':p') or (info and info.short_src or '?')
    if root then
        local r = vim.fn.fnamemodify(root, ':p'):gsub('/+$', '') .. '/'
        if src:sub(1, #r) == r then src = src:sub(#r + 1) end
    end
    return src .. ':' .. tostring(info and info.currentline or '?')
end

-- ★ THE CODE BEING MEASURED IS NOT THE CODE MEASURING (CART-1444's acceptance): a workload `require`s modules, and in
-- the process running the toolbelt every `cartograph.*` module is ALREADY LOADED — prepending another checkout to
-- package.path changes nothing, so a pre-fix checkout's workload would time TODAY's code and report "no repetition"
-- (an accessor artefact). `code = <dir>` runs the measurement in its OWN headless process whose package.path puts
-- `<dir>/lua` FIRST and this toolbelt's `lua/` after it: the workload loads that tree's modules, the measuring tactic
-- (absent there) loads ours. ⚠ a module both trees have loads from `<dir>` for the tactic too. The value comes back
-- as JSON, so it must be plain data.
local OURS = (vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p'):gsub('/lua/cartograph/workload%.lua$', ''))
M.OURS = OURS

local RUNNER = [[
local code, ours, name, pfile, out = _G.arg[1], _G.arg[2], _G.arg[3], _G.arg[4], _G.arg[5]
package.path = code .. '/lua/?.lua;' .. code .. '/lua/?/init.lua;' .. ours .. '/lua/?.lua;' .. ours .. '/lua/?/init.lua;' .. package.path
local fd = assert(io.open(pfile)); local p = vim.json.decode(fd:read('a')); fd:close()
local e = require('cartograph.tactics.' .. name)
local ok, v = pcall(e.measure, { data = { root = code } }, p)
if not ok then v = { error = 'the measurement raised in ' .. code .. ': ' .. tostring(v) } end
fd = assert(io.open(out, 'w')); fd:write(vim.json.encode(v)); fd:close()
]]

--- run tactic `name`'s measure on `p` in a process whose modules come from `code` first -> value (an { error } on failure)
function M.elsewhere(code, name, p)
    code = vim.fn.fnamemodify(code, ':p'):gsub('/+$', '')
    if vim.fn.isdirectory(code .. '/lua') == 0 then return { error = ('code = %s has no lua/ directory to load modules from'):format(code) } end
    local dir = vim.fn.tempname() .. '-elsewhere'
    vim.fn.mkdir(dir, 'p')
    local q = {}
    for k, v in pairs(p) do if k ~= 'code' then q[k] = v end end
    local function put(f, s) local fd = assert(io.open(dir .. '/' .. f, 'w')); fd:write(s); fd:close() end
    put('runner.lua', RUNNER)
    put('params.json', vim.json.encode(q))
    local obj, err = require('cartograph.tactics.spec-fails').exec({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', dir .. '/runner.lua',
        code, OURS, name, dir .. '/params.json', dir .. '/out.json' }, { cwd = code, timeout = p.timeout and tonumber(p.timeout) * 1000 or 900000 })
    local fd = io.open(dir .. '/out.json')
    local text = fd and fd:read('a'); if fd then fd:close() end
    vim.fn.delete(dir, 'rf')
    if not obj then return { error = 'the measuring process did not start: ' .. tostring(err) } end
    if obj.timed_out then return { error = 'the measuring process timed out (its process group killed)' } end
    if not text then return { error = ('no value from the measuring process in %s: %s'):format(code, ((obj.stderr or '') .. (obj.stdout or '')):sub(-400)) } end
    local okj, v = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    return okj and v or { error = 'the measuring process wrote no JSON: ' .. text:sub(1, 200) }
end

--- a tactic's measure that honours `code = <dir>` (see M.elsewhere)
function M.code_aware(name, measure)
    return function (store, p)
        if p and p.code then return M.elsewhere(p.code, name, p) end
        return measure(store, p or {})
    end
end

return M