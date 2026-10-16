-- edgescore: score the RESOLVER's call edges (c.to) — not flowtype's verdicts — against a Go type checker's oracle
-- (the same TSV score.lua reads: file, 0-based line, col, member, concrete|interface, receiver type, def file, 0-based
-- def line, implementers). CART-1717: the instrument that showed Go's generic vocab words block 23 right edges and
-- prevent 65 wrong ones.
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_oracle/edgescore.lua <root> <oracle.tsv> [tests]
-- rows: in-tree concrete calls RIGHT / WRONG (confirmed or ~) or unresolved by refusal rule; external calls linked into
-- the tree (LINKED-WRONG: the checker says the callee is outside) or unlinked; interface calls linked to an implementer
-- or not.
local root, otsv, tests = arg[1], arg[2], arg[3] == 'tests'
local d = require('cartograph.providers.treesitter').extract(root)
local at = require 'cartograph.at'
local byid = {}
for _, n in ipairs(d.nodes) do byid[n.id] = n end
local calls = {}
for _, c in ipairs(d.calls) do
    local k = c.file .. '\t' .. c.line
    calls[k] = calls[k] or {}
    table.insert(calls[k], c)
end
local h = {}
local function bump(k) h[k] = (h[k] or 0) + 1 end
for ln in io.lines(otsv) do
    local file, line, _, m, kind, _, df, dl, impl = ln:match('^([^\t]*)\t(%d+)\t(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(%-?%d+)\t?(.*)$')
    if file and (tests or not file:match('_test%.go$')) then
        local c
        for _, x in ipairs(calls[file .. '\t' .. line] or {}) do
            local nm = tostring(x.full or x.callee)
            if nm == m or nm:match('[.:]' .. m .. '$') then c = x end
        end
        local n = c and c.to and byid[c.to]
        local hedge = c and c.inferred and ' ~' or ' confirmed'
        if df:match('^EXTERNAL') then
            bump(n and ('external LINKED-WRONG' .. hedge) or 'external unlinked')
        elseif kind == 'interface' then
            local okk = false
            for x in (impl or ''):gmatch('[^,]+') do if n and (n.file .. ':' .. at.sl(n.range)) == x then okk = true end end
            bump(n and ((okk and 'interface linked-ok' or 'interface LINKED-WRONG') .. hedge) or 'interface unlinked')
        elseif not c then bump('concrete: no call record')
        elseif not c.to then bump('concrete unresolved ' .. (c.refused and c.refused.rule or (c.ext and 'ext' or 'none')))
        else
            local ok = n and n.file == df and n.range and at.sl(n.range) == tonumber(dl)
            bump('concrete ' .. (ok and 'RIGHT' or 'WRONG') .. hedge)
        end
    end
end
local ks = vim.tbl_keys(h)
table.sort(ks, function (a, b) return h[a] > h[b] end)
for _, k in ipairs(ks) do print(('%6d  %s'):format(h[k], k)) end
