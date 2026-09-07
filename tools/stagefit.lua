-- stagefit — DOES THE SHIPPED STAGE PARTITION CARRY THE JS RUNNER GLOBALS?
-- A GO/NO-GO measurement for CART-0816, run before any of it is built.
--
--   nvim --headless -u NONE -l tools/stagefit.lua <corpus|dir> [--decl <key>]
--                                                 [--top N]
--
-- ★★★ THE QUESTION, AND WHY IT IS A MEASUREMENT AND NOT A DESIGN. The largest
-- single JS resolution lever is the test framework — CART-0803 measured it at
-- 31541 calls / +24.1 pts on ghost, 15847 / +26.8 on converse.js. Half of it
-- (chai/sinon member surfaces) shipped as CART-0804. The other half is the
-- RUNNER GLOBALS — `it`, `describe`, `beforeEach`, `expect` — which nothing
-- imports: the runner injects them. Free-listing them in the node profile would
-- mint them CORPUS-WIDE, so a bare `it()` in `src/` would be claimed as mocha's.
-- That is a POSITIVE claim, and the stdlib-profile law is that a profile may
-- only SUBTRACT ([[cartograph-stdlib-profile]]). The sound cut scopes them to
-- the runner's own test tree.
--
-- ⚠⚠ AND THE MECHANISM FOR THAT IS ALREADY SHIPPED, which CART-0816 asserted it
-- was not. `prof.stages` + `portability.stage_map` + `region_verdict` landed
-- 2026-08-01 as CART-0216 for Factorio's data/runtime split: an ENTRY file
-- matches a declared pattern, every other file INHERITS over the import graph,
-- a file loaded at two stages is held to the INTERSECTION of what both provide,
-- and a file no entry reaches is an ORPHAN — returned, never dropped. Two gaps
-- are real: `stage_owners_of` refuses a BARE name by design (it needs a `.`/`:`
-- separator, correct for `game.print`, wrong for `it`), and the whole mechanism
-- is AUDIT-side — `grep stage providers/treesitter.lua` finds nothing.
--
-- SO THE THING TO MEASURE IS THE PARTITION ITSELF, on JS, before touching the
-- resolver: of the sites that WOULD be minted, how many sit in files reachable
-- only from a test entry (soundly mintable), how many in SHARED files (refused
-- by the intersection rule — the honest cost), and how many in files no entry
-- reaches (orphans, where "stage unknown" must not rule).
--
-- ★★ TWO STAGES ARE DECLARED, NOT ONE, and this is the hole the first sketch
-- had: `shared` means multi-stage membership, so ONE stage produces zero shared
-- files BY CONSTRUCTION. A test entry imports src; with only a test stage
-- declared, every src file a test requires reads as test-only and the
-- measurement blesses exactly the false mints the design fears.
--
-- ★ THE ENTRY PATTERNS ARE TRANSCRIBED FROM THE RUNNERS' OWN CONFIGS, with the
-- source named per stage. This is a report, so a transcription is honest; the
-- eventual resolver build must DERIVE them, which is the same posture as every
-- distiller (ask the tool, do not guess its convention).

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local shapes = require 'cartograph.shapes'
local portability = require 'cartograph.portability'
local callrec = require 'cartograph.callrec'
local census = require 'cartograph.census'

