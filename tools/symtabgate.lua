-- symtabgate — the SYMBOL-TABLE equivalence + realized-peak gate (federation F2 step 3,
-- [[cartograph-band-federation]]). Proves the light build_symtab index (compact stubs) is
-- RESOLUTION-EQUIVALENT to the full build_index: for every resolved call, bandresolve
-- resolves to the SAME id against both. If any call diverges, the stub is missing a field
-- resolution reads → FAIL. Also MEASURES the realized peak: resident bytes of the per-band
-- symbol tables vs the full per-band indexes (the f2peak model, now with real allocation).
--
--   nvim --headless -u NONE -l tools/symtabgate.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ports = require 'cartograph.ports'
local bandlink = require 'cartograph.bandlink'
local bandresolve = require 'cartograph.bandresolve'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1]
if not name then print('usage: symtabgate <corpus>'); os.exit(2) end
local data = bench.extract(name)
local band_of = ports.default_band_of(3)
local surf = ports.surface(data, band_of)
local chains = bandlink.chains(data)
local witness = bandresolve.tail_witness(data, ts.lang_of)

local idx_full = bandlink.indexes(data, band_of)                    -- build_index (full nodes)
local idx_sym = bandlink.indexes(data, band_of, ts.build_symtab)    -- build_symtab (stubs)

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

-- 1. RESOLUTION EQUIVALENCE: same id from both indexes, per resolved call.
local checked, diverge, div_ex = 0, 0, {}
for _, c in ipairs(data.calls or {}) do
    if c.to and c.file then
        local t = node_index[c.to]
        if t and t.file and not t.external then
            checked = checked + 1
            local key, clang, sb = c.full or c.callee, ts.lang_of(c.file), band_of(c.file)
            local gf = bandresolve.resolve_call(key, sb, idx_full, surf.const_index, chains, witness, clang, ts.lang_of, bandlink)
            local gs = bandresolve.resolve_call(key, sb, idx_sym, surf.const_index, chains, witness, clang, ts.lang_of, bandlink)
            if gf ~= gs then
                diverge = diverge + 1
                if #div_ex < 8 then div_ex[#div_ex + 1] = ('%s: full→%s vs symtab→%s'):format(tostring(key), tostring(gf), tostring(gs)) end
            end
        end
    end
end

-- 2. REALIZED PEAK: bytes of the index entries (full node vs stub).
local function bytes(v)
    local t = type(v)
    if t == 'string' then return #v
    elseif t == 'number' then return 8
    elseif t == 'boolean' then return 1
    elseif t == 'table' then local s = 0; for k, x in pairs(v) do s = s + bytes(x) + (type(k) == 'string' and #k or 4) end; return s
    else return 4 end
end
local function index_bytes(idx)
    local total = 0
    for _, ix in pairs(idx) do
        for _, list in pairs({ ix.exact, ix.tail }) do
            for _, ents in pairs(list) do for _, e in ipairs(ents) do total = total + bytes(e) end end
        end
    end
    return total
end
local bf, bs = index_bytes(idx_full), index_bytes(idx_sym)
local kb = function (x) return math.floor(x / 1024) end

print(('symtabgate %s — %d resolved calls checked'):format(name, checked))
print(('  RESOLUTION EQUIVALENCE: %d divergences (full vs symtab)  <- MUST be 0'):format(diverge))
for _, e in ipairs(div_ex) do print('  DIVERGE ' .. e) end
print(('  REALIZED PEAK: full index %d KB · symbol table %d KB = %.1f%% (%.1fx smaller)')
    :format(kb(bf), kb(bs), bf > 0 and 100 * bs / bf or 0, bs > 0 and bf / bs or 0))

if diverge > 0 then
    print('FAIL: symtab resolution diverges from full-index — a stub is missing a field resolution reads')
    vim.cmd('cquit 1')
else
    print('OK — symbol table is resolution-equivalent to the full index; the light index is sound')
    vim.cmd('qall!')
end
