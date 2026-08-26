-- GATE SCORE: replay history against the predictor and look for REFUTATIONS.
--
--   nvim --headless -u NONE -l tools/gatescore.lua [--limit N] [--verbose]
--
-- Every commit that moves an `expected` count in tools/corpora.lua is a LABELLED
-- EXAMPLE: a code change, plus corpora that demonstrably moved. The predictor
-- (tools/gatepredict.lua) claims certain corpora CANNOT move. A commit where a
-- corpus moved AND was predicted immovable is a REFUTATION — the only output
-- this loop can produce, since a promise is refutable but never confirmable.
--
-- ★ THE RECALIBRATION FILTER, WITHOUT WHICH THIS MANUFACTURES REFUTATIONS.
-- Many `expected` changes carry NO code diff at all: a pin correction, an era
-- stamp, a miscounted acceptance number being fixed, a newly registered corpus.
-- Those are MEASUREMENT CORRECTIONS, not movement caused by code. Scored naively
-- they read as "empty diff, corpus moved" — a refutation of a prediction that was
-- never made. Commits with no lua/cartograph change are SKIPPED and counted.
--
-- ★ THE KEY IS A LOWER BOUND, so it can REFUTE BUT NEVER CONFIRM — the same
-- asymmetry as the prediction, one level up. `expected` is only {refs, nodes}
-- and only 31 of 37 corpora declare it, so a commit showing corpus X unchanged
-- does NOT prove X did not move: the per-item graphdiff moves with both counts
-- fixed (that is what the slim-field commentary in snapshot.lua is about).
-- Confirmed POSITIVES only. A clean score is evidence, not proof.
--
-- APPROXIMATION, stated because it is load-bearing: the language inventory is
-- measured from the corpora as they are TODAY, and the spec registry is today's.
-- A corpus that gained a language since a replayed commit is scored with the
-- wrong inventory. That direction is conservative for `immovable` (more
-- languages present = fewer subtractions = fewer refutations claimed), which
-- means a refutation found here is more trustworthy than a clean score.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/gatescore%.lua$')
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local gp = require 'cartograph.gatepredict'
local ts = require 'cartograph.providers.treesitter'
local corpora = dofile(repo .. '/tools/corpora.lua')

local limit, verbose = 500, false
do
    local a = arg or {}
    for i = 1, #a do
        if a[i] == '--limit' then limit = tonumber(a[i + 1]) or limit end
        if a[i] == '--verbose' then verbose = true end
    end
end

local function git(...)
    local res = vim.system(vim.list_extend({ 'git', '-C', repo }, { ... }), { text = true }):wait()
    return res.stdout or '', res.code
end

