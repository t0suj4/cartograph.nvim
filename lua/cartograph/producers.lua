-- producers — INPUT PRODUCER CANDIDATES (CART-1118 v1): when an analysis needs a FACT the tree does not contain, find
-- the artifacts on this machine that could produce it, each cited by the line that SELECTS it.
-- @langs erlang
-- (the only grammar read is erlang's — rebar.config and *.app.src are Erlang terms, read with xmppspec.term;
-- package.json goes through the JSON decoder)
--
-- ★★ WHY. Two of 2026-09-26's hard reverses stopped not on an operation but on a MISSING FACT — "exported, never
-- referenced from outside" needs a CONSUMER POPULATION; "which sites owe an implementation" needs an OBLIGATION.
-- Both producers were already on disk (a consumer's manifest names the library; a module's -behaviour line names
-- the callbacks it owes), and the obligation alone lifted 38% of erlang dead-function findings (CART-1117). Several
-- producers already exist ad hoc (erl-macros from a dependency's headers, erlrecords' `apps`, the xmpp generated
-- source the absent-value oracle reads); this makes finding them a question with an answer.
--
-- ★ THE RULE IT KEEPS: the analysed tree may SELECT a producer, never SUPPLY one. So every candidate carries the
-- selecting line — the tree's own manifest entry (a dependency), the tree's own -behaviour line (an obligation), or,
-- for a CONSUMER, the consumer's manifest line naming this tree (found, not selected: labelled so). A candidate is a
-- candidate until an acceptance check accepts it; this module finds, it does not attach.
--
--   M.identity(root)             -> { name, eco, file, line } | nil   the name other manifests would use for this tree
--   M.deps(root)                 -> { {name, eco, file, line, text}… } what the tree's manifests select
--   M.scan_manifests(dirs)       -> { {root, identity, deps}… }        every manifest-bearing repo under `dirs`
--   M.consumers(root, repos)     -> { {root, file, line}… }            repos whose manifest names this tree
--   M.attachable(root, deps, repos, libs) -> per dependency, where its source is: a repo whose identity matches,
--                                   <root>/node_modules/<name>, or an ERL_LIBS-shaped dir entry <name>[-vsn]
--   M.obligations(root, attached) -> per -behaviour(B) line: the producer of B's callbacks — a module B.erl in the tree,
--                                   in an attachable dependency (src/ or ebin/), the runtime profile (OTP + installed libs:
--                                   otp-api, distilled from the running runtime), or NONE
local M = {}

