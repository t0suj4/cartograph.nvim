-- The SPEC AUDIT ([[cartograph-spec-audit]]): validate cartograph's OWN
-- specs/packs against reality. M.spec + M.packs are hand-authored CLAIMS
-- (this grammar node exists, this is a stdlib verb, `has_many` is real DSL)
-- and nothing else checks them — packs rot fastest (frameworks version
-- faster than languages). PROJECT-MANAGEMENT action: the subject is the
-- analysis apparatus, not user code — hence tools/, not a :Cartograph verb.
--
-- Two ground truths, two tiers (never conflated):
--   CONFIRMED stale — a query that fails to COMPILE against the grammar
--     (the grammar is the oracle: the node type is gone/renamed).
--   SUSPECT stale — a query capture / vocab entry that never FIRES across
--     the audited corpora (usage can only say suspect: unexercised ≠
--     nonexistent).
-- Plus GAP candidates: frequent plain-unresolved callee names no vocab
-- claims (the "missing entry" direction).
--
-- Vocab firing is counted from gate SNAPSHOTS (per-call callee tails), keyed
-- by the FILE's language, not the corpus label — mixed-content corpora
-- (grocy's js inside a php corpus) exercise every contained spec. Pack vocab
-- is audited only against corpora where that pack is ACTIVE.
--
-- usage:
--   nvim --headless -l tools/specaudit.lua               -- default set below
--   nvim --headless -l tools/specaudit.lua ruby rails    -- explicit corpora
--   ... --extract     re-extract when a corpus has no snapshot (else skipped)
--   ... --files=N     per-(corpus,lang) query-run sample cap (default 150)

local REPO = (function ()
    local src = debug.getinfo(1, 'S').source:sub(2)
    return src:match('^(.*)/tools/specaudit%.lua$') or vim.fn.getcwd()
end)()
local bench = dofile(REPO .. '/tools/bench.lua')
bench.bootstrap()
local snapshot = dofile(REPO .. '/tools/snapshot.lua')
local corpora = dofile(REPO .. '/tools/corpora.lua')
local ts = require('cartograph.providers.treesitter')

-- one snapshot-backed corpus per language + the pack corpora; mixed-content
-- corpora exercise embedded languages too (grocy: php+js)
local DEFAULT = { 'desynced', 'server', 'grocy', 'cpp', 'ghost', 'scheme',
    'ruby', 'rails', 'rspec', 'go', 'rust', 'zig', 'odin', 'python',
    'haskell', 'blesh' }

local names, EXTRACT, FILECAP = {}, false, 150
for _, a in ipairs(arg or {}) do
    if a == '--extract' then EXTRACT = true
    elseif a:match('^%-%-files=%d+$') then
        FILECAP = tonumber(a:match('%d+')) or FILECAP
    elseif not a:match('^%-%-') then names[#names + 1] = a end
end
if #names == 0 then names = DEFAULT end

local extlang = {}
for lang, spec in pairs(ts.spec) do
    for _, e in ipairs(spec.exts or {}) do extlang[e] = extlang[e] or lang end
end

-- a spec field "is a query" when it's a string with a capture in it
local function query_fields(spec)
    local out = {}
    for k, v in pairs(spec) do
        if type(v) == 'string' and v:find('@', 1, true)
            and v:find('(', 1, true) then out[k] = v end
    end
    return out
end

-- ── 1. compile check: every lang × every query field (corpus-independent) ──
local confirmed_stale = {}   -- { 'lang field: err' }
local compiled = {}          -- lang -> { {field, query, captures={names}} }
local no_parser = {}
for lang, spec in pairs(ts.spec) do
    local havep = pcall(vim.treesitter.language.add, lang)
    if not havep then
        no_parser[#no_parser + 1] = lang
    else
        compiled[lang] = {}
        for field, qsrc in pairs(query_fields(spec)) do
            local ok, q = pcall(vim.treesitter.query.parse, lang, qsrc)
            if not ok then
                confirmed_stale[#confirmed_stale + 1] = ('%s %s: %s')
                    :format(lang, field, tostring(q):gsub('\n.*', ''))
            else
                compiled[lang][#compiled[lang] + 1] =
                    { field = field, q = q }
            end
        end
    end
end

-- ── 2. per-corpus: vocab firing (snapshot calls) + capture firing (files) ──
local vocabhits = {}   -- lang -> entry -> n
local packhits = {}    -- pack -> entry -> n
local capturehits = {} -- lang -> 'field@capture' -> n
local gap = {}         -- lang -> tail -> n   (plain-unresolved, unlisted)
local callsseen = {}   -- lang -> n  (coverage threshold for vocab judgment)
local filesseen = {}   -- lang -> n  (coverage threshold for capture judgment)

local function tally(t, lang, key, n)
    local l = t[lang]; if not l then l = {}; t[lang] = l end
    l[key] = (l[key] or 0) + (n or 1)
end

local function corpus_files(root)
    local byext, total = {}, 0
    local stack = { root }
    while #stack > 0 and total < 200000 do
        local dir = table.remove(stack)
        local ok, iter = pcall(vim.fs.dir, dir)
        if ok then
            for name2, t in iter do
                if t == 'directory' then
                    if not name2:match('^%.') and name2 ~= 'node_modules'
                        and name2 ~= 'vendor' then
                        stack[#stack + 1] = dir .. '/' .. name2
                    end
                elseif t == 'file' then
                    local e = name2:match('%.([%w]+)$')
                    if e and extlang[e] then
                        local l = byext[extlang[e]] or {}
                        byext[extlang[e]] = l
                        l[#l + 1] = dir .. '/' .. name2
                        total = total + 1
                    end
                end
            end
        end
    end
    return byext
end

local audited = {}
for _, name in ipairs(names) do
    local c = corpora[name]
    if not c then
        print(('specaudit: unknown corpus %q — skipped'):format(name))
    else
        -- vocab + gap, from the snapshot's per-call callee tails
        local data = snapshot.load(name)
        if not data and EXTRACT then data = bench.extract(name) end
        if not data then
            print(('specaudit: %s has no snapshot (pass --extract) — vocab skipped')
                :format(name))
        else
            local active = {}
            for _, pn in ipairs(c.packs or {}) do
                if ts.packs[pn] then active[pn] = ts.packs[pn] end
            end
            for _, call in ipairs(data.calls or {}) do
                local e = call.file and call.file:match('%.([%w]+)$')
                local lang = e and extlang[e]
                local spec = lang and ts.spec[lang]
                if spec and call.callee then
                    callsseen[lang] = (callsseen[lang] or 0) + 1
                    local tail = call.callee:match('([%w_]+[!?]?)$')
                    local sn = spec.stdlib_names or {}
                    if sn[call.callee] then tally(vocabhits, lang, call.callee)
                    elseif tail and sn[tail] then tally(vocabhits, lang, tail) end
                    for pn, pack in pairs(active) do
                        if pack.lang == lang then
                            local pv = pack.stdlib_names or {}
                            if pv[call.callee] then tally(packhits, pn, call.callee)
                            elseif tail and pv[tail] then tally(packhits, pn, tail) end
                        end
                    end
                    -- plain unresolved (no target, no refusal = outside the
                    -- graph) and unlisted → a gap candidate
                    if not call.to and not call.refused and tail and #tail >= 3
                        and not sn[tail] then
                        local claimed = false
                        for _, pack in pairs(active) do
                            if pack.lang == lang
                                and (pack.stdlib_names or {})[tail] then
                                claimed = true
                            end
                        end
                        if not claimed then tally(gap, lang, tail) end
                    end
                end
            end
        end
        -- capture firing: run compiled queries over a file sample per lang
        local byext = corpus_files(vim.fn.expand(c.root))
        for lang, files in pairs(byext) do
            if compiled[lang] and #compiled[lang] > 0 then
                table.sort(files)
                local stride = math.max(1, math.ceil(#files / FILECAP))
                for i = 1, #files, stride do
                    local fd = io.open(files[i], 'rb')
                    local src = fd and fd:read('a')
                    if fd then fd:close() end
                    if src and #src < 2 * 1024 * 1024 then
                        local okp, parser =
                            pcall(vim.treesitter.get_string_parser, src, lang)
                        local tree = okp and parser:parse()[1]
                        if tree then
                            filesseen[lang] = (filesseen[lang] or 0) + 1
                            for _, cq in ipairs(compiled[lang]) do
                                for id in cq.q:iter_captures(tree:root(), src, 0, -1) do
                                    tally(capturehits, lang,
                                        cq.field .. '@' .. cq.q.captures[id])
                                end
                            end
                        end
                    end
                end
            end
        end
        audited[#audited + 1] = name
    end
end

-- ── 3. report ──────────────────────────────────────────────────────────────
local function sortedkeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

print(('SPEC AUDIT — corpora: %s'):format(table.concat(audited, ' ')))
print('')
print('== CONFIRMED STALE: query fails to compile against the grammar ==')
if #confirmed_stale == 0 then print('  (none)') end
for _, s in ipairs(confirmed_stale) do print('  ' .. s) end

print('')
print('== SUSPECT: query capture never fired (usage can only say suspect) ==')
local any = false
for _, lang in ipairs(sortedkeys(compiled)) do
    local seen = filesseen[lang] or 0
    if seen > 0 then
        local dead = {}
        for _, cq in ipairs(compiled[lang]) do
            for _, cap in ipairs(cq.q.captures) do
                local key = cq.field .. '@' .. cap
                if not (capturehits[lang] and capturehits[lang][key]) then
                    dead[#dead + 1] = key
                end
            end
        end
        if #dead > 0 then
            any = true
            table.sort(dead)
            print(('  %s (%d files sampled): %s')
                :format(lang, seen, table.concat(dead, ' · ')))
        end
    end
end
if not any then print('  (none)') end

print('')
print('== SUSPECT: stdlib_names entry never seen as a callee ==')
for _, lang in ipairs(sortedkeys(callsseen)) do
    local sn = ts.spec[lang] and ts.spec[lang].stdlib_names or {}
    local dead, live = {}, 0
    for entry in pairs(sn) do
        if vocabhits[lang] and vocabhits[lang][entry] then live = live + 1
        else dead[#dead + 1] = entry end
    end
    table.sort(dead)
    if next(sn) then
        print(('  %s (%d calls seen, %d/%d entries fired)%s'):format(lang,
            callsseen[lang], live, live + #dead,
            #dead > 0 and ': ' .. table.concat(dead, ' · ') or ''))
    end
end

print('')
print('== PACK vocab (audited only where the pack is active) ==')
local packcorp = {}
for _, name in ipairs(audited) do
    for _, pn in ipairs((corpora[name] or {}).packs or {}) do
        packcorp[pn] = packcorp[pn] or {}
        packcorp[pn][#packcorp[pn] + 1] = name
    end
end
for _, pn in ipairs(sortedkeys(packcorp)) do
    local pv = (ts.packs[pn] or {}).stdlib_names or {}
    local dead, live = {}, 0
    for entry in pairs(pv) do
        if packhits[pn] and packhits[pn][entry] then live = live + 1
        else dead[#dead + 1] = entry end
    end
    table.sort(dead)
    print(('  %s (on: %s; %d/%d entries fired)%s'):format(pn,
        table.concat(packcorp[pn], ' '), live, live + #dead,
        #dead > 0 and ': ' .. table.concat(dead, ' · ') or ''))
end
if not next(packcorp) then print('  (no pack-active corpus in the set)') end

print('')
print('== GAP candidates: frequent plain-unresolved names no vocab claims ==')
for _, lang in ipairs(sortedkeys(gap)) do
    local top = {}
    for tail, n in pairs(gap[lang]) do
        if n >= 25 then top[#top + 1] = { tail, n } end
    end
    table.sort(top, function (a, b) return a[2] > b[2] end)
    if #top > 0 then
        local parts = {}
        for i = 1, math.min(10, #top) do
            parts[#parts + 1] = ('%s×%d'):format(top[i][1], top[i][2])
        end
        print(('  %s: %s'):format(lang, table.concat(parts, ' · ')))
    end
end

print('')
print('== coverage ==')
local unexercised = {}
for lang in pairs(ts.spec) do
    if not callsseen[lang] and not filesseen[lang] then
        unexercised[#unexercised + 1] = lang
    end
end
table.sort(unexercised)
if #unexercised > 0 then
    print('  compile-checked ONLY (no corpus exercised them): '
        .. table.concat(unexercised, ' '))
end
if #no_parser > 0 then
    table.sort(no_parser)
    print('  no parser installed (nothing checked): '
        .. table.concat(no_parser, ' '))
end
