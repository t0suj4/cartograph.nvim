-- cartograph.erlbif — ARGUMENT TYPES BY PATH over erts' BIFs (CART-1248): the Erlang ADAPTER of cartograph.cinterp.
-- Every fact is the tree's (cartograph.cinterp.facts, each by its own evidence): the frame is the argument ARRAY
-- (BIF_ARG_n is BIF__ARGS[n-1]), the slot a scalar tagged WORD (Eterm), each representative built by the compiler with
-- erts' own constructors, the registrations make_tables generated, and the OUTCOME the status convention of erts' own
-- error macro: a return is a REJECTION when its path stored an error code into the status field (BIF_ERROR:
-- `(p)->freason = r; return THE_NON_VALUE`), a TRAP when it stored the trap code, else an ACCEPT.
-- ⚠ LIMITS: a BOXED term (tuple, float, bignum, binary, map, fun, …) is one representative with an UNKNOWN word — a
-- check on it reads as content; the atoms are only those the paths COMPARE against (a first run finds them) plus one
-- they do not.
local ffi = require 'ffi'
local CI = require 'cartograph.cinterp'
local FT = require 'cartograph.cinterp.facts'
local M = {}

local U64 = ffi.typeof('uint64_t')
local function hexword(h)
    if not h then return nil end
    h = ('%016s'):format(h):gsub(' ', '0')
    return U64(tonumber(h:sub(1, 8), 16)) * U64(2 ^ 32) + U64(tonumber(h:sub(9), 16))
end
local function same(v, h)
    if not (v and v.k == 'i') or not h then return nil end
    return ffi.cast('uint64_t', v.v) == hexword(h)
end

