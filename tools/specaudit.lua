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
    'haskell', 'blesh', 'erlang' }

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

-- a spec field "is a query" when it's a string with a capture in it — AND opens
-- with an s-expression. Without the last clause `annot_tag` qualified, because a
-- LUA PATTERN `'^%s*%-%-%-@([%a_]+)%s*(.*)$'` also contains an `@` and a `(`; it
-- then failed to compile and was reported under CONFIRMED STALE forever. A known
-- false positive in a section teaches you to skim it, which is the whole value of
-- the tier — and the fn_types check now files into the same list.
local function query_fields(spec)
    local out = {}
    for k, v in pairs(spec) do
        if type(v) == 'string' and v:find('@', 1, true)
            and v:match('^%s*[%(%[]') then out[k] = v end
    end
    return out
end

-- ── 0. the spec CONTRACT: capability matrix + closed-contract check ──
-- (corpus-independent, [[cartograph-spec-layering]]) — which capability groups
-- each language fills (the "N cheap front-ends" metric) + a tripwire for any
-- spec field not registered in the contract.
do
    local contract = require 'cartograph.spec.contract'
    for _, l in ipairs(contract.matrix_report(ts.spec)) do print(l) end
    print('')
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
        -- `fn_types` is a TABLE of node types, so it never reaches the query
        -- compiler and nothing ever checked it against the grammar. It sat with a
        -- php entry the grammar had RENAMED, naming nothing, indefinitely. The
        -- symbol table is the same oracle tools/langaudit.lua uses — a table of
        -- node types earns the compile tier exactly as a query does (CART-0306).
        local okins, info = pcall(vim.treesitter.language.inspect, lang)
        local syms = (okins and info or {}).symbols or {}
        for t in pairs(spec.fn_types or {}) do
            if syms[t] == nil then
                confirmed_stale[#confirmed_stale + 1] =
                    ('%s fn_types: %q is not a node type in this grammar'):format(lang, t)
            end
        end
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
local profhits = {}    -- profile -> declared name -> n
local profseen = {}    -- profile -> calls seen in ITS language (coverage threshold)
local callsseen = {}   -- lang -> n  (coverage threshold for vocab judgment)
local filesseen = {}   -- lang -> n  (coverage threshold for capture judgment)
local deftypes = {}    -- lang -> node type -> n  (what `functions`@def landed on)

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
            -- the DECLARATIVE ARTIFACT surface: whichever profile this root's
            -- shape activates. ~7400 hand-authored names across the shipped
            -- profiles and nothing checked whether any of them are real or used.
            local pname, prof
            do
                local ok_s, shapes = pcall(require, 'cartograph.shapes')
                local pf = ok_s and shapes.profile_for(vim.fn.expand(c.root))
                pname = pf and pf.profile
                if pname then
                    prof = require('cartograph.spec.profile').load(pname)
                    if prof then profseen[pname] = (profseen[pname] or 0) end
                end
            end
            for _, call in ipairs(data.calls or {}) do
                local e = call.file and call.file:match('%.([%w]+)$')
                local lang = e and extlang[e]
                local spec = lang and ts.spec[lang]
                -- profile firing: only for files in the profile's OWN language, so
                -- a polyglot corpus does not credit a lua profile with php calls
                if prof and lang == prof.lang and call.callee then
                    profseen[pname] = (profseen[pname] or 0) + 1
                    -- `callee` is the BARE name; the qualified form lives in
                    -- `full` (callrec.full: 'M.g' where callee is 'g'). Matching a
                    -- namespace member against callee reported zero literal hits
                    -- for every profile, which is how this was caught.
                    local full = call.full or call.callee
                    local tail = call.callee:match('([%w_]+)$')
                    if (prof.free or {})[full] then
                        tally(profhits, pname, full)
                    else
                        local ns, mem = full:match('^([%w_]+)[.:]([%w_]+)$')
                        local t = ns and (prof.types or {})[ns]
                        if t and (t.members or {})[mem] then
                            tally(profhits, pname, ns .. '.' .. mem)
                        elseif tail and (prof.free or {})[tail] then
                            tally(profhits, pname, tail)
                        end
                    end
                end
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
                                for id, node in cq.q:iter_captures(tree:root(), src, 0, -1) do
                                    local cap = cq.q.captures[id]
                                    tally(capturehits, lang, cq.field .. '@' .. cap)
                                    -- FN_TYPES COMPLETENESS, free of an extra walk:
                                    -- whatever the `functions` query calls a def, the
                                    -- spec's fn_types must be able to NAME. The two
                                    -- answered differently for six languages before
                                    -- anyone looked (CART-0306).
                                    if cq.field == 'functions' and cap == 'def' then
                                        tally(deftypes, lang, node:type())
                                    end
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
print('== fn_types COMPLETENESS: every observed `functions`@def type must be named ==')
-- The other direction from the compile check above: that one asks "does this
-- entry exist in the grammar", this asks "does the grammar produce a def type
-- this set cannot name". Only the second one catches an OMISSION, which is the
-- shape the language fence is blind to — a partial table looks exactly like a
-- complete one (CART-0306).
do
    local anyf = false
    for _, lang in ipairs(sortedkeys(deftypes)) do
        local declared = ts.spec[lang] and ts.spec[lang].fn_types
        local miss, cover = {}, {}
        for t, n in pairs(deftypes[lang]) do
            if declared and declared[t] then cover[#cover + 1] = ('%s=%d'):format(t, n)
            else miss[#miss + 1] = ('%s=%d'):format(t, n) end
        end
        table.sort(miss); table.sort(cover)
        if not declared then
            anyf = true
            print(('  %s: NO fn_types declared — falls back to the shared default, which'
                .. ' names %s'):format(lang, table.concat(cover, ' ')))
        elseif not next(declared) then
            -- ORDER MATTERS: an empty set misses EVERY observed type, so testing
            -- for misses first would report a declared refusal as a defect and
            -- the honest thing would read exactly like the dishonest one.
            print(('  %s: fn_types is empty BY DECLARATION — %s observed as a def type'
                .. ' and not nameable from the node type alone')
                :format(lang, table.concat(miss, ' ')))
        elseif #miss > 0 then
            anyf = true
            print(('  %s: %s NOT in fn_types (covered: %s)')
                :format(lang, table.concat(miss, ' · '),
                    #cover > 0 and table.concat(cover, ' ') or 'none'))
        end
    end
    if not anyf then print('  (every declared set covers every observed def type)') end
end

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
print('== SUSPECT: PROFILE-declared name never seen as a callee ==')
do
    local profmod = require 'cartograph.spec.profile'
    local all = {}
    local it = vim.uv.fs_scandir(REPO .. '/lua/cartograph/spec/profile')
    while it do
        local n = vim.uv.fs_scandir_next(it)
        if not n then break end
        local base = n:match('^(.+)%.lua$') or n:match('^(.+)%.mpack$')
        if base and base ~= 'init' then all[base] = true end
    end
    for _, pn in ipairs(sortedkeys(all)) do
        local prof = profmod.load(pn)
        local seen = profseen[pn]
        if not prof then
            print(('  %-14s (artifact will not load)'):format(pn))
        elseif not seen or seen == 0 then
            -- NOT "all stale": no audited corpus activates this profile, so its
            -- names were never given a chance to fire. Saying otherwise would be
            -- the same overclaim the two-tier split exists to prevent.
            print(('  %-14s not exercised by this corpus set (add a corpus whose'
                .. ' shape activates it)'):format(pn))
        else
            -- ONLY BARE NAMES ARE JUDGED. A type-member key is not answerable
            -- from a callee name, and whether it ever COULD be is
            -- language-dependent: Lua writes `table.insert` literally, Ruby never
            -- writes `Array.append` — the call site says `append` and attributing
            -- it needs receiver typing. So members are COUNTED and their literal
            -- hits reported, but their absence is NOT evidence of staleness.
            -- Claiming otherwise would report a fact about the ARTIFACT as a claim
            -- about the runtime, which is the trap portability.name_queryable
            -- exists for — and it is how a first draft of this section announced
            -- 1037 dead Rails names that were nothing of the kind.
            local dead, live = {}, 0
            for nm in pairs(prof.free or {}) do
                if profhits[pn] and profhits[pn][nm] then live = live + 1
                else dead[#dead + 1] = nm end
            end
            table.sort(dead)
            local shown = {}
            for i = 1, math.min(12, #dead) do shown[#shown + 1] = dead[i] end
            print(('  %-14s %d calls seen · bare names %d/%d fired%s'):format(pn,
                seen, live, live + #dead,
                #dead > 0 and ('; %d never: %s%s'):format(#dead,
                    table.concat(shown, ' · '),
                    #dead > 12 and ' …' or '') or ''))
            local members, mhit = 0, 0
            for T, t in pairs(prof.types or {}) do
                for m in pairs(t.members or {}) do
                    members = members + 1
                    if profhits[pn] and profhits[pn][T .. '.' .. m] then
                        mhit = mhit + 1
                    end
                end
            end
            if members > 0 then
                print(('  %-14s   %d type-member key(s), %d seen as a literal'
                    .. ' qualified call — the rest need receiver typing, so their'
                    .. ' absence is NOT stale evidence'):format('', members, mhit))
            end
        end
    end
end

print('')
print('== ECOSYSTEM specs: is every declared rule actually READ? ==')
-- The check that matters for a layout spec: not "does this name exist in a
-- grammar" but "does any code consult this field". A declared rule nobody reads is
-- dead spec that looks authoritative — and unlike a vocab entry, no corpus can
-- reveal it. Crude by design (a field read through a variable reads as unread), so
-- it reports SUSPECT, never CONFIRMED.
do
    local ok_e, eco = pcall(require, 'cartograph.spec.ecosystem')
    if not ok_e then
        print('  (no ecosystem loader)')
    else
        -- one pass over the plugin source, so this is O(source) not O(fields)
        -- BOTH the runtime and the TOOLS: a rule may legitimately be consumed only
        -- by a tool (api_source is, by apifetch), and scanning lua/ alone reported
        -- three such rules as permanently UNREAD — the same false-noise problem the
        -- `notes` exclusion fixed from the other direction.
        local src = {}
        local stack = { REPO .. '/lua/cartograph', REPO .. '/tools' }
        while #stack > 0 do
            local dir = table.remove(stack)
            local okd, iter = pcall(vim.fs.dir, dir)
            if okd then
                for n2, t2 in iter do
                    local pth = dir .. '/' .. n2
                    -- SKIP THE DECLARATIONS, NOT THE LOADER. Excluding
                    -- `/spec/ecosystem/` wholesale hid the roster, which lives in
                    -- init.lua and is the primary consumer — so five rules it
                    -- genuinely reads (roots.user.mod_list, enablement.list_key /
                    -- enabled_key, identity.version_key / deps_key) sat on the UNREAD
                    -- list, and the list is only worth anything if every name on it is
                    -- really waiting for a consumer.
                    local is_decl = pth:match('/spec/ecosystem/')
                        and not pth:match('/spec/ecosystem/init%.lua$')
                    if t2 == 'directory' then stack[#stack + 1] = pth
                    elseif n2:match('%.lua$') and not is_decl
                        and not pth:match('/tools/specaudit%.lua$') then
                        local fd = io.open(pth, 'rb')
                        if fd then src[#src + 1] = fd:read('a'); fd:close() end
                    end
                end
            end
        end
        local blob = table.concat(src, '\n')
        local function reads(field)
            return blob:find('%.' .. field .. '%f[^%w_]') ~= nil
                or blob:find("%['" .. field .. "'%]") ~= nil
                or blob:find('%f[%w_]' .. field .. '%s*=%s*') ~= nil
        end
        for _, en in ipairs(eco.names()) do
            local spec = eco.load(en)
            local unread, total = {}, 0
            local function walk(t, path)
                for k, v in pairs(t) do
                    -- `notes` is prose ABOUT the rules; it can never be consumed,
                    -- so counting it would give a permanently non-empty UNREAD
                    -- list and hide the entries actually awaiting a consumer
                    if type(k) == 'string' and k ~= 'schema' and k ~= 'notes' then
                        local here = path == '' and k or (path .. '.' .. k)
                        if type(v) == 'table' then
                            walk(v, here)
                        else
                            total = total + 1
                            if not reads(k) then unread[#unread + 1] = here end
                        end
                    end
                end
            end
            walk(spec or {}, '')
            table.sort(unread)
            print(('  %-14s %d/%d leaf rules read by some consumer%s'):format(en,
                total - #unread, total,
                #unread > 0 and ('; UNREAD: ' .. table.concat(unread, ' · ')) or ''))
        end
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
