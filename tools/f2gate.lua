-- f2gate — the FEDERATED-RESOLUTION reproduction diff (federation F2, [[cartograph-band-
-- federation]]). The gate that MUST be green before per-band resolution is wired into
-- production: for EVERY call the whole graph resolved (c.to = ground truth), does the
-- FEDERATED path (bandresolve: source-band index first, bandlink cross-band) reproduce
-- the SAME target — WITHOUT a whole-graph index? Verdicts, split IN-BAND vs CROSS-BAND
-- (by whether the target lives in the source's band):
--   REPRODUCED — federated found the same def (recall preserved under federation)
--   MISS       — whole-graph resolved it, federated didn't (recall lost to per-band
--                scoping: a global tail-unique that isn't band-unique, or a cross-band
--                ref with no const to route it — the honest, reconstructable residual)
--   WRONG      — federated resolved to a DIFFERENT def (SOUNDNESS violation — MUST be 0;
--                a band-local decoy the global uniqueness test didn't see). Each printed.
-- WRONG>0 fails. MISS is the recall cost of federation, quantified per band-locality.
-- See bandresolve for the KNOWN CONSERVATISM (WRONG here is an UPPER bound — verify each).
--
--   nvim --headless -u NONE -l tools/f2gate.lua <corpus>

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
if not name then print('usage: f2gate <corpus>'); os.exit(2) end
local data = bench.extract(name)
local band_of = ports.default_band_of(3)
local surf = ports.surface(data, band_of)
local idx = bandlink.indexes(data, band_of)
local chains = bandlink.chains(data)
local witness = bandresolve.tail_witness(data, ts.lang_of)

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

-- is owner A an ancestor/descendant of B (either direction) via the extends/ruby chains?
-- Used to tell a DISPATCH-OVERRIDE divergence (fed = syntactic owner, whole = a subtype's
-- override — the receiver-typed "what" refinement, sound at the name layer) from a true
-- WRONG sibling mis-link. Walks the single-parent super map + ruby instance adjacency.
local function related(a, b)
    if not (a and b) then return false end
    local function reaches(from, to)
        local seen, cur = { [from] = true }, from
        for _ = 1, 32 do
            local p = chains.super[cur]
            for _, q in ipairs(chains.inst[cur] or {}) do if q == to then return true end end
            if not p or p == false then break end
            if p == to then return true end
            if seen[p] then break end
            seen[p] = true; cur = p
        end
        return false
    end
    return reaches(a, b) or reaches(b, a)
end

-- tallies, split by band-locality of the ground-truth target
local rep = { inband = 0, xband = 0 }
local miss = { inband = 0, xband = 0 }
local wrong = { inband = 0, xband = 0 }
local rep_tier, miss_why = {}, {}
local wrong_ex, total, override = {}, 0, 0

for _, c in ipairs(data.calls or {}) do
    if c.to and c.file then
        local t = node_index[c.to]
        if t and t.file and not t.external then
            total = total + 1
            local sb, tb = band_of(c.file), band_of(t.file)
            local loc = (sb == tb) and 'inband' or 'xband'
            local key = c.full or c.callee
            local clang = ts.lang_of(c.file)
            local got, tier = bandresolve.resolve_call(
                key, sb, idx, surf.const_index, chains, witness, clang, ts.lang_of, bandlink)
            if got == c.to then
                rep[loc] = rep[loc] + 1
                rep_tier[tier] = (rep_tier[tier] or 0) + 1
            elseif got == nil then
                miss[loc] = miss[loc] + 1
                miss_why[loc .. ':' .. tier] = (miss_why[loc .. ':' .. tier] or 0) + 1
            else
                -- DISPATCH-OVERRIDE divergence, not a WRONG: fed gave the static-owner
                -- answer, whole gave a subtype's override (same tail, owners inheritance-
                -- related) — the receiver-typed refinement, sound at the name layer.
                local gnode = node_index[got]
                local ftail = gnode and gnode.name and gnode.name:match('([%w_]+)$')
                local ttail = t.name and t.name:match('([%w_]+)$')
                if ftail and ftail == ttail and gnode
                    and related(ports.owner_of(gnode.name), ports.owner_of(t.name)) then
                    override = override + 1
                else
                    wrong[loc] = wrong[loc] + 1
                    if #wrong_ex < 12 then wrong_ex[#wrong_ex + 1] =
                        ('[%s] %s: fed→%s (%s) vs whole→%s'):format(loc, tostring(key), got, tier, c.to) end
                end
            end
        end
    end
end

local function pct(x) return total > 0 and 100 * x / total or 0 end
local reptot = rep.inband + rep.xband
local misstot = miss.inband + miss.xband
local wrongtot = wrong.inband + wrong.xband
print(('f2gate %s — %d resolved calls (whole-graph ground truth)'):format(name, total))
print(('  REPRODUCED %d (%.1f%%)  [in-band %d · cross-band %d]')
    :format(reptot, pct(reptot), rep.inband, rep.xband))
print(('  MISS       %d (%.1f%%)  [in-band %d · cross-band %d]')
    :format(misstot, pct(misstot), miss.inband, miss.xband))
print(('  WRONG      %d (%.1f%%)  [in-band %d · cross-band %d]  <- MUST be 0')
    :format(wrongtot, pct(wrongtot), wrong.inband, wrong.xband))
print(('  override   %d (%.1f%%)  (fed=static owner, whole=subtype dispatch — sound at name layer)')
    :format(override, pct(override)))
do
    local ks = {}; for k in pairs(rep_tier) do ks[#ks + 1] = k end
    table.sort(ks, function (a, b) return rep_tier[a] > rep_tier[b] end)
    local p = {}; for _, k in ipairs(ks) do p[#p + 1] = ('%s %d'):format(k, rep_tier[k]) end
    if #p > 0 then print('  reproduced by tier: ' .. table.concat(p, ' · ')) end
end
do
    local ks = {}; for k in pairs(miss_why) do ks[#ks + 1] = k end
    table.sort(ks, function (a, b) return miss_why[a] > miss_why[b] end)
    local p = {}; for _, k in ipairs(ks) do p[#p + 1] = ('%s %d'):format(k, miss_why[k]) end
    if #p > 0 then print('  miss by locality:tier — ' .. table.concat(p, ' · ')) end
end
for _, e in ipairs(wrong_ex) do print('  WRONG ' .. e) end

if wrongtot > 0 then
    print('FAIL: federated resolution picked a different target than whole-graph (soundness)')
    print('  (verify each against bandresolve KNOWN CONSERVATISM before treating as a true hazard)')
    vim.cmd('cquit 1')
else
    print('OK — federated resolution never mis-links; MISS is the quantified recall cost of federation')
    vim.cmd('qall!')
end