--- THE CONTEXT: the facts table of the tree (a gap raises, naming it) -> the interpreter's ctx + result / registrations
--- / typenames / facts
function M.context(src)
    local T = FT.derive({ src = src })
    local got, miss = T.got, {}
    for _, f in ipairs({ 'units', 'noret', 'frame', 'layout', 'reps', 'sentinels', 'builtins', 'result', 'registrations', 'typenames' }) do
        if got[f] == nil then miss[#miss + 1] = f .. ' (' .. tostring(T.rows[f] and T.rows[f].gap) .. ')' end
    end
    if #miss > 0 then error('erlbif: facts not derived: ' .. table.concat(miss, '; ')) end
    if got.frame.kind ~= 'array' then error('erlbif: the frame is not an argument array') end
    if got.result.kind ~= 'status' then error('erlbif: the result is not a status convention') end
    local ctx = FT.ctx(got)
    ctx.result, ctx.registrations, ctx.typenames, ctx.facts = got.result, got.registrations, got.typenames, T
    return ctx
end

--- a BIF's ACCEPTANCE at argument k of arity n: every representative in ONE run — first without atoms, then with the
--- atoms its paths compared against — -> { [element] = outcome }, over, the atoms found. An element's outcome is
--- 'always' (every path accepts), 'never' (every path rejects), 'content' (both, or a status the path cannot tell),
--- or the name of another outcome its every path takes ('trap').
function M.acceptance(A, ctx, d, n, k)
    local R, res = ctx.reps, ctx.result
    local function run(elements)
        local set = {}
        for _, e in ipairs(elements) do set[e .. '@' .. n] = true end
        local slots = {}
        for i = 1, n do if i ~= k then slots[i] = '?' end end
        local args = { n = #d.params }
        for i, p in ipairs(d.params) do
            if p.name == ctx.frame.array then args[i] = { k = 'slot', i = 1 }
            elseif p.type and p.type.k == 'p' then args[i] = CI.object(p.name, { [res.field] = CI.UNSET }) end
        end
        A.steps = 0
        return A.run(d, args, slots, k, set, false), set
    end
    local base = {}
    for _, name in ipairs(R.order) do if not name:match('^ATOM:') then base[#base + 1] = name end end
    local sum = run(base)
    -- the atoms the paths compared against (a comparison's constant IS an atom's word)
    local want = {}
    for _, c in pairs(sum.compared or {}) do want[CI.key_of(c)] = true end
    local found = {}
    for _, name in ipairs(R.order) do
        if name:match('^ATOM:') then
            local h = R.tag[name].u64
            local w = CI._int(ffi.cast('int64_t', hexword(h)), 64, true)
            if want[CI.key_of(w)] then found[#found + 1] = name end
        end
    end
    local set
    if #found > 0 then
        local all = vim.list_extend(vim.list_slice(base), found)
        sum, set = run(all)
    else
        local s = {}
        for _, e in ipairs(base) do s[e .. '@' .. n] = true end
        set = s
    end
    -- the OUTCOME of each return: the status its path left (a field of an object the BIF was handed)
    local seen = {}
    for e in pairs(set) do seen[e] = {} end
    for _, r in ipairs(sum.returns or {}) do
        -- (every object the BIF was handed carries the status field: the one a path WROTE decides — all still UNSET is
        -- an accept, any unknown is unknown)
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
                    for name, h in pairs(res.codes) do if same(s, h) then o = name:lower() end end
                end
            end
            if seen[e] then seen[e][o] = true end
        end
    end
    -- (a NO-RETURN call is a VM ABORT here — erts_exit, an allocation failure — not a type error: the status convention
    -- decides rejection; an abort is an outcome only for an element with no other)
    for e in pairs(sum.rej or {}) do if seen[e] then seen[e].abort = true end end
    local out = {}
    for e, os in pairs(seen) do
        local t = CI.elem(e)
        if os.abort and next(os, nil) ~= nil and vim.tbl_count(os) > 1 then os.abort = nil end
        local l = vim.tbl_keys(os)
        if #l == 0 then out[t] = 'never'
        elseif #l == 1 then out[t] = ({ accept = 'always', reject = 'never', unknown = 'content' })[l[1]] or l[1]
        else out[t] = 'content' end
    end
    return out, sum.over, found
end

--- a position's reading by TYPE (ctx.typenames: the most specific guard that holds): a type is 'always' / 'never' /
--- an outcome when all its representatives agree, else 'content' -> { [type] = status }, accepted types, outcome types
function M.reading(acc, tn)
    local by = {}
    for e, st in pairs(acc) do
        local t = tn[e] or e
        if by[t] == nil then by[t] = st elseif by[t] ~= st then by[t] = 'content' end
    end
    local accepted, other = {}, {}
    for t, st in pairs(by) do
        if st == 'always' or st == 'content' then accepted[#accepted + 1] = t
        elseif st ~= 'never' then other[#other + 1] = t .. '=' .. st end
    end
    table.sort(accepted); table.sort(other)
    -- (UNTYPED: every type the same — the position decides nothing by type, another argument's check does)
    local statuses = {}
    for _, st in pairs(by) do statuses[st] = true end
    return by, accepted, other, vim.tbl_count(statuses) == 1
end

--- READINGS for named BIFs: opts = { src, bifs = { 'module:name/arity', … } } -> { [bif] = { cfn, pos = { [k] = {
--- by, accepted, other, over, atoms } } } }, ctx
function M.measure(opts)
    local ctx = M.context(opts.src)
    local A = CI.analyzer(ctx)
    local want = {}
    for _, b in ipairs(opts.bifs) do want[b] = true end
    local rows = {}
    for _, e in ipairs(ctx.registrations.funcs) do
        local q = ('%s:%s/%d'):format(e.module, e.name, e.arity)
        if want[q] and not rows[q] then
            local d = ctx.defs[e.cfn]
            local row = { cfn = e.cfn, pos = {} }
            if not d then row.missing = 'no definition of ' .. e.cfn
            else
                for k = 1, e.arity do
                    local acc, over, found = M.acceptance(A, ctx, d, e.arity, k)
                    local by, accepted, other, untyped = M.reading(acc, ctx.typenames)
                    row.pos[k] = { by = by, accepted = accepted, other = other, untyped = untyped, over = over, atoms = found }
                end
            end
            rows[q] = row
        end
    end
    return rows, ctx
end

return M
