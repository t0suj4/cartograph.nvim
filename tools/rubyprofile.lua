-- rubyprofile — measure the ruby-rails PROFILE's disposition-face delta + confirm
-- activation. Two parts ([[cartograph-stdlib-profile]]):
--  (A) ANALYTIC delta: extract the rails corpus, load the ruby-rails profile,
--      count unresolved calls currently at no-def/none whose callee the profile's
--      `free` set blesses — exactly the calls prof_ext would flip no-def→stdlib.
--  (B) END-TO-END: extract a real discourse root (config/application.rb present →
--      the rails shape fires → the profile activates) over a scoped file set, and
--      confirm data.profile=='ruby-rails' and the census stdlib disposition appears.
--
--   nvim --headless -u NONE -l tools/rubyprofile.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ts = require 'cartograph.providers.treesitter'

-- ── (A) analytic delta on the rails corpus (root=app/models, no profile) ──
local prof = require('cartograph.spec.profile').load('ruby-rails')
assert(prof and prof.schema == 1, 'ruby-rails profile failed to load')
local data = bench.extract('rails')
local nodef_none, blessed = 0, 0
local blessed_names = {}
local function bump(t, k) t[k] = (t[k] or 0) + 1 end
for _, c in ipairs(data.calls or {}) do
    if not c.to then
        local why = (type(c.ext) == 'table' and c.ext.why) or (c.ext and 'ext') or 'none'
        if why == 'none' or why == 'no-def' then
            nodef_none = nodef_none + 1
            local nm = c.callee
            if nm and prof.free[nm] then
                blessed = blessed + 1
                bump(blessed_names, nm)
            end
        end
    end
end
local arr = {}
for k, v in pairs(blessed_names) do arr[#arr + 1] = { k, v } end
table.sort(arr, function (a, b) return a[2] > b[2] end)

print('(A) ANALYTIC — rails corpus (discourse/app/models)')
print(('  free-set size: %d  ·  no-def/none unresolved: %d  ·  profile would flip to stdlib: %d (%.1f%%)')
    :format((function () local n = 0 for _ in pairs(prof.free) do n = n + 1 end return n end)(),
        nodef_none, blessed, 100 * blessed / math.max(1, nodef_none)))
io.write('  top flips:')
for i = 1, math.min(18, #arr) do io.write((' %s(%d)'):format(arr[i][1], arr[i][2])) end
print('')

-- ── (B) end-to-end activation on a real discourse root ──
local root = vim.fn.expand('~/git/discourse')
if vim.fn.isdirectory(root) ~= 1 or vim.fn.filereadable(root .. '/config/application.rb') ~= 1 then
    print('(B) SKIP — no discourse checkout with config/application.rb at ' .. root)
    return
end
-- scope to a few finder-consuming files so extraction is quick; root=discourse so
-- the rails shape detects and active_profile_for lights up the profile.
local files = {}
for _, rel in ipairs(vim.fn.globpath(root .. '/app/models', '*.rb', false, true)) do
    files[#files + 1] = rel:sub(#root + 2)
    if #files >= 120 then break end
end
local d2 = ts.extract(root, { files = files, fileset = (function ()
    local s = {} for _, f in ipairs(files) do s[f] = true end return s end)(), packs = { 'rails' } })
local census = require 'cartograph.census'
local c = census.take(d2)
local stdlib_ext, minted_nodes, resolved_to_mint = 0, 0, 0
for _, call in ipairs(d2.calls or {}) do
    if not call.to and type(call.ext) == 'table' and call.ext.why == 'stdlib' then
        stdlib_ext = stdlib_ext + 1
    end
    if call.to and tostring(call.to):sub(1, 12) == 'ruby-rails::' then
        resolved_to_mint = resolved_to_mint + 1
    end
end
for _, n in ipairs(d2.nodes or {}) do
    if n.external and n.file == 'ruby-rails' then minted_nodes = minted_nodes + 1 end
end
print(('(B) END-TO-END — discourse root, %d files'):format(#files))
print(('  data.profile = %s'):format(tostring(d2.profile)))
print(('  census: %d calls, %.1f%% resolved'):format(c.calls.total,
    100 * c.calls.resolved / math.max(1, c.calls.total)))
print(('  minted ruby-rails nodes: %d  ·  calls resolved to them: %d')
    :format(minted_nodes, resolved_to_mint))
print(('  residual why=stdlib dispositions (unminted): %d'):format(stdlib_ext))
print(('  stdlib-tier ref edges: %d'):format(c.edges and c.edges.ref and c.edges.ref.stdlib or 0))
