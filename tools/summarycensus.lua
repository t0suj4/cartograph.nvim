-- summarycensus — the SUMMARY-SURFACE census (federation, [[cartograph-consumer-federation]]).
-- The design question (user 2026-07-23 "federated runs would need to leave usable summaries …
-- maybe there is space to build them if they're missing"): per language, for each summary a
-- cross-band consumer needs, is it (a) LEFT as a byproduct, or (c) MISSING → a synthesis gap
-- the VM must fill? Generalizes retceil's ret-tier story to the whole summary set; sizes the
-- VM-as-summary-synthesizer work BEFORE building it.
--
-- Two layers:
--   STORED (free at extract, per-def node fields): ret (return TYPE — the cross-band resolution
--     keystone), exported (visibility), params (signature), retclass (generic). TYPED langs
--     declare ret; DYNAMIC langs don't → the synthesis gap.
--   DERIVED (byproduct of a band's ANALYSIS run — effects.purity over the write-axis): the
--     effects summary (pure / io / writes, hedged ~). Present iff analysed; unknown = the gap.
-- CAVEAT: purity is trustworthy only where the per-lang WRITE-CLASSIFIER populates rw/gw on use
-- edges (lua today). Langs without it show artifactual all-pure (NOT classified ≠ truly pure) —
-- read that as "effects summary not yet derivable for this lang", itself a gap finding.
--
--   nvim --headless -u NONE -l tools/summarycensus.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local effects = require 'cartograph.effects'

local name = arg[1]
if not name then print('usage: summarycensus <corpus>'); os.exit(2) end
local data = bench.extract(name)
store.ingest(data)

-- per-language tallies over fn/method defs
local L = {}
local function lang(l)
    local r = L[l]
    if not r then
        r = { n = 0, ret = 0, exported = 0, params = 0, retclass = 0,
            pure = 0, io = 0, writes = 0, hedged = 0, punknown = 0 }
        L[l] = r
    end
    return r
end

local ok_purity = pcall(function () effects.summaries(store) end) -- warm/validate the effects layer
for _, n in ipairs(data.nodes or {}) do
    if (n.kind == 'function' or n.kind == 'method') and not n.torn and not n.decl and n.file then
        local r = lang(ts.lang_of(n.file))
        r.n = r.n + 1
        if n.ret then r.ret = r.ret + 1 end
        if n.exported ~= nil then r.exported = r.exported + 1 end
        if n.params then r.params = r.params + 1 end
        if n.retclass then r.retclass = r.retclass + 1 end
        if ok_purity then
            local l = effects.purity(store, n.id)
            if not l then r.punknown = r.punknown + 1
            else
                local hedged = l:find('~', 1, true) ~= nil
                if hedged then r.hedged = r.hedged + 1 end
                local base = l:gsub('~', '')
                if base == 'pure' then r.pure = r.pure + 1
                elseif base == 'io' then r.io = r.io + 1
                elseif base == 'writes' then r.writes = r.writes + 1 end
            end
        end
    end
end

local langs = {}; for l in pairs(L) do langs[#langs + 1] = l end
table.sort(langs, function (a, b) return L[a].n > L[b].n end)
local function pc(x, d) return d > 0 and 100 * x / d or 0 end
print(('summarycensus %s%s'):format(name, ok_purity and '' or '  (purity layer unavailable — STORED only)'))
for _, l in ipairs(langs) do
    local r = L[l]
    if r.n >= 20 then
        print(('  %-11s %6d defs'):format(l, r.n))
        print(('    STORED  ret %5.1f%% · exported %5.1f%% · params %5.1f%% · retclass %.1f%%')
            :format(pc(r.ret, r.n), pc(r.exported, r.n), pc(r.params, r.n), pc(r.retclass, r.n)))
        if ok_purity then
            print(('    DERIVED purity: pure %.0f%% · io %.0f%% · writes %.0f%% · (hedged~ %.0f%%) · UNKNOWN %.0f%%')
                :format(pc(r.pure, r.n), pc(r.io, r.n), pc(r.writes, r.n), pc(r.hedged, r.n), pc(r.punknown, r.n)))
        end
        print(('    SYNTHESIS GAP: ret-absent %.1f%% (VM must infer the type)%s')
            :format(100 - pc(r.ret, r.n), ok_purity and (' · purity-unknown ' .. ('%.0f%%'):format(pc(r.punknown, r.n))) or ''))
    end
end
vim.cmd('qall!')