-- ── THE DECLARATIONS. Patterns are matched with `string.match` against the
-- graph's file paths, which are RELATIVE TO THE EXTRACTION ROOT.
local DECLS = {
    -- ghost: root is ghost/ghost/core.
    -- test entries — vitest.config.ts:79 `test/unit/**/*.test.{js,ts}` and
    -- vitest.config.db.ts:104-181 (`test/{e2e-webhooks,e2e-server,e2e-frontend,
    -- integration,legacy,e2e-api}/**/*.test.{js,ts}` + the `.isolated.test`
    -- project). Every one of them is `test/**` ending `.test.js|ts`, so one
    -- pattern is faithful to all seven includes rather than a generalisation of
    -- them. The setupFiles entry is listed separately because the runner loads
    -- it directly and nothing imports it.
    -- prod entries — package.json declares no `main`; its `files` list names
    -- index.js, ghost.js, bin/, MigratorConfig.js, loggingrc.js.
    ghost = {
        { name = 'test', entry = { '^test/.*%.test%.[jt]s$',
            '^test/utils/vitest%-setup%.ts$' },
          src = 'vitest.config.ts:79 + vitest.config.db.ts:104-181 include globs' },
        { name = 'prod', entry = { '^index%.js$', '^ghost%.js$', '^bin/[^/]+%.js$',
            '^MigratorConfig%.js$', '^loggingrc%.js$' },
          src = 'package.json "files"' },
    },
    -- converse.js: root is converse.js/src, so the config's `src/` prefix is
    -- already stripped by the time a path reaches here.
    -- test entries — vitest.config.js:71 `src/**/tests/**/*.js` + `src/**/tests/
    -- *.js` (project main), :82 `**/tests/**/*.js` + `**/tests/*.js` (headless),
    -- :108 `shims/tests/**`, `utils/tests/**`, `plugins/**/tests/*.node.js`.
    -- All three projects key on a `tests/` PATH SEGMENT at any depth, which is
    -- why a directory-prefix cut cannot find this bloc (CART-0803) and a
    -- segment pattern can.
    -- prod entry — package.json `main` is `dist/converse.js`, a BUILD ARTIFACT
    -- outside the extraction root, so the source entry is used instead.
    converse = {
        { name = 'test', entry = { '^tests/', '/tests/' },
          src = 'vitest.config.js:71,82,108 include globs' },
        { name = 'prod', entry = { '^index%.js$', '^headless/index%.js$' },
          src = 'package.json main -> dist/ (a build artifact); its source entry' },
    },
}

local target, declkey, top = nil, nil, 12
local i = 1
while arg and arg[i] do
    if arg[i] == '--decl' then declkey = arg[i + 1]; i = i + 2
    elseif arg[i] == '--top' then top = tonumber(arg[i + 1]); i = i + 2
    elseif not target then target = arg[i]; i = i + 1
    else i = i + 1 end
end
if not target then print('usage: stagefit <corpus|dir> [--decl ghost|converse] [--top N]'); os.exit(2) end

