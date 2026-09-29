-- packmap — WHICH C FUNCTION DOES EACH luajs PACK PRIMITIVE RE-IMPLEMENT? (cartograph.luajs.packmap, CART-1211 leaf 2)
--
--   nvim --headless -u NONE -l tools/packmap.lua <luajit git dir> [--rev <commit>] [--pack <pack.js>] [--json <out>]
--
-- The LuaJIT REVISION is the ORACLE's by default — the running LuaJIT's `jit.version` patch number is its commit
-- timestamp, found in the clone's log — because every claim here (the library set, its messages) is a claim about the
-- differential's reference, not about whatever the clone's HEAD is. The tree is exported with `git archive`.
-- The CONFIGURATION gates buildvm reads (LJ_52, LJ_HASJIT, LJ_HASFFI, LJ_HASBUFFER) are read from the oracle too.
-- Prints: the library (registered · in the oracle · the two readings' disagreements), the pack's coverage by module
-- and its implementation kinds, the method-table frontier, each primitive's C matches, the messages the pack raises
-- that LuaJIT never does; --json writes every row (leaf 3 orders its work from it).
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local USAGE = 'usage: packmap.lua <luajit git dir> [--rev <commit>] [--pack <pack.js>] [--json <out>]\n'
local lj = arg[1]
if not lj then io.stderr:write(USAGE); os.exit(2) end
lj = vim.fn.fnamemodify(lj, ':p'):gsub('/$', '')
local opt = {}
for i = 2, #arg - 1 do if arg[i]:match('^%-%-') then opt[arg[i]:sub(3)] = arg[i + 1] end end

local rev = opt.rev
if not rev then
    local stamp = jit.version:match('%.(%d+)$')
    for line in (vim.system({ 'git', '-C', lj, 'log', '--format=%h %ct' }, { text = true }):wait().stdout or ''):gmatch('[^\n]+') do
        local h, ct = line:match('^(%x+) (%d+)$')
        if ct == stamp then rev = h; break end
    end
    if not rev then io.stderr:write(('the oracle (%s) names commit time %s, which %s does not have — pass --rev\n'):format(jit.version, tostring(stamp), lj)); os.exit(1) end
end
local work = vim.fn.stdpath('cache') .. '/cartograph/packmap/' .. rev
vim.fn.delete(work, 'rf')
vim.fn.mkdir(work, 'p')
local ar = vim.system({ 'sh', '-c', ('git -C %q archive %q src dynasm | tar -x -C %q'):format(lj, rev, work) }):wait()
if ar.code ~= 0 then io.stderr:write('git archive failed\n'); os.exit(1) end
local src = work .. '/src'
-- an archived tree has no .git: its REVISION is written beside it, for what is later generated from it (cjs recipes)
do local fd = assert(io.open(work .. '/REV', 'w')); fd:write(rev, '\n'); fd:close() end
-- the headers LuaJIT's BUILD generates (buildvm: lj_ffdef.h, lj_libdef.h, …) — a source tree has none, and without
-- them 31 of its .c files do not preprocess; LuaJIT's own make builds them with the host compiler
local mk = vim.system({ 'make', 'lj_bcdef.h', 'lj_ffdef.h', 'lj_libdef.h', 'lj_recdef.h', 'lj_folddef.h' }, { cwd = src, text = true }):wait()
if mk.code ~= 0 then io.stderr:write('make (the generated headers) failed: ', mk.stderr or '', '\n'); os.exit(1) end
local config = {
    LJ_52 = table.pack ~= nil, -- (read from the oracle's own library: the one gate whose evidence is a registration)
    LJ_HASJIT = jit.status ~= nil,
    LJ_HASFFI = (pcall(require, 'ffi')),
    LJ_HASBUFFER = (pcall(require, 'string.buffer')),
}
local L, PM = require 'cartograph.luajs', require 'cartograph.luajs.packmap'
local pack_path = opt.pack and vim.fn.fnamemodify(opt.pack, ':p') or (REPO .. '/lua/cartograph/luajs/pack.js')
local pack_dir = work .. '/pack'
L.install_pack(pack_dir)
if opt.pack then vim.fn.writefile(vim.fn.readfile(pack_path, 'b'), pack_dir .. '/$pack.js', 'b') end
local t0 = vim.uv.hrtime()
-- the compile flags LuaJIT's OWN build uses (its make, asked for one object's command line)
local cflags = {}
local mkn = vim.system({ 'make', '-n', 'lj_err.o' }, { cwd = src, text = true }):wait().stdout or ''
for line in mkn:gmatch('[^\n]+') do
    if line:match('%-c %-o lj_err%.o lj_err%.c') then
        for flag in line:gmatch('%S+') do if flag:match('^%-[DUI]') then cflags[#cflags + 1] = flag end end
    end
end
local res = assert(PM.build({ src = src, pack_dir = pack_dir, pack_path = pack_path, work = work, config = config, rev = rev, cflags = cflags }))
local S = res.summary
io.write(('LUAJIT %s (the oracle %s), config %s — %d C functions extracted, %.1f s\n'):format(rev, jit.version,
    vim.inspect(config, { newline = '', indent = '' }), res.meta.c_functions, (vim.uv.hrtime() - t0) / 1e9))
if #(res.meta.pp_failed or {}) > 0 then io.write('  NOT PREPROCESSED (their functions are absent): ', table.concat(res.meta.pp_failed, ' '), '\n') end
io.write(('LIBRARY: %d registered functions (%s); the oracle has %d of them\n'):format(S.lj, vim.inspect(S.lj_kinds, { newline = '', indent = '' }), S.oracle))
if #res.not_in_oracle > 0 then io.write('  registered, NOT in the oracle: ', table.concat(res.not_in_oracle, ' '), '\n') end
if #res.oracle_only > 0 then io.write('  in the oracle, NO registration: ', table.concat(res.oracle_only, ' '), '\n') end
-- PRESENT is not IMPLEMENTED: a refused entry is an $abort stub (it breaks by name when reached)
local refused_n = S.by_kind.refused or 0
io.write(('PACK: %d of %d present — %d IMPLEMENTED + %d refused stubs — %s\n'):format(S.pack, S.lj, S.pack - refused_n, refused_n,
    vim.inspect(S.by_kind, { newline = '', indent = '' })))
for _, k in ipairs { 'refused', 'host', 'transliterated' } do
    local names = {}
    for _, r in ipairs(res.rows) do if r.pack_kind == k then names[#names + 1] = r.qname .. (r.pack_via and ('(' .. r.pack_via .. ')') or '') end end
    table.sort(names)
    if #names > 0 then io.write(('  %-15s %s\n'):format(k .. ':', table.concat(names, ' '))) end
end
local miss_by = {}
for _, q in ipairs(S.missing) do local m = q:match('^(.-)%.[^.]+$') or '_G'; miss_by[m] = miss_by[m] or {}; table.insert(miss_by[m], q) end
local ms = vim.tbl_keys(miss_by); table.sort(ms)
for _, m in ipairs(ms) do io.write(('  MISSING %-14s %3d: %s\n'):format(m, #miss_by[m], table.concat(miss_by[m], ' '))) end
if #res.missing_modules > 0 then io.write('  modules the pack has NOT AT ALL (suspect the accessor first): ', table.concat(res.missing_modules, ' '), '\n') end
io.write(('FRONTIER: %d function(s) in method tables (no global path): %s\n'):format(#res.frontiers,
    table.concat(vim.tbl_map(function (f) return f:match('^(%S+)') end, res.frontiers), ' ')))
io.write('PRIMITIVES (the pack exports) -> the C functions their evidence names:\n')
for _, p in ipairs(res.prims) do
    local m = {}
    -- DIRECT evidence first (the primitive's own text), then the count; `~` marks evidence reached through its closure
    for f, why in pairs(p.c_matches) do
        local direct = select(2, why:gsub('%f[%S][^~%s]%S*', ''))
        m[#m + 1] = { f = f, why = why, d = direct, n = select(2, why:gsub('%S+', '')), vm = why:find(' vm', 1, true) and 1 or 0 }
    end
    -- the INTERPRETER's handlers (called by the VM) first, then direct evidence, then its count
    table.sort(m, function (a, b)
        if a.vm ~= b.vm then return a.vm > b.vm end
        if a.d ~= b.d then return a.d > b.d end
        if a.n ~= b.n then return a.n > b.n end
        return a.f < b.f
    end)
    local shown = {}
    for i = 1, math.min(#m, 4) do shown[#shown + 1] = m[i].f .. ' [' .. vim.trim(m[i].why) .. ']' end
    if #shown > 0 then io.write(('  %-10s %-14s %s%s\n'):format(p.name, p.pack_kind, table.concat(shown, ', '), #m > 4 and (' … +' .. (#m - 4)) or '')) end
    if p.unassembled and #p.unassembled > 0 then
        io.write(('             its handler can raise, the pack never says: %s\n'):format(table.concat(p.unassembled, ' ')))
    end
end
if #(res.ubiquitous or {}) > 0 then io.write('  (every handler can also raise, the pack never: ', table.concat(res.ubiquitous, ' '), ')\n') end
local al = vim.tbl_keys(res.aligned); table.sort(al)
io.write(('HELPERS aligned by CO-OCCURRENCE (weak: in every unit using the helper, ranked by specificity — the share of units holding the C function that use it): %d\n'):format(#al))
-- only STRICT alignments are shown (specificity 1.00: in every unit using the helper, in no other): measured, the
-- 0.5–0.9 band paired ubiquitous helpers with ubiquitous C (isRec -> checklivetv) — noise; the JSON keeps them all
local strict = 0
for _, h in ipairs(al) do
    local c = res.aligned[h].c
    if c[1] and c[1].spec >= 1 then
        strict = strict + 1
        io.write(('  %-14s (%d units) -> %s\n'):format(h, res.aligned[h].units,
            table.concat(vim.tbl_map(function (x) return x.f end, vim.tbl_filter(function (x) return x.spec >= 1 end, c)), ' ')))
    end
end
io.write(('  (%d strict of %d ranked)\n'):format(strict, #al))
if #res.drift > 0 then
    io.write(('MESSAGE DRIFT: %d pack message(s) that assemble no LuaJIT message (literals joined by …):\n'):format(#res.drift))
    for _, s in ipairs(res.drift) do io.write('  "', s, '"\n') end
end
if opt.json then
    local fd = assert(io.open(opt.json, 'w')); fd:write(vim.json.encode(res)); fd:close()
    io.write('JSON: ', opt.json, '\n')
end
