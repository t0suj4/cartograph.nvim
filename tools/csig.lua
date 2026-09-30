-- csig — LUA LIBRARY SIGNATURES FROM LuaJIT's OWN C, JOINED AGAINST lua-language-server's (cartograph.luajs.csig,
-- CART-1240 leaf 1).
--
--   nvim --headless -u NONE -l tools/csig.lua <BUILT luajit src dir> [--profile <luajit.mpack>] [--no-witness] [--json <out>]
--
-- <src> is the tree tools/packmap.lua builds at the ORACLE's revision (~/.cache/nvim/cartograph/packmap/<rev>/src):
-- its registrations, its checkers and its preprocessed units are read from there; the build's own compile flags from
-- its make. The lua-ls side is the `luajit` profile's signatures (default lua/cartograph/spec/profile/luajit.mpack;
-- their meta dir, for `---@alias`, is read from the profile's sig_source). Prints, in this order:
--   CHECKERS   the premise: what each checker accepts, derived from its own body, and the rule that decided it —
--              with the dynamic witness's confirmations beside it
--   SIGNATURES complete / partial / no C body; argument positions stated, and OPEN (read directly: not compared)
--   JOIN       oraclejoin's six outcomes, disagreements grouped by the (C, lua-ls) pair, our refusals by reason
--   WITNESS    a child LuaJIT per function: each stated position probed with a value its type rejects (and absent
--              when required); what LuaJIT's own error message says is expected
-- It changes nothing: the profile is read, never written (whether the derived signatures replace the annotation
-- source is decided after this measurement).
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local USAGE = 'usage: csig.lua <BUILT luajit src dir> [--profile <luajit.mpack>] [--no-witness] [--json <out>]\n'
local src = arg[1]
if not src then io.stderr:write(USAGE); os.exit(2) end
src = vim.fn.fnamemodify(src, ':p'):gsub('/$', '')
local opt = {}
for i = 2, #arg do
    if arg[i] == '--no-witness' then opt['no-witness'] = true
    elseif arg[i]:match('^%-%-') then opt[arg[i]:sub(3)] = arg[i + 1] end
end
local S = require 'cartograph.luajs.csig'
local cflags = {}
for line in (vim.system({ 'make', '-n', 'lj_err.o' }, { cwd = src, text = true }):wait().stdout or ''):gmatch('[^\n]+') do
    if line:match('%-c %-o lj_err%.o lj_err%.c') then for fl in line:gmatch('%S+') do if fl:match('^%-[DU]') then cflags[#cflags + 1] = fl end end end
end
local config = { LJ_52 = table.pack ~= nil, LJ_HASJIT = jit.status ~= nil, LJ_HASFFI = (pcall(require, 'ffi')), LJ_HASBUFFER = (pcall(require, 'string.buffer')) }
local ppath = opt.profile or (REPO .. '/lua/cartograph/spec/profile/luajit.mpack')
local pf = assert(io.open(ppath, 'rb'))
local profile = vim.mpack.decode(pf:read('a')); pf:close()
local t0 = vim.uv.hrtime()
local M = S.measure({ src = src, cflags = cflags, config = config, profile = profile, witness = not opt['no-witness'] })
local W = M.witness
io.write(('CSIG %s — the oracle %s; lua-ls from %s (%d aliases); %.1f s\n'):format(src, jit.version, tostring(M.meta), M.aliases, (vim.uv.hrtime() - t0) / 1e9))
-- CHECKERS
local cn = vim.tbl_keys(M.checkers); table.sort(cn)
io.write(('CHECKERS (%d, every function of the tree taking (L, <pos>) that raises on it):\n'):format(#cn))
for _, n in ipairs(cn) do
    local c = M.checkers[n]
    local w = W and W.bychecker[n]
    local o = c.opt == true and 'optional' or type(c.opt) == 'table' and ('optional iff arg ' .. c.opt.param .. (c.opt.truthy and ' ~= NULL' or ' >= 0')) or 'required'
    io.write(('  %-22s %-15s %-22s %s%s%s  [%s]%s\n'):format(n, table.concat(c.types, '|') ~= '' and table.concat(c.types, '|') or (c.from_arg and ('<arg ' .. c.from_arg .. '>') or '?'), o,
        c.integer and 'integer ' or '', #c.coerces > 0 and ('+' .. table.concat(c.coerces, '+') .. ' ') or '', c.converts and ('converted by ' .. c.converts .. ' ') or '',
        table.concat(c.rule, '; '), w and ('  witness ' .. w.ok .. ' ok / ' .. w.bad .. ' not') or ''))
end
-- SIGNATURES
local st = M.stats
io.write(('SIGNATURES: %d complete, %d partial, %d with no C body; %d argument positions stated, %d of them OPEN (read directly, not compared)\n')
    :format(st.complete, st.partial, st.nobody, st.positions, st.open))
-- JOIN
local R = M.join
local c = R.counts
io.write(('JOIN C vs lua-ls: %d inputs — agree %d | disagree %d in %d cause(s) | refused by us %d | rejected by lua-ls %d | both %d\n')
    :format(c.total, c.agree, c.disagree, #R.groups, c.refused, c.rejected, c.both))
if R.vacuous then io.write('  ⚠ VACUOUS JOIN: no input agrees — suspect the harness before either reader\n') end
for _, g in ipairs(R.groups) do
    local ids = {}
    for _, e in ipairs(g.examples or {}) do ids[#ids + 1] = e.id end
    io.write(('  DISAGREE %3d  %-58s %s\n'):format(g.n, g.cause, table.concat(ids, ' ')))
end
local function by_reason(list)
    local rw = {}
    for _, r in ipairs(list) do local k = r.why:gsub('%s*%(.*$', ''); rw[k] = rw[k] or {}; table.insert(rw[k], r.id) end
    local rk = vim.tbl_keys(rw); table.sort(rk, function (a, b) if #rw[a] ~= #rw[b] then return #rw[a] > #rw[b] end return a < b end)
    return rk, rw
end
local rk, rw = by_reason(R.refusals)
for _, k in ipairs(rk) do io.write(('  refused %4d  %s  (%s%s)\n'):format(#rw[k], k, table.concat(vim.list_slice(rw[k], 1, 6), ' '), #rw[k] > 6 and ' …' or '')) end
local jk, jw = by_reason(R.rejections)
for _, k in ipairs(jk) do io.write(('  rejected %3d  %s  (%s%s)\n'):format(#jw[k], k, table.concat(vim.list_slice(jw[k], 1, 6), ' '), #jw[k] > 6 and ' …' or '')) end
io.write(('  INTEGER at positions both type number: both %d, only C (an int32 checker) %d, only lua-ls %d\n'):format(M.refine.both, M.refine.c_only, M.refine.luals_only))
io.write(('  lua-ls positions not compared (a type its meta never defines): %d%s\n'):format(#M.unresolved, #M.unresolved > 0 and (' — ' .. table.concat(M.unresolved, ' ')) or ''))
-- WITNESS
if W then
    io.write(('WITNESS (%d functions, a child LuaJIT each): %s\n'):format(W.functions, vim.inspect(W.tally, { newline = '', indent = '' })))
    for _, n in ipairs(W.notes) do io.write('  ', n, '\n') end
end
if opt.json then
    local fd = assert(io.open(opt.json, 'w'))
    fd:write(vim.json.encode({ checkers = M.checkers, stats = M.stats, counts = R.counts, groups = R.groups, refusals = R.refusals, rejections = R.rejections,
        witness = W and { tally = W.tally, notes = W.notes, bychecker = W.bychecker } or nil }))
    fd:close()
end
