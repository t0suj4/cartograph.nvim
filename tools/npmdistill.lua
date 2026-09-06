-- npmdistill — distil the surface of a project's npm DEPENDENCIES into an L2
-- environment profile ([[cartograph-stdlib-profile]]), CART-0800.
--
--   nvim --headless -u NONE -l tools/npmdistill.lua <corpus|dir> [--out <path>]
--                                                   [--limit N]
--
-- ★★★ SECURITY POSTURE — THE CONTROL IS "NEVER INSTALL", NOT A SANDBOX.
-- The concern raised (user, 2026-09-06) was malicious npm POSTINSTALL scripts, and
-- the first cut answered it with a container. That was the wrong boundary, and the
-- user said so: "I guess the containerization is unnecessary when we don't use
-- npm." Correct — and worth stating precisely, because a control in the wrong
-- place is worse than none: it invites the belief the risk is handled.
--
--   WHAT DEFEATS postinstall: NOT INSTALLING. `npm install` is what runs
--   preinstall/install/postinstall. This tool never invokes npm. It performs TWO
--   TEXT GETs per package — the manifest, then its TypeScript declaration — and
--   that is the entire interaction with the registry.
--   ⚠ `npm install --ignore-scripts` would NOT be equivalent: a package can still
--   reach execution at install time through bin shims and node-gyp. Not
--   installing is the only airtight version.
--
--   NO PACKAGE CODE IS EXECUTED, here or anywhere downstream. A `.d.ts` is a
--   DECLARATION file — no executable body by construction — and it is read for
--   NAMES only.
--
--   THE PACKAGE LIST COMES FROM THE CORPUS'S OWN package.json, read locally, and
--   every name is validated against a strict grammar before it enters a URL. The
--   tool cannot be steered by anything it downloads.
--
-- ⚠ WHAT IS *NOT* PROTECTED, said plainly: the declaration text is
-- attacker-controlled and is parsed on this host by a C tree-sitter grammar. THAT
-- is the residual exposure — and note the container never covered it either,
-- because the parse always happened host-side. If isolation is ever wanted here,
-- it is the PARSE that must move, not the fetch.

-- ★★ WHY IT IS WORTH IT, MEASURED (CART-0800). The node profile took ghost from
-- 29.7% to 42.3% and converse.js from 23.3% to only 23.9% — because ghost's
-- unresolved mass is node BUILTINS while converse.js's is npm PACKAGES (Strophe,
-- vitest, Lit). And npm imports are not a tail: in 400 ghost files there are 986
-- bare-specifier imports against 857 relative ones.
--
-- ★★★ AND IT MEASURED +0.5 POINTS UNTIL THREE DEFECTS WERE FOUND (CART-0804):
-- the package list was truncated ALPHABETICALLY, a 404 was mistaken for a
-- declaration, and a nested namespace path had no key. Fixed, ghost's surface went
-- 63 -> 104 packages and resolution 42.3% -> 45.6%. Each is written up at its
-- site below; the common shape is that all three FAILED QUIETLY — the tool printed
-- a package count and a member count, and both numbers looked healthy while the
-- corpus's most-imported package was absent from the artifact.
--
--   INVOCATION:  nvim --headless -u NONE -l tools/npmdistill.lua ghost
--   (--limit now defaults to 1000, a runaway bound rather than a selection —
--    see the comment on it below; ghost, the largest corpus here, imports 177)
--   ⚠ AND THE ARTIFACT IS PROJECT DATA. Remove it before gating anything: every
--   pinned count in tools/corpora.lua was calibrated WITHOUT an npm surface.
--
-- ⚠⚠ AND THE ROOT IS A CONVENTION, exactly as it is for node modules. `const sinon
-- = require('sinon')` names the binding after the package and IS reachable;
-- `const _ = require('lodash')` is NOT. Minting stays gated on the member existing
-- in the declared surface (spec/profile/npm.lua), so a local object that merely
-- shares a package's name mints nothing. Covering `_` needs the import BINDING
-- recorded in the graph, which it is not today — that is the other half of this
-- work and it needs no network.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')

