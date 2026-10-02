-- cartograph.cinterp.facts — THE FACTS an interpreter adapter needs, each DERIVED from the runtime's own tree
-- (CART-1248). A derivation is a plain file in lua/cartograph/cinterp/facts/ — no central list — returning
--   { fact = <name>, needs = { <fact>, … }, summary = <one line>, derive = function (tree, got) -> value | nil, why, kind }
-- `tree` = { src = <dir> }, `got` = the facts derived so far. A fact may have several derivations: each tests its OWN
-- evidence (lua_gettop's `top - base`, a make dry run, an `LJ_T*` tag family) and the first that holds wins, so no
-- runtime is ever named here. What does not derive is a GAP, and the table says which kind:
--   adapter — nothing derives it yet: a targeted derivation fills it (a frontier);
--   engine  — derived, in a shape cartograph.cinterp cannot run yet (unbuilt: a ticket);
--   blocked — a fact it needs is itself a gap;
--   error   — a derivation raised (a bug, named).
-- M.derive(tree) -> { rows = { [fact] = { value?, by?, gap?, kind?, cached?, tried = { [file] = why } } }, order, derived,
-- total, cache }
-- ★ A DERIVATION'S VALUE IS KEPT ACROSS RUNS (CART-1299, cartograph.stampcache) — a derive call is replaced by its stored
-- value only under the same KEY: the CONTENT of every file of the tree (and the scope), the toolchain (gcc's identity,
-- make's), the derivation's CODE (its file, every cartograph module and sibling derivation its text requires or loads —
-- read from the text — and this file), and each NEED's value (its content hash; a need with no plain value, units'
-- tree-sitter nodes, by the key of the call that made it). The engine's order is untouched: the cache answers one
-- call, never a fact. Stored: a value that round-trips (no function, userdata, metatable) and is worth its bytes
-- (from a MB up, WORTH_MS_PER_MB of derivation per MB written: the preprocessed sources, 87 MB for 2 s, are re-derived). A gap
-- or a raise is never stored (a missing gcc is not a fact of the tree). A derivation that reads a fact of `got` it
-- does not declare in `needs` is not stored (its key would miss that input), nor one that CHANGES a need's value (a
-- side effect: numbers-tvis adds its variants to reps.tag — a stored value would skip it, measured: cpath's join 42
-- agree → 30) — re-derived every run, and the need re-keyed by its changed value for the facts after it. Both named in
-- `cache.refused`.
-- ⚠ What the key does NOT see: files outside the tree a derivation reads itself (system headers reach the key only
-- through the sources fact's value — gcc -E's output — so a macro-only system header change is invisible to a fact
-- that does not need sources). CARTOGRAPH_STAMPCACHE=0 (or opts.cache = false) derives everything: the A/B.
local M = {}
local SC = require 'cartograph.stampcache'
local WORTH_MS_PER_MB = 100

local function dir_of_facts()
    local here = debug.getinfo(1, 'S').source:sub(2)
    return vim.fn.fnamemodify(here, ':p:h') .. '/facts'
end

