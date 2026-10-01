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
local AD = require 'cartograph.cinterp.adapter'
local M = {}

--- THE CONTEXT: the facts table of the tree (a gap raises, naming it) — the TEMPLATE's (cartograph.cinterp.adapter),
--- over an argument array and a status convention -> the interpreter's ctx + result / registrations / typenames / facts
function M.context(src)
    local ctx = AD.context(src, { 'units', 'noret', 'frame', 'layout', 'reps', 'sentinels', 'builtins', 'result', 'registrations', 'typenames' }, 'erlbif')
    if AD.frame_kind(ctx.frame) ~= 'array' then error('erlbif: the frame is not an argument array') end
    if ctx.result.kind ~= 'status' then error('erlbif: the result is not a status convention') end
    return ctx
end

--- a BIF's ACCEPTANCE at argument k of arity n — the TEMPLATE's: every value representative in one run, the atoms its
--- paths compared against in a second, each return's outcome by the status convention -> { [element] = outcome },
--- over, the atoms found. An element's outcome is 'always' / 'never' / 'content' / another outcome ('trap').
function M.acceptance(A, ctx, d, n, k)
    local out, over, info = AD.acceptance(A, ctx, d, k, n)
    return out, over, info.found
end

--- a position's reading by TYPE (ctx.typenames: the most specific guard that holds): a type is 'always' / 'never' /
--- an outcome when all its representatives agree, else 'content' -> { [type] = status }, accepted types, outcome types
function M.reading(acc, tn)
    -- (the TEMPLATE's reading — cartograph.cinterp.adapter.reading — in this adapter's shape)
    local r = AD.reading(acc, tn)
    return r.by, r.accepted, r.other, r.untyped
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
