-- Symfony routing adapter: the twig ↔ route ↔ controller loop — the
-- yaml-config sibling of django.lua. Routes DECLARED in config/routes*.yaml
-- (a leaf route is a top-level key with a `path:`) become ENTITIES (var
-- nodes anchored at their yaml declaration). The `controller:` they name
-- links to its method node (the view, one hover away); everything that
-- NAMES a route links to it — path('name')/url('name') in .twig,
-- generateUrl/redirectToRoute('name') in php (the reverse() analog). Twig
-- files join the graph as module nodes; {% extends %}/{% include %} become
-- template edges when the target resolves inside the tree (bundle aliases
-- like @SyliusAdmin/… point outside it and stay a disclosed frontier).
--
-- What falls out is the same URL-boundary audit django feeds (route-audit):
-- a path()/generateUrl naming an unregistered route is a runtime 500; a
-- route nothing names is dead surface; a name declared twice is a collision
-- the router resolves silently. Session post-pass like django/dblink:
-- re-derived per open/refresh, never persisted (nodes/edges marked sf=true).

local M = {}
local argv = require 'cartograph.argv'
local callrec = require 'cartograph.callrec'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

-- php calls that NAME a route by its first string arg
local LOOKUP = { generateUrl = true, redirectToRoute = true }

-- App\Controller\Foo::bar -> Foo::bar ; App\Controller\Foo -> Foo::__invoke.
-- def keys are the bare class name (last '\' segment) + method, so a
-- namespaced controller matches its extracted method node.
local function controller_key(ctrl)
    ctrl = ctrl:gsub('%s', '')
    local cls, meth = ctrl:match('^(.-)::([%w_]+)$')
    if not cls then cls, meth = ctrl, '__invoke' end
    local bare = cls:match('[^\\]+$')
    return bare and (bare .. '::' .. meth) or nil
end

function M.attach(data)
    -- strip a previous attachment (idempotent under refresh)
    local sfids, nodes = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.sf then sfids[n.id] = true else nodes[#nodes + 1] = n end
    end
    data.nodes = nodes
    if next(sfids) then
        local edges = {}
        for _, e in ipairs(data.edges) do
            if not (e.sf or sfids[e.from] or sfids[e.to]) then
                edges[#edges + 1] = e
            end
        end
        data.edges = edges
    end

    local root = data.root
    local lines_cache = {}
    local function file_lines(rel)
        if lines_cache[rel] == nil then
            local fd = io.open(root .. '/' .. rel, 'r')
            lines_cache[rel] = fd
                and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        return lines_cache[rel]
    end

    -- name -> {method nodes}: controller resolution, ambiguity-aware
    local byname = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'method' or n.kind == 'function' then
            byname[n.name] = byname[n.name] or {}
            table.insert(byname[n.name], n)
        end
    end

    local stats = { routes = 0, templates = 0, links = 0,
        controllers = 0, external = 0, imports = 0, unmatched = 0,
        unregistered = {}, unused = {}, duplicate = {}, unresolved = {} }

    -- ── config/routes*.yaml : leaf routes (a top-level key with a path) ──
    local function parse_yaml(rel, routes)
        local ls = file_lines(rel)
        if not ls then return end
        local cur
        for i, l in ipairs(ls) do
            -- a column-0 identifier key opens a new block
            local key = l:match('^([%w_%.%-]+):')
            if key and not l:match('^%s') then
                cur = { name = key, file = rel, line = i - 1 }
                routes[#routes + 1] = cur
            elseif cur then
                if l:match('^%s+path:') then cur.has_path = true end
                -- a `resource:` block imports/generates routes we cannot
                -- enumerate here (bundle files, the sylius resource loader):
                -- a completeness signal, NOT a leaf route
                if l:match('^%s+resource:') then cur.is_import = true end
                local ctrl = l:match('^%s+_?controller:%s*(.-)%s*$')
                if ctrl and ctrl ~= '' then
                    cur.controller = ctrl:gsub('^["\']', ''):gsub('["\']$', '')
                end
                local tmpl = l:match('^%s+template:%s*(.-)%s*$')
                if tmpl and tmpl ~= '' then
                    cur.template = tmpl:gsub('^["\']', ''):gsub('["\']$', '')
                end
            end
        end
    end

    -- discover route yaml across the tree: config/routes*, config/routes/**,
    -- and bundle routing files (**/Resources/config/routing*, routing/**).
    -- A routing FILE is identified by its PATH — never services.yaml, which
    -- also has top-level keys and `resource:` blocks.
    local routes_raw = {}
    local function is_routing(rel, name)
        if name == 'routing.yml' or name == 'routing.yaml'
            or name == 'routes.yml' or name == 'routes.yaml' then return true end
        if not name:match('%.ya?ml$') then return false end
        return rel:find('/routing/', 1, true) or rel:find('/routes/', 1, true)
    end
    local function scan_yaml(rel)
        local dirp = rel == '' and root or (root .. '/' .. rel)
        local it = vim.uv.fs_scandir(dirp)
        while it do
            local name, ty = vim.uv.fs_scandir_next(it)
            if not name then break end
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if ty == 'directory' then
                    if name ~= 'vendor' and name ~= 'node_modules'
                        and name ~= 'var' then scan_yaml(r) end
                elseif is_routing(r, name) then
                    parse_yaml(r, routes_raw)
                end
            end
        end
    end
    scan_yaml('')

    -- ── route entities + controller links ───────────────────────────────
    local seen = {}          -- name -> first route (dup detection)
    local route_node = {}    -- name -> entity node
    for _, rt in ipairs(routes_raw) do
        if rt.is_import then stats.imports = stats.imports + 1 end
        if rt.has_path then
            if seen[rt.name] then
                -- same name declared twice: a collision the router resolves
                -- silently (unless it is the exact same file+line re-read)
                if not route_node[rt.name] then goto continue end
                stats.duplicate[#stats.duplicate + 1] = rt.name
                route_node[rt.name] = nil
                goto continue
            end
            seen[rt.name] = rt
            local node = { id = 'sfroute::' .. rt.name, name = 'route ' .. rt.name,
                kind = 'var', sf = true, file = rt.file, order = rt.line,
                range = { start = { line = rt.line, char = 0 },
                    ['end'] = { line = rt.line, char = 0 } } }
            data.nodes[#data.nodes + 1] = node
            route_node[rt.name] = node
            stats.routes = stats.routes + 1
            -- link the controller method (the view), when it is ours
            if rt.controller then
                local k = controller_key(rt.controller)
                local cands = k and byname[k]
                if cands and #cands == 1 then
                    data.edges[#data.edges + 1] = { from = node.id,
                        to = cands[1].id, kind = 'use', sf = true,
                        at = { { start = { line = rt.line, char = 0 },
                            ['end'] = { line = rt.line, char = 0 } } } }
                    stats.controllers = stats.controllers + 1
                else
                    -- framework / vendored controller (TemplateController,
                    -- RedirectController) or ambiguous: honest frontier
                    stats.external = stats.external + 1
                end
            end
        end
        ::continue::
    end
    -- dedup produced entries out of order; keep them tidy
    table.sort(stats.duplicate)
    for _, name in ipairs(stats.duplicate) do route_node[name] = nil end

    -- a name still in route_node after dup-stripping is a live entity
    local live = {}
    for name, node in pairs(route_node) do if node then live[name] = node end end

    local used, unmatched = {}, {}
    local function link(from_id, name, file, line)
        local hit = live[name]
        if hit then
            data.edges[#data.edges + 1] = { from = from_id, to = hit.id,
                kind = 'use', sf = true,
                at = { { start = { line = line, char = 0 },
                    ['end'] = { line = line, char = 0 } } } }
            used[hit.id] = true
            stats.links = stats.links + 1
            return true
        end
        unmatched[#unmatched + 1] = { name = name, file = file, line = line }
        return false
    end

    -- not a Symfony routing project: cost nothing where it finds nothing
    if not next(live) and stats.routes == 0 then
        data.symfony = nil
        return stats
    end

    -- ── twig: module nodes, path()/url() route refs, template edges ─────
    -- index twig files by relative path for {% extends/include %} resolution
    local twig_files = {}
    local twig_node = {}
    local function scan_twig(rel)
        local dirp = rel == '' and root or (root .. '/' .. rel)
        local it = vim.uv.fs_scandir(dirp)
        while it do
            local name, ty = vim.uv.fs_scandir_next(it)
            if not name then break end
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if ty == 'directory' then
                    if name ~= 'vendor' and name ~= 'node_modules'
                        and name ~= 'var' then scan_twig(r) end
                elseif name:match('%.twig$') then
                    twig_files[#twig_files + 1] = r
                end
            end
        end
    end
    scan_twig('')

    local function ensure_twig(rel)
        if twig_node[rel] then return twig_node[rel] end
        local node = { id = rel, name = rel, kind = 'module', sf = true,
            file = rel, order = -1, range = R0 }
        data.nodes[#data.nodes + 1] = node
        twig_node[rel] = node
        stats.templates = stats.templates + 1
        return node
    end

    -- resolve a {% extends/include %} target to a real twig in the tree.
    -- app-relative paths resolve against the tree; @Bundle/… aliases point
    -- into vendored/bundle Resources dirs we don't map, so they stay frontier.
    local by_rel = {}
    for _, r in ipairs(twig_files) do by_rel[r] = true end
    local function resolve_twig(spec_path, from_rel)
        if spec_path:sub(1, 1) == '@' then return nil end -- bundle alias: frontier
        if by_rel[spec_path] then return spec_path end
        -- try under common template roots and relative to the referrer
        local dir = from_rel:match('^(.*)/[^/]*$') or ''
        for _, cand in ipairs({
            spec_path,
            'templates/' .. spec_path,
            (dir ~= '' and dir .. '/' .. spec_path or spec_path),
        }) do
            if by_rel[cand] then return cand end
        end
        return nil
    end

    for _, rel in ipairs(twig_files) do
        local ls = file_lines(rel)
        if ls then
            local route_refs, tmpl_refs = {}, {}
            for i, l in ipairs(ls) do
                for nm in l:gmatch("path%(%s*['\"]([%w_%.%-]+)['\"]") do
                    route_refs[#route_refs + 1] = { nm = nm, line = i - 1 }
                end
                for nm in l:gmatch("url%(%s*['\"]([%w_%.%-]+)['\"]") do
                    route_refs[#route_refs + 1] = { nm = nm, line = i - 1 }
                end
                for tp in l:gmatch("{%%%s*extends%s*['\"]([^'\"]+)['\"]") do
                    tmpl_refs[#tmpl_refs + 1] = { tp = tp, line = i - 1 }
                end
                for tp in l:gmatch("{%%%s*include%s*['\"]([^'\"]+)['\"]") do
                    tmpl_refs[#tmpl_refs + 1] = { tp = tp, line = i - 1 }
                end
            end
            if #route_refs > 0 or #tmpl_refs > 0 then
                local node = ensure_twig(rel)
                for _, ref in ipairs(route_refs) do
                    link(node.id, ref.nm, rel, ref.line)
                end
                for _, ref in ipairs(tmpl_refs) do
                    local tgt = resolve_twig(ref.tp, rel)
                    if tgt then
                        local tn = ensure_twig(tgt)
                        data.edges[#data.edges + 1] = { from = node.id,
                            to = tn.id, kind = 'use', sf = true,
                            at = { { start = { line = ref.line, char = 0 },
                                ['end'] = { line = ref.line, char = 0 } } } }
                    else
                        stats.unresolved[#stats.unresolved + 1] =
                            { tp = ref.tp, file = rel, line = ref.line }
                    end
                end
            end
        end
    end
    -- link routes whose defaults.template names a resolved twig
    for _, rt in ipairs(routes_raw) do
        if rt.template and live[rt.name] then
            local tgt = resolve_twig(rt.template, rt.file)
            if tgt then
                local tn = ensure_twig(tgt)
                data.edges[#data.edges + 1] = { from = live[rt.name].id,
                    to = tn.id, kind = 'use', sf = true,
                    at = { { start = { line = rt.line, char = 0 },
                        ['end'] = { line = rt.line, char = 0 } } } }
            end
        end
    end

    -- ── php: generateUrl/redirectToRoute('name') ────────────────────────
    for _, c in ipairs(data.calls or {}) do
        if LOOKUP[callrec.callee(c):match('([%w_]+)$') or ''] and callrec.fn(c)
            and argv.str(c, 1) ~= '' then
            link(callrec.fn(c), argv.str(c, 1), callrec.file(c), callrec.line(c))
        end
    end

    -- discovery is PARTIAL when the config imports/generates routes we can't
    -- enumerate (resource: blocks, the sylius resource loader). Then we must
    -- NOT claim a ref is unregistered or a route is dead — we only disclose
    -- the counts. With zero imports, route discovery is complete and the
    -- audit is authoritative (the plain-yaml / small-app case).
    stats.partial = stats.imports > 0
    stats.unmatched = #unmatched
    local dead = {}
    for name, node in pairs(live) do
        if not used[node.id] then dead[#dead + 1] = name end
    end
    if not stats.partial then
        table.sort(unmatched, function (a, b) return a.name < b.name end)
        stats.unregistered = unmatched
        table.sort(dead)
        stats.unused = dead
    end
    data.symfony = stats
    return stats
end

return M
