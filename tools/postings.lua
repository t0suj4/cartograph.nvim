-- postings — gate + SIZE the mention postings (store.build_postings), step 1 of
-- index-and-reduce ([[cartograph-merging-strategies]]).
--
-- WHY a tool and not just a spec: the whole demand-query plan rests on one
-- unmeasured claim — that inverting data.names into name -> files costs a small
-- fraction of what the graph costs. If the postings are heavy, nothing downstream
-- is worth building, so this measures BEFORE any query machinery exists.
--
-- WHAT IT REPORTS:
--   INDEX     data.names as it sits on disk today (bytes, files, occurrences)
--   POSTINGS  distinct names, posting slots, build time, resident MB
--   RATIO     postings MB vs the whole graph's MB — the affordability number
--   QUERY     postings lookup vs the linear scan it replaces, same answers
--
-- FAITHFULNESS is a DIFFERENTIAL over every distinct name, not a sample:
-- store.mentioning (postings) must equal store.mentioning_scan (the pre-index
-- scan) for all of them. Exit 1 on any divergence.
--
--   nvim --headless -u NONE -l tools/postings.lua [corpus]   (default: self)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()
package.path = repo .. '/tools/?.lua;' .. package.path

local store = require 'cartograph.store'
local hr = vim.uv.hrtime
local function mb() collectgarbage(); collectgarbage(); return collectgarbage('count') / 1024 end

local name = arg[1] or repo -- default: measure the plugin's own tree

-- === the graph (data.names rides along; no extra extraction cost) ===
local g0 = mb()
local data = bench.extract(name)
local m_graph = mb() - g0

local names = data.names or {}
local n_files, n_bytes, n_occ = 0, 0, 0
for _, s in pairs(names) do
    n_files = n_files + 1
    n_bytes = n_bytes + #s
    for _ in s:gmatch('[^\31]+') do n_occ = n_occ + 1 end
end

if n_files == 0 then
    print(('postings: %s produced no mention index (data.names empty) —'):format(name))
    print('  every parsed language opted out (spec.name_index = false), or the')
    print('  id pass did not run. Nothing to measure; not a failure.')
    vim.cmd('qall!')
    return
end

-- === build the postings ===
local b0 = mb(); local t0 = hr()
local px = store.build_postings(names)
local t_build, m_post = (hr() - t0) / 1e6, mb() - b0

local n_names, n_slots, maxlen, maxname = 0, 0, 0, '?'
for nme, p in pairs(px.post) do
    n_names = n_names + 1
    n_slots = n_slots + #p
    if #p > maxlen then maxlen, maxname = #p, nme end
end

-- === differential: postings vs the scan it replaces ===
-- Every name when that is affordable. The oracle half is a LINEAR SCAN, so the
-- work is names x files — on a big corpus that is hours, not seconds. Above the
-- budget it checks a deterministic prefix and SAYS which names it did not check
-- (a silent cap would read as "all names verified", which is the one thing a
-- gate must never imply).
store.ingest(data)
local BUDGET = 20e6 -- name-file comparisons
local cap = math.huge
if n_names * n_files > BUDGET then cap = math.max(200, math.floor(BUDGET / n_files)) end
local checked, diverged, shown = 0, 0, 0
local t1 = hr()
for nme in pairs(px.post) do
    if checked >= cap then break end
    checked = checked + 1
    local a = store.mentioning(nme)
    local b = store.mentioning_scan(nme)
    local same = #a == #b
    if same then for i = 1, #a do if a[i] ~= b[i] then same = false; break end end end
    if not same then
        diverged = diverged + 1
        if shown < 5 then
            shown = shown + 1
            print(('    DIVERGED %q — postings %d files, scan %d files')
                :format(nme, #a, #b))
        end
    end
end
local t_diff = (hr() - t1) / 1e6

-- === query cost: the same N lookups each way ===
local sample, ns = {}, 0
for nme in pairs(px.post) do ns = ns + 1; sample[ns] = nme; if ns >= 200 then break end end
local t2 = hr()
for _, nme in ipairs(sample) do store.mentioning(nme) end
local t_post_q = (hr() - t2) / 1e6
local t3 = hr()
for _, nme in ipairs(sample) do store.mentioning_scan(nme) end
local t_scan_q = (hr() - t3) / 1e6

print(('postings %s'):format(name))
print(('  INDEX     %d files · %.1f KB of data.names on disk · %d occurrences')
    :format(n_files, n_bytes / 1024, n_occ))
print(('  POSTINGS  %d distinct names · %d slots · %.0f ms build · %.1f MB resident')
    :format(n_names, n_slots, t_build, m_post))
print(('  RATIO     postings %.1f MB vs graph %.1f MB  ==>  %.1f%% of the graph')
    :format(m_post, m_graph, m_graph > 0 and (m_post / m_graph) * 100 or 0))
print(('  DENSEST   %q in %d files'):format(maxname, maxlen))
print(('  QUERY     %d lookups: postings %.1f ms · scan %.1f ms  ==>  %.0fx')
    :format(#sample, t_post_q, t_scan_q,
        t_post_q > 0 and t_scan_q / t_post_q or 0))
print(('  DIFFERENTIAL  %d/%d names checked in %.0f ms · %d diverged')
    :format(checked, n_names, t_diff, diverged))
if checked < n_names then
    print(('                CAPPED — %d names NOT checked against the scan oracle')
        :format(n_names - checked))
end

if diverged == 0 then
    print(('OK — postings == the scan they replace, over %s')
        :format(checked >= n_names and 'every name in the corpus'
            or ('%d of %d names (see CAPPED)'):format(checked, n_names)))
    vim.cmd('qall!')
else
    print('FAIL — the postings answer differently than the scan')
    vim.cmd('cquit 1')
end
