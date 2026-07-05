-- Ansible adapter: the notify ↔ handler loop + the include graph. Ansible
-- is a YAML task graph, not code with functions/calls, so this is an
-- attach() post-pass (the django/symfony mold) that parses playbooks and
-- roles with the `yaml` tree-sitter parser and builds neutral nodes/edges.
--
-- Handlers become ENTITIES (var nodes at their definition). Every `notify:`
-- links to the handler it names — this is the wiretap listener pattern:
-- a notify naming no handler is a SILENT no-op (the handler never runs, no
-- error), the classic Ansible footgun. `include_tasks`/`import_tasks` join
-- task files; `include_role`/`import_role` join roles. What falls out is
-- the ansible-audit lint: no-op notifies, handlers nothing notifies (dead),
-- and includes pointing at a file that isn't there.
--
-- Anchors/aliases are resolved (`notify: *x` where `&x` lists handlers
-- elsewhere — the CIS repos lean on this). A notify whose name is a jinja
-- expression ({{ }}) is DYNAMIC, not a no-op — disclosed, never guessed.
-- Session post-pass like django/dblink: re-derived per open/refresh, never
-- persisted (nodes/edges marked an=true). Needs the yaml parser; without it
-- the pass is skipped (see :checkhealth cartograph).

local M = {}

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

local SCALAR = { plain_scalar = true, single_quote_scalar = true,
    double_quote_scalar = true, string_scalar = true }

-- the string value of a scalar node (flow_node-wrapped or bare), quotes
-- stripped; nil if the node is a mapping/sequence/alias
local function scalar_text(node, src)
    if not node then return nil end
    if node:type() == 'flow_node' then node = node:named_child(0) end
    if not node then return nil end
    local t = node:type()
    if not SCALAR[t] then return nil end
    local s = vim.treesitter.get_node_text(node, src)
    if t == 'single_quote_scalar' or t == 'double_quote_scalar' then
        s = s:sub(2, -2)
    end
    return s
end

-- the alias name of a `*x` value node, or nil
local function alias_name(node, src)
    if node and node:type() == 'flow_node' then node = node:named_child(0) end
    if node and node:type() == 'alias' then
        local an = node:named_child(0)
        return an and vim.treesitter.get_node_text(an, src) or nil
    end
end

local function seq_of(node)
    if not node then return nil end
    if node:type() == 'block_sequence' or node:type() == 'flow_sequence' then
        return node
    end
    if node:type() == 'block_node' or node:type() == 'flow_node' then
        for c in node:iter_children() do
            if c:type() == 'block_sequence' or c:type() == 'flow_sequence' then
                return c
            end
        end
    end
end

local function map_of(node)
    if not node then return nil end
    if node:type() == 'block_mapping' or node:type() == 'flow_mapping' then
        return node
    end
    if node:type() == 'block_node' or node:type() == 'flow_node' then
        for c in node:iter_children() do
            if c:type() == 'block_mapping' or c:type() == 'flow_mapping' then
                return c
            end
        end
    end
end

-- the top-level sequence of a document: stream > document > block_node > seq
local function top_sequence(tree)
    local n = tree
    for _, want in ipairs({ 'document', 'block_node' }) do
        local nx
        for c in n:iter_children() do
            if c:type() == want then nx = c; break end
        end
        n = nx
        if not n then return nil end
    end
    return seq_of(n)
end

-- (key_string, value_node) of a block_mapping_pair
local function pair_kv(pair, src)
    local k = pair:named_child(0)
    return k and scalar_text(k, src), pair:named_child(1)
end

-- last dotted segment of a module key: ansible.builtin.include_tasks -> include_tasks
local function short_key(k)
    return k and (k:match('([%w_]+)$') or k) or nil
end

local INCLUDE_TASKS = { include_tasks = true, import_tasks = true }
local INCLUDE_ROLE = { include_role = true, import_role = true }

