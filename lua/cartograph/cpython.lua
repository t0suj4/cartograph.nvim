-- cartograph.cpython — ARGUMENT TYPES BY PATH over CPython's built-in functions (CART-1258): the CPython ADAPTER of
-- cartograph.cinterp, a thin instance of the adapter TEMPLATE. Every fact is the tree's (cartograph.cinterp.facts):
-- the frame the fast-call array WITH ITS COUNT (`_PyCFunctionFast`: `PyObject *const *args, Py_ssize_t nargs`), the
-- slot `PyObject *` read whole; the representatives REAL objects of a probe linked against the tree's libpython —
-- their addresses, the memory they reach (type objects, slot tables) and the addresses of the global type objects —
-- so `Py_TYPE(o)->tp_flags` and `Py_IS_TYPE(o, &PyLong_Type)` read what the runtime holds; the OUTCOME NULL (every
-- pointer function only returning NULL after a call is a thrower); the registrations the PyMethodDef rows, their
-- calling convention from the METH_ flags.
-- ⚠ LIMITS: METH_FASTCALL and METH_O only (METH_VARARGS' tuple is not read); a returned new object is an UNKNOWN call's
-- result, so most accepted types read as content, not always — the reading separates NEVER (every path returns NULL)
-- from the rest.
local CI = require 'cartograph.cinterp'
local AD = require 'cartograph.cinterp.adapter'
local M = {}

--- THE CONTEXT: the facts table of the tree (a gap raises, naming it) — the TEMPLATE's, over a counted argument array
--- and a NULL sentinel. `scope`: the units to read (globs relative to src; nil = the whole product)
function M.context(src, scope)
    local ctx = AD.context({ src = src, scope = scope }, { 'units', 'noret', 'frame', 'layout', 'reps', 'sentinels', 'builtins', 'result', 'registrations' }, 'cpython')
    if AD.frame_kind(ctx.frame) ~= 'counted' then error('cpython: the frame is not an argument array with its count') end
    if ctx.result.kind ~= 'sentinel' or not (ctx.sentinel and ctx.sentinel.k == 'null') then error('cpython: the result is not a NULL sentinel') end
    return ctx
end

--- the arguments one registration runs with, by its calling convention: METH_O hands the value itself (parameter 2);
--- METH_FASTCALL the template's array and count, METH_KEYWORDS' kwnames NULL (no keyword given)
function M.args(ctx, d, e)
    if e.meth.O then
        local args = { n = #d.params }
        args[1] = CI.object(d.params[1] and d.params[1].name or 'self')
        args[2] = { k = 'slotv', i = 1 }
        return args
    end
    local args = AD.args(ctx, d)
    if e.meth.KEYWORDS and #d.params >= 4 then args[4] = { k = 'null' } end
    return args
end

--- the positions one registration is read at: METH_O one (the runtime checks its arity: absent never), METH_FASTCALL
--- every position its C reads below `upto` (default 3)
function M.positions(e, upto)
    if e.meth.O then return 1, true end
    if e.meth.FASTCALL then return upto or 3, false end
    return 0
end

--- READINGS for registrations: opts = { ctx | src, scope, keys = { 'owner.name', … }, upto, npos = { [key] = n } } -> { [key] = { cfn, meth,
--- pos = { [k] = reading } } }, ctx
function M.measure(opts)
    local ctx = opts.ctx or M.context(opts.src, opts.scope)
    local A = CI.analyzer(ctx)
    local want = {}
    for _, k in ipairs(opts.keys) do want[k] = true end
    local rows = {}
    for _, e in ipairs(ctx.registrations.funcs) do
        local key = tostring(e.owner) .. '.' .. e.name
        if want[key] and not rows[key] then
            local d = ctx.defs[e.cfn]
            local row = { cfn = e.cfn, meth = e.meth, pos = {} }
            local npos, fixed = M.positions(e, (opts.npos and opts.npos[key]) or opts.upto)
            if not d then row.missing = 'no definition of ' .. e.cfn
            elseif npos == 0 then row.missing = 'calling convention not read: ' .. table.concat(vim.tbl_keys(e.meth), '|')
            else
                for k = 1, npos do
                    local acc, over = AD.acceptance(A, ctx, d, k, fixed and 1 or npos, M.args(ctx, d, e), fixed and { exact = true } or nil)
                    local r = AD.reading(acc, ctx.typenames)
                    r.over = over
                    if fixed then r.absent = 'never' end -- (METH_O: the call machinery checks the arity)
                    row.pos[k] = r
                end
            end
            rows[key] = row
        end
    end
    return rows, ctx
end

return M
