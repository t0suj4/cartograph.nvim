-- cartograph.cinterp.adapter — THE ADAPTER TEMPLATE (CART-1256): an interpreter adapter ASSEMBLED from a runtime's facts
-- table (cartograph.cinterp.facts), every variation chosen by a FACT'S KIND, never by a runtime's name:
--   the ELEMENTS a position is read over — from the FRAME kind: a STACK (top / base: tag@count for every count from the
--     position up, ABSENT at every count below it) or an ARGUMENT ARRAY (tag@arity) — over the VALUE representatives:
--     first-class ones (a firstclass fact), not '-' (a typenames fact), a representative's VARIANTS for it (numbers'
--     values), an ON-DEMAND family (reps.ondemand: atoms) only where a comparison on the paths names its word;
--   the ARGUMENTS a function runs on — from the frame kind: the thread; or the array's slot and an object for every
--     other pointer parameter, its status field UNSET;
--   the OUTCOME of a return — from the RESULT kind: a STATUS convention (the field a path wrote decides: an error code
--     rejects, a named code is its own outcome, UNSET accepts; a no-return call is a VM ABORT), else the RAISER
--     convention (a return accepts, a no-return call rejects);
--   the AGGREGATION of an element's outcomes — 'always' / 'never' / 'content' / a named outcome — and the join of a
--     representative's variants back into it (numof).
-- An adapter (luajs.cpath, erlbif) keeps its READING, its registrations' naming, its join and witness.
local ffi = require 'ffi'
local CI = require 'cartograph.cinterp'
local FT = require 'cartograph.cinterp.facts'
local M = {}

local U64 = ffi.typeof('uint64_t')
local function hexword(h)
    h = ('%016s'):format(h):gsub(' ', '0')
    return U64(tonumber(h:sub(1, 8), 16)) * U64(2 ^ 32) + U64(tonumber(h:sub(9), 16))
end
local function same(v, h)
    if not (v and v.k == 'i') or not h then return nil end
    return ffi.cast('uint64_t', v.v) == hexword(h)
end

--- the frame's KIND: 'array' (an argument array), 'stack' (top / base fields), or nil
function M.frame_kind(fr)
    if not fr then return nil end
    if fr.kind then return fr.kind end
    if fr.top and fr.base then return 'stack' end
    return nil
end

