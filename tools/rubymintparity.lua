-- rubymintparity — INLINE vs PARALLEL parity for the ruby-rails minting face
-- ([[cartograph-stdlib-profile]]). The memo's cardinal rule: any GLOBAL node-
-- minting change must pass --parallel parity (the zig arc's gotcha #1). The ruby
-- mint reuses c.ext (a merged call field) + runs only in relink, so it SHOULD be
-- parallel-safe by construction — this proves it. Generates a synthetic Rails
-- root large enough (>2*BATCH files) to force real worker fan-out, extracts it
-- both ways, and asserts the minted-node set + resolved-to-mint count agree.
--
--   nvim --headless -u NONE -l tools/rubymintparity.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
if not pcall(vim.treesitter.language.add, 'ruby') then print('no ruby parser'); return end
local ts = require 'cartograph.providers.treesitter'
local par = require 'cartograph.parallel'

local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/config', 'p'); vim.fn.mkdir(root .. '/app/models', 'p')
local function w(name, lines)
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
end
w('config/application.rb', { 'module Demo; end' })
local N = 130 -- > 2*BATCH(48) so parallel spawns >=2 workers
for i = 1, N do
    w(('app/models/m%03d.rb'):format(i), {
        ('class M%03d < ApplicationRecord'):format(i),
        '  belongs_to :owner',
        '  validates :title',
        '  def ready?',
        '    title.present? && subtitle.blank? && owner.persisted?',
        '  end',
        '  def act',
        '    save && items.each { |x| x }',  -- save/each: stdlib_names VOCAB → now minted
        '  end',
        'end',
    })
end

-- summarize a graph: the set of minted ruby-rails node ids + #calls resolved to them
local function summarize(data)
    local nodes, resolved = {}, 0
    for _, n in ipairs(data.nodes or {}) do
        if n.external and n.file == 'ruby-rails' then nodes[n.id] = true end
    end
    for _, c in ipairs(data.calls or {}) do
        if c.to and tostring(c.to):sub(1, 12) == 'ruby-rails::' then resolved = resolved + 1 end
    end
    return nodes, resolved
end

local inline = ts.extract(root)
local pdata
par.extract(root, { on_done = function (d) pdata = d end })
vim.wait(600000, function () return pdata ~= nil end, 50)
assert(pdata, 'parallel extract did not finish')

local iN, iR = summarize(inline)
local pN, pR = summarize(pdata)
local function keys(t) local a = {} for k in pairs(t) do a[#a + 1] = k end table.sort(a) return a end
local ik, pk = keys(iN), keys(pN)

print('rubymintparity — synthetic Rails root, ' .. N .. ' model files')
print(('  workers spawned (parallel): %s'):format(tostring(par._last_workers)))
print(('  inline:   profile=%s  minted=%d  resolved→mint=%d'):format(tostring(inline.profile), #ik, iR))
print(('  parallel: profile=%s  minted=%d  resolved→mint=%d'):format(tostring(pdata.profile), #pk, pR))
local same_set = (#ik == #pk)
if same_set then for i = 1, #ik do if ik[i] ~= pk[i] then same_set = false end end end
print(('  minted-node SET identical: %s'):format(same_set and 'YES' or 'NO'))
print(('  resolved-to-mint count identical: %s'):format(iR == pR and 'YES' or ('NO (%d vs %d)'):format(iR, pR)))
print(('  PARITY: %s'):format((same_set and iR == pR and iR > 0) and 'PASS' or 'FAIL'))
io.write('  minted: '); for _, k in ipairs(ik) do io.write(k .. ' ') end; print('')
