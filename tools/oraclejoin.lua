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

local JOIN_STATE = {}

-- the vantage the JVM gives Maven's model builder: java.version and os.* (Maven's `unix` family for Linux)
local jvm
local function JVM_VANTAGE()
    if jvm then return jvm end
    local sys = {}
    for line in vim.fn.system({ 'java', '-XshowSettings:properties', '-version' }):gmatch('[^\n]+') do
        local k, v = line:match('^%s+([%w%.]+) = (.*)$')
        if k then sys[k] = v end
    end
    local name = (sys['os.name'] or ''):lower()
    jvm = { sys = sys, jdk = sys['java.version'],
        os = { name = name, family = name == 'linux' and 'unix' or name, arch = sys['os.arch'], version = sys['os.version'] } }
    return jvm
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
            local X = require 'cartograph.xmlvalue'
            local r, why = X.read(src)
            if not r then return nil, why end
            -- decided as EXPAT decides (ElementTree is expat): duplicates and control characters
            -- rejected, internal entities EXPANDED
            local v, twhy = X.decide(r, X.IMPLEMENTATIONS.expat)
            if v == nil then return nil, twhy end
            return { o = { root = r.root, value = v }, keys = { 'root', 'value' } }
        end,
    },
    -- ★ CART-1051: cartograph.pom against MAVEN'S OWN MODEL BUILDER, offline (parents and BOMs from
    -- the tree only, no extension loads). Joined on `pom.projection`, per POM, under the JVM's vantage
    -- (the model builder reads the JVM's java.version and os.*; ours is told the same).
    pom = {
        lang = 'xml',
        repos = { '~/git/hadoop', '~/git/hive', '~/git/wildfly', '~/git/quarkus' },
        match = function(f) return f == 'pom.xml' or f:match('/pom%.xml$') end,
        oracle = { 'python3', REPO .. '/tools/oracles/maven_effective.py' },
        read_input = function(input)
            local P = require 'cartograph.pom'
            local cache = JOIN_STATE.pom or {}
            JOIN_STATE.pom = cache
            if not cache[input.repo] then
                local files = {}
                for _, f in ipairs(J.ls_files(input.repo)) do if f == 'pom.xml' or f:match('/pom%.xml$') then files[#files + 1] = f end end
                -- the same local repository the oracle reads (tools/mavenpoms.lua fills it), or none
                local lr = vim.fn.isdirectory(P.DEFAULT_REPO) == 1 and P.DEFAULT_REPO or nil
                cache[input.repo] = P.read(input.repo, files, { repo = lr })
            end
            local model = cache[input.repo]
            if not model.poms[input.rel] then
                for _, r in ipairs(model.refusals) do if r.path == input.rel then return nil, r.why end end
                return nil, 'not read'
            end
            local eff, why = P.effective(model, input.rel, JVM_VANTAGE())
            if not eff then return nil, why end
            return P.projection(eff)
        end,
    },
}

-- ★ CART-1268: cartograph.k8s's DOCUMENT READING over charts RENDERED BY HELM ITSELF. The inputs are not tracked files
-- but what `helm template --output-dir` emits for every chart under a repo (a subchart under charts/ renders with its
-- parent); a chart Helm refuses is SKIPPED with Helm's reason. Each rendered file is projected — kind, name, the first
-- container's image, every port, every soft-edge reference — by k8s.lua and, independently, by PyYAML
-- (tools/oracles/k8s_docs.py). ⚠ SHARED PREMISE: both walk the DERIVED API paths (exported to the oracle as JSON), so
-- what this joins is the YAML reading and the extraction, not the paths (tools/k8sapi.lua --check guards those).
local function k8s_projection(src)
    local K = require 'cartograph.k8s'
    local docs, refused, why = K.read(src)
    if refused > 0 and #docs == 0 then return nil, table.concat(why, '; ') end
    local a = {}
    for i, d in ipairs(docs) do
        local ports, seen = {}, {}
        for _, p in ipairs(d.ports or {}) do if not seen[p] then seen[p] = true; ports[#ports + 1] = p end end
        table.sort(ports)
        for j, p in ipairs(ports) do ports[j] = tostring(p) end
        local refs = {}
        for _, r in ipairs(d.refs or {}) do
            if r.how == 'name' then refs[#refs + 1] = ('name %s/%s @%s'):format(r.kind, r.name, r.path)
            elseif r.how == 'ref' then refs[#refs + 1] = ('ref %s/%s @%s%s'):format(r.kind, r.name, r.path, r.optional and ' optional' or '')
            elseif r.how == 'selector' then
                local ks = vim.tbl_keys(r.sel); table.sort(ks)
                local kv = {}
                for _, k in ipairs(ks) do kv[#kv + 1] = k .. '=' .. r.sel[k] end
                refs[#refs + 1] = ('selector %s{%s} @%s'):format(r.kind, table.concat(kv, ','), r.path)
            end
        end
        table.sort(refs)
        a[i] = { o = { kind = d.kind or '', name = d.name or '', image = d.image or '', ports = { a = ports }, refs = { a = refs } },
            keys = { 'kind', 'name', 'image', 'ports', 'refs' } }
    end
    return { a = a }
end
JOINS.helm = {
    lang = 'yaml',
    repos = { '~/git/microservices-demo', '~/git/helm/pkg/cmd/testdata/testcharts' },
    collect = function(repos)
        local H = require 'cartograph.helm'
        local inputs, paths, skipped = {}, {}, {}
        local cache = vim.fn.stdpath('cache') .. '/cartograph/helmjoin'
        for _, r in ipairs(repos) do
            local dir = vim.fn.expand(r)
            local charts = vim.fn.globpath(dir, '**/Chart.yaml', false, true)
            table.sort(charts)
            for _, c in ipairs(charts) do
                local cdir = vim.fn.fnamemodify(c, ':h')
                if not cdir:find('/charts/', #dir, true) then
                    local out = cache .. '/' .. vim.fn.sha256(cdir):sub(1, 12)
                    vim.fn.delete(out, 'rf')
                    local R, why = H.render(cdir, { out = out })
                    if not R then skipped[#skipped + 1] = cdir:sub(#dir + 2) .. ' (' .. tostring(why):sub(1, 90) .. ')'
                    else
                        for _, rel in ipairs(R.files) do
                            local p = out .. '/' .. rel
                            -- (the id IS the path: the oracle answers keyed by the path it was handed)
                            inputs[#inputs + 1] = { id = p, path = p }
                            paths[#paths + 1] = p
                        end
                    end
                end
            end
        end
        return inputs, paths, skipped
    end,
    oracle = function()
        local api = require('cartograph.k8s')._api
        local refs = {}
        for _, r in ipairs(api.refs) do refs[#refs + 1] = { r[1], r[2], r[3] or false, r[4] } end
        local tmp = vim.fn.tempname() .. '.json'
        local fd = assert(io.open(tmp, 'w')); fd:write(vim.json.encode({ pod = api.pod, refs = refs })); fd:close()
        return { 'python3', REPO .. '/tools/oracles/k8s_docs.py', tmp }
    end,
    read = k8s_projection,
}

-- ★ CART-1053: yamlvalue's IMPLEMENTATION PROFILES, each joined against the real implementation over
-- the same corpus — what PyYAML/ruamel/Psych/YAML::XS/yq LOAD, every scalar "type:value", against
-- `yamlvalue.typed(doc.raw, profile)`. One row per implementation: `yaml:<name>`.
do
    local oracles = {
        ['pyyaml-safe'] = { 'python3', REPO .. '/tools/oracles/yaml_typed.py', 'pyyaml-safe' },
        ['ruamel-safe'] = { 'python3', REPO .. '/tools/oracles/yaml_typed.py', 'ruamel-safe' },
        ['psych-safe'] = { 'ruby', REPO .. '/tools/oracles/yaml_typed.rb' },
        ['yaml-xs'] = { 'perl', REPO .. '/tools/oracles/yaml_typed.pl' },
        yq = { 'python3', REPO .. '/tools/oracles/yaml_typed_yq.py' },
    }
    for impl, cmd in pairs(oracles) do
        JOINS['yaml:' .. impl] = {
            -- ORDERED: key order is one of the things implementations differ on (where a merge puts
            -- the merged keys), so it is compared, not sorted away
            lang = 'yaml', repos = JOINS.yaml.repos, match = JOINS.yaml.match, oracle = cmd, ordered = true,
            read = function(src)
                local Y = require 'cartograph.yamlvalue'
                local docs, why = Y.read(src)
                if not docs then return nil, why end
                return Y.typed_stream(docs, Y.IMPLEMENTATIONS[impl])
            end,
        }
    end
end

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
-- (a join that BUILDS its inputs — the helm join renders charts — supplies them; every other join lists tracked files)
if spec.collect then inputs, paths, skipped = spec.collect(spec.repos) end
for _, r in ipairs(spec.collect and {} or spec.repos) do
    local dir = vim.fn.expand(r)
    if vim.fn.isdirectory(dir) == 0 then skipped[#skipped + 1] = r .. ' (absent)'
    else
        for _, f in ipairs(J.ls_files(dir)) do
            if spec.match(f) then
                local p = dir .. '/' .. f
                local size = vim.fn.getfsize(p)
                if spec.max_bytes and size > spec.max_bytes then skipped[#skipped + 1] = p .. ' (too large)'
                elseif size >= 0 then
                    inputs[#inputs + 1] = { id = p, path = p, repo = dir, rel = f }
                    paths[#paths + 1] = p
                else
                    inputs[#inputs + 1] = { id = p, path = p } -- a tracked path that is not a readable file
                end
            end
        end
    end
end
local t0 = vim.uv.hrtime()
local map, why = J.external(type(spec.oracle) == 'function' and spec.oracle() or spec.oracle, paths)
if not map then print('the oracle failed: ' .. tostring(why)); os.exit(1) end
local report = J.run {
    inputs = inputs,
    oracle_map = map,
    ordered = spec.ordered,
    read = function(input)
        if spec.read_input then return spec.read_input(input) end
        local src = readf(input.path)
        if not src then return J.UNOPENABLE end
        return spec.read(src)
    end,
}
print(('JOIN %s (%.1f s)'):format(name, (vim.uv.hrtime() - t0) / 1e9))
for _, l in ipairs(J.lines(report, { show = show })) do print(l) end
if #skipped > 0 then print(('skipped: %d  e.g. %s'):format(#skipped, skipped[1])) end
if spec.read_input and JOIN_STATE.pom then
    -- ★ THE VANTAGE'S OWN COUNTER: if the JVM's properties never reached us (they are printed on
    -- stderr), every jdk/os profile stays undecided while Maven applied them, and agreement would
    -- hold only on the axis profiles do not touch
    local lb, judged = 0, 0
    local v = JVM_VANTAGE()
    for _, model in pairs(JOIN_STATE.pom) do
        for rel in pairs(model.poms) do
            local eff = require('cartograph.pom').effective(model, rel, v)
            if eff then judged = judged + 1; if eff.lower_bound then lb = lb + 1 end end
        end
    end
    local n = 0
    for _ in pairs(v.sys) do n = n + 1 end
    print(('vantage: java %s, os %s/%s, %d system properties; %d of %d model(s) still LOWER BOUNDS (undecided profiles)')
        :format(tostring(v.jdk), tostring(v.os.name), tostring(v.os.arch), n, lb, judged))
end
local partial = 0
for _, v in pairs(map) do if v.partial then partial = partial + 1 end end
if partial > 0 then
    print(('oracle PARTIAL: %d model(s) built without imports it may not fetch (the same frontier on both sides)'):format(partial))
end