-- ★★★ THE DEFAULT IS A RUNAWAY BOUND, NOT A SELECTION POLICY (CART-0805). It was
-- 60, and that was the SECOND half of the same defect as the alphabetical sort:
-- ranking fixed WHICH packages survive a cut and left an arbitrary cut in place.
-- On ghost the old default dropped 117 packages the corpus demonstrably imports —
-- 27 packages and 4743 members instead of 104 and 10614 — so two people distilling
-- the same corpus with different flags built DIFFERENT GRAPHS from the same code.
--
-- ⚠ THE DISTINCTION IS THE WHOLE POINT. A cap that DECIDES WHAT YOU GET is a bug:
-- every surviving name is one the code has already asked for, and refusing to
-- fetch it refuses a question the corpus posed. A cap that BOUNDS A PATHOLOGICAL
-- INPUT is a safety rail: the package list comes from a manifest, each name
-- becomes two network requests, and a manifest with ten thousand dependencies
-- should not be able to turn one command into twenty thousand of them.
-- So the default is set far above any real manifest (ghost, the largest corpus
-- here, imports 177) and SAYS SO LOUDLY if it ever binds. If you see it fire,
-- the interesting question is what that manifest is, not what to pass.
local target, out, limit = nil, repo .. '/lua/cartograph/spec/profile/npm-api.mpack', 1000
local i = 1
while arg and arg[i] do
    local a = arg[i]
    if a == '--out' then out = arg[i + 1]; i = i + 2
    elseif a == '--limit' then limit = tonumber(arg[i + 1]) or limit; i = i + 2
    else target = a; i = i + 1 end
end
if not target then print('usage: npmdistill.lua <corpus|dir> [--out P] [--limit N]'); os.exit(2) end
if vim.fn.executable('curl') ~= 1 and vim.fn.executable('wget') ~= 1 then
    print('npmdistill: needs curl or wget to read the registry.'); os.exit(2)
end

