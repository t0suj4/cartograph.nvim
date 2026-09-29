-- luajs — TRANSLITERATE A LUA TREE TO JAVASCRIPT AND SEE WHAT BREAKS (cartograph.luajs, CART-1197).
--
--   nvim --headless -u NONE -l tools/luajs.lua <lua dir> <out dir> [--run]
--
-- Emits every .lua file under <lua dir> as <out dir>/<same path>.js (the template pack beside them as $pack.js),
-- then reports the breaks in three layers, each a different instrument:
--   EMIT    the constructs the emitter refused by name (cartograph.luajs), by kind
--   PARSE   node's OWN parser over every emitted file (`node --check`) — an independent implementation, so an emitter
--           bug that produces invalid JS cannot hide; must be 0
--   RUN     (--run) each module LOADED under node (`require`, LUAJS_ROOT = <out dir>), its outcome by the pack's own
--           classes: ok · a LuaBreak (a construct with no faithful form, reached at run time — named) · a LuaError (a
--           Lua-level error: a missing host API is `attempt to index a nil value` on `vim`) · any other JS error (an
--           emitter or pack bug)
-- A module that loads is not a module that WORKS: the differential test (tests/luajs_spec.lua) is the semantics oracle.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local src_dir = vim.fn.fnamemodify(assert(arg[1], 'usage: luajs.lua <lua dir> <out dir> [--run]'), ':p'):gsub('/$', '')
local out_dir = vim.fn.fnamemodify(assert(arg[2], 'usage: luajs.lua <lua dir> <out dir> [--run]'), ':p'):gsub('/$', '')
local run = false
for i = 3, #arg do if arg[i] == '--run' then run = true end end
local L = require 'cartograph.luajs'
vim.fn.mkdir(out_dir, 'p')
vim.fn.writefile(vim.fn.readfile(REPO .. '/lua/cartograph/luajs/pack.js', 'b'), out_dir .. '/$pack.js', 'b')
-- the pack's pattern matcher: LuaJIT's, transliterated from C (tools/cjs.lua lstrmatch)
vim.fn.writefile(vim.fn.readfile(REPO .. '/lua/cartograph/luajs/lstrmatch.js', 'b'), out_dir .. '/$lstrmatch.js', 'b')

