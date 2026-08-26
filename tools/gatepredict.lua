-- GATE PREDICTION: from a diff, which of the 37 corpus gates CANNOT move?
--
--   nvim --headless -u NONE -l tools/gatepredict.lua            predict from git diff HEAD
--   nvim --headless -u NONE -l tools/gatepredict.lua --files a,b   predict for named files
--   nvim --headless -u NONE -l tools/gatepredict.lua --inventory   just the language inventories
--   nvim --headless -u NONE -l tools/gatepredict.lua --stamp F     write the prediction to F (json)
--
-- The prediction is a PROMISE: refutable only, never confirmable. It subtracts
-- gates and never claims one will pass. Run it before a full sweep, stamp it,
-- and let the sweep refute it — see tools/gatescore.lua and CART-0569.
--
-- The inventory is a TREE WALK, not the saved baseline. That is the sound
-- direction: a file present but currently yielding no nodes is exactly the file
-- a fix might START extracting, and a baseline-derived inventory cannot see it.
-- `--inventory` prints where the two disagree, because that gap is a coverage
-- finding in its own right.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/gatepredict%.lua$')
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local gp = require 'cartograph.gatepredict'
local ts = require 'cartograph.providers.treesitter'
local corpora = dofile(repo .. '/tools/corpora.lua')
local snapshot = dofile(repo .. '/tools/snapshot.lua')

local opt = { files = nil, inventory = false, stamp = nil }
do
    local a = arg or {}
    for i = 1, #a do
        if a[i] == '--inventory' then opt.inventory = true end
        if a[i] == '--files' then opt.files = a[i + 1] end
        if a[i] == '--stamp' then opt.stamp = a[i + 1] end
    end
end

-- the language registry, live
local dialect = nil
do
    local ok, tok = pcall(require, 'cartograph.providers.tokens')
    if ok then dialect = tok.ext_dialect end
end
local ext_langs = gp.ext_langs(ts.spec, dialect)
-- ★ THE PROVIDER AXIS. bench.lua:223 dispatches exactly ONE provider per
-- corpus (`c.provider or 'treesitter'`), exclusively — so a provider a change
-- cannot reach makes its corpora immovable regardless of what files they hold.
local provider_langs = { treesitter = {}, tokens = {} }
for lang in pairs(ts.spec) do provider_langs.treesitter[lang] = true end
for _, d in pairs(dialect or {}) do provider_langs.tokens[d] = true end
local known = {}
for lang in pairs(ts.spec) do known[lang] = true end
for _, d in pairs(dialect or {}) do known[d] = true end