local reg = dofile(repo .. '/tools/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end
declkey = declkey or (root:find('ghost') and 'ghost') or (root:find('converse') and 'converse')
local decl = DECLS[declkey]
if not decl then
    print(('no stage declaration for %s. Known: ghost, converse. A declaration is'
        .. ' TRANSCRIBED from the runner config; guessing one would make this'
        .. ' measurement about my glob rather than the project.'):format(tostring(declkey)))
    os.exit(2)
end

local pf = shapes.profile_for(root)
local base = pf and require('cartograph.spec.profile').load(pf.profile)
if not base then print('no profile activates on ' .. root); os.exit(2) end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
store.ingest(data)

-- ⚠ A COPY, NOT THE SHIPPED PROFILE. `stages` on spec/profile/node.lua is read
-- by the portability audit, and this is a measurement: nothing shipped changes.
local stages = {}
for _, st in ipairs(decl) do stages[#stages + 1] = { name = st.name, entry = st.entry } end
local prof = setmetatable({ stages = stages }, { __index = base })
-- ★★★ AND A SECOND PROFILE WITH NO `lang`, WHICH IS NOT A CONVENIENCE — it is
-- the A/B that measures a DIVERGENCE BETWEEN THE AUDIT AND THE RESOLVER, found
-- by this run's own falsifier column. See the LANGUAGE AXIS section: the
-- resolver folds typescript/tsx INTO javascript (`elang_for`: "one language
-- across .js/.jsx/.ts/.tsx") and the node profile therefore applies to `.ts`
-- files — measured, 1992 stdlib-provenance resolutions on ghost. `stage_map`
-- uses a DIFFERENT language function (portability's own `ext_lang`, the
-- extraction spec registry, where `.ts` is `typescript`) and so excludes every
-- TypeScript file from the partition as "another language". `stage_map` skips
-- its filter entirely when `prof.lang` is nil, so this is the corrected
-- partition, over-including only whatever non-family languages the tree holds —
-- named below rather than hidden, so the reader can size the over-inclusion.
local prof_all = setmetatable({ stages = stages, lang = false }, { __index = base })

print(('stagefit %s — profile %s (%s), declaration `%s`')
    :format(root:gsub('.*/', ''), pf.profile, base.lang or '?', declkey))
for _, st in ipairs(decl) do
    print(('  stage %-6s from %s'):format(st.name, st.src))
end

-- ── THE JOINT CHECK, FIRST. stage_map seeds its queue from node `file` paths
-- matched against the entry patterns and walks `import` edges keyed from/to. If
-- JS import edges do not key on those same paths, entries or propagation come
-- out ZERO — and zero reads exactly like "this corpus has no test files", which
-- is an answer rather than a fault. A number that does not move is the tell.
local nimp = 0
for _, e in ipairs(data.edges or {}) do if e.kind == 'import' then nimp = nimp + 1 end end
local sm_shipped = portability.stage_map(store, prof)
local sm = portability.stage_map(store, prof_all)
if not sm then print('  stage_map returned nil — the profile declares no stages'); os.exit(2) end
local nent, per_stage = 0, {}
for _, s in pairs(sm.entries) do nent = nent + 1; per_stage[s] = (per_stage[s] or 0) + 1 end
local placed = 0
for _ in pairs(sm.by_file) do placed = placed + 1 end
print('')
local placed_shipped, ent_shipped = 0, 0
for _ in pairs(sm_shipped.by_file) do placed_shipped = placed_shipped + 1 end
for _ in pairs(sm_shipped.entries) do ent_shipped = ent_shipped + 1 end
print(('  JOINT: %d import edges · %d entry files · %d files placed · %d shared · %d orphans')
    :format(nimp, nent, placed, #sm.shared, #sm.orphans))
print(('  ⚠ stage_map AS SHIPPED (prof.lang=%s) places %d files from %d entries:'
    .. ' %d fewer files and %d fewer entries than the RESOLVER own language family.')
    :format(tostring(base.lang), placed_shipped, ent_shipped,
        placed - placed_shipped, nent - ent_shipped))
print('    Every number below uses the CORRECTED partition; see LANGUAGE AXIS.')
for _, st in ipairs(decl) do
    print(('    entries[%s] = %d'):format(st.name, per_stage[st.name] or 0))
end
if nent == 0 or placed <= nent then
    print('  ⚠ NO PROPAGATION. Either the entry patterns match nothing or import'
        .. ' edges do not key on these paths — this is a FAULT, not a finding.')
end
-- 3 propagated (non-entry) samples, so the reader can see the walk worked
local samples = {}
for f, at in pairs(sm.by_file) do
    if not sm.entries[f] and #samples < 3 then
        local s = {}
        for k in pairs(at) do s[#s + 1] = k end
        table.sort(s)
        samples[#samples + 1] = ('%s [%s]'):format(f, table.concat(s, '+'))
    end
end
table.sort(samples)
for _, s in ipairs(samples) do print('    propagated e.g. ' .. s) end

-- ★★★ THE AUDIT AND THE RESOLVER DISAGREE ABOUT WHAT LANGUAGE A `.ts` FILE IS,
-- and this measurement found it by accident. stage_map builds its file set from
-- nodes whose extension maps to `prof.lang`, using portability's own
-- `ext_lang()` — the EXTRACTION spec registry, where `.ts` is `typescript` and
-- `.tsx` is `tsx`. The node profile declares `lang = 'javascript'`, so every
-- TypeScript file is dropped from the partition.
--
-- ⚠ I FIRST WROTE THAT UP AS "the profile cannot reach a .ts file at all", which
-- is what the code reads like — `spec_overlay` attaches the profile only when
-- `lang == active_profile.lang` (treesitter.lua:5332). THE FALSIFIER COLUMN
-- BELOW REFUTED IT: `.ts` files on ghost carry 1992 stdlib-provenance
-- resolutions. The resolver does not use the extraction language. It uses
-- `elang_for`, which folds typescript AND tsx INTO javascript — "one language
-- across .js/.jsx/.ts/.tsx", treesitter.lua:1451-1493 — and `elang_for` is a
-- LOCAL, not exported, which is exactly why portability grew a second and
-- divergent copy of the question.
--
-- So this is not a language-axis limit, it is an AUDIT BUG: 233 files and 5103
-- unresolved calls that the resolver treats as javascript are invisible to the
-- partition. It matters for CART-0816 specifically — if the resolver consulted
-- stage_map today, every `.ts` spec file would be an ORPHAN and its `it` calls
-- unmintable, on the very files ghost is migrating to.
--
-- Split the buckets accordingly: an ORPHAN (`unreached`) is a limit of the ENTRY
-- DECLARATION, an OTHER-LANG file is a limit of the partition's language
-- function, and they are fixed by completely different work.
local ext_lang = {}
for lang, sp in pairs(ts.spec or {}) do
    for _, e in ipairs(sp.exts or {}) do ext_lang[e:lower()] = lang end
end
local function lang_of(file)
    local ext = file and file:match('%.([%w]+)$')
    return ext and ext_lang[ext:lower()]
end

-- ── the file CLASS: test-only / shared / prod-only / other-lang / unreached
local function class_of(file)
    local at = file and sm.by_file[file]
    if not at then
        local l = lang_of(file)
        if l and base.lang and l ~= base.lang then return 'other-lang' end
        return 'unreached'
    end
    local n, has_test = 0, false
    for k in pairs(at) do n = n + 1; if k == 'test' then has_test = true end end
    if n > 1 then return 'shared' end
    return has_test and 'test-only' or 'prod-only'
end

-- ── THE JOIN. Every UNRESOLVED call whose callee is a BARE name — no dotted
-- `full`, so nothing types a receiver — is a runner-global mint candidate, and
-- these are exactly the names `stage_owners_of` refuses today. Classify each
-- site by the stage of the file it sits in.
local CLASSES = { 'test-only', 'shared', 'prod-only', 'other-lang', 'unreached' }
local by_name, tot = {}, {}
for _, cl in ipairs(CLASSES) do tot[cl] = 0 end
for _, call in callrec.each(data) do
    if not callrec.to(call) and not call.dynamic then
        local full = callrec.full(call)
        local name = callrec.callee(call)
        -- BARE only: a dotted call names a receiver and belongs to the member
        -- surface (CART-0804's mechanical half), not to a free-list
        if name and not (full and full:find('%.')) then
            local cl = class_of(callrec.file(call))
            local e = by_name[name]
            if not e then e = { n = 0 }; for _, k in ipairs(CLASSES) do e[k] = 0 end
                by_name[name] = e end
            e.n = e.n + 1; e[cl] = e[cl] + 1
            tot[cl] = tot[cl] + 1
        end
    end
end
local prodsites, orphanfiles = {}, {}
for _, call in callrec.each(data) do
    if not callrec.to(call) and not call.dynamic then
        local full = callrec.full(call)
        local name = callrec.callee(call)
        if name and not (full and full:find('%.')) then
            local file = callrec.file(call)
            local cl = class_of(file)
            -- ★ OPEN THE NAMED INSTANCE. A falsifying column of "4" is a number
            -- until you know whether those four are runner globals or unrelated
            -- bare names, and the two verdicts are opposite.
            if cl == 'prod-only' and #prodsites < 24 then
                prodsites[#prodsites + 1] = ('%s  %s:%d')
                    :format(name, file or '?', (callrec.line(call) or 0) + 1)
            elseif cl == 'unreached' then
                orphanfiles[file or '?'] = (orphanfiles[file or '?'] or 0) + 1
            end
        end
    end
end
local ranked = {}
for name, e in pairs(by_name) do ranked[#ranked + 1] = { name = name, e = e } end
table.sort(ranked, function (a, b)
    if a.e.n ~= b.e.n then return a.e.n > b.e.n end
    return a.name < b.name
end)

local grand = 0
for _, k in ipairs(CLASSES) do grand = grand + tot[k] end
local cc = census.take(data)
local function pts(n) return cc.calls.total > 0 and (n * 100 / cc.calls.total) or 0 end
print('')
print(('  BARE unresolved call sites by the stage of their file (%d sites, %d names)')
    :format(grand, #ranked))
print(('  %-22s %6s %6s %6s %7s %6s   %s'):format('name', 'test', 'shared',
    'prod', 'otherL', 'unrch', 'mintable?'))
for k = 1, math.min(#ranked, top) do
    local r = ranked[k]
    -- MINTABLE = test-only. `shared` is refused by the intersection rule (a
    -- helper a test imports is also loaded by src, so it may use only what BOTH
    -- stages provide); `prod-only` would be a FALSE MINT; `orphan` has no stage
    -- and "stage unknown -> do not rule" is the sound default.
    local bad = r.e['prod-only']
    print(('  %-22s %6d %6d %6d %7d %6d   %s'):format(r.name:sub(1, 22),
        r.e['test-only'], r.e['shared'], r.e['prod-only'], r.e['other-lang'],
        r.e['unreached'], bad > 0 and ('⚠ %d prod-only'):format(bad) or 'yes'))
end
-- ★★★ THE VERDICT IS PER NAME, AND THE AGGREGATE IS MISLEADING IN THE DANGEROUS
-- DIRECTION. I built the prod-only TOTAL as the decision column; on ghost it is
-- 4 and on converse.js it is 1707, which reads as a clean NO-GO. Every one of
-- those 1707 is a PROJECT global — `__` (the gettext alias, 757), `html` and
-- `stx` (lit-html template tags, 626), `sizzle`, `dayjs` — injected by a bundler
-- or an i18n layer, and not one of them is a name a runner-global free-list
-- would ever hold. The aggregate answers a question nobody asked: "would a
-- free-list of EVERY bare unresolved name be sound", and no, obviously not.
--
-- ⚠ THE CANDIDATE SET IS THE OPEN PROBLEM, NOT THE PARTITION. Naming the runner
-- globals here would be my guess at mocha's surface; the sound source is the
-- runner's own @types package (@types/mocha, @types/jasmine), which is CART-0816's
-- distiller half and does not exist yet. So this section reports the per-name
-- verdict for the top names and refuses to compute a corpus verdict — the
-- decision belongs to whoever supplies the candidate set.
-- ⚠ AND THE THREE BUCKETS MUST PARTITION THE TOP-N. A first cut had two —
-- clean (test-only > 0) and dirty (prod-only > 0) — and `http`, 264 sites and
-- every one of them SHARED, appeared in neither. That is the intersection rule
-- doing its job, which is the most interesting disposition of the three, and it
-- was rendered as silence. A name with no test sites and no prod sites is
-- REFUSED, not absent.
local clean, dirty, refused = {}, {}, {}
for k = 1, math.min(#ranked, top) do
    local r = ranked[k]
    if r.e['prod-only'] > 0 then dirty[#dirty + 1] = r.name
    elseif r.e['test-only'] > 0 then clean[#clean + 1] = r.name
    else refused[#refused + 1] = ('%s(%d shared)'):format(r.name, r.e['shared']) end
end
print('')
print(('  PER-NAME VERDICT over the top %d bare names (the aggregate below is NOT'):format(top))
print('  a verdict — see the comment in this file: converse.js prod-only is 1707 and')
print('  every site is a project global, not a runner global):')
print(('    fenced by the partition (%d): %s'):format(#clean, table.concat(clean, ' ')))
print(('    NOT fenced (%d): %s'):format(#dirty, table.concat(dirty, ' ')))
print(('    refused by the INTERSECTION rule, no test-only site (%d): %s')
    :format(#refused, table.concat(refused, ' ')))
print('')
print(('  TOTAL  test-only %d (%+.1f pts) · shared %d · prod-only %d'
    .. ' · other-lang %d (%+.1f pts) · unreached %d')
    :format(tot['test-only'], pts(tot['test-only']), tot['shared'],
        tot['prod-only'], tot['other-lang'], pts(tot['other-lang']),
        tot['unreached']))
-- ── ★★★ THE LANGUAGE AXIS, measured because the orphan bucket forced the
-- question, and REPORTED AGAINST MY OWN FIRST READING OF IT. The audit compares
-- `prof.lang` with the EXTRACTION language; the resolver compares it with the
-- EFFECTIVE one, which folds typescript/tsx into javascript. The `stdlib` column
-- is what tells them apart from the outside.
local bylang, unres_bylang = {}, {}
for _, n in ipairs(data.nodes or {}) do
    if n.file then
        local l = lang_of(n.file) or '?'
        bylang[l] = bylang[l] or {}
        bylang[l][n.file] = true
    end
end
-- ⚠ AND THE COLUMN THAT COULD FALSIFY THE CLAIM. "The profile cannot reach a
-- .ts file" is a structural argument about a scalar `==`; the OBSERVABLE
-- consequence is that no call in such a file may ever resolve with the profile's
-- provenance. Counting stdlib-provenance resolutions per language tests the
-- claim directly instead of restating the code.
local stdlib_bylang = {}
for _, call in callrec.each(data) do
    local l = lang_of(callrec.file(call)) or '?'
    if not callrec.to(call) and not call.dynamic then
        unres_bylang[l] = (unres_bylang[l] or 0) + 1
    elseif callrec.to(call) and callrec.prov(call) == 'stdlib' then
        stdlib_bylang[l] = (stdlib_bylang[l] or 0) + 1
    end
end
-- ⚠ THE FOLD IS A FACT ABOUT THE CODE, NOT AN INFERENCE FROM THE DATA.
-- elang_for folds these into javascript unconditionally; the `stdlib` column is
-- EVIDENCE of it, and its absence on a corpus whose .ts files hold 30 calls is
-- no evidence of anything. Reading the label off the evidence alone mislabelled
-- converse.js's 676 TypeScript files as "a genuinely different language".
local FOLDED = { typescript = 'javascript', tsx = 'javascript' }
local langs = {}
for l in pairs(bylang) do langs[#langs + 1] = l end
table.sort(langs, function (a, b) return (unres_bylang[a] or 0) > (unres_bylang[b] or 0) end)
print('')
print(('  LANGUAGE AXIS — the profile declares lang=%s. The AUDIT compares that'
    .. ' with the EXTRACTION language (portability.ext_lang);')
    :format(tostring(base.lang)))
print('  the RESOLVER compares it with the EFFECTIVE one (elang_for, which folds'
    .. ' typescript+tsx into javascript).')
print(('  %-12s %7s %11s %8s  %s'):format('lang', 'files', 'unresolved',
    'stdlib', 'profile applies?'))
local off_lang = 0
for _, l in ipairs(langs) do
    local nf = 0; for _ in pairs(bylang[l]) do nf = nf + 1 end
    local on = (l == base.lang)
    -- only a FOLDED language is work the audit is losing; a genuinely different
    -- one is the language axis doing its job
    if not on and FOLDED[l] then off_lang = off_lang + (unres_bylang[l] or 0) end
    print(('  %-12s %7d %11d %8d  %s'):format(l, nf, unres_bylang[l] or 0,
        stdlib_bylang[l] or 0,
        on and 'resolver yes . audit yes'
            or (FOLDED[l]
                and ((stdlib_bylang[l] or 0) > 0
                    and 'resolver YES (elang fold, PROVEN here) . AUDIT NO'
                    or 'resolver yes (elang fold) . AUDIT NO — no stdlib hit to prove it here')
                or 'neither — a genuinely different language')))
end
print(('  %d unresolved calls sit in files the AUDIT excludes from the partition'
    .. ' (%+.1f pts of stage-scoped work it cannot see)'):format(off_lang, pts(off_lang)))
print('  ★ the `stdlib` column is the FALSIFIER, and IT FIRED: a nonzero count'
    .. ' beside')
print('    "AUDIT NO" means the RESOLVER does reach that language and only the'
    .. ' audit')
print('    does not — a divergence between two copies of one question, not a'
    .. ' language')
print('    the profile cannot model. My first reading of this section was wrong'
    .. ' and')
print('    this column is why I know.')

print('')
print('  ⚠ THE FALSIFYING COLUMN is prod-only: a site a stage-scoped free-list'
    .. ' would mint')
print('    that no test entry reaches. Nonzero means the partition does not fence')
print('    the claim and the runner globals must not ship on it.')
if #prodsites > 0 then
    table.sort(prodsites)
    print('')
    print(('  EVERY prod-only site (%d, capped at 24) — a column of "%d" is a number')
        :format(#prodsites, tot['prod-only']))
    print('  until you know whether these are runner globals or unrelated bare names:')
    for _, l in ipairs(prodsites) do print('    ' .. l) end
end
-- and where the ORPHANS are, because an orphan is a limit of the ENTRY
-- DECLARATION, not of the partition: a better-derived glob converts orphan into
-- test-only, so this bucket sizes the remaining lever rather than a refusal
local of = {}
for f, n in pairs(orphanfiles) do of[#of + 1] = { f = f, n = n } end
table.sort(of, function (a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.f < b.f
end)
if #of > 0 then
    print('')
    print(('  UNREACHED files by bare-unresolved sites (%d files) — same language as')
        :format(#of))
    print('  the profile, but no declared entry reaches them. This is a limit of the')
    print('  ENTRY DECLARATION, not of the partition: a better-derived glob turns these')
    print('  into test-only, so the bucket sizes what better sourcing would add.')
    for k = 1, math.min(#of, 10) do
        print(('    %5d  %s'):format(of[k].n, of[k].f))
    end
end
