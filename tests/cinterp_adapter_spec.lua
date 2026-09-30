-- cartograph.cinterp.adapter (CART-1256): an adapter ASSEMBLED from a runtime's facts table ALONE — no cpath, no erlbif
-- — over both fixture runtimes: each variation (the elements, the arguments, the outcome of a return) chosen by a
-- fact's KIND, and the readings the hand-built adapters pin come out the same.
local AD = require 'cartograph.cinterp.adapter'
local CI = require 'cartograph.cinterp'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'c') and vim.fn.executable('gcc') == 1 end

local cache = {}
local function assemble(which)
    if cache[which] then return cache[which] end
    local files = dofile(vim.fn.getcwd() .. '/tests/fixtures/cinterp/' .. which .. '.lua')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, text in pairs(files) do local fd = assert(io.open(dir .. '/' .. name, 'w')); fd:write(text); fd:close() end
    local ctx = AD.context(dir, { 'units', 'noret', 'frame', 'layout', 'reps', 'sentinels', 'builtins', 'result' })
    cache[which] = { ctx = ctx, A = CI.analyzer(ctx) }
    return cache[which]
end

test('adapter: the KINDS the facts give choose the template\'s variations — a stack and raisers, an argument array and a status', function ()
    if not ready() then skip 'no C parser / gcc' end
    local lj, erts = assemble('luajit').ctx, assemble('erts').ctx
    eq({ 'stack', 'array' }, { AD.frame_kind(lj.frame), AD.frame_kind(erts.frame) })
    eq({ nil, 'status' }, { lj.result.kind, erts.result.kind }, 'no status convention: the raiser convention')
    local d = erts.defs.hd_1
    local args = AD.args(erts, d)
    eq({ 'obj', 'slot' }, { args[1].k, args[2].k }, 'the process an object, the argument array slot 1')
    eq({ 'thread' }, { AD.args(lj, lj.defs.lj_cf_x_istable)[1].k })
end)

test('adapter over the LuaJIT-shaped tree: a checker that jumps into its raise, a count-dispatched check — cpath\'s readings', function ()
    if not ready() then skip 'no C parser / gcc' end
    local c = assemble('luajit')
    local out = AD.acceptance(c.A, c.ctx, c.ctx.defs.x_checknum, 1, 3, { CI.thread(), CI._int(1), n = 2 })
    eq({ 'always', 'never', 'never' }, { out.NUMX, out.STR, out.ABSENT }, 'the number variants joined back into NUMX')
    local d = AD.acceptance(c.A, c.ctx, c.ctx.defs.lj_cf_x_disp, 2, 4)
    eq({ 'always', 'content', 'always' }, { d.NUMX, d.STR, d.ABSENT })
end)

test('adapter over the erts-shaped tree: the status convention, a trap, the atoms a switch names — erlbif\'s readings', function ()
    if not ready() then skip 'no C parser / gcc' end
    local c = assemble('erts')
    local hd = AD.acceptance(c.A, c.ctx, c.ctx.defs.hd_1, 1, 1)
    eq({ 'always', 'never', 'never', 'content' }, { hd.LIST1, hd.NIL, hd.ATOM, hd.BOXED })
    eq({ nil, nil }, { hd['ATOM:true'], hd['HDR:MATCHSTATE'] }, 'an atom no path compares is no element, nor is a representative no guard calls a value')
    local later = AD.acceptance(c.A, c.ctx, c.ctx.defs.later_1, 1, 1)
    eq({ 'trap', 'always' }, { later['SMALL#1'], later.ATOM })
    local b, _, info = AD.acceptance(c.A, c.ctx, c.ctx.defs.bool_1, 1, 1)
    eq({ 'always', 'always', 'never', 2 }, { b['ATOM:true'], b['ATOM:false'], b.ATOM, #info.found }, 'the on-demand family: only the two atoms compared')
    local al = AD.acceptance(c.A, c.ctx, c.ctx.defs.alloc_1, 1, 1)
    eq('always', al.ATOM, 'a no-return call is an ABORT under a status convention, not a rejection')
end)