-- ── registry + inventories (today's, once) ────────────────────────────
local dialect
do
    local ok, tok = pcall(require, 'cartograph.providers.tokens')
    if ok then dialect = tok.ext_dialect end
end
local ext_langs = gp.ext_langs(ts.spec, dialect)
local known = {}
for lang in pairs(ts.spec) do known[lang] = true end
for _, d in pairs(dialect or {}) do known[d] = true end
local provider_langs = { treesitter = {}, tokens = {} }
for lang in pairs(ts.spec) do provider_langs.treesitter[lang] = true end
for _, d in pairs(dialect or {}) do provider_langs.tokens[d] = true end

local inventories = {}
for name, c in pairs(corpora) do
    local res = vim.system({ 'find', '-L', c.root, '-type', 'f', '-not', '-path', '*/.git/*' },
        { text = true }):wait()
    local exts = {}
    for line in (res.stdout or ''):gmatch('[^\n]+') do
        local e = gp.ext_of(line, ext_langs)
        if e then exts[e] = (exts[e] or 0) + 1 end
    end
    inventories[name] = { langs = gp.corpus_langs(exts, ext_langs),
        provider = c.provider or 'treesitter' }
end

-- ── which corpora did a commit move? ──────────────────────────────────
--- Attribute each ADDED `expected =` line to its corpus entry.
--- ★ THE KEY PATTERN MUST ACCEPT DIGITS. `^    [a-z_]+ = {$` does not match
--- `v8`, so the scan silently keeps the PREVIOUS entry's name and reports a
--- refutation that never happened (a C++ change "moving" the js/ts corpus
--- ghost). Verify the attribution, do not trust the nearest-match.
local function moved_by(sha)
    local after = git('show', sha .. ':tools/corpora.lua')
    if after == '' then return {} end
    local lines, keys = {}, {}
    local i = 0
    for line in after:gmatch('([^\n]*)\n?') do
        i = i + 1
        lines[i] = line
        local k = line:match('^    ([A-Za-z0-9_]+) = {$')
        if k then keys[#keys + 1] = { at = i, name = k } end
    end
    local diff = git('show', '--format=', '-U0', sha, '--', 'tools/corpora.lua')
    local moved = {}
    for line in diff:gmatch('[^\n]+') do
        local body = line:match('^%+(%s+expected = .*)$')
        if body then
            for n, l in ipairs(lines) do
                if l == body then
                    local owner
                    for _, k in ipairs(keys) do
                        if k.at < n then owner = k.name else break end
                    end
                    if owner then moved[owner] = true end
                    break
                end
            end
        end
    end
    return moved
end

-- ── replay ────────────────────────────────────────────────────────────
local shas = {}
for s in git('log', '--format=%h', '--', 'tools/corpora.lua'):gmatch('[^\n]+') do
    shas[#shas + 1] = s
end

local scored, skipped, refutations, no_move = 0, 0, {}, 0
local subtracted_total, corpora_total = 0, 0
print(('replaying %d commits that touch tools/corpora.lua\n'):format(math.min(#shas, limit)))

for idx = 1, math.min(#shas, limit) do
    local sha = shas[idx]
    local files = {}
    local nlua = 0
    for f in git('show', '--name-only', '--format=', sha):gmatch('[^\n]+') do
        if f ~= 'tools/corpora.lua' then files[#files + 1] = f end
        if f:match('^lua/cartograph/.*%.lua$') then nlua = nlua + 1 end
    end
    local moved = moved_by(sha)
    local nmoved = 0
    for _ in pairs(moved) do nmoved = nmoved + 1 end

    if nlua == 0 then
        skipped = skipped + 1
        if verbose then
            local m = {}
            for k in pairs(moved) do m[#m + 1] = k end
            table.sort(m)
            print(('  SKIP %s recalibration (no lua change) moved=[%s]')
                :format(sha, table.concat(m, ',')))
        end
    else
        scored = scored + 1
        local touched = gp.touched(files, known, provider_langs)
        local pred = gp.predict(inventories, touched)
        local imm = {}
        for _, e in ipairs(pred.immovable) do imm[e.corpus] = true end
        subtracted_total = subtracted_total + #pred.immovable
        corpora_total = corpora_total + #pred.immovable + #pred.movable
        local bad = {}
        for c in pairs(moved) do
            if imm[c] then bad[#bad + 1] = c end
        end
        table.sort(bad)
        if nmoved == 0 then no_move = no_move + 1 end
        if #bad > 0 then
            refutations[#refutations + 1] = { sha = sha, corpora = bad,
                scope = touched.scope, subject = git('log', '-1', '--format=%s', sha):gsub('%s+$', '') }
            print(('  ★ REFUTED %s scope=%s predicted-immovable but MOVED: %s')
                :format(sha, touched.scope, table.concat(bad, ',')))
            print(('      %s'):format(git('log', '-1', '--format=%s', sha):gsub('%s+$', '')))
        elseif verbose then
            local m = {}
            for k in pairs(moved) do m[#m + 1] = k end
            table.sort(m)
            print(('  ok   %s scope=%-5s subtracted=%-2d moved=[%s]')
                :format(sha, touched.scope, #pred.immovable, table.concat(m, ',')))
        end
    end
end

print(('\nscored:      %d commits with a lua/cartograph change'):format(scored))
print(('skipped:     %d pure recalibrations (no code diff — NOT refutations)'):format(skipped))
print(('  of scored, %d moved no corpus at all (no prediction at stake)'):format(no_move))
if corpora_total > 0 then
    print(('subtraction: %.1f%% of corpus-gates ruled out on average (%d of %d)')
        :format(100 * subtracted_total / corpora_total, subtracted_total, corpora_total))
end
print(('REFUTATIONS: %d'):format(#refutations))
if #refutations == 0 then
    print('  none — every scored commit moved only corpora the predictor kept in play.')
    print('  NOT a proof: the key is a lower bound (see this file\'s header).')
end
os.exit(0)