--- THE CONTEXT: the facts table over src; every fact in `need` must derive (a gap raises, naming it) -> the
--- interpreter's ctx plus every derived fact the template reads (numbers, firstclass, typenames, result, registrations)
--- and ctx.facts, the whole table
function M.context(src, need, who)
    local T = FT.derive({ src = src })
    local got, miss = T.got, {}
    for _, f in ipairs(need) do
        if got[f] == nil then miss[#miss + 1] = f .. ' (' .. tostring(T.rows[f] and T.rows[f].gap) .. ')' end
    end
    if #miss > 0 then error((who or 'adapter') .. ': facts not derived: ' .. table.concat(miss, '; ')) end
    local ctx = FT.ctx(got)
    if got.numbers then ctx.numtag, ctx.numvars, ctx.numof = got.numbers.numtag, got.numbers.numvars, got.numbers.numof end
    ctx.firstclass, ctx.typenames, ctx.result, ctx.registrations, ctx.facts = got.firstclass, got.typenames, got.result, got.registrations, T
    return ctx
end

--- the VALUE representatives: every rep a value can be (not a firstclass-false one, not a '-' type, not on demand), a
--- rep with VARIANTS (the number tag at several values) as its variants -> { tag … }
function M.values(ctx)
    local R, out = ctx.reps, {}
    local ondemand = R.ondemand or {}
    for _, t in ipairs(R.order) do
        local ok = not ondemand[t]
        if ok and ctx.firstclass and not ctx.firstclass[t] then ok = false end
        if ok and ctx.typenames and ctx.typenames[t] == '-' then ok = false end
        if ok then
            if ctx.numtag and t == ctx.numtag and ctx.numvars then for _, v in ipairs(ctx.numvars) do out[#out + 1] = v end
            else out[#out + 1] = t end
        end
    end
    return out
end

--- the ELEMENTS of one position, from the frame kind: tags at every count / at the arity, and the ABSENT ones
--- -> set, slots (every other argument's slot unknown)
function M.elements(ctx, tags, k, n)
    local set, slots = {}, {}
    if M.frame_kind(ctx.frame) == 'stack' then
        for count = k, n do for _, t in ipairs(tags) do set[t .. '@' .. count] = true end end
        for count = 0, k - 1 do set['ABSENT@' .. count] = true end
    else
        for _, t in ipairs(tags) do set[t .. '@' .. n] = true end
    end
    for i = 1, n do if i ~= k then slots[i] = '?' end end
    return set, slots
end

--- the ARGUMENTS a function runs on, from the frame kind
function M.args(ctx, d)
    if M.frame_kind(ctx.frame) == 'array' then
        local status = ctx.result and ctx.result.kind == 'status' and ctx.result.field
        local args = { n = #d.params }
        for i, p in ipairs(d.params) do
            if p.name == ctx.frame.array then args[i] = { k = 'slot', i = 1 }
            elseif p.type and p.type.k == 'p' then args[i] = CI.object(p.name, status and { [status] = CI.UNSET } or nil) end
        end
        return args
    end
    return { CI.thread(), n = 1 }
end

--- every element's OUTCOMES on a run, from the result kind -> { [element] = { [outcome] = true } }
function M.outcomes(ctx, sum, set)
    local res = ctx.result or {}
    local seen = {}
    for e in pairs(set) do seen[e] = {} end
    if res.kind == 'status' then
        for _, r in ipairs(sum.returns or {}) do
            -- (every object handed in carries the status field: the one a path WROTE decides — all UNSET accepts)
            local skeys = {}
            for key in pairs(r.env or {}) do if key:sub(1, 5) == '\0obj:' and key:sub(-(#res.field + 1)) == '.' .. res.field then skeys[#skeys + 1] = key end end
            for e in pairs(r.fset) do
                local o = #skeys == 0 and 'unknown' or 'accept'
                for _, key in ipairs(skeys) do
                    local s = CI.at(r.env[key], e)
                    if s and s.k == 'unset' then -- (not written on this path)
                    elseif not (s and s.k == 'i') then o = 'unknown'
                    elseif o ~= 'unknown' then
                        o = 'reject'
                        for name, h in pairs(res.codes or {}) do if same(s, h) then o = name:lower() end end
                    end
                end
                if seen[e] then seen[e][o] = true end
            end
        end
        -- (a NO-RETURN call is a VM ABORT under a status convention — not a type error)
        for e in pairs(sum.rej or {}) do if seen[e] then seen[e].abort = true end end
    else
        -- (the RAISER convention: a return accepts, a no-return call — or no return at all — rejects)
        for e in pairs(set) do
            if sum.ret[e] then seen[e].accept = true end
            if sum.rej[e] or not sum.ret[e] then seen[e].reject = true end
        end
    end
    return seen
end

--- an element's outcomes -> its status; an ABORT counts only for an element with no other outcome
local function status(os)
    if os.abort and vim.tbl_count(os) > 1 then os.abort = nil end
    local l = vim.tbl_keys(os)
    if #l == 0 then return 'never' end
    if #l == 1 then return ({ accept = 'always', reject = 'never', unknown = 'content' })[l[1]] or l[1] end
    return 'content'
end

--- one position's ACCEPTANCE: every value representative in ONE run — an on-demand family joining where a comparison
--- names its word, then a second run — -> { [tag] = status } (variants joined back into their rep: numof), over,
--- { rets = every return value seen, found = the on-demand elements that joined }. `args` overrides the frame's own
--- (a checker read with its extra parameters bound: checkopt(L, 1, -1)).
function M.acceptance(A, ctx, d, k, n, args)
    local R = ctx.reps
    local tags = M.values(ctx)
    local function run(tl)
        local set, slots = M.elements(ctx, tl, k, n)
        A.steps = 0 -- (the budget is PER RUN)
        return A.run(d, args or M.args(ctx, d), slots, k, set, false), set
    end
    local sum, set = run(tags)
    local found = {}
    if R.ondemand and next(R.ondemand) then
        local want = {}
        for _, c in pairs(sum.compared or {}) do want[CI.key_of(c)] = true end
        for _, t in ipairs(R.order) do
            if R.ondemand[t] and R.tag[t] and R.tag[t].u64 then
                if want[CI.key_of(CI._int(ffi.cast('int64_t', hexword(R.tag[t].u64)), 64, true))] then found[#found + 1] = t end
            end
        end
        if #found > 0 then sum, set = run(vim.list_extend(vim.list_slice(tags), found)) end
    end
    local seen = M.outcomes(ctx, sum, set)
    -- (per element, then its VARIANTS joined back into the representative: the same status stays, a difference is
    -- content)
    local out = {}
    for e, os in pairs(seen) do
        local t = CI.elem(e)
        local base = (ctx.numof and ctx.numof[t]) or t
        local st = status(os)
        if out[base] == nil then out[base] = st elseif out[base] ~= st then out[base] = 'content' end
    end
    local rets = {}
    for _, r in ipairs(sum.returns or {}) do for e in pairs(r.fset) do rets[#rets + 1] = CI.at(r.v, e) or false end end
    return out, sum.over, { rets = rets, found = found }
end

return M
