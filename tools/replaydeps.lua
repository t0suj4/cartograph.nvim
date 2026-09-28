-- replaydeps — HOW DEPENDENT ARE REPLAYED STEPS ON EACH OTHER? (CART-1191 leaf 3, measure before building). A replay
-- stops at the first conflict, because a later step MAY have been planned against the conflicting one; this measures
-- how often one actually was, on real history, and whether a cheap derived proxy predicts it.
--
--   nvim --headless -u NONE -l tools/replaydeps.lua <repo> <range>
--
-- GROUND TRUTH, verb-agnostic: replay the range into a scratch clone of the range's base once in full and once per
-- step LEFT OUT; step j DEPENDS on step i when j's outcome changes without i. Each step runs as its OWN replay (a stop
-- does not end the run), so a left-out step does not read as a dependence of everything after it.
-- PROXIES (derived from the invocations alone): SAME FILE (the steps name the same `file` arg), ANCHOR (j's `before`
-- contains a line i's `after` added). Reports each proxy's agreement with the ground truth over all i < j pairs.
-- Writes nothing in <repo>; the scratch clone is deleted.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local repo = vim.fn.fnamemodify(assert(arg[1], 'usage: replaydeps.lua <repo> <range>'), ':p'):gsub('/$', '')
local range = assert(arg[2], 'usage: replaydeps.lua <repo> <range>')
local R = require 'cartograph.replay'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local function sh(dir, ...) local r = vim.system({ 'git', '-C', dir, ... }, { text = true }):wait(); return r.code == 0 and r.stdout or nil end
local base = vim.trim(sh(repo, 'rev-parse', range:match('^(.-)%.%.') or (range .. '^')) or '')
local items = R.from_notes(repo, range)
local steps = {}
for _, it in ipairs(items) do if type(it.invocation) == 'table' then steps[#steps + 1] = it end end
io.write(('%d item(s) in %s, %d with an invocation; base %s\n'):format(#items, range, #steps, base:sub(1, 7)))
local W = vim.fn.tempname()
vim.system({ 'git', 'clone', '-q', repo, W }):wait()
sh(W, 'remote', 'set-url', 'origin', vim.trim(sh(repo, 'remote', 'get-url', 'origin') or ''))
--- replay every step but `skip`, each on its own -> { [id] = outcome }
local function run(skip)
    sh(W, 'reset', '-q', '--hard', base); sh(W, 'clean', '-fdq')
    store.ingest(ts.extract(W))
    local out = {}
    for k, it in ipairs(steps) do
        if k ~= skip then out[it.id] = R.run(store, { it }, { apply = true }).steps[1].outcome end
    end
    return out
end
local t0 = vim.uv.hrtime()
local full = run(nil)
local counts = {}
for _, o in pairs(full) do counts[o] = (counts[o] or 0) + 1 end
local parts = {}
for o, n in pairs(counts) do parts[#parts + 1] = o .. ' ' .. n end
table.sort(parts)
io.write('full replay: ', table.concat(parts, ', '), '\n')
local dep = {}
for i = 1, #steps do
    local without = run(i)
    dep[i] = {}
    for j = i + 1, #steps do dep[i][j] = without[steps[j].id] ~= full[steps[j].id] end
end
-- the proxies
local function lines(s) local o = {}; for l in tostring(s or ''):gmatch('[^\n]+') do o[l] = true end; return o end
local function same_file(i, j) local a, b = steps[i].invocation.args or {}, steps[j].invocation.args or {}; return a.file ~= nil and a.file == b.file end
local function anchor(i, j)
    local a, b = steps[i].invocation.args or {}, steps[j].invocation.args or {}
    if type(a.after) ~= 'string' or type(b.before) ~= 'string' then return false end
    local was = lines(a.before)
    for l in a.after:gmatch('[^\n]+') do if not was[l] and #vim.trim(l) >= 4 and b.before:find(l, 1, true) then return true end end
    return false
end
local pairs_n, deps_n = 0, 0
local agree = { same_file = { tp = 0, fp = 0, fn = 0 }, anchor = { tp = 0, fp = 0, fn = 0 } }
local independent_after = {}
for i = 1, #steps do
    local later, indep = 0, 0
    for j = i + 1, #steps do
        pairs_n = pairs_n + 1; later = later + 1
        local d = dep[i][j]
        if d then deps_n = deps_n + 1 else indep = indep + 1 end
        for name, f in pairs { same_file = same_file, anchor = anchor } do
            local p = f(i, j)
            if p and d then agree[name].tp = agree[name].tp + 1 elseif p then agree[name].fp = agree[name].fp + 1 elseif d then agree[name].fn = agree[name].fn + 1 end
        end
    end
    if later > 0 then independent_after[#independent_after + 1] = indep / later end
end
local mean = 0
for _, x in ipairs(independent_after) do mean = mean + x end
mean = #independent_after > 0 and mean / #independent_after or 0
io.write(('pairs i<j: %d, dependent: %d (%.1f%%)\n'):format(pairs_n, deps_n, pairs_n > 0 and 100 * deps_n / pairs_n or 0))
io.write(('a conflict at step i leaves on average %.1f%% of the later steps INDEPENDENT of it (reachable past it)\n'):format(100 * mean))
for _, name in ipairs { 'same_file', 'anchor' } do
    local a = agree[name]
    io.write(('proxy %-9s: true+ %d, false+ %d, missed %d\n'):format(name, a.tp, a.fp, a.fn))
end
for i = 1, #steps do for j = i + 1, #steps do
    if dep[i][j] then io.write(('  %s -> %s  (%s)\n'):format(steps[i].id, steps[j].id, tostring((steps[j].invocation.args or {}).file))) end
end end
io.write(('%.0f s\n'):format((vim.uv.hrtime() - t0) / 1e9))
vim.fn.delete(W, 'rf')