-- ── the package list, read LOCALLY from the corpus's own manifest ────────────
local ok, c = pcall(bench.corpus, target)
local root = ok and c.root or target
local function read(p) local fd = io.open(p, 'r'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s end
local manifest, mdir = nil, root
for _ = 1, 4 do
    local s = read(mdir .. '/package.json')
    if s then manifest = s; break end
    local parent = mdir:match('^(.*)/[^/]+$')
    if not parent or parent == mdir then break end
    mdir = parent
end
if not manifest then print('npmdistill: no package.json at or above ' .. root); os.exit(2) end
local okj, pkg = pcall(vim.json.decode, manifest)
if not okj or type(pkg) ~= 'table' then print('npmdistill: package.json unreadable'); os.exit(2) end

local names = {}
for _, field in ipairs({ 'dependencies', 'devDependencies', 'peerDependencies' }) do
    for name in pairs(pkg[field] or {}) do
        -- a package name is a strict grammar; anything else is not fetched.
        -- THIS IS A SECURITY CHECK, not tidiness: the name goes into a URL.
        if name:match('^@?[%w][%w%-%._]*/?[%w%-%._]*$') then names[#names + 1] = name end
    end
end
table.sort(names) -- deterministic artifact (CART-0790)
if #names == 0 then print('npmdistill: no dependencies declared'); os.exit(2) end
local declared = #names
print(('npmdistill: %s — %d packages declared in %s/package.json')
    :format(target, declared, mdir:gsub('^' .. vim.pesc(vim.env.HOME or ''), '~')))

-- ── WHICH OF THEM THE CODE ACTUALLY IMPORTS ─────────────────────────────────
-- ★★★ RANK BY DEMAND, NOT BY ALPHABET (CART-0804). This was `table.sort(names)`
-- followed by a truncation to the first `limit`, and on ghost that is 216
-- declared packages cut to 60 — every one of which begins `@actions`, `@aws-sdk`,
-- `@eslint` or `@tryghost`. chai, sinon, supertest and nock, which between them
-- account for roughly a third of the corpus's unresolved calls, were all past the
-- cut. The surface was distilled and the packages the code leans on were not in
-- it, which is the whole reason the npm profile measured +0.5 points on ghost.
--
-- A DEPENDENCY LIST IS A DECLARATION; THE IMPORT SITES ARE THE MEASUREMENT. The
-- corpus says how much it wants each package and this now reads that, using the
-- spec's OWN import query and `ts.bare_package` — no second copy of the
-- specifier rule, and no text grep (the B4 lesson: a structural query found what
-- a grep census had measured at zero).
-- the scan parses, so the runtime has to be up before the FETCH rather than
-- after it (bootstrap is idempotent; the declaration parse below still calls it)
bench.bootstrap()
pcall(vim.treesitter.language.add, 'javascript')
pcall(vim.treesitter.language.add, 'typescript')
local ts = require 'cartograph.providers.treesitter'
local demand = {}
do
    local files = ts.list_files(root)
    local qcache = {}
    for _, rel in ipairs(files) do
        -- the PARSE grammar, not the family lang — a query has to compile under
        -- the grammar that will run it (the A1 parse_lang split)
        local lang = ts.parse_lang(rel)
        local sp = lang and ts.spec[lang]
        if sp and sp.import_query then
            local src = read(root .. '/' .. rel)
            if src then
                if qcache[lang] == nil then
                    local okq, q = pcall(vim.treesitter.query.parse, lang, sp.import_query)
                    qcache[lang] = okq and q or false
                end
                local q = qcache[lang]
                local tree
                if q then
                    local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
                    if okp then
                        local okt, t = pcall(function () return parser:parse()[1] end)
                        tree = okt and t or nil
                    end
                end
                if tree then
                    for _, match in q:iter_matches(tree:root(), src, 0, -1,
                            { all = true, max_start_depth = nil }) do
                        for id, nodes in pairs(match) do
                            if q.captures[id] == 'path' then
                                local n = type(nodes) == 'table' and nodes[1] or nodes
                                local pk = n and ts.bare_package(
                                    vim.treesitter.get_node_text(n, src))
                                if pk then demand[pk] = (demand[pk] or 0) + 1 end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ⚠ A DECLARED PACKAGE NOTHING IMPORTS IS DROPPED, not merely deprioritised: its
-- surface can only add names that no call in this corpus can reach, and every
-- name in the surface is a chance for a member to match by accident.
local wanted, unimported = {}, 0
for _, n in ipairs(names) do
    if (demand[n] or 0) > 0 then wanted[#wanted + 1] = n else unimported = unimported + 1 end
end
-- demand DESC, then name ASC — the tie-break keeps the artifact deterministic
table.sort(wanted, function (a, b)
    if demand[a] ~= demand[b] then return demand[a] > demand[b] end
    return a < b
end)
local cut = 0
if #wanted > limit then
    cut = #wanted - limit
    local t = {}
    for k = 1, limit do t[k] = wanted[k] end
    wanted = t
    print(('npmdistill: ⚠ THE RUNAWAY BOUND FIRED — %d imported packages past'
        .. ' --limit %d, so this surface describes %d of them and the graph built'
        .. ' on it will differ from one distilled without the cap. Raise --limit,'
        .. ' or ask why this manifest declares %d dependencies.')
        :format(cut, limit, #wanted, #names + unimported))
end
-- ⚠ THE CUT IS A PROPERTY OF THE INVOCATION AND THE ARTIFACT MUST SAY SO. A
-- surface distilled under a cap is a DIFFERENT surface, and a graph built on it
-- resolves differently — recording the number is what lets a later measurement be
-- attributed to a corpus rather than to a flag (CART-0811).
names = wanted
if #names == 0 then
    print('npmdistill: the corpus imports none of its declared packages — nothing'
        .. ' to distil. (A surface of names no call can reach is not a profile.)')
    os.exit(2)
end
print(('npmdistill: %d imported (%d declared but never imported, %d past --limit %d)'
    .. ' — top: %s'):format(#names, unimported, cut, limit,
    table.concat((function ()
        local t = {}
        for k = 1, math.min(8, #names) do
            t[k] = ('%s x%d'):format(names[k], demand[names[k]])
        end
        return t
    end)(), ', ')))

-- ── the fetch: two text GETs per package, no install, no execution ──────────
-- ⚠⚠ `-f` IS LOAD-BEARING, NOT TIDINESS (CART-0804). unpkg answers a missing file
-- with HTTP 404 and a BODY — the text `Not found: /sinon@22.1.0/index.d.ts` — so
-- without --fail curl exits 0 and hands back a non-empty string. The emptiness
-- check below then passes, the DefinitelyTyped fallback never runs, and the
-- "declaration" absorbs to zero members. THE FALLBACK THE HEADER DESCRIBES WAS
-- DEAD CODE for exactly the packages it names: sinon, chai, lodash and supertest
-- ship no `types` field, so all four took the default `index.d.ts`, all four got
-- a 404 body, and none of them ever reached @types. 63 of 177 packages produced a
-- surface; with --fail it is far more, and sinon — the corpus's most-imported
-- package by a factor of 1.3 — is one of them.
-- ★ THE TELL WAS A SURFACE THAT DID NOT CONTAIN WHAT THE CORPUS MOST IMPORTS.
local function get(url)
    local r = vim.fn.system({ 'curl', '-fsSL', '--max-time', '10', url })
    if vim.v.shell_error ~= 0 then return nil end
    return r
end
--- `@types/x` describes `x`, and DefinitelyTyped encodes a scope as `foo__bar`.
local function ns_key(p)
    local t = p:match('^@types/(.+)$')
    if not t then return p end
    local scope, rest = t:match('^([^_]+)__(.+)$')
    if scope then return '@' .. scope .. '/' .. rest end
    return t
end
local fetched = {}
for _, name in ipairs(names) do
    local man = get('https://unpkg.com/' .. name .. '/package.json')
    local types = man and (man:match('"types"%s*:%s*"([^"]+)"')
        or man:match('"typings"%s*:%s*"([^"]+)"')) or 'index.d.ts'
    -- a `types` that is not itself a declaration file names a DIRECTORY, and node
    -- resolves a directory to its index — nock declares `"types": "types"`, whose
    -- content is at `types/index.d.ts`. Correcting the path costs no extra GET.
    if not types:match('%.d%.ts$') then types = types:gsub('/$', '') .. '/index.d.ts' end
    local dts = get('https://unpkg.com/' .. name .. '/' .. types)
    if not dts or dts == '' then
        -- ★ FALL BACK TO DefinitelyTyped: most JS packages ship no declarations.
        -- Measured on ghost: of 5 sampled packages only `moment` declared a
        -- `types` field, while sinon, lodash and bookshelf all have `@types/<pkg>`.
        local alias = name:gsub('^@', ''):gsub('/', '__')
        dts = get('https://unpkg.com/@types/' .. alias .. '/index.d.ts')
    end
    if dts and dts ~= '' and not dts:match('^%s*<') then
        fetched[#fetched + 1] = { ns = ns_key(name), src = dts }
    end
end

-- ── parse the DECLARATIONS on the host, with the typescript grammar ─────────
-- A .d.ts has no executable body; this reads names, never runs anything.
--
-- ★★ THE WALK ITSELF LIVES IN tools/dtsread.lua (CART-0805), because the BROWSER
-- surface is the same job over TypeScript's own lib.dom.d.ts and a second copy of a
-- declaration walker is a second copy of every bug in it. What stays here is what
-- is actually specific to npm: which packages to fetch, how to reach them without
-- installing anything, and the fact that a PACKAGE NAME is the namespace.
bench.bootstrap()
pcall(vim.treesitter.language.add, 'typescript')
local dts = dofile(repo .. '/tools/dtsread.lua')

local acc = dts.new()
local npkg = 0
for _, f in ipairs(fetched) do
    if dts.absorb(acc, f.src, { ns = f.ns }) > 0 then npkg = npkg + 1 end
end
local rep = dts.finish(acc)
local nmem, nret, nflat, nrets = acc.nmem, acc.nret, rep.flat, rep.rets

local namespaces = {}
for k in pairs(acc.nsset) do namespaces[#namespaces + 1] = k end
local nsset, sigs, vocab = acc.nsset, acc.sigs, acc.vocab


if npkg == 0 then
    print('npmdistill: no package declared a readable surface — refusing to write'
        .. ' an empty profile, which would activate and disposition NOTHING.')
    os.exit(2)
end
table.sort(namespaces)

local fd = assert(io.open(out, 'wb'))
fd:write(vim.mpack.encode({
    schema = 1, runtime = 'npm-api', lang = 'javascript',
    version = tostring(pkg.name or target) .. '@' .. tostring(pkg.version or '?'),
    stamp = ('npm-%d-%d%s'):format(npkg, nmem, cut > 0 and ('-cut' .. cut) or ''),
    -- how many imported packages this artifact does NOT describe: 0 unless
    -- --limit was given, and a reader of the surface can tell
    cut = cut,
    sig_kind = 'javascript', sig_root = 'unpkg',
    types = {}, namespaces = namespaces, nsset = nsset,
    free = {}, vocab = vocab, sigs = sigs,
}))
fd:close()
print(('npmdistill: %d packages, %d members (+%d nested paths flattened),'
    .. ' %d with a declared return type, %d callable properties typed BY ARITY -> %s')
    :format(npkg, nmem, nflat, nret, nrets, out:gsub('^' .. vim.pesc(repo) .. '/', '')))
