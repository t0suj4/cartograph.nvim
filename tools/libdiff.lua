-- libdiff — a LIBRARY FUNCTION of the luajs pack against the ORACLE's, over generated inputs (cartograph.luajs.libdiff,
-- CART-1211 leaf 3 / CART-1220).
--
--   nvim --headless -u NONE -l tools/libdiff.lua <fn> [--n <count>] [--seed <n>] [--js <expr>]
--
-- <fn> names a library function with a declared input family (cartograph.luajs.libdiff.FAMILIES; an unknown one is refused naming them). The
-- oracle is this process's LuaJIT; the pack is installed (cartograph.luajs.install_pack) and run under node. Prints the
-- count compared, the count that DIFFER (numbers by bits), and the shortest differing inputs with both results.
-- --js overrides the pack side (a JS expression over P = the pack module and G = its _G), e.g. to test a candidate.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
local fn = arg[1]
if not fn then io.stderr:write('usage: libdiff.lua <fn> [--n <count>] [--seed <n>] [--js <expr>]\n'); os.exit(2) end
local opt = {}
for i = 2, #arg - 1 do if arg[i]:match('^%-%-') then opt[arg[i]:sub(3)] = arg[i + 1] end end
local L, D = require 'cartograph.luajs', require 'cartograph.luajs.libdiff'
local dir = vim.fn.tempname()
L.install_pack(dir)
local t0 = vim.uv.hrtime()
local res, why = D.run({ fn = fn, n = tonumber(opt.n or '200000'), seed = opt.seed and tonumber(opt.seed) or nil, dir = dir, js_fn = opt.js })
if not res then io.stderr:write(tostring(why), '\n'); os.exit(1) end
io.write(('%s: %d input(s), %d DIFFER from the oracle (%s), %.1f s\n'):format(fn, res.n, res.differ, jit.version, (vim.uv.hrtime() - t0) / 1e9))
for _, e in ipairs(res.examples) do
    io.write(('  %-40s lua %-24s js %s\n'):format(vim.inspect(e[1]):sub(1, 40), e[2], e[3]))
end
os.exit(res.differ == 0 and 0 or 1)