local files = vim.fs.find(function (n) return n:match('%.lua$') end, { path = src_dir, type = 'file', limit = math.huge })
table.sort(files)
local by_kind, refused_files, total_refusals, emitted = {}, 0, 0, {}
local t0 = vim.uv.hrtime()
for _, path in ipairs(files) do
    local rel = path:sub(#src_dir + 2)
    local fd = io.open(path); local src = fd:read('a'); fd:close()
    local depth = select(2, rel:gsub('/', ''))
    local pack = (depth == 0 and './' or ('../'):rep(depth)) .. '$pack.js'
    local ok, js, refusals = pcall(L.emit, src, rel, { pack = pack })
    local dest = out_dir .. '/' .. rel:gsub('%.lua$', '.js')
    vim.fn.mkdir(vim.fn.fnamemodify(dest, ':h'), 'p')
    if not ok then
        by_kind['EMITTER CRASH'] = (by_kind['EMITTER CRASH'] or 0) + 1
        io.write('EMITTER CRASH ', rel, ': ', tostring(js):sub(1, 200), '\n')
    else
        local w = assert(io.open(dest, 'wb')); w:write(js); w:close()
        emitted[#emitted + 1] = { rel = rel, dest = dest }
        if #refusals > 0 then refused_files = refused_files + 1 end
        for _, r in ipairs(refusals) do
            local k = r.kind .. ': ' .. r.why
            by_kind[k] = (by_kind[k] or 0) + 1
            total_refusals = total_refusals + 1
        end
    end
end
-- ★ NVIM'S OWN PURE-LUA RUNTIME, transliterated beside the modules (cartograph.luajs.vim_runtime: the modules DERIVED
-- from the pack's `$require('vim.…')` names and their own requires)
local vim_emitted = L.vim_runtime(out_dir, table.concat(vim.fn.readfile(REPO .. '/lua/cartograph/luajs/pack.js'), '\n'))
local vim_refusals, vim_names = 0, {}
for _, e in ipairs(vim_emitted) do
    vim_names[#vim_names + 1] = e.rel
    vim_refusals = vim_refusals + #e.refusals
    for _, r in ipairs(e.refusals) do by_kind['vim runtime ' .. r.kind .. ': ' .. r.why] = (by_kind['vim runtime ' .. r.kind .. ': ' .. r.why] or 0) + 1 end
end
io.write(('VIM RUNTIME (%s/lua): %d module(s) transliterated (%s), %d refusal(s)\n'):format(vim.env.VIMRUNTIME, #vim_emitted, table.concat(vim_names, ' '), vim_refusals))
for _, e in ipairs(vim_emitted) do emitted[#emitted + 1] = e end
local emit_s = (vim.uv.hrtime() - t0) / 1e9

local function dump(t)
    local rows = {}
    for k, n in pairs(t) do rows[#rows + 1] = { k = k, n = n } end
    table.sort(rows, function (a, b) if a.n ~= b.n then return a.n > b.n end return a.k < b.k end)
    for _, r in ipairs(rows) do io.write(('  %6d  %s\n'):format(r.n, r.k)) end
end
io.write(('EMIT: %d file(s) in %.1f s; %d emitted, %d with a refusal, %d refusal(s):\n'):format(#files, emit_s, #emitted, refused_files, total_refusals))
dump(by_kind)

-- PARSE: node's own parser
local bad = {}
for _, e in ipairs(emitted) do
    local r = vim.system({ 'node', '--check', e.dest }, { text = true }):wait()
    if r.code ~= 0 then bad[#bad + 1] = e.rel .. ': ' .. ((r.stderr or ''):match('SyntaxError[^\n]*') or vim.trim(r.stderr or '')) end
end
io.write(('PARSE (node --check): %d of %d emitted file(s) fail\n'):format(#bad, #emitted))
for i = 1, math.min(#bad, 20) do io.write('  ', bad[i], '\n') end

if run then
    local outcomes, examples = {}, {}
    local probe = [[
const f = process.argv[1];
// a module is LOADED as require would load it: its chunk run with its module name as `...`
try { const m = require(f); if (m && m.$chunk) m.$chunk(process.argv[2]); console.log('OK'); }
catch (e) {
  const n = e && e.constructor && e.constructor.name;
  if (n === 'LuaBreak') console.log('BREAK\t' + e.what);
  else if (n === 'LuaError') console.log('LUAERROR\t' + String(e.value).slice(0, 160));
  else console.log('JSERROR\t' + String(e && e.message || e).slice(0, 160));
}
]]
    for _, e in ipairs(emitted) do
        local modname = e.rel:gsub('%.lua$', ''):gsub('/init$', ''):gsub('/', '.')
        local r = vim.system({ 'node', '-e', probe, e.dest, modname }, { text = true, env = L.run_env(out_dir, src_dir), timeout = 20000 }):wait()
        local line = vim.trim((r.stdout or ''):match('[^\n]*$') ~= '' and (r.stdout or ''):match('([^\n]*)\n?$') or (r.stdout or ''))
        local cls, detail = line:match('^(%u+)\t?(.*)$')
        cls = cls or ('NO OUTCOME (exit ' .. tostring(r.code) .. ')')
        -- normalize the detail so identical causes group
        local key = cls .. (detail and detail ~= '' and (': ' .. detail:gsub('%(.-:%d+%)', ''):gsub('%d+', 'N')) or '')
        outcomes[key] = (outcomes[key] or 0) + 1
        examples[key] = examples[key] or e.rel
    end
    io.write('RUN (each module loaded under node):\n')
    local rows = {}
    for k, n in pairs(outcomes) do rows[#rows + 1] = { k = k, n = n } end
    table.sort(rows, function (a, b) if a.n ~= b.n then return a.n > b.n end return a.k < b.k end)
    for i = 1, math.min(#rows, 40) do io.write(('  %5d  %s   [e.g. %s]\n'):format(rows[i].n, rows[i].k:sub(1, 150), examples[rows[i].k])) end
    if #rows > 40 then io.write(('  … %d more outcome kind(s)\n'):format(#rows - 40)) end
end
