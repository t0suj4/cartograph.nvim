-- oraclejoin — run a registered READER-vs-ORACLE join over real corpora (CART-1044).
--
--   nvim --headless -u NONE -l tools/oraclejoin.lua <join> [--repos a,b,…] [--show N]
--
-- The harness is `cartograph.oraclejoin`; this file only REGISTERS joins: which files, which of
-- our readers, which oracle (a script in tools/oracles/ that reads NUL-separated paths). A new
-- reader gets its acceptance test by adding a row here, not by writing a sixth join script.

local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local J = require 'cartograph.oraclejoin'

local function readf(p)
    local fd = io.open(p, 'rb')
    if not fd then return nil end
    local s = fd:read('*a'); fd:close()
    return s
end

local JOINS = {
    yaml = {
        lang = 'yaml',
        repos = { '~/git/jenkins-infra/kubernetes-management', '~/git/jenkins-infra/jenkins-infra',
            '~/git/jenkins-infra/packer-images', '~/git/jenkins-infra/azure', '~/git/jenkins-infra/datadog',
            '~/git/jenkins-infra/digitalocean', '~/git/jenkins-infra/fastly', '~/git/jenkins-infra/docker-geoipupdate',
            '~/git/jenkins-infra/github-reusable-workflows', '~/git/jenkins-infra/jenkins-security-scan',
            '~/git/jenkins-infra/plugin-modernizer-stats', '~/git/jenkins-infra/update-center2',
            '~/git/jenkins-infra/backend-extension-indexer' },
        match = function(f) return f:match('%.ya?ml$') end,
        oracle = { 'python3', REPO .. '/tools/oracles/yaml_baseloader.py' },
        read = function(src)
            local docs, why = require('cartograph.yamlvalue').read(src)
            if not docs then return nil, why end
            local a = {}
            for i, d in ipairs(docs) do a[i] = d.value end
            return { a = a }
        end,
    },
    xml = {
        lang = 'xml',
        repos = { '~/git/wildfly', '~/git/quarkus', '~/git/hive', '~/git/tspannhw-hive', '~/git/hadoop',
            '~/git/jenkins-infra/update-center2', '~/git/jenkins-infra/backend-extension-indexer' },
        match = function(f) return f:match('%.xml$') end,
        oracle = { 'python3', REPO .. '/tools/oracles/xml_elementtree.py' },
        max_bytes = 3000000,
        read = function(src)
            local r, why = require('cartograph.xmlvalue').read(src)
            if not r then return nil, why end
            return { o = { root = r.root, value = r.value }, keys = { 'root', 'value' } }
        end,
    },
}

local name = arg[1]
local spec = name and JOINS[name]
if not spec then
    local ks = {}
    for k in pairs(JOINS) do ks[#ks + 1] = k end
    table.sort(ks)
    print('usage: oraclejoin <join> [--repos a,b] [--show N]   joins: ' .. table.concat(ks, ', '))
    os.exit(2)
end
local show = 5
for i = 2, #arg do
    if arg[i] == '--repos' and arg[i + 1] then
        local rs = {}
        for r in arg[i + 1]:gmatch('[^,]+') do rs[#rs + 1] = r end
        spec.repos = rs
    elseif arg[i] == '--show' and arg[i + 1] then show = tonumber(arg[i + 1]) or show end
end
pcall(vim.treesitter.language.add, spec.lang)

local inputs, paths, skipped = {}, {}, {}
for _, r in ipairs(spec.repos) do
    local dir = vim.fn.expand(r)
    if vim.fn.isdirectory(dir) == 0 then skipped[#skipped + 1] = r .. ' (absent)'
    else
        for _, f in ipairs(J.ls_files(dir)) do
            if spec.match(f) then
                local p = dir .. '/' .. f
                local size = vim.fn.getfsize(p)
                if spec.max_bytes and size > spec.max_bytes then skipped[#skipped + 1] = p .. ' (too large)'
                elseif size >= 0 then
                    inputs[#inputs + 1] = { id = p, path = p }
                    paths[#paths + 1] = p
                else
                    inputs[#inputs + 1] = { id = p, path = p } -- a tracked path that is not a readable file
                end
            end
        end
    end
end
local t0 = vim.uv.hrtime()
local map, why = J.external(spec.oracle, paths)
if not map then print('the oracle failed: ' .. tostring(why)); os.exit(1) end
local report = J.run {
    inputs = inputs,
    oracle_map = map,
    read = function(input)
        local src = readf(input.path)
        if not src then return J.UNOPENABLE end
        return spec.read(src)
    end,
}
print(('JOIN %s (%.1f s)'):format(name, (vim.uv.hrtime() - t0) / 1e9))
for _, l in ipairs(J.lines(report, { show = show })) do print(l) end
if #skipped > 0 then print(('skipped: %d  e.g. %s'):format(#skipped, skipped[1])) end
