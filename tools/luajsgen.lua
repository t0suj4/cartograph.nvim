-- luajsgen — BOUNDED-EXHAUSTIVE DIFFERENTIAL of the Lua→JS transliteration (cartograph.luajs.gencheck, CART-1206).
--
--   nvim --headless -u NONE -l tools/luajsgen.lua <fragment> <max size> [corpus dir (default lua)] [out dir] [min=<n>]
--
-- Derives the Lua grammar from the corpus (cartograph.grammargen), prints the COUNT of programs per size first, then
-- runs every program of the fragment up to <max size> under real Lua and under node, and prints the FUNNEL per size
-- (generated → parses → loads → terminates → emitted → compared → diverged, + Lua-rejected programs the emitter
-- translated anyway), the divergences by class (value · message · crash · hang) smallest first, and the claim's label.
-- Fragments: control · values · coercion (cartograph.luajs.gencheck.FRAGMENTS).
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local USAGE = 'usage: luajsgen.lua <control|values|coercion> <max size> [corpus dir] [out dir] [min=<n>]'
local GG, GC = require 'cartograph.grammargen', require 'cartograph.luajs.gencheck'
local name, max = arg[1], tonumber(arg[2] or '')
local frag = name and GC.FRAGMENTS[name]
if not frag or not max then io.stderr:write(USAGE, '\n'); os.exit(2) end
local corpus = vim.fn.fnamemodify(arg[3] or (REPO .. '/lua'), ':p'):gsub('/$', '')
local out = arg[4] or (vim.fn.stdpath('cache') .. '/cartograph/luajsgen/' .. name)
local min = 1
for i = 3, #arg do local m = arg[i]:match('^min=(%d+)$'); if m then min = tonumber(m) end end

local t0 = vim.uv.hrtime()
local files = vim.fs.find(function (n) return n:match('%.lua$') end, { path = corpus, type = 'file', limit = math.huge })
table.sort(files)
local src = {}
for _, f in ipairs(files) do local fd = io.open(f); src[#src + 1] = { f, fd:read('a') }; fd:close() end
local G = GG.derive(src, 'lua')
io.write(('GRAMMAR: %d file(s) read, %d refused, %d kind(s) — derived in %.1f s\n'):format(G.files, #G.refused,
    vim.tbl_count(G.kinds), (vim.uv.hrtime() - t0) / 1e9))
local F = GG.fragment(G, frag)
local dead = F.dead()
if #dead > 0 then io.write('REFUSED: the fragment selects kinds with no derived production: ', table.concat(dead, ' '), '\n'); os.exit(1) end
io.write('COUNT (programs of each size):')
for n = min, max do io.write((' %d:%d'):format(n, F.count(frag.root, n))) end
io.write('\n')

vim.fn.delete(out, 'rf')
local t1 = vim.uv.hrtime()
local res = assert(GC.run({ G = G, name = name, fragment = frag, max = max, min = min, dir = out, repo = REPO,
    corpus = vim.fn.fnamemodify(corpus, ':~'), rev = (function ()
        -- the corpus revision: git HEAD (+ "dirty" when the corpus has uncommitted changes), else none
        local h = vim.system({ 'git', '-C', corpus, 'rev-parse', '--short', 'HEAD' }, { text = true }):wait()
        if h.code ~= 0 then return nil end
        local d = vim.system({ 'git', '-C', corpus, 'status', '--porcelain', '--', '.' }, { text = true }):wait()
        return vim.trim(h.stdout) .. ((d.stdout or '') ~= '' and '+dirty' or '')
    end)() }))
io.write(('FUNNEL (%.1f s):\n'):format((vim.uv.hrtime() - t1) / 1e9))
io.write(('  %4s'):format('size'))
for _, c in ipairs(res.cols) do io.write(('  %12s'):format(c)) end
io.write('\n')
local sizes = vim.tbl_keys(res.funnel); table.sort(sizes)
for _, n in ipairs(sizes) do
    io.write(('  %4d'):format(n))
    for _, c in ipairs(res.cols) do io.write(('  %12d'):format(res.funnel[n][c] or 0)) end
    io.write('\n')
end
io.write(('  %4s'):format('all'))
for _, c in ipairs(res.cols) do io.write(('  %12d'):format(res.total[c])) end
io.write('\n')
local toks = vim.tbl_keys(res.tokens)
table.sort(toks, function (a, b) return res.tokens[a] > res.tokens[b] end)
io.write('COMPARED PROGRAMS HOLDING EACH TOKEN:')
for _, t in ipairs(toks) do io.write((' %s:%d'):format(t, res.tokens[t])) end
io.write('\n')
local by = {}
for _, d in ipairs(res.diverged) do by[d.class] = by[d.class] or {}; table.insert(by[d.class], d) end
for _, class in ipairs { 'value', 'message', 'crash', 'hang' } do
    local l = by[class]
    if l then
        io.write(('DIVERGED %s: %d — smallest first:\n'):format(class, #l))
        for i = 1, math.min(#l, 6) do
            local d = l[i]
            io.write(('  [%d] %s\n      lua: %s\n      js:  %s\n'):format(d.size, d.text,
                (d.lua or '<none>'):gsub('\n', ' | '), (d.js or '<none>'):gsub('\n', ' | ')))
        end
    end
end
-- EVERY divergence, not the six shown: a class is a claim about all of them (out dir / diverged.txt)
do
    local fd = assert(io.open(out .. '/diverged.txt', 'w'))
    for _, d in ipairs(res.diverged) do
        fd:write(('[%s %d] %s\n  lua: %s\n  js:  %s\n'):format(d.class, d.size, d.text, (d.lua or ''):gsub('\n', ' | '), (d.js or ''):gsub('\n', ' | ')))
    end
    fd:close()
    if #res.diverged > 0 then io.write(('ALL %d DIVERGENCES: %s/diverged.txt\n'):format(#res.diverged, out)) end
end
if #res.rejects_translated > 0 then    io.write(('LUA REJECTS, EMITTER TRANSLATED: %d — e.g.:\n'):format(res.total.rejects_translated))
    for i = 1, math.min(#res.rejects_translated, 5) do io.write('  ', res.rejects_translated[i], '\n') end
end
if #res.unreached > 0 then
    io.write('UNREACHED (a token of the fragment no compared program holds — the claim is VACUOUS for it): ',
        table.concat(res.unreached, ' '), '\n')
end
io.write('CLAIM: ', res.label, '\n')
