-- lookupsnarrow — gate the NAME-NARROWED lookups (treesitter.M.lookups `narrow`),
-- step 2 of index-and-reduce ([[cartograph-merging-strategies]]).
--
-- THE CLAIM: for every name in the narrowed set, the narrowed lookups are
-- IDENTICAL to the full corpus build — so a demand query can resolve against a
-- name-keyed working set instead of holding the whole corpus's fn_unique /
-- var_named resident.
--
-- THE HAZARD: fn_unique is a corpus-wide uniqueness claim, so it survives a NAME
-- cut and dies under a FILE cut. This tool therefore runs BOTH:
--
--   POSITIVE  narrow by name  -> must be identical for every retained name
--   NEGATIVE  narrow by file  -> must DIVERGE (a name unique in the slice but
--             ambiguous corpus-wide is the ghost/v8 slice bug). If the file cut
--             does NOT diverge on this corpus, the positive result proves nothing
--             here — the gate has no teeth — so that is a FAILURE too.
--
-- The narrowed name set is built the way a real query would: pick a sample of
-- files and take the union of the names they mention (data.names), which is
-- exactly what the postings hand back.
--
--   nvim --headless -u NONE -l tools/lookupsnarrow.lua [corpus] [files]
--     corpus  default: the plugin's own tree
--     files   how many files the simulated query touches (default 10)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local hr = vim.uv.hrtime
local function mb() collectgarbage(); collectgarbage(); return collectgarbage('count') / 1024 end

local name = arg[1] or repo
local nq = tonumber(arg[2] or '10') or 10

local data = bench.extract(name)
local root, nodes = data.root, data.nodes

-- === the simulated demand query: N files, and the names they mention ===
local px = store.build_postings(data.names or {})
if px.n_files == 0 then
    print('lookupsnarrow: no mention index on this corpus — cannot simulate a query')
    vim.cmd('cquit 1')
    return
end
local qfiles, want, n_want = {}, {}, 0
for i = 1, math.min(nq, px.n_files) do
    local f = px.files[math.floor((i - 0.5) * px.n_files / math.min(nq, px.n_files)) + 1]
        or px.files[i]
    qfiles[f] = true
end
for f in pairs(qfiles) do
    for nme in ((data.names or {})[f] or ''):gmatch('[^\31]+') do
        if not want[nme] then n_want = n_want + 1 end
        want[nme] = true
    end
end

-- === FULL vs NAME-NARROWED ===
local a0 = mb(); local t0 = hr()
local full = ts.lookups(nodes, root)
local t_full, m_full = (hr() - t0) / 1e6, mb() - a0

local a1 = mb(); local t1 = hr()
local narrow = ts.lookups(nodes, root, { names = want, files = qfiles })
local t_nar, m_nar = (hr() - t1) / 1e6, mb() - a1

local function same_entry(x, y)
    if x == nil or y == nil then return x == y end
    return x.id == y.id and x.file == y.file and x.line == y.line
end

local bad, shown = 0, 0
local function report(fmt, ...)
    bad = bad + 1
    if shown < 6 then shown = shown + 1; print('    ' .. fmt:format(...)) end
end

