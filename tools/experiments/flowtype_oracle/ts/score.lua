-- score cartograph.flowtype's JS/TS walker against the TypeScript checker (tools/experiments/flowtype_oracle/ts):
--   nvim -l score.lua <root> <oracle tsv> [tests]
-- class / object / other rows: flow's exact answer must be the checker's declaration (same file and line), a set
-- must contain it. interface rows: the checker answers the interface member — scored for coverage only.
local root, otsv = arg[1], arg[2]
local store = require 'cartograph.store'
local t0 = vim.uv.hrtime()
store.ingest(require('cartograph.providers.treesitter').extract(root))
local t1 = vim.uv.hrtime()
local R = require('cartograph.flowtype').of(store, { open = false,
    exclude = arg[3] ~= 'tests' and '[%._]?[st][pe][es][ct]%.[jt]sx?$' or nil })
local t2 = vim.uv.hrtime()
local fl = {}
for _, p in ipairs(R.probes) do fl[p.file .. '\t' .. p.line .. '\t' .. p.col .. '\t' .. p.member] = p end
local function declpos(id) local f, l = tostring(id):match('^(.-)::.-@(%d+)$'); return f, tonumber(l) end
local cnt, ex = {}, {}
local function bump(k, sample) cnt[k] = (cnt[k] or 0) + 1; ex[k] = ex[k] or {}; if #ex[k] < 6 and sample then ex[k][#ex[k] + 1] = sample end end
for ln in io.lines(otsv) do
    local file, line, col, m, kind, df, dl = ln:match('^([^\t]*)\t(%d+)\t(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(%d+)$')
    if file then
        local scope = (df:match('^EXTERNAL') and 'ext' or 'tree') .. '/' .. kind
        local p = fl[file .. '\t' .. line .. '\t' .. col .. '\t' .. m]
        local v
        if not p then v = 'no-probe'
        elseif p.kind == 'none' or p.kind == 'unknown' then v = p.kind
        elseif kind == 'interface' or kind == 'abstract' or kind == 'field' or kind == 'other' then v = 'answered-' .. p.kind
        else
            local hit = false
            for _, id in ipairs(p.targets) do local f2, l2 = declpos(id); if f2 == df and l2 == tonumber(dl) then hit = true end end
            if p.kind == 'exact' then v = hit and 'EXACT-RIGHT' or 'EXACT-WRONG' else v = hit and 'set-contains' or 'SET-MISSES' end
        end
        bump(scope .. ' ' .. v, (v == 'EXACT-WRONG' or v == 'SET-MISSES' or v == 'no-probe') and
            (file .. ':' .. (line + 1) .. ' ' .. m .. ' truth ' .. df .. ':' .. (dl + 1) .. ' flow ' .. (p and table.concat(p.targets, ',') or '-')) or nil)
    end
end
print(('extract %.1f s, flow %.1f s; flow probes %d'):format((t1 - t0) / 1e9, (t2 - t1) / 1e9, #R.probes))
local ks = {} for k in pairs(cnt) do ks[#ks + 1] = k end table.sort(ks)
for _, k in ipairs(ks) do print(('  %6d  %s'):format(cnt[k], k)) end
for _, k in ipairs(ks) do if #ex[k] > 0 then print(k); for _, e in ipairs(ex[k]) do print('     ', e) end end end