--- every derivation, by file name (the order a fact's derivations are tried in) -> { d … }, broken = { why … }
function M.list(dir)
    local out, broken = {}, {}
    for _, path in ipairs(vim.fn.globpath(dir or dir_of_facts(), '*.lua', false, true)) do
        local okl, d = pcall(dofile, path)
        local name = vim.fn.fnamemodify(path, ':t:r')
        if not okl then broken[#broken + 1] = name .. ': ' .. tostring(d)
        elseif type(d) ~= 'table' or type(d.fact) ~= 'string' or type(d.derive) ~= 'function' then
            broken[#broken + 1] = name .. ': a derivation needs `fact` and `derive(tree, got)`'
        else d.name = name; d.path = path; d.needs = d.needs or {}; out[#out + 1] = d end
    end
    table.sort(out, function (a, b) return a.name < b.name end)
    return out, broken
end

--- THE TABLE over one tree: every fact any derivation names, in the order the needs allow
function M.derive(tree, opts)
    opts = opts or {}
    local ds, broken = M.list(opts.dir)
    local byfact, facts = {}, {}
    for _, d in ipairs(ds) do
        if not byfact[d.fact] then byfact[d.fact] = {}; facts[#facts + 1] = d.fact end
        table.insert(byfact[d.fact], d)
    end
    local rows, got, order, tried_of, pend_of = {}, {}, {}, {}, {}
    local C = (opts.cache ~= false and vim.env.CARTOGRAPH_STAMPCACHE ~= '0') and M.cache(tree, opts.dir) or nil
    local fkey = {} -- (fact -> the key a consumer's key reads it by)
    local function decided(f) return rows[f] ~= nil end
    local progress = true
    while progress do
        progress = false
        for _, f in ipairs(facts) do
            if not decided(f) then
                local ready, blockers, waiting = {}, {}, false
                for _, d in ipairs(byfact[f]) do
                    local ok_needs = true
                    for _, n in ipairs(d.needs) do
                        if not got[n] then
                            ok_needs = false
                            if decided(n) or not byfact[n] then blockers[n] = true else waiting = true end
                        end
                    end
                    if ok_needs then ready[#ready + 1] = d end
                end
                -- (each derivation runs ONCE; the fact is decided when one holds, or when none is left waiting)
                local tried = tried_of[f] or {}
                tried_of[f] = tried
                local fresh = {}
                for _, d in ipairs(ready) do if tried[d.name] == nil then fresh[#fresh + 1] = d end end
                if #fresh > 0 or (#ready > 0 and not waiting) then
                    for _, d in ipairs(fresh) do
                        local t0 = vim.uv.hrtime()
                        local okd, v, why, kind, cached
                        local key = C and C.key(d, fkey, got)
                        if key then v, cached = C.get(key) end
                        if cached then okd = true
                        else
                            local view = C and C.view(d, got) or got
                            okd, v, why, kind = pcall(d.derive, tree, view)
                            if C then C.after(d, got, fkey) end
                            if key and okd and v ~= nil then C.put(key, d, v, (vim.uv.hrtime() - t0) / 1e6) end
                        end
                        local ms = (vim.uv.hrtime() - t0) / 1e6
                        if not okd then
                            tried[d.name] = 'raised: ' .. tostring(v)
                            pend_of[f] = pend_of[f] or { gap = tried[d.name], kind = 'error', tried = tried }
                        elseif v ~= nil then
                            -- (a SCOPE — the units a person chose: `tree.scope`, globs relative to src — narrows the
                            -- build's units before anything reads them; the build's flags stay each unit's own)
                            if f == 'compdb' and tree.scope and v.units then v = M.scoped(v, tree) end
                            got[f] = v
                            rows[f] = { value = v, by = d.name, ms = ms, tried = tried, cached = cached or nil }
                            if C then fkey[f] = C.fact_key(v, key) end
                            break
                        else
                            tried[d.name] = tostring(why)
                            if kind == 'engine' then pend_of[f] = { gap = tostring(why), kind = 'engine', by = d.name, tried = tried } end
                        end
                    end
                    if not rows[f] and waiting then progress = progress or #fresh > 0; goto continue end
                    if not rows[f] and pend_of[f] then rows[f] = pend_of[f] end
                    if not rows[f] then
                        local l = {}
                        for n, w in pairs(tried) do l[#l + 1] = n .. ': ' .. w end
                        table.sort(l)
                        rows[f] = { gap = table.concat(l, '; '), kind = 'adapter', tried = tried }
                    end
                    order[#order + 1] = f
                    progress = true
                elseif not waiting and #ready == 0 then
                    local l = vim.tbl_keys(blockers); table.sort(l)
                    rows[f] = { gap = 'needs ' .. table.concat(l, ', '), kind = 'blocked', tried = {} }
                    order[#order + 1] = f
                    progress = true
                end
            end
            ::continue::
        end
    end
    local derived = 0
    for _, f in ipairs(facts) do if rows[f] and rows[f].value ~= nil then derived = derived + 1 end end
    return { rows = rows, order = order, derived = derived, total = #facts, got = got, broken = broken, cache = C and C.stats }
end

--- THE CACHE of one derive over `tree` (see the header) -> { key(d, fkey, got), get(key), put(key, d, v, ms), view(d, got),
--- fact_key(v, key), stats = { hits, stored, refused = { [derivation] = why }, stamp_ms } } — the stamps are taken on
--- the first key asked for
function M.cache(tree, dir)
    dir = dir or dir_of_facts()
    local blob = SC.blob('facts')
    local stats = { hits = 0, stored = 0, refused = {}, stamp_ms = 0 }
    local base
    local function base_key()
        if base then return base end
        local t0 = vim.uv.hrtime()
        local src = vim.fn.fnamemodify(tree.src, ':p'):gsub('/$', '')
        local th = SC.tree(src)
        local function out(cmd) local r = vim.system(cmd, { text = true }):wait(); return r and r.code == 0 and vim.trim(r.stdout or '') or '-' end
        local scope = tree.scope and table.concat(tree.scope, '\1') or ''
        local me = debug.getinfo(1, 'S').source:sub(2)
        base = SC.key({ 'facts', th, scope, vim.fn.exepath('gcc'), out({ 'gcc', '-dumpfullversion', '-dumpmachine' }),
            vim.fn.exepath('make'), (out({ 'make', '--version' }):match('^[^\n]*')), SC.file(me) or '' })
        stats.stamp_ms = (vim.uv.hrtime() - t0) / 1e6
        return base
    end
    -- the CODE a derivation runs, read from its text: the cartograph modules it requires (transitively), the sibling
    -- files its text names (a dofile of a sibling derivation)
    local lua_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
    local function mod_path(m)
        local b = lua_root .. '/' .. m:gsub('%.', '/')
        if vim.uv.fs_stat(b .. '.lua') then return b .. '.lua' end
        if vim.uv.fs_stat(b .. '/init.lua') then return b .. '/init.lua' end
    end
    local codes = {}
    local function code(d)
        if codes[d.path] then return codes[d.path] end
        local seen, parts = {}, {}
        local function add(path)
            if not path or seen[path] then return end
            seen[path] = true
            local fd = io.open(path, 'rb'); if not fd then parts[#parts + 1] = path .. '=?'; return end
            local text = fd:read('a'); fd:close()
            parts[#parts + 1] = path:sub(#lua_root + 2) .. '=' .. (SC.file(path) or '?')
            for m in text:gmatch("require%s*%(?%s*['\"]([%w_%.%-]+)['\"]") do
                if m:match('^cartograph%.') then add(mod_path(m)) end
            end
            for f in text:gmatch("['\"]([%w_%-]+%.lua)['\"]") do
                local sib = dir .. '/' .. f
                if vim.uv.fs_stat(sib) then add(sib) end
            end
        end
        add(d.path)
        table.sort(parts)
        codes[d.path] = SC.key(parts)
        return codes[d.path]
    end
    local C = { stats = stats }
    --- the key of one derive call | nil (a need with no key: not cached)
    function C.key(d, fkey, got)
        local parts = { base_key(), d.name, code(d) }
        local ns = vim.deepcopy(d.needs)
        table.sort(ns)
        for _, n in ipairs(ns) do
            if got[n] ~= nil then
                if not fkey[n] then return nil end
                parts[#parts + 1] = n .. '=' .. fkey[n]
            else parts[#parts + 1] = n .. '=-' end
        end
        return SC.key(parts)
    end
    function C.get(key)
        local v, found = blob.get(key)
        if found then stats.hits = stats.hits + 1 end
        return v, found
    end
    -- (a derive reads `got` through a view that notes a fact it does not declare: its key would not see that input)
    local strays = {}
    function C.view(d, got)
        local declared = {}
        for _, n in ipairs(d.needs) do declared[n] = true end
        return setmetatable({}, {
            __index = function (_, k) if not declared[k] then strays[d.name] = k end return got[k] end,
            __newindex = function (_, k, x) got[k] = x end,
        })
    end
    -- (after a derive ran: a need whose value it CHANGED — re-hashed, the derivation never stored)
    local mutated = {}
    function C.after(d, got, fkey)
        for _, n in ipairs(d.needs) do
            local was = fkey[n]
            if was and not was:find('^call:') then
                local now = SC.value(got[n])
                if now ~= was then mutated[d.name] = n; fkey[n] = now or ('changed:' .. was) end
            end
        end
    end
    function C.put(key, d, v, ms)
        if mutated[d.name] then stats.refused[d.name] = 'changes its need ' .. mutated[d.name] .. ' (a side effect a stored value would skip)'; return end
        if strays[d.name] then stats.refused[d.name] = 'reads got.' .. strays[d.name] .. ', which its needs do not declare'; return end
        local h, why = SC.value(v)
        if not h then stats.refused[d.name] = why; return end
        local ok, B = pcall(require, 'string.buffer')
        local mb = ok and (#B.encode(v) / 1e6) or 0
        if mb >= 1 and ms / mb < WORTH_MS_PER_MB then -- (under a MB, bytes are not worth weighing)
            stats.refused[d.name] = ('not worth its bytes (%.1f MB for %.0f ms)'):format(mb, ms); return
        end
        local bytes, perr = blob.put(key, v)
        if bytes then stats.stored = stats.stored + 1 else stats.refused[d.name] = perr end
    end
    --- a decided fact's key for its consumers: its value's content hash, else the key of the call that made it
    function C.fact_key(v, key)
        return SC.value(v) or (key and ('call:' .. key)) or nil
    end
    return C
end

--- a compdb narrowed to a SCOPE: `tree.scope` = { glob, … } relative to tree.src (`Objects/*.c`, `Python/bltinmodule.c`)
--- -> the same compdb, only the units a glob matches (`scoped_out` = how many were left out)
function M.scoped(db, tree)
    local src = vim.fs.normalize(vim.fn.fnamemodify(tree.src, ':p')):gsub('/$', '')
    local pats = {}
    for _, g in ipairs(tree.scope) do pats[#pats + 1] = vim.glob.to_lpeg(g) end
    local units = {}
    for _, u in ipairs(db.units) do
        local rel = u.file:sub(1, #src + 1) == src .. '/' and u.file:sub(#src + 2) or u.file
        for _, p in ipairs(pats) do if p:match(rel) then units[#units + 1] = u; break end end
    end
    local out = {}
    for k, v in pairs(db) do out[k] = v end
    out.units, out.scoped_out = units, #db.units - #units
    return out
end

--- the interpreter's ctx from derived facts (cartograph.cinterp's contract) -> ctx | nil, the missing facts
function M.ctx(got)
    local need = { 'units', 'noret', 'frame', 'layout', 'reps', 'sentinels', 'builtins' }
    local miss = {}
    for _, f in ipairs(need) do if got[f] == nil then miss[#miss + 1] = f end end
    if #miss > 0 then return nil, miss end
    local ctx = {}
    for k, v in pairs(got.units) do ctx[k] = v end
    ctx.noret, ctx.frame, ctx.layout, ctx.reps, ctx.sentinels, ctx.builtins = got.noret, got.frame, got.layout.layout, got.reps, got.sentinels, got.builtins
    ctx.sources = got.sources and got.sources.units
    ctx.memory = got.reps.memory -- (the heap words the representatives own, if any)
    ctx.symaddr = got.reps.symaddr -- (the addresses of global objects the running runtime placed, if a probe linked it)
    ctx.sizes = got.sizes -- (every sizeof operand, the compiler's, if derived)
    ctx.layout_of = got.layouts and got.layouts.lookup -- (a field of an aggregate, asked of the compiler)
    return ctx
end

-- ── helpers the derivations share ──────────────────────────────────────────────────────────────────────────────────
local function readfile(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end
M.readfile = readfile

--- the tree's own files a build reads: every `*.<ext>` in a unit's directory or an include directory (compdb) — the
--- units' dirs first, then the -I dirs in the order the compile lines give them
function M.files(got, ext)
    local dirs, seen = {}, {}
    local function add(d) d = vim.fn.fnamemodify(d, ':p'):gsub('/$', ''); if not seen[d] then seen[d] = true; dirs[#dirs + 1] = d end end
    for _, u in ipairs(got.compdb.units) do add(vim.fn.fnamemodify(u.file, ':h')) end
    for _, u in ipairs(got.compdb.units) do for _, fl in ipairs(u.flags) do local i = fl:match('^%-I(.+)$'); if i then add(i) end end end
    local out = {}
    for _, d in ipairs(dirs) do vim.list_extend(out, vim.fn.globpath(d, '*.' .. ext, false, true)) end
    return out
end

--- COMPILE AND RUN a small C program as `unit` is compiled (its -D / -U / -I / -include, its directory on the path, in
--- the directory its build runs in) -> stdout | nil, why
function M.run_c(text, unit, opts)
    opts = opts or {}
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local c = tmp .. '/probe.c'
    local fd = assert(io.open(c, 'w')); fd:write(text); fd:close()
    local cmd = { 'gcc', '-w', '-o', tmp .. '/probe' }
    vim.list_extend(cmd, unit.flags or {})
    vim.list_extend(cmd, { '-I' .. vim.fn.fnamemodify(unit.file, ':h'), c })
    -- (a probe LINKED against the tree's own library — `opts.link`, after the source — runs the real runtime)
    vim.list_extend(cmd, opts.link or {})
    cmd[#cmd + 1] = '-lm'
    local r = vim.system(cmd, { text = true, cwd = unit.cwd }):wait()
    if r.code ~= 0 then vim.fn.delete(tmp, 'rf'); return nil, 'the probe does not compile: ' .. (r.stderr or ''):sub(1, 400), r.stderr end
    vim.uv.update_time() -- (the loop clock is cached: a warm facts cache leaves long spawn-free stretches — CART-1320)
    local out = vim.system({ tmp .. '/probe' }, { text = true, env = opts.env }):wait(opts.timeout or 120000)
    if not out then vim.fn.delete(tmp, 'rf'); return nil, 'the probe did not finish' end
    vim.fn.delete(tmp, 'rf')
    if out.code ~= 0 then return nil, 'the probe exits ' .. out.code end
    return out.stdout
end

--- the first file among `files` whose text matches `pat` -> path, text, the capture
function M.find(files, pat)
    for _, p in ipairs(files) do
        local t = readfile(p)
        if t then local c = t:match(pat); if c then return p, t, c end end
    end
    return nil
end

return M
