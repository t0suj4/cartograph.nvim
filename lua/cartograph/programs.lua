-- PROGRAMS: which files of a tree run in ONE process, sharing its global state — the globals table `_G` and the
-- string library (CART-1737). flowtype gives each program its own environment; everything else (module tables reached
-- through `require`) is shared as before.
--
-- ★ SPLIT ONLY ON EVIDENCE. Two files in different environments cannot see each other's global writes, so a split
-- HIDES flows — a wrong split makes whole answers that a run falsifies. A missing `require` edge is no evidence two
-- files run apart: a computed-name loader (`dofile(path)`, `require(prefix .. name)`, `load(src)`) can bring any file
-- into a process, a manifest (WoW's .toc) or a runtime (nvim's runtimepath) loads files with no edge at all. So:
--   * ONE environment by default;
--   * the DERIVED split — each entry's require closure, closures that share a file merged — is a CANDIDATE the
--     explainer shows, never applied on its own: "no loader in the tree reaches it" is no evidence either, a HOST loads
--     files with no edge (WoW w2: 1,164 closures, one _G through the .toc; only a stray `dofile(<expr>)` blocked
--     the split). It applies where a shape SEPARATES processes (none declared yet; Factorio's data / control stages
--     are the first). The explainer names the blockers (file:line) and the shared-process evidence;
--   * CONFIG decides over both: the scoped key `program` (config.at, CART-1120) — a name puts the files it covers into
--     that program, 'per-file' makes each covered file its own. The user's setting wins, as with shapes.
--
--   M.of(store) -> { env = { [file] = program name }, programs = { [name] = { files = n, how = … } }, blockers, shared,
--                    candidates = derived component count }
--   M.explain(store) -> lines (shown by :CartographShapes)
local M = {}

local LOADERS = { require = true, dofile = true, loadfile = true, -- (load / loadstring run a SOURCE string: unknown code, EXT)
    ['vim.cmd.source'] = true, ['vim.cmd.luafile'] = true }
local SHARED_SHAPES = { ['nvim-plugin'] = true, ['nvim-config'] = true }

local memo = setmetatable({}, { __mode = 'k' })

function M.of(store)
    local m = memo[store]
    if m and m.gen == store.generation and m.data == store.data then return m.res end
    local callrec, argv = require 'cartograph.callrec', require 'cartograph.argv'
    local cfg = require 'cartograph.config'
    local files, inb, out = {}, {}, {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.kind == 'module' and n.file and n.file:match('%.lua$') then files[n.file] = true end
    end
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'import' and files[e.from] and files[e.to] then
            inb[e.to] = true
            local o = out[e.from]
            if not o then o = {}; out[e.from] = o end
            o[e.to] = true
        end
    end
    -- what blocks a derived split: a loader whose argument is not a literal
    local blockers = {}
    for _, c in ipairs(store.data.calls or {}) do
        local f = callrec.file(c)
        if f and files[f] then
            local name = callrec.full(c) or callrec.callee(c)
            if name and LOADERS[name] then
                local a = argv.at(c, 1)
                if a and a.k ~= 'lit' then
                    blockers[#blockers + 1] = { file = f, line = (callrec.line(c) or 0) + 1, loader = name,
                        arg = a.k == 'concat' and ('prefix ' .. tostring(a.prefix)) or a.k }
                end
            end
        end
    end
    table.sort(blockers, function (a, b) if a.file ~= b.file then return a.file < b.file end return a.line < b.line end)
    -- what says the files share a process: a load manifest, a shape whose runtime loads everything into one
    local shared = {}
    if store.toc then shared[#shared + 1] = 'a load manifest (.toc): its files share one _G' end
    local root = store.data.root
    if type(root) == 'string' then
        local ok, probes = pcall(require('cartograph.shapes').probe, root)
        for _, p in ipairs(ok and probes or {}) do
            if p.evidence and SHARED_SHAPES[p.name] then shared[#shared + 1] = ('shape %s (%s): one nvim process'):format(p.name, p.evidence) end
        end
    end
    -- the derived candidates: union of each entry's closure
    local parent = {}
    for f in pairs(files) do parent[f] = f end
    local function find(x) while parent[x] ~= x do parent[x] = parent[parent[x]]; x = parent[x] end return x end
    for f in pairs(files) do
        if not inb[f] then
            local seen, q = { [f] = true }, { f }
            while #q > 0 do
                local x = table.remove(q)
                for y in pairs(out[x] or {}) do
                    if not seen[y] then seen[y] = true; q[#q + 1] = y; local a, b = find(f), find(y); if a ~= b then parent[b] = a end end
                end
            end
        end
    end
    local roots, ncand = {}, 0
    for f in pairs(files) do local r = find(f); if not roots[r] then roots[r] = true; ncand = ncand + 1 end end
    local derive = false -- (no shape declares separate processes yet: candidates only, see the header)
    local env, programs = {}, {}
    local function put(f, name, how)
        env[f] = name
        local p = programs[name]
        if not p then p = { files = 0, how = how }; programs[name] = p end
        p.files = p.files + 1
    end
    local sorted = vim.tbl_keys(files)
    table.sort(sorted)
    for _, f in ipairs(sorted) do
        local v, prov = cfg.at(store.abs and store.abs(f) or f, 'program')
        if v == 'per-file' then put(f, f, 'config (' .. tostring(prov and prov.scope) .. '): per-file')
        elseif type(v) == 'string' then put(f, v, 'config (' .. tostring(prov and prov.scope) .. ')')
        elseif derive then put(f, 'derived:' .. find(f), 'derived: the require closure of its entries')
        else put(f, 'default', 'default: one environment') end
    end
    local res = { env = env, programs = programs, blockers = blockers, shared = shared, candidates = ncand, derived = derive }
    memo[store] = { gen = store.generation, data = store.data, res = res }
    return res
end

--- the explainer: how the programs were derived, what blocked a split, what config decided
function M.explain(store)
    local r = M.of(store)
    local names = vim.tbl_keys(r.programs)
    table.sort(names, function (a, b) return r.programs[a].files > r.programs[b].files end)
    local L = { ('programs (shared _G / string library) — %d program(s) over the lua files'):format(#names) }
    for i, n in ipairs(names) do
        if i > 12 then L[#L + 1] = ('  … %d more'):format(#names - 12); break end
        L[#L + 1] = ('  %5d  %s  — %s'):format(r.programs[n].files, n, r.programs[n].how)
    end
    L[#L + 1] = ('  derived candidates: %d require-closure component(s) — %s'):format(r.candidates,
        r.derived and 'APPLIED' or 'CANDIDATES, not applied (a split needs evidence the files run apart; declare it below)')
    for _, s in ipairs(r.shared) do L[#L + 1] = '    shared process: ' .. s end
    if #r.blockers > 0 then
        L[#L + 1] = ('    %d computed-name loader(s) may load any file into a process, e.g.:'):format(#r.blockers)
        for i, b in ipairs(r.blockers) do
            if i > 6 then break end
            L[#L + 1] = ('      %s:%d  %s(<%s>)'):format(b.file, b.line, b.loader, b.arg)
        end
    end
    L[#L + 1] = '  override: setup{ scoped = { [<dir or query>] = { program = <name> | \'per-file\' } } }'
    return L
end

return M
