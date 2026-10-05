-- cartograph.workload — what the ONE-RUN discovery tactics share (CART-1444): a WORKLOAD (Lua source returning
-- `function (store)`; a toolbelt `@file` param reads one) and WRAPPING named functions of modules for its run, always
-- restored. memo-advisor, sort-ties, phase-profile, hot-callers and door-trap measure through it.
-- ⚠ A wrapper on a module FIELD sees only the calls made through the field: a caller that bound `local f = M.f` at
-- load is invisible (harness #47) — every tactic reports CALLS so a zero is told from "nothing happened".
local M = {}

--- the workload's function from its source -> fn | nil, why
function M.load(src)
    local chunk, cwhy = load(src or '', 'workload', 't')
    if not chunk then return nil, 'the workload does not load: ' .. tostring(cwhy) end
    local okw, work = pcall(chunk)
    if not okw or type(work) ~= 'function' then return nil, 'the workload must return function (store): ' .. tostring(work) end
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

return M