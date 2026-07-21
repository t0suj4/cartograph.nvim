-- Django URL adapter: the template ↔ route ↔ view loop. Route
-- registrations (path/re_path/url calls carrying name="...") become
-- ENTITIES — var nodes anchored at the registration site, where the
-- view is one hover away — and everything that NAMES a route links to
-- it: {% url 'ns:name' %} in templates (which join the graph as module
-- nodes) and reverse()/reverse_lazy() calls in code. Matching is by the
-- name's tail after the namespace prefix; a tail registered more than
-- once refuses (ambiguity is disclosed, never guessed).
--
-- What falls out is the wiretap audit at the URL boundary (lint rule
-- route-audit): a {% url %} naming an unregistered route is a template
-- that 500s at render; a registered route nothing names is dead
-- surface; a name registered twice is a collision the resolver decides
-- silently. Session post-pass like dblink: re-derived per open/refresh,
-- never persisted (nodes marked dj = true).

local M = {}
local argv = require 'cartograph.argv'
local callrec = require 'cartograph.callrec'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

local REGISTER = { path = true, re_path = true, url = true }
local LOOKUP = { reverse = true, reverse_lazy = true }

local function tail_of(name)
    return name:match('([^:]+)$')
end

--- PURE: attach routes, templates and links to `data`. Returns stats
--- { routes, templates, links, unregistered = { {name, file, line} },
---   unused = {names}, duplicate = {names} } (also set as data.django).
function M.attach(data)
    -- strip a previous attachment (idempotent under refresh)
    local djids, nodes = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.dj then djids[n.id] = true else nodes[#nodes + 1] = n end
    end
    data.nodes = nodes
    if next(djids) then
        local edges = {}
        for _, e in ipairs(data.edges) do
            if not (e.dj or djids[e.from] or djids[e.to]) then
                edges[#edges + 1] = e
            end
        end
        data.edges = edges
    end

    local xlang = require 'cartograph.xlang'
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

    -- the app's URL NAMESPACE, read from the registering file (oscar
    -- app configs carry `namespace = "basket"` / `app_name = ...`) —
    -- names are only unique WITHIN a namespace (index, summary, detail
    -- recur in every app)
    local ns_cache = {}
    local function ns_of(rel)
        if ns_cache[rel] == nil then
            local ns
            for _, l in ipairs(file_lines(rel) or {}) do
                ns = l:match('namespace%s*=%s*["\']([%w_%-]+)["\']')
                    or l:match('app_name%s*=%s*["\']([%w_%-]+)["\']')
                if ns then break end
            end
            ns_cache[rel] = ns or false
        end
        return ns_cache[rel] or nil
    end

    -- ── registrations: path(..., name="x") → route entities ─────────────
    local by_full = {}   -- 'ns:name' (or bare) -> { reg, ... }
    local stats = { routes = 0, templates = 0, links = 0,
        unregistered = {}, unused = {}, duplicate = {} }
    for _, c in ipairs(data.calls or {}) do
        if REGISTER[callrec.callee(c):match('([%w_]+)$') or ''] then
            local ls = file_lines(callrec.file(c))
            local text = ls and xlang.call_text(root, c, ls) or ''
            local name = text:match('name%s*=%s*["\']([%w_:%-]+)["\']')
            if name then
                local ns = ns_of(callrec.file(c))
                local full = ns and (ns .. ':' .. name) or name
                by_full[full] = by_full[full] or {}
                table.insert(by_full[full],
                    { name = full, file = callrec.file(c), line = c.line })
            end
        end
    end
    local route_node = {} -- full name -> node (unique registrations only)
    local by_tail = {}    -- tail -> { full, ... } (the un-namespaced fallback)
    for full, regs in pairs(by_full) do
        -- same name, same file = Django's legal same-name overloads (the
        -- resolver picks the pattern by arguments): ONE route entity.
        -- Cross-file same-name registrations stay a disclosed collision.
        local samefile = true
        for _, r in ipairs(regs) do
            if r.file ~= regs[1].file then samefile = false break end
        end
        if #regs == 1 or samefile then
            local r = regs[1]
            local node = { id = 'route::' .. full, name = 'route ' .. full,
                kind = 'var', dj = true, file = r.file, order = r.line,
                range = { start = { line = r.line, char = 0 },
                    ['end'] = { line = r.line, char = 0 } } }
            data.nodes[#data.nodes + 1] = node
            route_node[full] = node
            stats.routes = stats.routes + 1
            local t = tail_of(full)
            by_tail[t] = by_tail[t] or {}
            table.insert(by_tail[t], full)
        else
            stats.duplicate[#stats.duplicate + 1] =
                ('%s (%d registrations)'):format(full, #regs)
        end
    end
    table.sort(stats.duplicate)

    local used = {}
    local function link(from_id, name, file, line)
        -- exact namespaced match first; then a globally-unique TAIL —
        -- nested namespaces (dashboard:catalogue-*) rarely match the
        -- file-derived one exactly, but the tail identifies the route
        -- when it is unique. Ambiguity refuses, honestly.
        local hit = route_node[name]
        if not hit then
            local cands = by_tail[tail_of(name) or '']
            if cands and #cands == 1 then hit = route_node[cands[1]] end
        end
        if hit then
            data.edges[#data.edges + 1] = { from = from_id, to = hit.id,
                kind = 'use', dj = true,
                at = { { start = { line = line, char = 0 },
                    ['end'] = { line = line, char = 0 } } } }
            used[hit.id] = true
            stats.links = stats.links + 1
            return true
        end
        stats.unregistered[#stats.unregistered + 1] =
            { name = name, file = file, line = line }
        return false
    end

    -- not a Django project (no named registrations): skip the template
    -- walk entirely — this pass must cost nothing where it finds nothing
    if not next(by_tail) then
        data.django = nil
        return stats
    end

    -- ── templates: modules + {% url 'name' %} references ────────────────
    local function walk(rel)
        local dirp = rel == '' and root or (root .. '/' .. rel)
        local it = vim.uv.fs_scandir(dirp)
        while it do
            local name, ty = vim.uv.fs_scandir_next(it)
            if not name then break end
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if ty == 'directory' then
                    if name ~= 'node_modules' and name ~= 'static' then
                        walk(r)
                    end
                elseif name:match('%.html$') then
                    local ls = file_lines(r)
                    if ls then
                        local refs = {}
                        for i, l in ipairs(ls) do
                            for nm in l:gmatch("{%%%s*url%s+[\"']([%w_:%-]+)[\"']") do
                                refs[#refs + 1] = { nm = nm, line = i - 1 }
                            end
                        end
                        if #refs > 0 then
                            data.nodes[#data.nodes + 1] = { id = r, name = r,
                                kind = 'module', dj = true, file = r,
                                order = -1, range = R0 }
                            stats.templates = stats.templates + 1
                            for _, ref in ipairs(refs) do
                                link(r, ref.nm, r, ref.line)
                            end
                        end
                    end
                end
            end
        end
    end
    walk('')

    -- ── reverse('name') lookups in code ──────────────────────────────────
    for _, c in ipairs(data.calls or {}) do
        if LOOKUP[callrec.callee(c):match('([%w_]+)$') or ''] and c.fn
            and argv.str(c, 1) ~= '' then
            link(c.fn, argv.str(c, 1), callrec.file(c), c.line)
        end
    end

    -- registered but never named anywhere: dead surface
    for _, node in pairs(route_node) do
        if not used[node.id] then
            stats.unused[#stats.unused + 1] =
                node.name:gsub('^route ', '')
        end
    end
    table.sort(stats.unused)
    table.sort(stats.unregistered, function (a, b) return a.name < b.name end)
    data.django = stats
    return stats
end

return M