-- ── the fence: is every language reachable from some file? ────────────
do
    -- ★ THE FENCE'S OWN POPULATION MUST BE THE WHOLE EXTRACTION PATH. Globbing
    -- only spec/** reported forth and postscript as unreachable languages —
    -- they are reachable, but via providers/tokens.lua, which that glob never
    -- looked at. A fence measured over the wrong population fails honestly and
    -- is still wrong.
    local present = {}
    for _, g in ipairs({ '/lua/cartograph/spec', '/lua/cartograph/providers' }) do
        for _, f in ipairs(vim.fn.globpath(repo .. g, '**/*', false, true)) do
            present[#present + 1] = f:gsub('^' .. vim.pesc(repo) .. '/', '')
        end
    end
    local gaps = gp.registry_gaps(known, present, provider_langs)
    if #gaps > 0 then
        print(('FENCE: %d language(s) no file maps to: %s')
            :format(#gaps, table.concat(gaps, ',')))
        print('  a spec change for these would be UNMAPPED — the predictor would')
        print('  subtract corpora on no evidence. Fix the mapping before trusting a run.')
    end
end

-- ── inventories, by tree walk ─────────────────────────────────────────
local function walk_exts(root)
    local out, n = {}, 0
    -- ★ `-L`: the factorio corpus is a SYMLINK-ASSEMBLED multi-mod root, and
    -- plain `find -type f` does not follow symlinks — it measured EMPTY, which
    -- would have ruled that gate out of every language change on no evidence.
    local cmd = { 'find', '-L', root, '-type', 'f', '-not', '-path', '*/.git/*' }
    local res = vim.system(cmd, { text = true }):wait()
    for line in (res.stdout or ''):gmatch('[^\n]+') do
        -- longest CLAIMED suffix, so `x.ps.src` counts as postscript and not
        -- as an unclaimed `src` (gatepredict.M.ext_of explains why that matters)
        local ext = gp.ext_of(line, ext_langs)
        if ext then
            out[ext] = (out[ext] or 0) + 1
            n = n + 1
        end
    end
    return out, n
end

local inventories, unclaimed_by, declared = {}, {}, {}
local names = {}
for name in pairs(corpora) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
    local c = corpora[name]
    local exts = walk_exts(c.root)
    local langs, unclaimed = gp.corpus_langs(exts, ext_langs)
    inventories[name] = { langs = langs, provider = c.provider or 'treesitter' }
    unclaimed_by[name] = unclaimed
    declared[name] = c.lang
end

if opt.inventory then
    print('CORPUS INVENTORY — measured by tree walk, vs the DECLARED `lang`')
    print('a corpus carrying a language it is not named for is why name-matching is unsound\n')
    for _, name in ipairs(names) do
        local langs = inventories[name].langs
        local ks = {}
        for l, n in pairs(langs) do ks[#ks + 1] = { l, n } end
        table.sort(ks, function (a, b) return a[2] > b[2] end)
        local parts = {}
        for i = 1, math.min(#ks, 7) do parts[#parts + 1] = ks[i][1] .. '=' .. ks[i][2] end
        local extra = {}
        for _, kv in ipairs(ks) do
            if kv[1] ~= declared[name] then extra[#extra + 1] = kv[1] end
        end
        print(('%-12s declared=%-11s via=%-10s measured: %s'):format(name,
            declared[name] or '-', inventories[name].provider, table.concat(parts, ' ')))
        if #extra > 0 then
            print(('%-12s %s ALSO CARRIES: %s'):format('', '', table.concat(extra, ',')))
        end
    end
    -- ★ PRINT THE UNCLAIMED BUCKET. It was collected and never displayed, which
    -- is this project's own instrument lesson reproduced: a field nothing renders
    -- is a field whose signal is invisible. These are extensions NO language in
    -- the registry claims — the honest shape of what a corpus holds that we have
    -- no reader for at all.
    print('\nUNCLAIMED — extensions no registered language claims (nothing can read these)')
    for _, name in ipairs(names) do
        local u = unclaimed_by[name] or {}
        local ks = {}
        for e, n in pairs(u) do ks[#ks + 1] = { e, n } end
        table.sort(ks, function (a, b) return a[2] > b[2] end)
        if #ks > 0 then
            local parts = {}
            for i = 1, math.min(#ks, 5) do parts[#parts + 1] = ks[i][1] .. '=' .. ks[i][2] end
            local tot = 0
            for _, kv in ipairs(ks) do tot = tot + kv[2] end
            print(('  %-12s %d files across %d exts: %s'):format(name, tot, #ks,
                table.concat(parts, ' ')))
        end
    end

    -- where the baseline disagrees with the tree: files present, nothing extracted
    print('\nBASELINE vs TREE — languages present on disk that the baseline has NO nodes for')
    print('(a file the extractor is silent on is exactly what a fix might start reading)')
    for _, name in ipairs(names) do
        local data = snapshot.load(name)
        if data then
            local bexts = {}
            for _, nd in ipairs(data.nodes or {}) do
                local e = (nd.file or ''):match('%.([%w_]+)$')
                if e then bexts[e] = (bexts[e] or 0) + 1 end
            end
            local blangs = gp.corpus_langs(bexts, ext_langs)
            local silent = {}
            for l, n in pairs(inventories[name].langs) do
                if not blangs[l] then silent[#silent + 1] = ('%s(%d files)'):format(l, n) end
            end
            table.sort(silent)
            if #silent > 0 then
                print(('  %-12s %s'):format(name, table.concat(silent, ' ')))
            end
        end
    end
    return
end

-- ── what changed ──────────────────────────────────────────────────────
local changed = {}
if opt.files then
    for f in opt.files:gmatch('[^,]+') do changed[#changed + 1] = f end
else
    local out = vim.fn.system(('git -C %s diff HEAD --name-only'):format(vim.fn.shellescape(repo)))
    for f in out:gmatch('[^\n]+') do changed[#changed + 1] = f end
    local unt = vim.fn.system(('git -C %s ls-files --others --exclude-standard')
        :format(vim.fn.shellescape(repo)))
    for f in unt:gmatch('[^\n]+') do changed[#changed + 1] = f end
end

local touched = gp.touched(changed, known, provider_langs)
local pred = gp.predict(inventories, touched)

local SCOPE_SAYS = {
    all = 'REFUSING TO SUBTRACT — a shared engine/spec file changed, so every corpus stays in play',
    none = 'no file that can affect extraction changed — no corpus can move',
    langs = 'language-scoped diff — subtraction is possible',
}
print(('changed files: %d'):format(#changed))
print(('scope: %s — %s'):format(touched.scope, SCOPE_SAYS[touched.scope]))
for _, f in ipairs(changed) do
    if touched.why[f] then print(('  %-52s %s'):format(f, touched.why[f])) end
end
local ls = {}
for l in pairs(touched.langs) do ls[#ls + 1] = l end
table.sort(ls)
if #ls > 0 then print(('languages reached: %s'):format(table.concat(ls, ','))) end

print(('\nPREDICTION (refutable only — it never claims a gate will PASS)'))
print(('  CANNOT MOVE (%d): %s'):format(#pred.immovable,
    (function ()
        local t = {}
        for _, e in ipairs(pred.immovable) do t[#t + 1] = e.corpus end
        return #t > 0 and table.concat(t, ',') or '(none)'
    end)()))
print(('  not ruled out (%d):'):format(#pred.movable))
for _, e in ipairs(pred.movable) do print(('    %-12s %s'):format(e.corpus, e.why)) end

if opt.stamp then
    local rows = {}
    for _, e in ipairs(pred.immovable) do rows[#rows + 1] = e.corpus end
    local fd = assert(io.open(opt.stamp, 'w'))
    fd:write(vim.json.encode({
        scope = touched.scope,
        languages = ls,
        immovable = rows,
        changed = changed,
        rev = vim.fn.system(('git -C %s rev-parse HEAD'):format(vim.fn.shellescape(repo))):gsub('%s+$', ''),
    }))
    fd:close()
    -- ★ SAY WHAT THE STAMP IS, NOT WHAT WE WISH IT WERE. tools/gatescore.lua
    -- replays HISTORY; it has no stamp-reading mode, so there is no consumer for
    -- this file yet. The online audit (stamp -> full sweep -> diff) is the
    -- unbuilt half of CART-0569, and claiming it here would be a stale doc on
    -- the day it was written.
    print(('\nstamped -> %s'):format(opt.stamp))
    print('  NOTE: no consumer yet. gatescore.lua scores HISTORY, not a stamp.')
    print('  The stamp exists so a full sweep can be diffed against it by hand,')
    print('  or by the online audit when it is built (CART-0569).')
end
