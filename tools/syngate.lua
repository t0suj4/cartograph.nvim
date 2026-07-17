-- The SYNTHETIC ANALYSIS ground-truth gate ([[cartograph-synthetic-analysis-groundtruth]]).
--   nvim --headless -u NONE -l tools/syngate.lua
-- Generates planted analysis corpora with a KNOWN answer key (tools/gen.lua's
-- M.analysis), runs the analysis LENSES over them, and asserts findings == key —
-- the systematic version of dogfooding. The key's NEGATIVES (fact=false) are the
-- point: a lens that narrows where it must NOT is a false positive caught here,
-- not by eyeballing self. Exit 1 on any false positive OR false negative.
-- INC 1 = narrowing (narrow.lua). LICM/CSE/untangle keys follow in later INCs.

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local gen = dofile(repo .. '/tools/gen.lua')
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local narrow = require 'cartograph.narrow'

local SEED, NFILES = 1, 12

-- ── narrowing (INC 1) ────────────────────────────────────────────────────────
local a = gen.analysis('lua', NFILES, SEED)
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
for name, src in pairs(a.files) do
    vim.fn.writefile(vim.split(src, '\n', { plain = true }), dir .. '/' .. name)
end
store.ingest(ts.extract(dir))

-- env per (file, line) across every fn (each line belongs to one fn)
local env_at = {}
for _, n in ipairs(store.data.nodes) do
    if n.kind == 'function' then
        local ok, res = pcall(narrow.narrow, store, n.id)
        if ok then
            for _, p in ipairs(res.points) do
                env_at[(n.file or '') .. '\31' .. p.line] = p.env
            end
        end
    end
end

local pass, fpos, fneg = 0, {}, {}
for _, e in ipairs(a.key) do
    local got = (env_at[e.file .. '\31' .. e.line] or {})[e.var]
    if e.fact == false then -- must NOT narrow
        if got ~= nil then
            fpos[#fpos + 1] = ('%s:%d  `%s` FALSE-POSITIVE narrowed to %s (must stay unknown)')
                :format(e.file, e.line, e.var, got)
        else pass = pass + 1 end
    else -- must narrow to e.fact
        if got == e.fact then pass = pass + 1
        else
            fneg[#fneg + 1] = ('%s:%d  `%s` expected %s, got %s')
                :format(e.file, e.line, e.var, e.fact, tostring(got))
        end
    end
end

print(('syngate narrow: %d key facts — %d ok, %d false-pos, %d false-neg')
    :format(#a.key, pass, #fpos, #fneg))
for _, m in ipairs(fpos) do print('  FP ' .. m) end
for _, m in ipairs(fneg) do print('  FN ' .. m) end
if #fpos > 0 or #fneg > 0 then print('SYNGATE: FAIL'); os.exit(1) end
print('SYNGATE: PASS')
