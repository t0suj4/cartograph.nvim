-- scopekey — gate + measure SCOPE-CONFINED candidates (store.mentioning_in),
-- step 3 of index-and-reduce ([[cartograph-merging-strategies]]).
--
-- THE CLAIM: mentioning_in(name, from) returns exactly the candidates the reduce
-- would have KEPT — it pre-applies the cut the id pass makes anyway (a candidate
-- whose scope differs from the mention's is dropped) rather than approximating it.
-- So no answer changes; only the number of files a demand query must load.
--
-- THE GATE is a differential against store.mentioning_in_scan, which compares
-- scope STRINGS straight off the map — a different mechanism from the interned-id
-- parallel array under test, so it checks the machinery instead of restating it.
--
-- THE MEASUREMENT is what a query actually loads: candidates per (file, name)
-- mention, plain vs confined, reported at the mean AND the tail. The tail is the
-- point — an unbounded worst case is what makes demand resolution useless, and
-- p99 is where plain-name keys fall apart (4648 files on server).
--
--   nvim --headless -u NONE -l tools/scopekey.lua [corpus] [sample]
--     corpus  default: the plugin's own tree
--     sample  mentions to check in the differential (default 20000)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()

local store = require 'cartograph.store'
local hr = vim.uv.hrtime

local name = arg[1] or repo
local budget = tonumber(arg[2] or '20000') or 20000

local data = bench.extract(name)
store.ingest(data)

local t0 = hr()
local scopes = store.scopes()
local t_scopes = (hr() - t0) / 1e6
local px = store.scope_axis(store.postings(), scopes)

if px.n_files == 0 then
    print('scopekey: no mention index on this corpus — nothing to confine')
    vim.cmd('cquit 1')
    return
end

local n_distinct = px.n_scopes or 0
local unscoped = 0
for i = 1, px.n_files do if (px.fscope or {})[i] == 0 then unscoped = unscoped + 1 end end

-- === MEASURE: candidates per mention, plain vs scope-confined ===
local pl, sl = {}, {}
local tot_p, tot_s, n_mentions = 0, 0, 0
for i = 1, px.n_files do
    local f = px.files[i]
    for nme in ((data.names or {})[f] or ''):gmatch('[^\31]+') do
        local a = #(px.post[nme] or {})
        local b = #store.mentioning_in(nme, f)
        pl[#pl + 1] = a; sl[#sl + 1] = b
        tot_p = tot_p + a; tot_s = tot_s + b; n_mentions = n_mentions + 1
    end
end
local function pctl(t, p)
    if #t == 0 then return 0 end
    table.sort(t)
    return t[math.max(1, math.ceil(#t * p))]
end

-- === GATE: confined == the direct scope-string filter, over sampled mentions ===
local checked, diverged, shown = 0, 0, 0
local t1 = hr()
for i = 1, px.n_files do
    if checked >= budget then break end
    local f = px.files[i]
    for nme in ((data.names or {})[f] or ''):gmatch('[^\31]+') do
        if checked >= budget then break end
        checked = checked + 1
        local a = table.concat(store.mentioning_in(nme, f), ',')
        local b = table.concat(store.mentioning_in_scan(nme, f), ',')
        if a ~= b then
            diverged = diverged + 1
            if shown < 5 then
                shown = shown + 1
                print(("    DIVERGED '%s' from %s"):format(nme, f))
            end
        end
    end
end
local t_diff = (hr() - t1) / 1e6

-- === a confined answer must never LOSE a candidate the reduce would keep ===
-- (subset in the wrong direction is the dangerous failure: silently fewer)
local lost = 0
for i = 1, math.min(px.n_files, 200) do
    local f = px.files[i]
    for nme in ((data.names or {})[f] or ''):gmatch('[^\31]+') do
        local keep = {}
        for _, g in ipairs(store.mentioning_in(nme, f)) do keep[g] = true end
        for _, g in ipairs(store.mentioning(nme)) do
            if (scopes or {})[g] == (scopes or {})[f] and not keep[g] then lost = lost + 1 end
        end
    end
end

print(('scopekey %s'):format(name))
print(('  SCOPES    %d distinct · %d/%d indexed files unscoped · computed in %.0f ms')
    :format(n_distinct, unscoped, px.n_files, t_scopes))
print(('  CANDIDATES per mention over %d mentions'):format(n_mentions))
print(('    mean   %8.1f -> %-8.1f  %.1fx fewer files to load')
    :format(tot_p / n_mentions, tot_s / n_mentions,
        tot_s > 0 and tot_p / tot_s or 0))
print(('    p50    %8d -> %-8d'):format(pctl(pl, .5), pctl(sl, .5)))
print(('    p99    %8d -> %-8d  <-- the tail is the point')
    :format(pctl(pl, .99), pctl(sl, .99)))
print(('    max    %8d -> %-8d'):format(pctl(pl, 1), pctl(sl, 1)))
print(('  GATE      %d/%d mentions · %d diverged · %d lost candidates · %.0f ms')
    :format(checked, n_mentions, diverged, lost, t_diff))
if checked < n_mentions then
    print(('            CAPPED — %d mentions NOT checked (raise the sample arg)')
        :format(n_mentions - checked))
end
if n_distinct <= 1 then
    print('  NOTE      this corpus has no usable partition (<=1 distinct scope), so')
    print('            confinement cannot reduce anything here — the plain name stays')
    print('            the only key. Not a failure; a property of the partition.')
end

if diverged == 0 and lost == 0 then
    print('OK — confined candidates == the direct scope filter, nothing lost')
    vim.cmd('qall!')
else
    print('FAIL — confinement disagrees with the scope filter it claims to pre-apply')
    vim.cmd('cquit 1')
end
