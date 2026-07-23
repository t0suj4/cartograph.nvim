-- typeeager — the BAND-LOCAL TYPE-INFERENCE eager-vs-deferred probe (federation,
-- [[cartograph-consumer-federation]] / [[cartograph-band-federation]]). eagergate asked this
-- of RESOLUTION; this asks it of TYPE FACTS: what fraction is derivable band-locally (eager,
-- committable at band-build) vs depends on a CROSS-BAND callee's summary (deferred to the
-- return-rounds fixpoint over the ret summary)?
--
-- Two type-fact populations we actually carry:
--   DECLARED RET (n.ret on a def) — band-local CONFIRMED (declared in the band itself); the
--     trivially-eager, monotone-top-tier baseline. Split by lang (typed vs dynamic).
--   RETURN-CHAIN calls (c.rt = the determining call whose target's ret types this one — the
--     graph-VM's receiver-chain inference): the type SOURCE is the determining call's target.
--     BAND-LOCAL if that target is in the same band (eager); CROSS-BAND if in another (needs
--     the ret summary → the deferred linkage/rounds pass).
-- The eager fraction = declared + in-band chains; the deferred = cross-band chains. Monotonicity
-- (safe to commit eagerly) is handled by the existing tinf→confirmed ladder, not measured here.
--
--   nvim --headless -u NONE -l tools/typeeager.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ports = require 'cartograph.ports'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1]
if not name then print('usage: typeeager <corpus>'); os.exit(2) end
local data = bench.extract(name)
local band_of = ports.default_band_of(3)

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end
local callidx = {}
for _, c in ipairs(data.calls or {}) do
    if c.file and c.at and c.at.start then
        callidx[c.file .. '\31' .. c.at.start.line .. '\31' .. c.at.start.char] = c
    end
end

-- 1. DECLARED RET (band-local confirmed) by lang
local defs, declared = {}, {}
for _, n in ipairs(data.nodes or {}) do
    if (n.kind == 'function' or n.kind == 'method') and not n.torn and not n.decl and n.file then
        local l = ts.lang_of(n.file)
        defs[l] = (defs[l] or 0) + 1
        if n.ret then declared[l] = (declared[l] or 0) + 1 end
    end
end

-- 2. RETURN-CHAIN calls: type source band-local vs cross-band
local chains, inband, xband, unres = 0, 0, 0, 0
for _, c in ipairs(data.calls or {}) do
    if c.rt and c.file then
        chains = chains + 1
        local det = callidx[c.file .. '\31' .. c.rt.r .. '\31' .. c.rt.c]
        local dn = det and det.to and node_index[det.to]
        if not dn or not dn.file then
            unres = unres + 1 -- determining call unresolved → no type source yet
        elseif band_of(dn.file) == band_of(c.file) then
            inband = inband + 1 -- type flows within the band → EAGER
        else
            xband = xband + 1 -- type crosses a band → needs the ret summary (DEFERRED)
        end
    end
end

local function pc(x, d) return d > 0 and 100 * x / d or 0 end
print(('typeeager %s'):format(name))
print('  DECLARED RET (band-local confirmed, per lang):')
local ls = {}; for l in pairs(defs) do ls[#ls + 1] = l end
table.sort(ls, function (a, b) return defs[a] > defs[b] end)
for _, l in ipairs(ls) do
    if defs[l] >= 20 then
        print(('    %-10s %5d defs · ret %.1f%%'):format(l, defs[l], pc(declared[l] or 0, defs[l])))
    end
end
print(('  RETURN-CHAIN type facts: %d total'):format(chains))
print(('    BAND-LOCAL (type source in-band → EAGER):     %d (%.1f%%)'):format(inband, pc(inband, chains)))
print(('    CROSS-BAND (needs a callee ret summary → DEFER): %d (%.1f%%)'):format(xband, pc(xband, chains)))
print(('    determining call unresolved (no type source):   %d (%.1f%%)'):format(unres, pc(unres, chains)))
vim.cmd('qall!')
