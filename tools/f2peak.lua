-- f2peak — the F2 PEAK-WIN measurement (federation, [[cartograph-band-federation]] /
-- [[cartograph-record-fold-arc]] the peak arc). The gate that decides whether wiring
-- federated resolution into PRODUCTION is worth it: the peak arc established the merge
-- peak = the ONE whole-graph index + its ref-edge working set. Per-band indexes SUMMED
-- ≈ the global index — so federation lowers the peak ONLY if resolution STREAMS (resolve
-- a band holding only ITS index + the indexes of the bands it LINKS TO, then release).
-- The win is real iff the max streaming working set << the global index, which depends
-- entirely on the LINKAGE FAN-OUT. This measures that ratio from the band structure,
-- BEFORE building the (large, risky) streaming driver — measure-first on the whole F2
-- production premise (the ifaceceil discipline applied to the peak).
--
-- Working set to resolve band B = nodes(B) + Σ nodes(the bands B's needs route to via the
-- constant→band linkage). peak_stream = max_B working_set(B); global = Σ_B nodes(B).
-- A hub band needed by everyone inflates the union — that shows up here, honestly.
--
--   nvim --headless -u NONE -l tools/f2peak.lua <corpus> [depth]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ports = require 'cartograph.ports'

local name = arg[1]
if not name then print('usage: f2peak <corpus> [depth]'); os.exit(2) end
local depth = tonumber(arg[2]) or 3
local data = bench.extract(name)
local band_of = ports.default_band_of(depth)
local surf = ports.surface(data, band_of)

-- approx resident bytes of a value (proxy for the working set).
local function bytes(v)
    local t = type(v)
    if t == 'string' then return #v
    elseif t == 'number' then return 8
    elseif t == 'boolean' then return 1
    elseif t == 'table' then
        local s = 0
        for k, x in pairs(v) do s = s + bytes(x) + (type(k) == 'string' and #k or 4) end
        return s
    else return 4 end
end
-- SYMBOL subset a cross-band ref actually reads (bandlink: id + kind + file(lang) + name-key).
-- Everything else (flow/df/range/params/…) is ANALYSIS DETAIL never touched by resolution.
local SYM = { id = true, name = true, kind = true, file = true }

-- per band: node count + FULL-detail bytes; plus the global light SYMBOL TABLE bytes.
local nodes_b, defs_b, detail_b, all_nodes, all_defs = {}, {}, {}, 0, 0
local detail_bytes, symtab_bytes = 0, 0
for _, n in ipairs(data.nodes or {}) do
    if n.file then
        local b = band_of(n.file)
        nodes_b[b] = (nodes_b[b] or 0) + 1
        all_nodes = all_nodes + 1
        local nb = bytes(n)
        detail_b[b] = (detail_b[b] or 0) + nb
        detail_bytes = detail_bytes + nb
        if (n.kind == 'function' or n.kind == 'method') and not n.torn and not n.decl then
            defs_b[b] = (defs_b[b] or 0) + 1
            all_defs = all_defs + 1
            for k, v in pairs(n) do if SYM[k] then symtab_bytes = symtab_bytes + bytes(v) + #k end end
        end
    end
end

-- neighbours(B) = the bands B must hold indexes for to resolve its cross-band needs:
-- each need's owner constant routes (const→band) to its defining band(s).
local nbands = 0; for _ in pairs(nodes_b) do nbands = nbands + 1 end
local max_ws, max_ws_band, fanout_sum, fanout_max = 0, nil, 0, 0
for b, bnd in pairs(surf.bands) do
    local nbrs, nn = {}, 0
    for key in pairs(bnd.needs or {}) do
        local owner = ports.owner_of(key)
        if owner and ports.is_const(owner) then
            for tb in pairs(surf.const_index[owner] or {}) do
                if tb ~= b and not nbrs[tb] then nbrs[tb] = true; nn = nn + 1 end
            end
        end
    end
    local ws = nodes_b[b] or 0
    for tb in pairs(nbrs) do ws = ws + (nodes_b[tb] or 0) end
    fanout_sum = fanout_sum + nn
    if nn > fanout_max then fanout_max = nn end
    if ws > max_ws then max_ws = ws; max_ws_band = b end
end

-- band-size distribution
local sizes = {}; for _, v in pairs(nodes_b) do sizes[#sizes + 1] = v end
table.sort(sizes)
local med = sizes[math.ceil(#sizes / 2)] or 0
local biggest = sizes[#sizes] or 0

print(('f2peak %s (depth %d) — %d bands, %d nodes (%d defs)')
    :format(name, depth, nbands, all_nodes, all_defs))
print(('  band size (nodes): median %d · max %d · mean %.0f')
    :format(med, biggest, nbands > 0 and all_nodes / nbands or 0))
print(('  linkage fan-out (neighbour bands): mean %.1f · max %d')
    :format(nbands > 0 and fanout_sum / nbands or 0, fanout_max))
print(('  GLOBAL index working set: %d nodes'):format(all_nodes))
print(('  STREAMING peak working set (max band + its linked neighbours): %d nodes  (band %s)')
    :format(max_ws, tostring(max_ws_band)))
local ratio = all_nodes > 0 and 100 * max_ws / all_nodes or 0
print(('  ==> DIRECT-detail streaming peak = %.1f%% of global  (%.1fx)  [neighbours held as FULL detail]')
    :format(ratio, max_ws > 0 and all_nodes / max_ws or 0))

-- === INDIRECTION model: a compact global SYMBOL TABLE (id+kind+file per def) replaces
-- holding neighbour DETAIL. Cross-band refs resolve against the flat symbol table (no
-- neighbour term → FAN-OUT INDEPENDENT); the heavy per-node detail (flow/df — analysis
-- payload) is streamed/deferred, never co-resident for resolution. ===
local max_det_b, max_det = nil, 0
for b, d in pairs(detail_b) do if d > max_det then max_det = d; max_det_b = b end end
local kb = function (x) return math.floor(x / 1024) end
local peak_indirect = symtab_bytes + max_det          -- symtab + one band's detail at a time
local peak_reso = symtab_bytes                         -- resolution-only (detail not needed at all)
print('  --- INDIRECTION (global symbol table, detail streamed) ---')
print(('  full node detail: %d KB · global SYMBOL TABLE {id,kind,file,name}: %d KB = %.1f%% (fan-out FREE)')
    :format(kb(detail_bytes), kb(symtab_bytes), 100 * symtab_bytes / detail_bytes))
print(('  resolution-only peak (symtab, no detail):        %d KB = %.1f%% of global  (%.1fx)')
    :format(kb(peak_reso), 100 * peak_reso / detail_bytes, peak_reso > 0 and detail_bytes / peak_reso or 0))
print(('  symtab + one band detail (biggest = %s): %d KB = %.1f%% of global  (%.1fx)')
    :format(tostring(max_det_b), kb(peak_indirect), 100 * peak_indirect / detail_bytes,
        peak_indirect > 0 and detail_bytes / peak_indirect or 0))
print('  VERDICT: with a global symbol table, the peak decouples from fan-out — the win is the')
print('           symbol-table fraction; finer banding shrinks the streamed per-band detail freely.')
vim.cmd('qall!')
