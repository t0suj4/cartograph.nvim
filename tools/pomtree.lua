-- pomtree — the Maven build layer over real trees, one summary block per repo (CART-1051).
--
--   nvim --headless -u NONE -l tools/pomtree.lua <repo>… [--show N] [--profiles a,b] [--jdk 21] [--os linux]
--
-- A repo is a path or a name under ~/git. The POMs are `git ls-files` (NUL-separated), so test
-- fixtures are in the population and land among the ORPHANS (not reachable through <modules>).
-- ★ THE CORPUS NUMBERS OF CART-1051 (links, holes, sources) COME FROM THIS FILE — rerun, do not re-derive.
-- The model's ACCEPTANCE is `tools/oraclejoin.lua pom`: Maven's own model builder, offline (the
-- system Maven's jars; parents and BOMs from the tree only; no build extension loads). This file
-- reports what the model SAYS about a tree; that one checks the model against Maven.

local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local P = require 'cartograph.pom'
local J = require 'cartograph.oraclejoin'

local repos, show, vantage = {}, 3, {}
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == '--show' then show = tonumber(arg[i + 1]); i = i + 1
    elseif a == '--profiles' then
        vantage.profiles = {}
        for id in arg[i + 1]:gmatch('[^,]+') do vantage.profiles[id] = true end
        i = i + 1
    elseif a == '--jdk' then vantage.jdk = arg[i + 1]; i = i + 1
    elseif a == '--os' then vantage.os = { name = arg[i + 1], family = arg[i + 1] == 'linux' and 'unix' or arg[i + 1] }; i = i + 1
    else repos[#repos + 1] = a end
    i = i + 1
end

local function inspect1(t) return vim.inspect(t, { newline = '', indent = '' }) end

for _, repo in ipairs(repos) do
    local dir = repo:find('/', 1, true) and vim.fn.expand(repo) or vim.fn.expand('~/git/' .. repo)
    local files = {}
    for _, f in ipairs(J.ls_files(dir)) do if f == 'pom.xml' or f:match('/pom%.xml$') then files[#files + 1] = f end end
    local t0 = vim.uv.hrtime()
    local lr = vim.fn.isdirectory(P.DEFAULT_REPO) == 1 and P.DEFAULT_REPO or nil
    local model = P.read(dir, files, { repo = lr })
    local A = P.analyze(model, vantage)
    local lb, vf = 0, {}
    for _, e in pairs(A.effective) do if e.lower_bound then lb = lb + 1 end end
    for _, rel in ipairs(A.reactor) do
        for _, d in ipairs(A.effective[rel] and A.effective[rel].deps or {}) do
            local k = d.version_from:match('^(%a+)')
            vf[k] = (vf[k] or 0) + 1
        end
    end
    local classed = A.refs.resolved
    for _, n in pairs(A.refs.holes) do classed = classed + n end
    local ext = 0
    for _, ok in pairs(model.external) do if ok then ext = ext + 1 end end
    print(('%s: %d POM(s), %d refused; reactor %d, orphans %d; parents %s; %d read from the local repository; unread external parents %s')
        :format(repo, #files, #model.refusals, #A.reactor, #A.orphans, inspect1(A.parent_via), ext, inspect1(A.frontiers)))
    print(('  references %d: %d resolved, holes %s%s'):format(A.refs.total, A.refs.resolved, inspect1(A.refs.holes),
        classed == A.refs.total and '' or '  ⚠ UNCLASSED ' .. (A.refs.total - classed)))
    print(('  dependency versions %s; inter-module links %d, version skew %d; no-op overrides %d; missing %d; lower bounds %d  (%.1fs)')
        :format(inspect1(vf), #A.links, #A.skew, #A.noops, #A.missing, lb, (vim.uv.hrtime() - t0) / 1e9))
    for k = 1, math.min(show, #A.holes) do local h = A.holes[k]; print('    undefined', h.path, h.at, h.expr) end
    for k = 1, math.min(show, #A.missing) do local h = A.missing[k]; print('    missing', h.path, h.what, h.dep or h.module) end
    for k = 1, math.min(show, #A.skew) do local h = A.skew[k]; print('    skew', h.from, h.dep, h.want, h.have) end
    for k = 1, math.min(show, #A.noops) do local h = A.noops[k]; print('    no-op', h.path, h.key, tostring(h.value)) end
end
