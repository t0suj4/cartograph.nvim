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
-- M.derive(tree) -> { rows = { [fact] = { value?, by?, gap?, kind?, tried = { [file] = why } } }, order, derived, total }
local M = {}

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
        else d.name = name; d.needs = d.needs or {}; out[#out + 1] = d end
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
                        local okd, v, why, kind = pcall(d.derive, tree, got)
                        local ms = (vim.uv.hrtime() - t0) / 1e6
                        if not okd then
                            tried[d.name] = 'raised: ' .. tostring(v)
                            pend_of[f] = pend_of[f] or { gap = tried[d.name], kind = 'error', tried = tried }
                        elseif v ~= nil then
                            -- (a SCOPE — the units a person chose: `tree.scope`, globs relative to src — narrows the
                            -- build's units before anything reads them; the build's flags stay each unit's own)
                            if f == 'compdb' and tree.scope and v.units then v = M.scoped(v, tree) end
                            got[f] = v
                            rows[f] = { value = v, by = d.name, ms = ms, tried = tried }
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
    return { rows = rows, order = order, derived = derived, total = #facts, got = got, broken = broken }
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