local function read(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end
local function isdir(p) return vim.fn.isdirectory(p) == 1 end
local function isfile(p) return vim.fn.filereadable(p) == 1 end

-- every term in an erlang file (top-level forms and, for .app.src.script, whatever the script builds)
local function erl_terms(path)
    local src = read(path)
    if not src then return {} end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'erlang')
    if not ok then return {} end
    local root = parser:parse()[1]:root()
    local XS = require 'cartograph.xmppspec'
    local out = {}
    local function walk(n)
        for c in n:iter_children() do
            if c:named() then
                local t = c:type()
                -- a tuple or list literal: read it as a term and stop (its insides are part of the term)
                if t == 'tuple' or t == 'list' then out[#out + 1] = XS.term(c, src)
                else walk(c) end
            end
        end
    end
    walk(root)
    return out
end

local function atom(t) return t and t.t == 'atom' and t.v or nil end

--- the name other manifests use for this tree
function M.identity(root)
    for _, f in ipairs(vim.fn.glob(root .. '/src/*.app.src*', false, true)) do
        for _, t in ipairs(erl_terms(f)) do
            local function find(x)
                if x.t == 'tuple' and atom(x.items[1]) == 'application' and atom(x.items[2]) then
                    return { name = atom(x.items[2]), eco = 'erlang', file = f, line = x.line }
                end
                for _, c in ipairs(x.items or {}) do local r = find(c); if r then return r end end
            end
            local r = find(t)
            if r then return r end
        end
    end
    local pj = root .. '/package.json'
    if isfile(pj) then
        local ok, j = pcall(vim.json.decode, read(pj))
        if ok and type(j) == 'table' and type(j.name) == 'string' then
            local line = 1
            for i, l in ipairs(vim.split(read(pj), '\n')) do if l:find('"name"', 1, true) then line = i; break end end
            return { name = j.name, eco = 'npm', file = pj, line = line }
        end
    end
    return nil
end

-- rebar.config deps: {deps, [ {Name, Vsn, Src} | {if_var_true, Var, Dep} | … ]}; a wrapper tuple recurses
-- the wrapper -> the index of its first dependency term: `{if_var_true, Var, Dep}` names a VARIABLE at 2 (not a dep)
local REBAR_WRAP = { if_var_true = 3, if_var_false = 3, if_var_match = 4, if_have_fun = 3,
    if_version_above = 3, if_version_below = 3, if_not_rebar3 = 2, if_rebar3 = 2 }
local function rebar_deps(path)
    local out = {}
    local function dep(x)
        if x.t ~= 'tuple' then
            if atom(x) then out[#out + 1] = { name = atom(x), line = x.line, text = x.text } end
            return
        end
        local head = atom(x.items[1])
        if head and REBAR_WRAP[head] then
            for i = REBAR_WRAP[head], #x.items do dep(x.items[i]) end
        elseif head then
            out[#out + 1] = { name = head, line = x.line, text = x.text:gsub('%s+', ' '):sub(1, 120) }
        end
    end
    for _, t in ipairs(erl_terms(path)) do
        if t.t == 'tuple' and atom(t.items[1]) == 'deps' and t.items[2] and t.items[2].t == 'list' then
            for _, x in ipairs(t.items[2].items) do dep(x) end
        end
    end
    return out
end

--- what the tree's manifests select
function M.deps(root)
    local out = {}
    local rc = root .. '/rebar.config'
    if isfile(rc) then
        for _, d in ipairs(rebar_deps(rc)) do
            out[#out + 1] = { name = d.name, eco = 'erlang', file = rc, line = d.line, text = d.text }
        end
    end
    local pj = root .. '/package.json'
    if isfile(pj) then
        local src = read(pj)
        local ok, j = pcall(vim.json.decode, src)
        if ok and type(j) == 'table' then
            local lines = vim.split(src, '\n')
            for _, sec in ipairs({ 'dependencies', 'devDependencies', 'peerDependencies' }) do
                for name, ver in pairs(type(j[sec]) == 'table' and j[sec] or {}) do
                    local line = 0
                    for i, l in ipairs(lines) do if l:find('"' .. name .. '"', 1, true) then line = i; break end end
                    out[#out + 1] = { name = name, eco = 'npm', file = pj, line = line,
                        text = ('%s: %s (%s)'):format(name, tostring(ver), sec) }
                end
            end
        end
    end
    table.sort(out, function (a, b) return a.file .. a.line .. a.name < b.file .. b.line .. b.name end)
    return out
end

local SKIP = { node_modules = true, _build = true, deps = true, ['.git'] = true, vendor = true }

--- every manifest-bearing repo under `dirs` (depth-bounded, dependency caches skipped)
function M.scan_manifests(dirs, depth)
    depth = depth or 3
    local repos, seen = {}, {}
    local function visit(d, lvl)
        if seen[d] or lvl > depth then return end
        seen[d] = true
        if isfile(d .. '/rebar.config') or isfile(d .. '/package.json') then
            repos[#repos + 1] = { root = d, identity = M.identity(d), deps = M.deps(d) }
        end
        for name, kind in vim.fs.dir(d) do
            if kind == 'directory' and not SKIP[name] and name:sub(1, 1) ~= '.' then visit(d .. '/' .. name, lvl + 1) end
        end
    end
    for _, d in ipairs(dirs) do if isdir(d) then visit(vim.fn.fnamemodify(d, ':p'):gsub('/$', ''), 0) end end
    return repos
end

--- repos whose manifest names this tree (the CONSUMER POPULATION; found, not selected by the tree)
function M.consumers(root, repos)
    local id = M.identity(root)
    if not id then return {}, 'the tree declares no identity (no src/*.app.src*, no package.json name)' end
    local out = {}
    for _, r in ipairs(repos) do
        if r.root ~= root then
            for _, d in ipairs(r.deps) do
                if d.name == id.name then out[#out + 1] = { root = r.root, file = d.file, line = d.line, text = d.text } end
            end
        end
    end
    return out, id
end

--- per dependency the tree selects, where its source is on this machine
function M.attachable(root, deps, repos, libs)
    local by_name = {}
    -- keyed by ECOSYSTEM too: an erlang dependency `lua` is not a VS Code extension whose package.json says "lua"
    for _, r in ipairs(repos) do
        if r.identity then
            local k = r.identity.eco .. ':' .. r.identity.name
            by_name[k] = by_name[k] or {}
            table.insert(by_name[k], r.root)
        end
    end
    local out = {}
    for _, d in ipairs(deps) do
        local cands = {}
        for _, p in ipairs(by_name[d.eco .. ':' .. d.name] or {}) do cands[#cands + 1] = { path = p, how = 'a repo whose identity is ' .. d.name } end
        local nm = root .. '/node_modules/' .. d.name
        if d.eco == 'npm' and isdir(nm) then cands[#cands + 1] = { path = nm, how = 'node_modules' } end
        if d.eco == 'erlang' then
            for _, lib in ipairs(libs or {}) do
                for _, p in ipairs(vim.fn.glob(lib .. '/' .. d.name .. '-*', false, true)) do
                    cands[#cands + 1] = { path = p, how = 'an ERL_LIBS entry', source = isdir(p .. '/src') }
                end
                if isdir(lib .. '/' .. d.name) then cands[#cands + 1] = { path = lib .. '/' .. d.name, how = 'an ERL_LIBS entry' } end
            end
        end
        for _, c in ipairs(cands) do if c.source == nil then c.source = isdir(c.path .. '/src') end end
        out[#out + 1] = { dep = d, candidates = cands }
    end
    return out
end

--- per -behaviour(B) line in the tree: who produces B's callback obligations
function M.obligations(root, attached)
    local otp
    do
        local ok, prof = pcall(require, 'cartograph.spec.profile')
        local a = ok and prof.load and prof.load('otp-api')
        otp = a and a.nsset or {}
    end
    -- a dependency's modules from its sources, or from its compiled ebin/ (an installed library ships no src/)
    local dep_mod = {}
    for _, a in ipairs(attached or {}) do
        for _, c in ipairs(a.candidates) do
            for _, pat in ipairs({ '/src/*.erl', '/ebin/*.beam' }) do
                for _, f in ipairs(vim.fn.glob(c.path .. pat, false, true)) do
                    local m = vim.fn.fnamemodify(f, ':t:r')
                    dep_mod[m] = dep_mod[m] or { file = f, dep = a.dep.name }
                end
            end
        end
    end
    local tree_mod = {}
    for _, f in ipairs(vim.fn.glob(root .. '/src/*.erl', false, true)) do tree_mod[vim.fn.fnamemodify(f, ':t:r')] = f end
    local rows, by = {}, {}
    for _, f in ipairs(vim.fn.glob(root .. '/src/*.erl', false, true)) do
        local src = read(f) or ''
        local ln = 0
        for l in (src .. '\n'):gmatch('([^\n]*)\n') do
            ln = ln + 1
            local b = l:match('^%-behaviou?r%(%s*([%w_]+)%s*%)')
            if b then
                local prod
                if tree_mod[b] then prod = { kind = 'tree', file = tree_mod[b] }
                elseif dep_mod[b] then prod = { kind = 'dependency', file = dep_mod[b].file, dep = dep_mod[b].dep }
                -- the runtime profile was distilled from the INSTALLED runtime: OTP plus whatever libraries the
                -- system put in its lib dir, so it is labelled for what it is, not called OTP
                elseif otp[b] then prod = { kind = 'runtime', file = 'otp-api profile (distilled from the installed runtime)' }
                else prod = { kind = 'NONE' } end
                rows[#rows + 1] = { behaviour = b, file = f, line = ln, producer = prod }
                by[b] = by[b] or { n = 0, producer = prod }
                by[b].n = by[b].n + 1
            end
        end
    end
    return rows, by
end

return M
