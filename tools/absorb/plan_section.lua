-- extract one algebra section THROUGH THE COMPOSITION RUNNER
local root = vim.fn.getcwd()
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local ts, store = require 'cartograph.providers.treesitter', require 'cartograph.store'
local compose, hz = require 'cartograph.compose', require 'cartograph.hazard'

local WANT, DEST = arg[1], arg[2]
local data = ts.extract(root); data.root = data.root or root; store.ingest(data)

local secs, ln = {}, 0
for line in io.lines(root .. '/lua/cartograph/algebra/core.lua') do
    ln = ln + 1
    local t = line:match('^%-%- \226\148\128\226\148\128 (.-) [\226\148\128 ]*$') or line:match('^%-%- \226\148\128\226\148\128 (.+)$')
    if t then secs[#secs + 1] = { title = t, line = ln, ids = {} } end
end
for i = 1, #secs do secs[i].last = (secs[i + 1] and secs[i + 1].line - 1) or math.huge end
for _, n in ipairs(store.data.nodes) do
    if n.kind == 'function' and tostring(n.file):find('algebra/core%.lua$') and n.top and n.order then
        for _, s in ipairs(secs) do
            if n.order + 1 >= s.line and n.order + 1 <= s.last then
                -- ★ SEED THE SECTION'S EXPORTS ONLY. A private file-local travels
                -- via `close_moveset`'s capture closure if it is private, and STAYS
                -- if it is shared — which is the right answer either way. Seeding
                -- every top-level function put `is_prefix` in the seed, whose ref
                -- resolves only BY ORDINAL (its calls do not resolve, so it has no
                -- witnesses) and the write side rightly refuses a probable handle.
                if (n.name or ''):find('^M%.') then s.ids[#s.ids + 1] = n.id end
                break
            end
        end
    end
end
local sec
for _, s in ipairs(secs) do if s.title:upper():find(WANT:upper(), 1, true) then sec = s; break end end
if not sec then print('no such section: ' .. WANT); return end

-- ★ THE RECIPE ADDRESSES SYMBOLS BY DURABLE REF, never by id
local refs = {}
for _, id in ipairs(sec.ids) do refs[#refs + 1] = store.ref_of(id) end
print(('SECTION %s   %d functions'):format(sec.title:sub(1, 52), #refs))

local recipe = compose.recipe {
    { verb = 'moveset', args = { seed_refs = refs, dest = DEST } },
}
local rows, why = compose.run(store, recipe, { apply = arg[3] == 'apply' })
if not rows then print('REFUSED: ' .. tostring(why)); return end
for _, r in ipairs(rows) do
    print(('  step %d  ok=%-5s applied=%-5s %s'):format(r.i, tostring(r.ok),
        tostring(r.applied), tostring(r.why or '')))
    for _, h in ipairs(r.hazards or {}) do
        local row = hz.row(h)
        print(('     [%s] %s'):format(tostring(row.kind), tostring(row.reason):sub(1, 120)))
    end
    for _, f in ipairs(r.fixes or {}) do
        print(('     ★ FIX %s %s'):format(f.verb, vim.inspect(f.args):gsub('%s+', ' ')))
    end
end