function M.attach(data)
    -- strip a previous attachment (idempotent under refresh)
    local anids, nodes = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.an then anids[n.id] = true else nodes[#nodes + 1] = n end
    end
    data.nodes = nodes
    if next(anids) then
        local edges = {}
        for _, e in ipairs(data.edges) do
            if not (e.an or anids[e.from] or anids[e.to]) then
                edges[#edges + 1] = e
            end
        end
        data.edges = edges
    end

    local stats = { handlers = 0, notifies = 0, links = 0, includes = 0,
        noop = {}, dead = {}, broken = {}, dynamic = 0 }
    if not pcall(vim.treesitter.get_string_parser, '', 'yaml') then
        data.ansible = nil
        return stats -- no yaml parser: skip, health reports it
    end
    local root = data.root

    -- ── scan the tree for yaml files (skip vendored/molecule/hidden) ────
    local files = {}
    local function scan(rel)
        local dirp = rel == '' and root or (root .. '/' .. rel)
        local it = vim.uv.fs_scandir(dirp)
        while it do
            local name, ty = vim.uv.fs_scandir_next(it)
            if not name then break end
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if ty == 'directory' then
                    if name ~= 'molecule' and name ~= 'node_modules'
                        and name ~= '.git' and name ~= 'collections' then scan(r) end
                elseif name:match('%.ya?ml$') then
                    files[#files + 1] = r
                end
            end
        end
    end
    scan('')
    if #files == 0 then data.ansible = nil; return stats end
    local fileset = {}
    for _, f in ipairs(files) do fileset[f] = true end

    -- parse once; keep tree/src/anchors per file
    local parsed = {}
    for _, rel in ipairs(files) do
        local fd = io.open(root .. '/' .. rel, 'r')
        if fd then
            local src = fd:read('a'); fd:close()
            local okp, tree = pcall(function ()
                return vim.treesitter.get_string_parser(src, 'yaml'):parse()[1]:root()
            end)
            if okp and tree then
                -- anchor table: anchor_name -> anchored value node
                local anchors = {}
                local function find_anchors(n)
                    if n:type() == 'anchor' then
                        local nm = n:named_child(0)
                        local val = n:next_named_sibling() or n:parent()
                        if nm then anchors[vim.treesitter.get_node_text(nm, src)] = val end
                    end
                    for c in n:iter_children() do
                        if c:named() then find_anchors(c) end
                    end
                end
                find_anchors(tree)
                parsed[rel] = { tree = tree, src = src, anchors = anchors }
            end
        end
    end

    -- ── pass 1: handler entities (from handlers files + handlers: blocks) ─
    -- a name is one handler; a `listen:` topic is a MANY-to-many trigger —
    -- several handlers can listen to one topic, and notify fires them ALL,
    -- so a key maps to a LIST of handler nodes, not one.
    local handler_by_name = {}   -- name -> entity node (dedup)
    local by_key = {}            -- name/topic -> { node, ... } notify targets
    local handlers_list = {}
    local function register_key(k, node)
        by_key[k] = by_key[k] or {}
        for _, n in ipairs(by_key[k]) do if n == node then return end end
        by_key[k][#by_key[k] + 1] = node
    end
    local function add_handler(seq, rel, src)
        if not seq then return end
        for item in seq:iter_children() do
            if item:type() == 'block_sequence_item' then
                local m = map_of(item:named_child(0))
                if m then
                    local hname, listens, line
                    for p in m:iter_children() do
                        if p:type() == 'block_mapping_pair' then
                            local k, v = pair_kv(p, src)
                            local sk = short_key(k)
                            if sk == 'name' then
                                hname = scalar_text(v, src)
                                line = select(1, p:range())
                            elseif sk == 'listen' then
                                local s = scalar_text(v, src)
                                if s then
                                    listens = listens or {}
                                    listens[#listens + 1] = s
                                else
                                    local ls = seq_of(v)
                                    if ls then
                                        for li in ls:iter_children() do
                                            if li:type() == 'block_sequence_item' then
                                                local lt = scalar_text(li:named_child(0), src)
                                                if lt then
                                                    listens = listens or {}
                                                    listens[#listens + 1] = lt
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if hname then
                        local node = handler_by_name[hname]
                        if not node then
                            node = { id = 'handler::' .. hname,
                                name = 'handler ' .. hname, kind = 'var',
                                an = true, file = rel, order = line or 0,
                                range = { start = { line = line or 0, char = 0 },
                                    ['end'] = { line = line or 0, char = 0 } } }
                            data.nodes[#data.nodes + 1] = node
                            handler_by_name[hname] = node
                            handlers_list[#handlers_list + 1] = node
                            stats.handlers = stats.handlers + 1
                        end
                        register_key(hname, node)
                        for _, topic in ipairs(listens or {}) do
                            register_key(topic, node)
                        end
                    end
                end
            end
        end
    end
    for rel, pf in pairs(parsed) do
        -- whole-file handlers: a file under a handlers/ dir
        if rel:find('/handlers/', 1, true) or rel:find('^handlers/') then
            add_handler(top_sequence(pf.tree), rel, pf.src)
        end
        -- `handlers:` blocks anywhere (playbooks)
        local function find_handler_blocks(n)
            if n:type() == 'block_mapping_pair' then
                local k, v = pair_kv(n, pf.src)
                if short_key(k) == 'handlers' then add_handler(seq_of(v), rel, pf.src) end
            end
            for c in n:iter_children() do
                if c:named() then find_handler_blocks(c) end
            end
        end
        find_handler_blocks(pf.tree)
    end

    -- ── pass 2: notify links + include edges ────────────────────────────
    local used = {}
    -- static prefixes of DYNAMIC notifies (`notify: "Remount {{ mp }}"` →
    -- "Remount "): a handler key starting with one is plausibly triggered at
    -- runtime, so it must NOT be called dead. Empty prefixes (a bare
    -- `{{ var }}`) are ignored — they'd match everything and gut the audit.
    local dyn_prefixes = {}
    -- ensure a module node for a task file that participates (source of edges)
    local file_node = {}
    local function ensure_file(rel)
        if file_node[rel] then return file_node[rel] end
        local node = { id = rel, name = rel, kind = 'module', an = true,
            file = rel, order = -1, range = R0 }
        data.nodes[#data.nodes + 1] = node
        file_node[rel] = node
        return node
    end

    local function collect_notify(vnode, src, anchors, out)
        local al = alias_name(vnode, src)
        if al and anchors[al] then vnode = anchors[al] end
        local s = scalar_text(vnode, src)
        if s then out[#out + 1] = s; return end
        local seq = seq_of(vnode)
        if seq then
            for item in seq:iter_children() do
                if item:type() == 'block_sequence_item' then
                    local iv = item:named_child(0)
                    local ial = alias_name(iv, src)
                    if ial and anchors[ial] then iv = anchors[ial] end
                    local is = scalar_text(iv, src)
                    if is then out[#out + 1] = is end
                end
            end
        end
    end

    -- resolve an include_tasks target (relative to the file, then role tasks/)
    local function resolve_include(target, from_rel)
        if target:find('{{', 1, true) then return nil, true end -- dynamic
        local dir = from_rel:match('^(.*)/[^/]*$') or ''
        -- the role's tasks/ dir (Ansible's include_tasks fallback): the path
        -- up to the `tasks` SEGMENT, at root (^tasks/) or nested (…/tasks/)
        local troot = from_rel:match('^(.-/tasks)/') or from_rel:match('^(tasks)/')
        for _, cand in ipairs({
            (dir ~= '' and dir .. '/' .. target or target),
            target,
            troot and (troot .. '/' .. target) or nil,
        }) do
            if cand and fileset[cand] then return cand end
        end
        return nil
    end

    for rel, pf in pairs(parsed) do
        local src, anchors = pf.src, pf.anchors
        local function visit(n)
            if n:type() == 'block_mapping_pair' then
                local k, v = pair_kv(n, src)
                local sk = short_key(k)
                if sk == 'notify' and v then
                    local names = {}
                    collect_notify(v, src, anchors, names)
                    local line = select(1, n:range())
                    for _, nm in ipairs(names) do
                        stats.notifies = stats.notifies + 1
                        if nm:find('{{', 1, true) then
                            stats.dynamic = stats.dynamic + 1
                            local pre = nm:match('^(.-){{')
                            if pre and #pre > 0 then dyn_prefixes[pre] = true end
                        else
                            local hs = by_key[nm]
                            if hs then
                                for _, h in ipairs(hs) do -- topic fires ALL listeners
                                    data.edges[#data.edges + 1] = { from = ensure_file(rel).id,
                                        to = h.id, kind = 'use', an = true,
                                        at = { { start = { line = line, char = 0 },
                                            ['end'] = { line = line, char = 0 } } } }
                                    used[h.id] = true
                                end
                                stats.links = stats.links + 1
                            else
                                stats.noop[#stats.noop + 1] =
                                    { name = nm, file = rel, line = line }
                            end
                        end
                    end
                elseif INCLUDE_TASKS[sk] and v then
                    local target = scalar_text(v, src)
                    if not target then
                        local m = map_of(v)
                        if m then
                            for p in m:iter_children() do
                                if p:type() == 'block_mapping_pair' then
                                    local pk, pv = pair_kv(p, src)
                                    if short_key(pk) == 'file' then target = scalar_text(pv, src) end
                                end
                            end
                        end
                    end
                    if target then
                        stats.includes = stats.includes + 1
                        local tgt, dyn = resolve_include(target, rel)
                        if tgt then
                            data.edges[#data.edges + 1] = { from = ensure_file(rel).id,
                                to = ensure_file(tgt).id, kind = 'import', an = true }
                        elseif not dyn then
                            stats.broken[#stats.broken + 1] =
                                { target = target, file = rel,
                                  line = select(1, n:range()) }
                        end
                    end
                elseif INCLUDE_ROLE[sk] and v then
                    local m = map_of(v)
                    local rolename
                    if m then
                        for p in m:iter_children() do
                            if p:type() == 'block_mapping_pair' then
                                local pk, pv = pair_kv(p, src)
                                if short_key(pk) == 'name' then rolename = scalar_text(pv, src) end
                            end
                        end
                    end
                    if rolename and not rolename:find('{{', 1, true) then
                        stats.includes = stats.includes + 1
                        local main = 'roles/' .. rolename .. '/tasks/main.yml'
                        if fileset[main] then
                            data.edges[#data.edges + 1] = { from = ensure_file(rel).id,
                                to = ensure_file(main).id, kind = 'import', an = true }
                        end
                        -- a role outside the tree stays an honest frontier
                    end
                end
            end
            for c in n:iter_children() do
                if c:named() then visit(c) end
            end
        end
        visit(pf.tree)
    end

    -- a handler key starting with a dynamic-notify prefix is plausibly
    -- triggered at runtime (`Remount {{ mp }}` → the `Remount /tmp` listeners):
    -- honest analysis cannot call it dead
    local maybe = {}
    for k, ns in pairs(by_key) do
        for pre in pairs(dyn_prefixes) do
            if k:sub(1, #pre) == pre then
                for _, n in ipairs(ns) do maybe[n.id] = true end
                break
            end
        end
    end
    -- handlers nothing notifies (by name, listen topic, or a dynamic prefix): dead
    for _, node in ipairs(handlers_list) do
        if not used[node.id] and not maybe[node.id] then
            stats.dead[#stats.dead + 1] = node.name:gsub('^handler ', '')
        end
    end
    table.sort(stats.dead)
    table.sort(stats.noop, function (a, b) return a.name < b.name end)

    if stats.handlers == 0 and stats.includes == 0 and stats.notifies == 0 then
        data.ansible = nil -- not an ansible tree
        return stats
    end
    data.ansible = stats
    return stats
end

return M
