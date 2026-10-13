-- the RUNTIME ORACLE's recorder (CART-1672): a CALL hook over the whole suite — (call site file:line) -> the callee's
-- file:linedefined, cartograph's own code only — written to $CARTOGRAPH_CALLS_OUT at exit (one `site<TAB>callee` row
-- per distinct pair). Loaded before tests/run.lua by record.sh; the JIT is off (a hook does not see compiled calls).
local out = assert(os.getenv('CARTOGRAPH_CALLS_OUT'), 'CARTOGRAPH_CALLS_OUT names the output file')
local seen = {}
local busy = false
if rawget(_G, 'jit') then jit.off(); jit.flush() end
debug.sethook(function (ev)
    -- (a TAIL CALL replaces its caller's frame: level 3 is then the tail-caller's CALLER, and the callee would be
    -- charged to a site that never called it — `return t.stamp(path)` inside S.stamp landed on S.stamp's caller)
    if busy or ev ~= 'call' then return end
    busy = true
    local ce = debug.getinfo(2, 'S')
    local cr = debug.getinfo(3, 'Sl')
    if ce and cr and cr.currentline and cr.currentline > 0 then
        local s = cr.source:match('lua/cartograph/.+$')
        if s then
            local k = s .. ':' .. cr.currentline
            local t = seen[k]
            if not t then t = {}; seen[k] = t end
            t[(ce.source:match('lua/cartograph/.+$') or ce.source) .. ':' .. tostring(ce.linedefined)] = true
        end
    end
    busy = false
end, 'c')
vim.api.nvim_create_autocmd('VimLeavePre', { callback = function ()
    debug.sethook()
    local fd = assert(io.open(out, 'w'))
    for k, t in pairs(seen) do for ck in pairs(t) do fd:write(k, '\t', ck, '\n') end end
    fd:close()
end })
