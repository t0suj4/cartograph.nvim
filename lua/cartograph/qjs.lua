-- cartograph.qjs — ARGUMENT TYPES BY PATH over QuickJS' built-in functions (CART-1258): the QuickJS ADAPTER of
-- cartograph.cinterp, a thin instance of the adapter TEMPLATE. Every fact is the tree's (cartograph.cinterp.facts):
-- the frame an argument array WITH ITS COUNT (the JSCFunction type: `int argc, JSValue *argv`), padded with undefined up
-- to the registered length (the C-call path's own fill loop); the slot the 16-byte JSValue, one representative per
-- JS_TAG_ constant with its payload unknown; the OUTCOME the sentinel JS_Throw returns (JS_EXCEPTION), every thrower's
-- call taken as it; the types the tree's own JS_Is<X> predicates, first-class what typeof answers outside its default.
-- The registrations are the JS_CFUNC_DEF / JS_CFUNC_MAGIC_DEF rows; a shared function is run with its row's MAGIC.
-- ⚠ LIMITS: an object, a string, a symbol is one representative of unknown memory — a check of its class reads as
-- content; an int's / a bool's value is unknown too (the payload union is not in the slot's layout).
local CI = require 'cartograph.cinterp'
local AD = require 'cartograph.cinterp.adapter'
local M = {}

--- THE CONTEXT: the facts table of the tree (a gap raises, naming it) — the TEMPLATE's, over a counted argument array
--- and a sentinel convention
function M.context(src)
    local ctx = AD.context(src, { 'units', 'noret', 'frame', 'layout', 'reps', 'sentinels', 'builtins', 'result', 'registrations', 'typenames', 'firstclass' }, 'qjs')
    if AD.frame_kind(ctx.frame) ~= 'counted' then error('qjs: the frame is not an argument array with its count') end
    if ctx.result.kind ~= 'sentinel' then error('qjs: the result is not a sentinel convention') end
    if not ctx.sentinel then error('qjs: the sentinel ' .. tostring(ctx.result.text) .. ' did not evaluate') end
    return ctx
end

--- the arguments one registration runs with: the template's, its MAGIC handed at the integer parameter after the array
function M.args(ctx, d, e)
    local args = AD.args(ctx, d)
    if e.magic ~= nil then
        for i = (ctx.frame.arrayat or 0) + 1, #d.params do
            local p = d.params[i]
            if p.type and p.type.k == 'i' then args[i] = e.magic and CI._int(e.magic) or nil; break end
        end
    end
    return args
end

--- READINGS for registrations: opts = { src, keys = { '<table>:<name>', … } } -> { [key] = { cfn, length, magic, pos =
--- { [k] = { by, accepted, always, other, untyped, absent, over } } } }, ctx. Positions 1 .. the registered length (at
--- least 1), every count up to one past it.
function M.measure(opts)
    local ctx = opts.ctx or M.context(opts.src)
    local A = CI.analyzer(ctx)
    local want = {}
    for _, k in ipairs(opts.keys) do want[k] = true end
    local rows = {}
    for _, e in ipairs(ctx.registrations.funcs) do
        local key = e.table .. ':' .. e.name
        if want[key] and not rows[key] then
            local d = ctx.defs[e.cfn]
            local row = { cfn = e.cfn, length = e.length, magic = e.magic, pos = {} }
            if not d then row.missing = 'no definition of ' .. e.cfn
            else
                local npos = math.max(e.length, 1)
                for k = 1, npos do
                    local acc, over = AD.acceptance(A, ctx, d, k, npos + 1, M.args(ctx, d, e), e.length)
                    local r = AD.reading(acc, ctx.typenames)
                    r.over = over
                    row.pos[k] = r
                end
            end
            rows[key] = row
        end
    end
    return rows, ctx
end

return M
