-- hybridtemp — the HYBRID-BY-TEMPERATURE probe ([[cartograph-thin-index]]). Resident call
-- records are fat mostly from PER-PRESENT-FIELD hash-slot overhead (~40 B/slot). A hybrid
-- would keep HOT fields fast (columns/direct) and pack COLD sparse fields into a lazy
-- bytecode blob (one slot/call instead of one/cold-field). This only wins if the COLD tail
-- is a big share of the slots. Measures, on the POST-INGEST records: slots per field, the
-- hot vs cold vs folded-index split, and the MB a cold-field bytecode blob would save.
--
--   nvim --headless -u NONE -l tools/hybridtemp.lua [corpus]   (default: libs)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local store = require 'cartograph.store'

local name = arg[1] or 'libs'
local SLOT = 40 -- bytes per Lua hash-table slot (node + key/value refs); rough, consistent

-- HOT = fields read on the hot paths (resolution / LSP-nav / census / lint) — must stay fast.
local HOT = { callee = true, full = true, file = true, line = true, fn = true,
    to = true, refused = true, at = true, method = true }
-- folded-argv handle (index into the shared argv store) — not a value, a pointer triple
local FOLDED = { _av = true, _av0 = true, _avn = true }

local data = bench.extract_parallel(name)
store.ingest(data)
local calls = store.data.calls or {}
if store.data._callstore then calls = require('cartograph.rescols').materialize(store.data._callstore) end
local N = #calls

local slots = {}
local hot_slots, cold_slots, folded_slots, total = 0, 0, 0, 0
local calls_with_cold = 0
for _, c in ipairs(calls) do
    local has_cold = false
    for k in pairs(c) do
        slots[k] = (slots[k] or 0) + 1
        total = total + 1
        if HOT[k] then hot_slots = hot_slots + 1
        elseif FOLDED[k] then folded_slots = folded_slots + 1
        else cold_slots = cold_slots + 1; has_cold = true end
    end
    if has_cold then calls_with_cold = calls_with_cold + 1 end
end

local order = {}
for k in pairs(slots) do order[#order + 1] = k end
table.sort(order, function (a, b) return slots[a] > slots[b] end)

local function mb(s) return s * SLOT / 1048576 end
print(('hybridtemp %s — %d calls, %d total field-slots (~%.1f MB @ %dB/slot)')
    :format(name, N, total, mb(total), SLOT))
print('  ── slots per field (HOT / cold / folded-index) ──')
for _, k in ipairs(order) do
    local tag = HOT[k] and 'HOT ' or FOLDED[k] and 'fold' or 'cold'
    print(('    %-4s %-12s %8d  (%.0f%%)'):format(tag, k, slots[k], 100 * slots[k] / N))
end
print('  ── the split ──')
print(('    HOT   slots: %8d  (~%.1f MB, %.0f%% of slots)'):format(hot_slots, mb(hot_slots), 100 * hot_slots / total))
print(('    COLD  slots: %8d  (~%.1f MB, %.0f%% of slots)'):format(cold_slots, mb(cold_slots), 100 * cold_slots / total))
print(('    fold  slots: %8d  (~%.1f MB, %.0f%% of slots)'):format(folded_slots, mb(folded_slots), 100 * folded_slots / total))
-- a cold-field bytecode blob = ONE slot per call-with-cold, replacing cold_slots
local blob_slots = calls_with_cold
local saved = mb(cold_slots) - mb(blob_slots)
print(('  ── hybrid verdict ──'))
print(('    bytecoding COLD fields: %d cold slots → %d blob slots (1 per %d calls-with-cold)')
    :format(cold_slots, blob_slots, calls_with_cold))
print(('    ≈ %.1f MB saved  (%.0f%% of the record mass) — the HOT %.0f%% stays fast, untouched')
    :format(saved, 100 * (mb(cold_slots) - mb(blob_slots)) / mb(total), 100 * hot_slots / total))
vim.cmd('qall!')
