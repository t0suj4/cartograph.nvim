-- dogfood — cartograph on cartograph, one screen. The self-analysis report
-- both tools/dogfood.lua (headless / CI fence) and :CartographDogfood (in
-- editor) render: RESOLUTION (the honesty census + by_prov), SERVING (the LSP
-- answering its own graph), and LINT (incl. the BAND SEAM-GUARD — any raw read
-- of the wide index tables outside band.lua/store.lua, the P2b migration turned
-- into a regression fence). Pure over a store; the caller declares the seam.

local census = require 'cartograph.census'
local lint = require 'cartograph.lint'
local lsp = require 'cartograph.lsp'
local atr = require 'cartograph.at'

local M = {}

-- #1: the BAND SEAM — the wide index tables belong to band.lua/store.lua. Bracket
-- form only, so the whole-adjacency-map passers (bare `store.uses`, handed to
-- scc/cone/dominators) stay allowed; only per-node reads must go through the
-- Band. edge_inferred is OUT (one deferred reader, the honesty-vector follow-up).
M.BAND_SEAM = {
    name = 'band',
    owners = { 'cartograph/band%.lua$', 'cartograph/store%.lua$' },
    patterns = {
        'store%.uses%[', 'store%.usedby%[',
        'store%.calls_by_fn%[', 'store%.calls_by_file%[', 'store%.calls_by_prov%[',
        'store%.var_uses%[', 'store%.var_usedby%[', 'store%.reg_by%[',
        'store%.imports_out%[', 'store%.imports_in%[', 'store%.registers%[',
        'store%.edge_tier%[', 'store%.occ%[',
    },
}

-- SERVING: does the LSP answer its own graph? definition at each resolved
-- call's position must land on the call's graph target. <100% = a position-
-- math / call_at suspect (the value over a bare census).
local function serving_consistency(store)
    local served, consistent, mis = 0, 0, {}
    for _, c in ipairs(store.data.calls or {}) do
        if c.to and c.at then
            local n = store.node(c.to)
            if n and n.file and not n.external and n.range then
                served = served + 1
                local res = lsp.handle(store, 'textDocument/definition', {
                    textDocument = { uri = vim.uri_from_fname(store.abs(c.file)) },
                    position = { line = atr.sl(c.at), character = atr.sc(c.at) },
                })
                local wu, wl = vim.uri_from_fname(store.abs(n.file)), atr.sl(n.range)
                local hit = false
                for _, loc in ipairs(res or {}) do
                    if loc.uri == wu and loc.range.start.line == wl then hit = true; break end
                end
                if hit then consistent = consistent + 1
                elseif #mis < 8 then
                    mis[#mis + 1] = ('%s:%d %s'):format((c.file or '?'):gsub('.*/lua/', ''),
                        (c.line or 0) + 1, c.callee or '?')
                end
            end
        end
    end
    return served, consistent, mis
end

--- The dashboard, as report lines. Returns (lines, counts) where
--- counts.seam is the seam-guard breach count (0 = fence intact).
function M.report(store)
    local data = store.data
    local out = {}
    local function line(s) out[#out + 1] = s or '' end

    line(('cartograph dogfood — %s (%d nodes)'):format(
        (data.root or '?'):gsub('.*/', ''), #(data.nodes or {})))
    line('')

    line('RESOLUTION')
    for _, l in ipairs(census.report(data)) do
        if l:match('ref trust') or l:match('by stage') or l:match('^calls ') then
            line('  ' .. l:gsub('^%s+', ''))
        end
    end
    line('')

    local served, consistent, mis = serving_consistency(store)
    line('SERVING (LSP answers its own graph)')
    line(('  definition consistency: %d/%d (%s)'):format(consistent, served,
        served == 0 and '—' or ('%.1f%%'):format(consistent * 100 / served)))
    for _, m in ipairs(mis) do line('    ~ ' .. m) end
    line('')

    local findings = lint.run(store)
    local by_rule, seam_sites = {}, {}
    for _, f in ipairs(findings) do
        by_rule[f.rule] = (by_rule[f.rule] or 0) + 1
        if f.rule == 'seam-guard' and #seam_sites < 12 then
            seam_sites[#seam_sites + 1] = ('%s:%d'):format((f.file or '?'):gsub('.*/lua/', ''), f.line or 0)
        end
    end
    local seam_n = by_rule['seam-guard'] or 0
    line('LINT')
    line(('  seam-guard (Band): %d %s'):format(seam_n, seam_n == 0 and '✓ intact' or '✗ BREACH'))
    for _, s in ipairs(seam_sites) do line('    ' .. s) end
    local rules = {}
    for r in pairs(by_rule) do if r ~= 'seam-guard' then rules[#rules + 1] = r end end
    table.sort(rules, function (a, b) return by_rule[a] > by_rule[b] end)
    for _, r in ipairs(rules) do line(('  %-18s %d'):format(r, by_rule[r])) end

    return out, { seam = seam_n, served = served, consistent = consistent }
end

--- Run the report on the OPEN graph with the Band seam declared (non-
--- destructively — a user's own seams are preserved). Returns (lines, counts).
function M.run(store)
    local config = require 'cartograph.config'
    local saved = config.seams
    local merged = { M.BAND_SEAM }
    for _, s in ipairs(saved or {}) do merged[#merged + 1] = s end
    config.seams = merged
    local ok, lines, counts = pcall(M.report, store)
    config.seams = saved
    if not ok then error(lines) end
    return lines, counts
end

return M
