-- rescolacc — the STREAMING-ACCUMULATOR parity gate (record-fold step 2, the
-- parent-merge peak lever). rescols.accumulator folds worker chunks into columns
-- as they arrive and drops the records, so the parent never materializes the full
-- record array at the merge peak. This proves that path is faithful: feeding the
-- calls as OUT-OF-ORDER batches (+ a duplicate, to exercise the canonical reorder
-- and the per-file dedup) and finalizing yields a store BYTE-IDENTICAL to
-- rescols.view over the calls in canonical order — record-for-record, argv
-- included. The resident twin of the "stream-and-drop == build-from-whole" claim.
--
--   nvim --headless -u NONE -l tools/rescolacc.lua <corpus>
-- Exit 1 on any divergence, 2 if not applicable.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/rescolacc%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local rescols = require 'cartograph.rescols'

local name = arg and arg[1]
if not name then print('usage: rescolacc <corpus>'); os.exit(2) end
if not pcall(bench.corpus, name) then print('unknown corpus: ' .. name); os.exit(2) end

-- a canonical, key-sorted serialization of a materialized record (recursive, so
-- nested argv element tables / ranges / refused compare structurally)
local function canon(v)
    if type(v) ~= 'table' then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. canon(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
end

local data = bench.extract(name)
local calls = data.calls or {}

-- REFERENCE: rescols.view over the calls in canonical (extract/file) order
local ref = rescols.view(calls)

-- canonical rank per file = first-appearance order in the extracted calls (the
-- fileset order a real parent would reorder to)
local fileorder, rank = {}, 0
for i = 1, #calls do
    local f = calls[i].file
    if f and not fileorder[f] then rank = rank + 1; fileorder[f] = rank end
end

-- split the calls into contiguous per-file batches (a file lives in one chunk),
-- then feed them REVERSED (racy arrival) through the accumulator, and re-feed the
-- first batch at the end (a demanded file's duplicate → must be deduped away)
local batches, cur = {}, nil
for i = 1, #calls do
    local f = calls[i].file
    if not cur or cur.file ~= f then cur = { file = f }; batches[#batches + 1] = cur end
    cur[#cur + 1] = calls[i]
end
local acc = rescols.accumulator({ fileorder = fileorder })
for b = #batches, 1, -1 do acc.add(batches[b]) end
if batches[1] then acc.add(batches[1]) end -- duplicate → deduped
local store = acc.finalize()

print(('rescolacc %s — %d calls · %d batches (fed reversed + 1 dup)')
    :format(name, #calls, #batches))

local fails = {}
local nref, nacc = #calls, store.cc.n
if nref ~= nacc then
    fails[#fails + 1] = ('row count %d (view) vs %d (accumulator)'):format(nref, nacc)
else
    for i = 1, nref do
        local a = canon(rescols.record(ref, i))
        local b = canon(rescols.record(store, i))
        if a ~= b then
            fails[#fails + 1] = ('row #%d diverged:\n      view: %s\n      acc : %s')
                :format(i, a, b)
            if #fails >= 10 then break end
        end
    end
end

if #fails > 0 then
    print('FAIL:')
    for _, f in ipairs(fails) do print('  - ' .. f) end
    vim.cmd('cquit 1')
else
    print('OK — the streaming accumulator (reorder + dedup) == rescols.view build-from-whole')
    vim.cmd('qall!')
end
