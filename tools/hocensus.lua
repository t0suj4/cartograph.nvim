-- hocensus — THE HELPER SIGNATURE OF EVERY NEAR PAIR, from the shipped code.
--
--   nvim --headless -u NONE -l tools/hocensus.lua [max_dist] [--detail]
--
-- ★★★ THIS EXISTS TO BE COMPARED, AND THE COMPARISON IS THE POINT. The reference
-- is `~/tools/templates/experiments/nearclones_binders.lua` — user-authored, read-only,
-- and an INDEPENDENT implementation of the same encoding. Two encoders agreeing on one
-- tree is real convergence (different origin, different author); a shipped module
-- agreeing with itself is not evidence of anything.
--
-- ⚠ AND THAT IS NOT A PLATITUDE HERE. The WHOLE higher-order section is byte-identical
-- between the prototype and the vendored copy — all 11 functions, 273 lines, helpers
-- included (`ho_distinct`, `ho_free_bound`, `ho_subst_vars`, `ho_apply`, `alpha_eq`, …),
-- not just `hoau`'s body. So ANY divergence in these numbers is the ENCODER — which is
-- exactly the half this absorption rewrote, and that is what makes the join diagnostic.
--
-- ⚠ FOUR DIVERGENCES ARE EXPECTED AND DELIBERATE, listed in `algebra.ho_term`'s header:
-- descent via `expr.children`, `type` keeping its kids, a valueless `pair` having arity 1,
-- and loop binders via `expr.walk`. Two of them can move the numbers: `type`'s kids make
-- the encoding FINER (a false agreement becomes an honest hole), the `pair` arity makes
-- one case COARSER. A difference outside those two is a bug, not a decision.
--
-- WHAT IT REPORTS, per pair: the helper signature CART-0698 asks for — how many VALUE
-- parameters (closed holes) and how many FUNCTION parameters (holes over the function's
-- own locals) an extracted helper would need.

-- ⚠ `<sfile>` IS NOT SET UNDER `-l` (E498) — the house bootstrap is
-- `debug.getinfo`, which is what every other tool in here uses.
local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local ho = require 'cartograph.hotemplate'

local max_dist, detail = 3, false
for _, a in ipairs(arg or {}) do
    if a == '--detail' then detail = true
    elseif tonumber(a) then max_dist = tonumber(a) end
end

store.ingest(ts.extract(root .. '/lua'))
local pairs_ = clones.near(store, { max_dist = max_dist })
io.write(('near pairs: %d  (max_dist %d)\n'):format(#pairs_, max_dist))

local agg = { n = 0, ok = 0, holes = 0, cart_params = 0, rename = 0, dep = 0, closed = 0,
    local_vs_term = 0, pairs_with_dep = 0, consistent = 0, inconsistent = 0 }
local dephist, refused, rows = {}, {}, {}
for idx, p in ipairs(pairs_) do
    agg.n = agg.n + 1
    local t, why = ho.of_pair(store, p)
    if not t then
        refused[#refused + 1] = ('#%-3d %s:%d / %s:%d — %s')
            :format(idx, p.a.name, p.a.line, p.b.name, p.b.line, why)
    else
        agg.ok = agg.ok + 1
        local an = clones.analyze_pair(p, store)
        local ren, dep, closed, lvt = 0, 0, 0, 0
        for _, h in ipairs(t.holes) do
            if h.kind == 'rename' then ren = ren + 1
            elseif h.kind == 'closed' then closed = closed + 1
            else
                dep = dep + 1
                if h.kind == 'local-vs-term' then lvt = lvt + 1 end
                dephist[h.arity] = (dephist[h.arity] or 0) + 1
            end
        end
        agg.holes = agg.holes + #t.holes
        agg.cart_params = agg.cart_params + #((an or {}).holes or {})
        agg.rename, agg.dep, agg.closed = agg.rename + ren, agg.dep + dep, agg.closed + closed
        agg.local_vs_term = agg.local_vs_term + lvt
        if dep > 0 then agg.pairs_with_dep = agg.pairs_with_dep + 1 end
        if t.renaming == 'consistent' then agg.consistent = agg.consistent + 1
        elseif t.renaming == 'inconsistent' then agg.inconsistent = agg.inconsistent + 1 end
        io.write(('#%-3d %-11s cart params=%2d insdel=%d | ho holes=%2d (rename=%d dep=%d closed=%d local-vs-term=%d) renaming %-12s %s | %s:%d / %s:%d\n')
            :format(idx, (an or {}).kind or '?', #((an or {}).holes or {}), (an or {}).insdel or 0,
                #t.holes, ren, dep, closed, lvt, t.renaming, ho.signature_text(t),
                p.a.name, p.a.line, p.b.name, p.b.line))
        if detail and dep > 0 then
            rows[#rows + 1] = ('\n■ #%d  %s:%d / %s:%d — helper signature: %s')
                :format(idx, p.a.file, p.a.line, p.b.file, p.b.line, ho.signature_text(t))
            for _, h in ipairs(t.holes) do
                if h.kind ~= 'closed' and h.kind ~= 'rename' then
                    rows[#rows + 1] = ('      %-14s %s(%s) : %s  ≜  %s'):format(h.kind, h.Y,
                        table.concat(h.ys, ','), ho.show(h.left):sub(1, 90), ho.show(h.right):sub(1, 90))
                end
            end
        end
    end
end

io.write('\nSUMMARY\n')
for _, k in ipairs { 'n', 'ok', 'holes', 'cart_params', 'rename', 'dep', 'closed',
    'local_vs_term', 'pairs_with_dep', 'consistent', 'inconsistent' } do
    io.write(('  %-16s %d\n'):format(k, agg[k]))
end
io.write('  dependency count of dep/local-vs-term holes:')
for k = 0, 8 do if dephist[k] then io.write((' %d->%d'):format(k, dephist[k])) end end
io.write('\n')
-- ⚠ A REFUSAL IS AN ANSWER AND IS NAMED. A pair missing from the census with no
-- reason beside it is indistinguishable from one the loop never reached.
io.write(('\nREFUSED %d\n'):format(#refused))
for _, r in ipairs(refused) do io.write('  ', r, '\n') end
if detail then
    io.write('\nDETAILS (hole = Y(locals it depends on) : left ≜ right)\n')
    for _, r in ipairs(rows) do io.write(r, '\n') end
end
