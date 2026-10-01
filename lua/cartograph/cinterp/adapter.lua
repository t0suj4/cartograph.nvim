-- cartograph.cinterp.adapter — THE ADAPTER TEMPLATE (CART-1256): an interpreter adapter ASSEMBLED from a runtime's facts
-- table (cartograph.cinterp.facts), every variation chosen by a FACT'S KIND, never by a runtime's name:
--   the ELEMENTS a position is read over — from the FRAME kind: a STACK (top / base: tag@count for every count from the
--     position up, ABSENT at every count below it), an ARGUMENT ARRAY (tag@arity), or an argument array WITH ITS COUNT
--     (tag@count from the position up; below it the PAD — the value the call path fills the array with up to the
--     registered length — or ABSENT past that length) — over the VALUE representatives:
--     first-class ones (a firstclass fact), not '-' (a typenames fact), a representative's VARIANTS for it (numbers'
--     values), an ON-DEMAND family (reps.ondemand: atoms) only where a comparison on the paths names its word;
--   the ARGUMENTS a function runs on — from the frame kind: the thread; or the array's slot (its count the element's
--     own) and an object for every other pointer parameter, its status field UNSET;
--   the OUTCOME of a return — from the RESULT kind: a STATUS convention (the field a path wrote decides: an error code
--     rejects, a named code is its own outcome, UNSET accepts; a no-return call is a VM ABORT), a SENTINEL value (a
--     return whose classifying fields all equal the sentinel's rejects, one differing accepts, else content; a
--     THROWER's call is the sentinel), else the RAISER convention (a return accepts, a no-return call rejects);
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
    if fr.kind == 'array' and (fr.count or fr.countat) then return 'counted' end
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
    -- (the constants a SENTINEL convention and a PADDED frame name, evaluated in the tree's own types: the sentinel's
    -- value — every thrower's call IS it — and the representative the pad value is)
    if (got.result and got.result.kind == 'sentinel') or (got.frame and got.frame.pad) then
        local A0 = CI.analyzer(ctx)
        if got.result and got.result.kind == 'sentinel' then
            ctx.sentinel = A0.expr(got.result.text)
            ctx.throwers = {}
            for name in pairs(got.result.throwers or {}) do ctx.throwers[name] = ctx.sentinel or false end
        end
        if got.frame and got.frame.pad then ctx.padrep = M.rep_of(ctx, A0.expr(got.frame.pad.text)) end
    end
    return ctx
end

--- a representative's FIELD (a layout path), read from its words -> int value | nil
function M.repfield(ctx, t, path)
    local f, rep = ctx.layout.fields[path], ctx.reps.tag[t]
    if not (f and rep) then return nil end
    local word, off = nil, f.off
    if rep.words then word = rep.words[math.floor(off / 8) + 1]; off = off % 8 elseif off < 8 then word = rep.u64 end
    if not word or not f.cls:match('^[iu]%d') then return nil end
    local u = hexword(word)
    if off > 0 then u = bit.rshift(u, off * 8) end
    return CI._int(ffi.cast('int64_t', u), tonumber(f.cls:match('%d+')), f.cls:sub(1, 1) == 'u')
end

--- the fields a value of the slot type is CLASSIFIED by: the layout's (what representatives differ in) -> { path … }
local function classifying(ctx)
    local l = {}
    for path in pairs(ctx.layout.fields or {}) do l[#l + 1] = path end
    table.sort(l)
    return l
end

--- a value's field at one element: an aggregate's member, the focus slot's representative -> value | nil
local function field_at(ctx, v, e, path, fi)
    if not v then return nil end
    if v.k == 'agg' then return v.f[path] end
    if v.k == 'slotv' and v.i == fi then return M.repfield(ctx, CI.elem(e), path) end
    return nil
end

--- the REPRESENTATIVE a value of the slot type is: the one whose every classifying field the value equals -> tag | nil
function M.rep_of(ctx, v)
    if not (v and v.k == 'agg') then return nil end
    local fs = classifying(ctx)
    for _, t in ipairs(ctx.reps.order) do
        local all = #fs > 0
        for _, path in ipairs(fs) do
            local a, b = v.f[path], M.repfield(ctx, t, path)
            if not (a and b and a.k == 'i' and b.k == 'i' and a.v == b.v) then all = false; break end
        end
        if all then return t end
    end
    return nil
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
function M.elements(ctx, tags, k, n, length)
    local set, slots = {}, {}
    local kind = M.frame_kind(ctx.frame)
    if kind == 'counted' then
        -- (n: the largest count read; below the position the PAD up to the registered length, else ABSENT)
        for count = k, n do for _, t in ipairs(tags) do set[t .. '@' .. count] = true end end
        for count = 0, k - 1 do
            if ctx.padrep and length and k <= length then set[ctx.padrep .. '@' .. count] = true else set['ABSENT@' .. count] = true end
        end
    elseif kind == 'stack' then
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
    local kind = M.frame_kind(ctx.frame)
    if kind == 'counted' then
        local fr = ctx.frame
        local args = { n = #d.params }
        for i, p in ipairs(d.params) do
            if i == fr.arrayat then args[i] = { k = 'slot', i = 1 }
            elseif i == fr.countat then args[i] = CI.count()
            elseif p.type and p.type.k == 'p' then args[i] = CI.object(p.name) end
        end
        return args
    end
    if kind == 'array' then
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
    elseif res.kind == 'sentinel' then
        -- (a return is classified by the fields representatives differ in: all equal to the sentinel's REJECTS, one
        -- differing ACCEPTS, an unknown one is content; a no-return call is an abort, as under a status)
        local fs, sv = classifying(ctx), ctx.sentinel
        for _, r in ipairs(sum.returns or {}) do
            for e in pairs(r.fset) do
                local v = CI.at(r.v, e)
                local o = sv and 'reject' or 'unknown'
                for _, path in ipairs(fs) do
                    local a, s = field_at(ctx, v, e, path, 1), sv and sv.f and sv.f[path]
                    if not (a and a.k == 'i' and s and s.k == 'i') then if o == 'reject' then o = 'unknown' end
                    elseif a.v ~= s.v then o = 'accept' end
                end
                if seen[e] then seen[e][o] = true end
            end
        end
        -- (a run still OVER its budget leaves every element unknown, never an abort)
        for e in pairs(sum.rej or {}) do if seen[e] then seen[e][sum.over and 'unknown' or 'abort'] = true end end
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
function M.acceptance(A, ctx, d, k, n, args, length)
    local R = ctx.reps
    local tags = M.values(ctx)
    local counted = M.frame_kind(ctx.frame) == 'counted'
    local function run(tl)
        local set, slots = M.elements(ctx, tl, k, n, length)
        -- (the budget is PER RUN; a run OVER it makes the callee that spent the most of its own steps an UNKNOWN call —
        -- QuickJS' bytecode interpreter, reached through a proxy's trap — and runs again: a run within the budget is
        -- never changed)
        local sum
        for _ = 1, 4 do
            A.steps, A.self, A.cstack = 0, {}, {}
            sum = A.run(d, args or M.args(ctx, d), slots, k, set, false)
            if not sum.over then break end
            local worst, most = nil, 0
            for id, s in pairs(A.self) do if s > most and not A.toobig[id] then worst, most = id, s end end
            if not worst then break end
            A.toobig[worst] = true
        end
        return sum, set
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
        local t, c = CI.elem(e)
        local base = (ctx.numof and ctx.numof[t]) or t
        if counted and c < k then base = 'ABSENT' end
        local st = status(os)
        if out[base] == nil then out[base] = st elseif out[base] ~= st then out[base] = 'content' end
    end
    local rets = {}
    for _, r in ipairs(sum.returns or {}) do for e in pairs(r.fset) do rets[#rets + 1] = CI.at(r.v, e) or false end end
    return out, sum.over, { rets = rets, found = found }
end

--- a position's READING by TYPE (typenames: each representative's type — a variant's joined back already): a type is
--- 'always' / 'never' / an outcome when EVERY representative of it agrees, else 'content'; ABSENT is the position's
--- absence, not a type (CART-1257: the reading is the template's, not an adapter's) -> { by = { [type] = status },
--- accepted (always or content), always, other ('type=outcome'), untyped (every type the same status), absent }
function M.reading(acc, tn)
    local by = {}
    for e, st in pairs(acc) do
        if e ~= 'ABSENT' then
            local t = (tn and tn[e]) or e
            if by[t] == nil then by[t] = st elseif by[t] ~= st then by[t] = 'content' end
        end
    end
    local accepted, always, other, statuses = {}, {}, {}, {}
    for t, st in pairs(by) do
        statuses[st] = true
        if st == 'always' or st == 'content' then accepted[#accepted + 1] = t end
        if st == 'always' then always[#always + 1] = t end
        if st ~= 'always' and st ~= 'content' and st ~= 'never' then other[#other + 1] = t .. '=' .. st end
    end
    table.sort(accepted); table.sort(always); table.sort(other)
    return { by = by, accepted = accepted, always = always, other = other, untyped = vim.tbl_count(statuses) == 1, absent = acc.ABSENT }
end

return M
