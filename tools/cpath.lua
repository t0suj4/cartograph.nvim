-- cpath — ARGUMENT TYPES BY PATH over LuaJIT's C (cartograph.luajs.cpath, CART-1240 leaf 2): no checker named, every
-- function's argument slots read through the paths that reach no no-return raiser.
--
--   nvim --headless -u NONE -l tools/cpath.lua <BUILT luajit src dir> [--positions <K>] [--no-witness] [--json <out>]
--
-- <src> is tools/packmap.lua's tree at the oracle's revision (~/.cache/nvim/cartograph/packmap/<rev>/src). Prints:
--   PREMISES  the representatives' tvis* matrix (diagonal, the unions covering their members) and the API's own
--             lua_type over every tag and absent (lua.h's codes) — the interpreter reproducing real C before any use
--   GATE      leaf 1's checker table (cartograph.luajs.csig — the COMPARISON only, nothing below reads it) reproduced
--             by the path reading: every checker, its extra parameters over generic values (-1/1, NULL/a string)
--   READINGS  per registered function and position: accepted / always / absent / untyped; result counts
--   JOIN      against leaf 1 at the positions it states; the positions ONLY the path reading types, and their WITNESS
--             (csig's child LuaJIT, LuaJIT's own error wording)
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local USAGE = 'usage: cpath.lua <BUILT luajit src dir> [--positions <K>] [--no-witness] [--json <out>]\n'
local src = arg[1]
if not src then io.stderr:write(USAGE); os.exit(2) end
src = vim.fn.fnamemodify(src, ':p'):gsub('/$', '')
local opt = {}
for i = 2, #arg do
    if arg[i] == '--no-witness' then opt['no-witness'] = true
    elseif arg[i]:match('^%-%-') then opt[arg[i]:sub(3)] = arg[i + 1] end
end
local P, CS, B = require 'cartograph.luajs.cpath', require 'cartograph.luajs.csig', require 'cartograph.luajs.boundary'
local cflags = {}
for line in (vim.system({ 'make', '-n', 'lj_err.o' }, { cwd = src, text = true }):wait().stdout or ''):gmatch('[^\n]+') do
    if line:match('%-c %-o lj_err%.o lj_err%.c') then for fl in line:gmatch('%S+') do if fl:match('^%-[DU]') then cflags[#cflags + 1] = fl end end end
end
local config = { LJ_52 = table.pack ~= nil, LJ_HASJIT = jit.status ~= nil, LJ_HASFFI = (pcall(require, 'ffi')), LJ_HASBUFFER = (pcall(require, 'string.buffer')) }
local t0 = vim.uv.hrtime()
local ctx = P.context(src)
local tn = ctx.typenames
-- PREMISES
local R = ctx.reps
local diag, bad = 0, {}
for _, p in ipairs(R.tvis) do
    for _, t in ipairs(R.order) do
        local base = p:gsub('^tvis', '')
        local own = (tn[t] or ''):sub(1, #base) == base
        if R.matrix[p][t] == 1 and own then diag = diag + 1 end
    end
end
local A0 = P.analyzer(ctx)
local lt, lrow = ctx.defs.lua_type, {}
for _, t in ipairs(R.order) do
    local sum = lt and A0.run(lt, { P.thread(), P._int(1), n = 2 }, {}, 1, { [t .. '@1'] = true }, false)
    local v = sum and sum.vals[t .. '@1'] or nil
    lrow[#lrow + 1] = ('%s=%s'):format(t, v and v.k == 'i' and tostring(tonumber(v.v)) or '?')
end
local sa = lt and A0.run(lt, { P.thread(), P._int(1), n = 2 }, {}, 1, { ['ABSENT@0'] = true }, false)
local va = sa and sa.vals['ABSENT@0'] or nil
local fc = {}
for t, yes in pairs(ctx.firstclass) do if not yes then fc[#fc + 1] = t end end
table.sort(fc)
io.write(('CPATH %s — the oracle %s; %d functions, %d tags (%d not first-class: %s); context %.1f s\n'):format(src, jit.version,
    vim.tbl_count(ctx.defs), #R.order, #fc, table.concat(fc, ' '), (vim.uv.hrtime() - t0) / 1e9))
io.write(('PREMISES: tvis* x representatives — %d predicates over %d tags from the compiler; lua_type %s absent=%s\n'):format(#R.tvis, #R.order,
    table.concat(lrow, ' '), va and va.k == 'i' and tostring(tonumber(va.v)) or '?'))
local fr = ctx.frame
io.write(('  FRAME (derived: lua_gettop\'s top - base, the rebase in %s): thread %s, top %s, base %s, origin %s\n'):format(
    tostring(fr.origin_in), fr.thread, fr.top, fr.base, tostring(fr.origin)))
-- THE GATE: leaf 1's checkers, read by path
local L1 = CS.checkers(src, CS.vocabulary(src), B.noreturn(src))
local names = vim.tbl_keys(L1); table.sort(names)
local A = P.analyzer(ctx)
local firstnames = {}
for t, yes in pairs(ctx.firstclass) do if yes then firstnames[tn[t]] = true end end
local gate = { reproduced = 0, finer = 0, absent = 0 }
io.write('GATE (leaf 1\'s checker table reproduced by the path reading — no name read):\n')
for _, n in ipairs(names) do
    local d = ctx.defs[n]
    if not d then gate.absent = gate.absent + 1; io.write(('  %-22s not compiled in this build\n'):format(n)) goto continue end
    local chk = {}
    for _, t in ipairs(L1[n].types) do chk[#chk + 1] = t end
    for _, t in ipairs(L1[n].coerces) do chk[#chk + 1] = t end
    local luanum = CS.vocabulary(src).luanum
    local variants = { {} }
    for i = 3, #d.params do
        local p = d.params[i]
        local opts = (p.type and p.type.k == 'i') and { P._int(-1), P._int(1) } or ((p.type and p.type.k == 'p') and { { k = 'null' }, { k = 'str' } } or { false })
        local nv = {}
        for _, v in ipairs(variants) do for _, o in ipairs(opts) do local c = vim.deepcopy(v); c[i] = o or nil; nv[#nv + 1] = c end end
        variants = nv
    end
    local hit, shown = false, {}
    for _, var in ipairs(variants) do
        local args = { P.thread(), P._int(1), n = #d.params }
        for i = 3, #d.params do args[i] = var[i] end
        local r = P.reading(P.acceptance(A, ctx, d, args, 1, 2), tn)
        -- leaf 1's optionality AT THIS BINDING (checkopt: its argument >= 0; luaL_checkoption: not NULL)
        local o1 = L1[n].opt
        if type(o1) == 'table' then
            local v = args[o1.param]
            if o1.truthy then o1 = v ~= nil and v.k ~= 'null' else o1 = v ~= nil and v.k == 'i' and tonumber(v.v) >= 0 end
        end
        -- (leaf 1's type from a call-site argument, at THIS binding: luaL_checktype's `tt`)
        local c2 = chk
        if L1[n].from_arg then local v = args[L1[n].from_arg]; c2 = { v and v.k == 'i' and luanum[tonumber(v.v)] or nil } end
        local diff = P.compare(r.accepted, r.absent ~= 'never', c2, o1 == true, firstnames)
        if not diff then hit = true end
        local desc = {}
        for i = 3, #d.params do local v = args[i]; desc[#desc + 1] = v == nil and '?' or (v.k == 'i' and tostring(tonumber(v.v)) or v.k) end
        shown[#shown + 1] = ('(%s) %s'):format(table.concat(desc, ','), diff or 'same')
    end
    if hit then gate.reproduced = gate.reproduced + 1 else gate.finer = gate.finer + 1 end
    io.write(('  %-22s %-7s %s\n'):format(n, hit and 'SAME' or 'DIFFERS', table.concat(shown, '  ')))
    ::continue::
end
io.write(('  %d of %d reproduced at some binding, %d differ (read them: the path reading is finer where the C is), %d not compiled in\n')
    :format(gate.reproduced, gate.reproduced + gate.finer, gate.finer, gate.absent))
-- THE MEASUREMENT
local prof = vim.mpack.decode(assert(io.open(REPO .. '/lua/cartograph/spec/profile/luajit.mpack', 'rb')):read('a'))
local L1m = CS.measure({ src = src, cflags = cflags, config = config, profile = prof, witness = false })
local M = P.measure({ src = src, cflags = cflags, config = config, leaf1 = L1m, positions = tonumber(opt.positions or '4'), witness = not opt['no-witness'] })
local st = M.stats
io.write(('READINGS: %d functions x %d positions in %.1f s — %d typed, %d untyped (tag-independent), %d over budget; %d C bodies only raise (the VM\'s fast path handles success)\n')
    :format(st.functions, tonumber(opt.positions or '4'), M.seconds, st.typed, st.untyped, st.over, st.raise_only))
local rc = { known = 0, unknown = 0 }
for _, row in pairs(M.rows) do if #row.results.counts > 0 and not row.results.unknown then rc.known = rc.known + 1 else rc.unknown = rc.unknown + 1 end end
io.write(('  RESULT COUNTS (a literal return; FFH_RES read from lj_lib.h): %d functions exact, %d with a non-literal count\n'):format(rc.known, rc.unknown))
local J = M.join
io.write(('JOIN path vs checker (leaf 1): agree %d | disagree %d in %d cause(s) | leaf 1 states no closed position %d\n'):format(J.counts.agree, J.counts.disagree, #J.groups, J.counts.refused))
for _, g in ipairs(J.groups) do
    local ids = {}
    for _, e in ipairs(g.examples) do ids[#ids + 1] = e.id end
    io.write(('  %3d  %-66s %s\n'):format(g.n, g.cause, table.concat(ids, ' ')))
end
io.write(('ONLY the path reading types: %d positions (leaf 1 refused the function or left the position open)\n'):format(#M.only))
if M.witness then
    io.write(('WITNESS on them (%d functions; "named" = LuaJIT names a type outside type()\'s words): %s\n'):format(M.witness.functions, vim.inspect(M.witness.tally, { newline = '', indent = '' })))
    for _, n in ipairs(M.witness.notes) do io.write('  ', n, '\n') end
end
if opt.json then
    local fd = assert(io.open(opt.json, 'w'))
    fd:write(vim.json.encode({ rows = M.rows, stats = M.stats, counts = J.counts, groups = J.groups, only = M.only, witness = M.witness and { tally = M.witness.tally, notes = M.witness.notes } or nil }))
    fd:close()
end