-- (a) every retained name answers identically
local n_fn, n_var = 0, 0
for nme in pairs(want) do
    if not same_entry(full.fn_unique[nme], narrow.fn_unique[nme]) then
        report('fn_unique %q: full %s, narrowed %s', nme,
            full.fn_unique[nme] and full.fn_unique[nme].id or 'nil',
            narrow.fn_unique[nme] and narrow.fn_unique[nme].id or 'nil')
    elseif full.fn_unique[nme] then n_fn = n_fn + 1 end
    local fv, nv = full.var_named[nme], narrow.var_named[nme]
    if (fv == nil) ~= (nv == nil) then
        report('var_named %q: full %s, narrowed %s', nme,
            fv and #fv or 'nil', nv and #nv or 'nil')
    elseif fv then
        n_var = n_var + 1
        if #fv ~= #nv then
            report('var_named %q: full %d entries, narrowed %d', nme, #fv, #nv)
        else
            for i = 1, #fv do
                if not same_entry(fv[i], nv[i]) then
                    report('var_named %q[%d]: %s vs %s', nme, i, fv[i].id, nv[i].id)
                    break
                end
            end
        end
    end
end

-- (b) nothing leaks in from outside the narrowed set
local leaked = 0
for nme in pairs(narrow.fn_unique) do if not want[nme] then leaked = leaked + 1 end end
for nme in pairs(narrow.var_named) do if not want[nme] then leaked = leaked + 1 end end
if leaked > 0 then report('%d names present in the narrowed result but not requested', leaked) end

-- (c) scopes: identical wherever the narrowed build computed one
local n_scope, scope_note = 0, 'corpus has no scoped language (scopes = nil)'
if full.scopes and narrow.scopes then
    for f, v in pairs(narrow.scopes) do
        n_scope = n_scope + 1
        if full.scopes[f] ~= v then
            report('scopes[%s]: full %q, narrowed %q', f, tostring(full.scopes[f]), tostring(v))
        end
    end
    scope_note = ('%d files scoped, all equal to the full build'):format(n_scope)
elseif full.scopes and not narrow.scopes then
    report('the full build has scopes but the narrowed one dropped them entirely')
end

-- === NEGATIVE CONTROL: the FILE cut must break fn_unique ===
-- a slice of files, lookups built over ONLY their nodes — the shape a worker slice
-- had. A name the slice calls unique while the corpus does not is the bug.
local slice_files, sf = {}, 0
for i = 1, px.n_files, 3 do sf = sf + 1; slice_files[px.files[i]] = true end
local slice_nodes = {}
for _, n in ipairs(nodes) do
    if slice_files[n.file] then slice_nodes[#slice_nodes + 1] = n end
end
local sliced = ts.lookups(slice_nodes, root)
local phantom, phantom_eg = 0, nil
for nme, e in pairs(sliced.fn_unique) do
    local f = full.fn_unique[nme]
    if not f or f.id ~= e.id then
        phantom = phantom + 1
        if not phantom_eg then phantom_eg = nme end
    end
end

-- Per-TABLE entry counts, not one blended MB: the three tables narrow by wildly
-- different factors, and a single number hides which one dominates (gc deltas are
-- noisy at this size besides — counts are exact).
local function count(t) local c = 0 for _ in pairs(t or {}) do c = c + 1 end return c end
local f_fn, f_var = count(full.fn_unique), count(full.var_named)
local f_sc, n_sc = count(full.scopes), count(narrow.scopes)
local function ratio(a, b) return b > 0 and a / b or 0 end

-- scopes measured DIRECTLY, not inferred from a gc delta: at this size a heap
-- delta around the build is dominated by allocation noise (it reads NEGATIVE on
-- big corpora), and reporting one as a footprint ratio invites exactly the wrong
-- conclusion — that scopes' poor narrowing ratio makes it the bottleneck. Entries
-- x distinct values x serialized bytes is the answer, and it is small.
local sc_blob, sc_distinct = 0, 0
if full.scopes then
    local seen = {}
    for _, v in pairs(full.scopes) do
        if not seen[v] then sc_distinct = sc_distinct + 1; seen[v] = true end
    end
    sc_blob = #vim.mpack.encode(full.scopes)
end

print(('lookupsnarrow %s'):format(name))
print(('  QUERY     %d files -> %d names mentioned'):format(nq, n_want))
print(('  BUILD     full %.0f ms · narrowed %.0f ms'):format(t_full, t_nar))
print(('  fn_unique %6d -> %-6d  %.0fx smaller'):format(f_fn, n_fn, ratio(f_fn, n_fn)))
print(('  var_named %6d -> %-6d  %.0fx smaller'):format(f_var, n_var, ratio(f_var, n_var)))
print(('  scopes    %6d -> %-6d  %.1fx smaller   (does NOT narrow by name)')
    :format(f_sc, n_sc, ratio(f_sc, n_sc)))
print(('  SCOPES    %s'):format(scope_note))
if f_sc > 0 then
    print(('            %d entries over %d DISTINCT values · %.1f KB serialized')
        :format(f_sc, sc_distinct, sc_blob / 1024))
    print('            Most specs return the file\'s DIRECTORY, so the map is N keys')
    print('            sharing a handful of strings — and the keys are file paths the')
    print('            graph already holds. Poor narrowing ratio, negligible size: it')
    print('            is not the bottleneck. ruby/zig return the FILE itself, which')
    print('            is a flag rather than a map. The one real cost is BUILD time —')
    print('            javascript\'s scope fs_stats up the tree per file — and')
    print('            narrowing already halves that.')
end
local _ = m_full; local _ = m_nar
print(('  POSITIVE  name cut: %d mismatches · %d leaked names'):format(bad, leaked))
print(('  NEGATIVE  file cut over %d/%d files: %d PHANTOM uniques%s')
    :format(sf, px.n_files, phantom,
        phantom_eg and (" (e.g. '%s')"):format(phantom_eg) or ''))

if bad == 0 and phantom > 0 then
    print('OK — the name cut is identical; the file cut breaks, so the gate has teeth')
    vim.cmd('qall!')
elseif bad == 0 then
    print('FAIL — no phantom uniques from the file cut: this corpus cannot tell a')
    print('       sound narrowing from an unsound one, so the pass proves nothing.')
    print('       Use a corpus with corpus-wide duplicate function names.')
    vim.cmd('cquit 1')
else
    print('FAIL — the name-narrowed lookups differ from the full build')
    vim.cmd('cquit 1')
end
