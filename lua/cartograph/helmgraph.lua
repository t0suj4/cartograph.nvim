-- cartograph.helmgraph — a chart's VALUES IN THE GRAPH (CART-1313): every key path of a chart's values.yaml a `var`
-- node at its line, every template's `.Values` read a `use` edge from the template to the key it reads, SITED at the
-- read. Nothing new to render: the cockpit's existing var view (who reads this var, where) IS "where is this value
-- used", and every analysis that walks var uses walks chart values too. The schema stays closed: a key is a VAR, a
-- template a MODULE, a read a USE (tag `hv`).
-- READS are helmlint's static ones (the `helm` tree-sitter grammar): every branch, helpers included as their own files,
-- no render needed. A read of a path values.yaml does not define links to the nearest key it does define (the reader
-- of `.Values.resources.limits` reads into `resources: {}`); a read of nothing defined is counted (helmlint names it).
-- ⚠ Each chart (and each vendored subchart) is its own scope: a parent's `sub.x` override is not linked to the
-- subchart's read of `.Values.x` (value origins, CART-1307, answer that per render).
local M = {}

local function readf(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

-- the chart roots of a graph: every directory holding a Chart.yaml (from the yaml files the k8s walk finds)
function M.charts(root, files)
    local out = {}
    for _, rel in ipairs(files or require('cartograph.k8s').find(root)) do
        local dir = rel:match('^(.*)/Chart%.ya?ml$') or (rel:match('^Chart%.ya?ml$') and '.')
        if dir then out[#out + 1] = dir end
    end
    table.sort(out)
    return out
end

--- mint every chart's values and reads into `data` (idempotent) -> stats { charts, keys, templates, reads, edges, sites,
--- undefined }
function M.attach(data, opts)
    local stats = { charts = 0, keys = 0, templates = 0, reads = 0, edges = 0, sites = 0, undefined = 0, relative = 0 }
    if not data or not data.root then return stats end
    local keep, mine = {}, {}
    for _, n in ipairs(data.nodes or {}) do if n.hv then mine[n.id] = true else keep[#keep + 1] = n end end
    if next(mine) then
        local edges = {}
        for _, e in ipairs(data.edges or {}) do if not (e.hv or mine[e.from] or mine[e.to]) then edges[#edges + 1] = e end end
        data.nodes, data.edges = keep, edges
    end
    data.nodes, data.edges = data.nodes or {}, data.edges or {}
    local have = {}
    for _, n in ipairs(data.nodes) do have[n.id] = true end
    local function module(rel, tag)
        if have[rel] then return end
        have[rel] = true
        data.nodes[#data.nodes + 1] = { id = rel, name = rel, kind = 'module', file = rel, order = 0, hv = tag,
            range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } } }
    end
    local P = require 'cartograph.helmprov'
    local L = require 'cartograph.helmlint'
    for _, dir in ipairs((opts and opts.charts) or M.charts(data.root, opts and opts.files)) do
        local prefix = dir == '.' and '' or (dir .. '/')
        local vrel = prefix .. 'values.yaml'
        local vsrc = readf(data.root .. '/' .. vrel)
        if vsrc then
            stats.charts = stats.charts + 1
            module(vrel, 'values')
            local lines = P.key_lines(vsrc)
            local keys = {}
            local paths = vim.tbl_keys(lines)
            table.sort(paths)
            for _, path in ipairs(paths) do
                if not path:find('[', 1, true) then -- (a list item is not a key: Helm reads a list whole)
                    local l = lines[path] - 1
                    local id = vrel .. '::' .. path
                    keys[path] = id
                    data.nodes[#data.nodes + 1] = { id = id, name = path, kind = 'var', file = vrel, order = l, hv = 'key',
                        range = { start = { line = l, char = 0 }, ['end'] = { line = l, char = 0 } } }
                    stats.keys = stats.keys + 1
                end
            end
            local tdir = data.root .. '/' .. prefix .. 'templates'
            for _, f in ipairs(vim.fn.globpath(tdir, '**/*', false, true)) do
                if vim.fn.isdirectory(f) == 0 then
                    local trel = f:sub(#data.root + 2)
                    local src = readf(f) or ''
                    local reads = L.reads(src) or {}
                    if #reads > 0 then
                        stats.templates = stats.templates + 1
                        module(trel, 'template')
                        local by = {}
                        for _, r in ipairs(reads) do
                            stats.reads = stats.reads + 1
                            if r.relative then stats.relative = stats.relative + 1
                            else
                                local p, id = r.path, nil
                                for _ = 1, 50 do
                                    id = keys[p]
                                    if id or not p:find('.', 1, true) then break end
                                    p = p:gsub('%.[^.]*$', '')
                                end
                                if not id then stats.undefined = stats.undefined + 1
                                else
                                    local e = by[id]
                                    if not e then
                                        e = { from = trel, to = id, kind = 'use', at = {}, rw = 1, hv = 'reads' }
                                        by[id] = e
                                        data.edges[#data.edges + 1] = e
                                        stats.edges = stats.edges + 1
                                    end
                                    local l = (r.line or 1) - 1
                                    e.at[#e.at + 1] = { start = { line = l, char = 0 }, ['end'] = { line = l, char = 0 } }
                                    stats.sites = stats.sites + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    data.helmgraph = stats
    return stats
end

function M.summary(s)
    if not s or s.charts == 0 then return nil end
    return ('helm values: %d chart(s), %d key(s) as vars, %d template(s) reading them — %d use edge(s), %d read site(s)%s%s')
        :format(s.charts, s.keys, s.templates, s.edges, s.sites,
            s.undefined > 0 and (', %d read(s) of nothing values.yaml defines'):format(s.undefined) or '',
            s.relative > 0 and (', %d relative read(s) inside with/range not linked'):format(s.relative) or '')
end

return M
