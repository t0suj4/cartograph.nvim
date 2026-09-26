-- producers — INPUT PRODUCER CANDIDATES for a tree (CART-1118 v1; the library is lua/cartograph/producers.lua): who
-- CONSUMES it, where the dependencies it selects are on this machine, and who produces the callback OBLIGATIONS its
-- -behaviour lines take on. Every candidate is cited by the line that selects it. A WORK LIST: it finds, it attaches
-- nothing.
--
--   nvim --headless -u NONE -l tools/producers.lua <root> [--search DIR]... [--lib DIR]...
--
-- --search  where to look for other repos' manifests (default ~/git and ~/work; depth 3; node_modules/_build/deps
--           skipped). --lib  an ERL_LIBS-shaped dir (e.g. /usr/lib/erlang/lib) for erlang dependencies.
-- Read-only; no network.
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
local P = require 'cartograph.producers'

local root, search, libs = nil, {}, {}
local i = 1
while arg[i] do
    local a = arg[i]
    if a == '--search' then search[#search + 1] = vim.fn.expand(arg[i + 1]); i = i + 1
    elseif a == '--lib' then libs[#libs + 1] = vim.fn.expand(arg[i + 1]); i = i + 1
    elseif not root then root = vim.fn.fnamemodify(vim.fn.expand(a), ':p'):gsub('/+$', '')
    else io.stderr:write('unknown argument ' .. a .. '\n'); os.exit(2) end
    i = i + 1
end
if not root then io.stderr:write('usage: producers.lua <root> [--search DIR]... [--lib DIR]...\n'); os.exit(2) end
if #search == 0 then search = { vim.fn.expand('~/git'), vim.fn.expand('~/work') } end
local function w(s) io.write(s, '\n') end
local function rel(p) return (p:gsub('^' .. vim.pesc(vim.fn.expand('~')), '~')) end

local repos = P.scan_manifests(search)
local id = P.identity(root)
w(('producers  %s   (%d manifest-bearing repos under %s)'):format(rel(root), #repos, table.concat(vim.tbl_map(rel, search), ', ')))
w(('  identity: %s'):format(id and ('%s (%s)  %s:%d'):format(id.name, id.eco, rel(id.file), id.line) or 'none declared'))

local cons = P.consumers(root, repos)
w(('\n  CONSUMERS (a manifest elsewhere names this tree — found, not selected): %d'):format(#cons))
for _, c in ipairs(cons) do w(('    %s  %s:%d  %s'):format(rel(c.root), rel(c.file), c.line, c.text or '')) end

local deps = P.deps(root)
local att = P.attachable(root, deps, repos, libs)
local found = 0
for _, a in ipairs(att) do if #a.candidates > 0 then found = found + 1 end end
w(('\n  DEPENDENCIES the tree selects: %d, with a candidate source on this machine: %d'):format(#deps, found))
for _, a in ipairs(att) do
    local c = a.candidates[1]
    w(('    %-18s %s:%d  -> %s'):format(a.dep.name, rel(a.dep.file), a.dep.line,
        c and (rel(c.path) .. ' (' .. c.how .. (c.source and ', has src/' or ', no src/') .. ')'
            .. (#a.candidates > 1 and (' +' .. (#a.candidates - 1) .. ' more') or '')) or 'NOT ON THIS MACHINE'))
end

local rows, by = P.obligations(root, att)
local kinds = {}
for _, r in ipairs(rows) do kinds[r.producer.kind] = (kinds[r.producer.kind] or 0) + 1 end
w(('\n  OBLIGATIONS: %d -behaviour line(s); producer of the callbacks: tree %d, dependency %d, runtime %d, NONE %d')
    :format(#rows, kinds.tree or 0, kinds.dependency or 0, kinds.runtime or 0, kinds.NONE or 0))
local bs = {}
for b, x in pairs(by) do bs[#bs + 1] = { b = b, n = x.n, p = x.producer } end
table.sort(bs, function (a, b) return a.n > b.n or (a.n == b.n and a.b < b.b) end)
for _, x in ipairs(bs) do
    w(('    %-26s x%-3d %s%s'):format(x.b, x.n, x.p.kind, x.p.file and ('  ' .. rel(x.p.file)) or ''))
end
