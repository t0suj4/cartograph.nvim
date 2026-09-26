-- userequire — THE CENSUS behind the `use-without-require` lint (the reverse of
-- `redundant-require`, [[cartograph-bidirectional-instruments]]).
--
--   nvim --headless -u NONE -l tools/userequire.lua <corpus|path> [--rows N]
--
-- ⚠ A WORK LIST WITH STRUCTURAL FALSE POSITIVES, NOT A GATE. The lint reports only
-- the GLOBAL class; this prints every class the shared classifier
-- (lua/cartograph/userequire.lua — read its header for the definitions) sorts a lua
-- use-without-a-require into, because the classes that are NOT findings are
-- findings about the TOOL: `unseen-require` is a require the import extractor did
-- not mint an edge for, `not-global:unexplained` / `caller-local` are cross-file
-- resolutions the code gives no way to reach (fabcensus's population).
--
-- Rows print grouped by (file -> definer), which is the unit a fix is made in.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = here .. '/../lua/?.lua;' .. here .. '/../lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local ur = require 'cartograph.userequire'

local target, nrows = nil, 12
do
    local a, i = arg or {}, 1
    while a[i] do
        if a[i] == '--rows' then i = i + 1; nrows = tonumber(a[i]) or nrows
        elseif not target then target = a[i] end
        i = i + 1
    end
end
if not target then
    io.write('usage: nvim --headless -u NONE -l tools/userequire.lua <corpus|path> [--rows N]\n')
    os.exit(2)
end
local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then io.write('not a directory: ' .. root .. '\n'); os.exit(2) end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
local res = ur.classify(data, function (f)
    local fd = io.open(root .. '/' .. f, 'r')
    if not fd then return nil end
    local t = fd:read('*a'); fd:close()
    return t
end)

local function out(s) io.write(s, '\n') end
local C = res.census
out(('USE WITHOUT REQUIRE — %s'):format(root))
out('')
out('WORK LIST, NOT A GATE. A cross-file lua use (a non-method call on a free name, or a')
out('read of a var) that lands in a file the caller has no import edge to.')
out('')
out(('  cross-file uses WITH a require (not the population)  %6d'):format(C.required or 0))
out(('  population (no import edge F -> G)                   %6d'):format(C.population or 0))
out(('    excluded: receiver bound by one of F\'s imports      %6d'):format(C['excluded:import-bound'] or 0))
out(('    excluded, never counted in the population: method %d, parameter %d, member read %d, no site %d')
    :format(C['excluded:method'] or 0, C['excluded:param'] or 0, C['excluded:member-read'] or 0,
        C['excluded:no-site'] or 0))
local order = {
    { 'other-name', 'F spells a path that is not the def\'s name (tostring -> FUNCS.tostring)' },
    { 'other-name:unseen-require', '  … and F names G\'s module in a string (a require the extractor missed)' },
    { 'other-name:unexplained', '  … and nothing in F names G (a guessed resolution)' },
    { 'not-global', 'F spells the def\'s name but G binds its root local' },
    { 'not-global:unseen-require', '  … and F names G\'s module in a string (a require the extractor missed)' },
    { 'not-global:unexplained', '  … and nothing in F names G (a guessed resolution)' },
    { 'unread', 'F\'s or G\'s text could not be read: no verdict' },
    { 'host-root', 'G patches a table the corpus never defines (vim.cmd = …): no require owed' },
    { 'caller-local', 'G\'s def is global, but F binds its own local of that name' },
    { 'unseen-require', 'G\'s def is global and F names G\'s module in a string' },
    { 'global', 'THE FINDING: a global of G used with no require of G' },
    { 'global:import-chain', '  … F\'s own requires reach G transitively' },
    { 'global:required-elsewhere', '  … another file requires G' },
    { 'global:required-by-none', '  … nothing requires G (entry point / host-loaded)' },
    { 'global:via-global-alias', '  … G\'s local module table, published globally by another file' },
}
for _, o in ipairs(order) do out(('  %-28s %6d  %s'):format(o[1], C[o[1]] or 0, o[2])) end
local sum = (C['excluded:import-bound'] or 0) + (C['other-name'] or 0) + (C['not-global'] or 0)
    + (C['caller-local'] or 0) + (C['host-root'] or 0) + (C.unread or 0)
    + (C['unseen-require'] or 0) + (C.global or 0)
if sum ~= (C.population or 0) then
    out(('⚠ PARTITION BROKEN: %d classified vs %d in the population'):format(sum, C.population or 0))
end
local fs = ur.findings(res)
out('')
out(('lint findings (one per file -> definer pair, GLOBAL class): %d'):format(#fs))

-- grouped rows per class, a sample of each
local groups = {}
for _, r in ipairs(res.rows) do
    local k = r.class .. (r.sub and (':' .. r.sub) or '')
    local g = groups[k]
    if not g then g = { list = {}, seen = {} }; groups[k] = g end
    local pk = r.file .. ' -> ' .. r.def.file
    local e = g.seen[pk]
    if not e then
        e = { key = pk, n = 0, names = {}, nseen = {}, line = r.line, tiers = {} }
        g.seen[pk] = e
        g.list[#g.list + 1] = e
    end
    e.n = e.n + 1
    e.tiers[r.tier or '?'] = true
    if not e.nseen[r.root] then e.nseen[r.root] = true; e.names[#e.names + 1] = r.root end
end
local ks = {}
for k in pairs(groups) do ks[#ks + 1] = k end
table.sort(ks)
for _, k in ipairs(ks) do
    local g = groups[k]
    table.sort(g.list, function (a, b) if a.n ~= b.n then return a.n > b.n end return a.key < b.key end)
    out('')
    out(('── %s: %d file pair(s) ──'):format(k, #g.list))
    for i, e in ipairs(g.list) do
        if i > nrows then out(('  … %d more'):format(#g.list - nrows)); break end
        local tl = {}
        for t in pairs(e.tiers) do tl[#tl + 1] = t end
        table.sort(tl)
        out(('  %4d  %s  [%s]  line %d  %s'):format(e.n, e.key, table.concat(tl, ','),
            (e.line or -1) + 1, table.concat(e.names, ' ', 1, math.min(#e.names, 6))))
    end
end
