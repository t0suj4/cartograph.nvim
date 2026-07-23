-- rubyfinder — instrument the rails ORM-finder receiver-typing rung: does it FIRE,
-- and where does it stall? Reports finder bindings captured, how many name an AR
-- model, how many have a receiver call, and how many resolve to a LOCAL def. Tells
-- apart "0 headroom (correct)" from "rung broken". [[cartograph-local-type-inference]]
--
--   nvim --headless -u NONE -l tools/rubyfinder.lua [rails|<dir>]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'

local name = arg[1] or 'rails'
-- a registered corpus carries its own packs; a raw dir needs the rails pack passed
local data = bench.extract(name, name:match('/') and { packs = { 'rails' } } or nil)

-- 1. finder bindings captured (data.ruby_ctor entries with finder=true)
local finder_binds, newctor_binds, files_with_finders = 0, 0, 0
for _file, fb in pairs(data.ruby_ctor or {}) do
    local any = false
    for _var, b in pairs(fb) do
        if b.finder then finder_binds = finder_binds + 1; any = true
        else newctor_binds = newctor_binds + 1 end
    end
    if any then files_with_finders = files_with_finders + 1 end
end

-- 2. how many calls carry a receiver that matches a finder binding, and of those,
--    how many resolved (c.to) and were inferred (c.inferred)
local recv_matches_finder, finder_recv_resolved = 0, 0
local example = {}
for _, c in ipairs(data.calls or {}) do
    local fb = c.file and data.ruby_ctor and data.ruby_ctor[c.file]
    local b = fb and c.recv and fb[c.recv]
    if b and b.finder and b.n == 1 then
        recv_matches_finder = recv_matches_finder + 1
        if c.to then
            finder_recv_resolved = finder_recv_resolved + 1
            if #example < 12 then
                example[#example + 1] = ('    %s.%s → %s'):format(b.cls, c.callee or '?', c.to)
            end
        end
    end
end

print(('rubyfinder %s'):format(name))
print(('  finder bindings captured: %d  (in %d files) · .new bindings: %d')
    :format(finder_binds, files_with_finders, newctor_binds))
print(('  calls whose receiver = a single-assign finder binding: %d'):format(recv_matches_finder))
print(('  ...of which RESOLVED to a def: %d'):format(finder_recv_resolved))
if #example > 0 then
    print('  examples (finder-typed receiver → resolved target):')
    for _, e in ipairs(example) do print(e) end
end
