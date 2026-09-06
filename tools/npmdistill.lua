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
--   INVOCATION USED FOR THAT MEASUREMENT (the default --limit is still 60):
--     nvim --headless -u NONE -l tools/npmdistill.lua ghost --limit 200
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

local target, out, limit = nil, repo .. '/lua/cartograph/spec/profile/npm-api.mpack', 60
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
end
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
bench.bootstrap()
pcall(vim.treesitter.language.add, 'typescript')
local nsset, namespaces, sigs, vocab = {}, {}, {}, {}
local npkg, nmem, nret = 0, 0, 0
--- ★★★ THE DECLARED RETURN TYPE, which this tool used to read and throw away
--- (CART-0800). `sinon.stub()` returns `SinonStub` and `supertest(app)` returns
--- `SuperTest<Test>`; the .d.ts states both, and keeping only the member NAME
--- discarded the one fact that lets a chain terminate.
--- WHY IT MATTERS: cartograph's `resolve_returns` is already a fixpoint over
--- calls, following each callee's `ret`. A JS function has none, so nothing
--- propagates — and MEASURED on converse.js, 99 of 179 inferable return chains
--- BOTTOM OUT AT A LIBRARY. This is that bottom.
--- ⚠ THE BASE TYPE ONLY, and `Promise<X>` unwraps to X. A member typed
--- `Promise<SinonStub>` is awaited at the call site far more often than it is
--- held, so X is the type a receiver will actually carry. Anything that is not a
--- plain identifier (a union, a literal, a function type, a generic with more
--- than one argument) yields NIL rather than a guess: a wrong return type
--- propagates through a fixpoint and multiplies.
local function ret_of(n, src)
    local rt = n:field('return_type')[1]
    if not rt then return nil end
    local txt = vim.treesitter.get_node_text(rt, src):gsub('%s+', ' ')
    txt = txt:gsub('^:%s*', '')
    local inner = txt:match('^Promise%s*<%s*([%w_$]+)%s*>$')
    if inner then return inner end
    -- ★ A GENERIC APPLICATION'S BASE NAME IS A REAL TYPE (CART-0804).
    -- `SinonStub<TArgs, TReturnValue>` IS a SinonStub: the type arguments decide
    -- the types of its members' parameters, never WHICH members it has, and the
    -- members are the only thing this surface answers about. Refusing the whole
    -- thing lost `sinon.stub`'s return type — the bottom that a `.returns()`
    -- chain terminates on — for no soundness gain. A union or a function type
    -- still yields nil, because there the base name is a guess.
    local base = txt:match('^([%w_$]+)%s*<.*>$')
    local plain = base or txt:match('^([%w_$]+)$')
    if not plain then return nil end
    -- ⚠ A PRIMITIVE TYPES NOTHING A MEMBER CAN BE RESOLVED ON, and a GENERIC TYPE
    -- VARIABLE is not a type at all. The first cut kept both and produced
    -- `bookshelf.at -> T`, `bookshelf.belongsTo -> R`, `knex.before -> any` —
    -- entries that can only ever match by accident, and a wrong return type
    -- MULTIPLIES through a fixpoint.
    local PRIM = { void = 1, any = 1, unknown = 1, never = 1, ['this'] = 1,
        boolean = 1, string = 1, number = 1, object = 1, symbol = 1, bigint = 1,
        null = 1, undefined = 1, Object = 1, Function = 1 }
    if PRIM[plain] then return nil end
    -- a type VARIABLE by convention: one or two characters, capitalised (T, R,
    -- K, V, TResult is longer and is a real name). Cheap, and the failure mode of
    -- being too strict here is a MISSING return type, not a wrong one.
    if #plain <= 2 and plain:match('^%u') then return nil end
    return plain
end

--- The declared TYPE of a property signature — `assert: SinonAssert` — which is
--- NOT a return type and must never be stored as one: `sinon.assert` does not
--- RETURN a SinonAssert, it IS one. Kept separate for that reason, and read only
--- to flatten a nested namespace path below.
--- the BASE NAME of a type expression, or nil when the expression is not one
--- named type. `SinonStub<A, B>` -> SinonStub (see ret_of on why the base is a
--- real type); a union, a function type or an intersection -> nil.
local function base_of(txt)
    txt = (txt or ''):gsub('%s+', ' '):gsub('^:%s*', '')
    return txt:match('^([%w_$]+)%s*<.*>$') or txt:match('^([%w_$]+)$')
end

-- owner -> { arity -> return base name }, from the CALL SIGNATURES of a callable
-- interface; and alias name -> the set of type names its definition mentions
local call_sigs, alias_names = {}, {}

local function type_of(n, src)
    if n:type() ~= 'property_signature' and n:type() ~= 'public_field_definition' then
        return nil
    end
    local tn = n:field('type')[1]
    if not tn then return nil end
    local txt = vim.treesitter.get_node_text(tn, src):gsub('%s+', ' '):gsub('^:%s*', '')
    return txt:match('^([%w_$]+)%s*<.*>$') or txt:match('^([%w_$]+)$')
end

-- owner -> { member -> true }, so a declared type can be expanded into the
-- members it carries (the flatten pass after every package is absorbed)
local owner_members, prop_type = {}, {}

local function absorb(nsname, src)
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'typescript')
    if not okp then return end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return end
    local found = 0
    -- ★★★ MEMBERS ARE KEYED BY THEIR DECLARING INTERFACE TOO, not only by the
    -- package. Without this a return type cannot chain: `sinon.stub()` returns
    -- `SinonStub`, and resolving `.returns()` on it needs `SinonStub.returns` to
    -- exist. MEASURED before this: of 769 members carrying a declared return type,
    -- ZERO had a type whose own members were in the surface — every chain stopped
    -- one step after it started.
    local function walk(n, owner)
        local t = n:type()
        -- ★★★ A CALLABLE INTERFACE IS HOW A .d.ts SPELLS AN OVERLOADED FUNCTION
        -- (CART-0808). sinon declares `stub: SinonStubStatic` and SinonStubStatic
        -- carries three anonymous call signatures with three DIFFERENT return
        -- types, one per arity. That is not ambiguity to refuse — it is a fact
        -- keyed by argument count, and the call site states its argument count.
        if t == 'call_signature' and owner then
            local params, rtn
            for ch in n:iter_children() do
                local ct = ch:type()
                if ct == 'formal_parameters' then params = ch
                elseif ct == 'type_annotation' then rtn = ch end
            end
            if rtn then
                local base = base_of(vim.treesitter.get_node_text(rtn, src))
                local arity = params and params:named_child_count() or 0
                if base then
                    call_sigs[owner] = call_sigs[owner] or {}
                    -- FIRST signature at an arity wins: the declarations list the
                    -- specific overloads before the catch-alls
                    if call_sigs[owner][arity] == nil then
                        call_sigs[owner][arity] = base
                    end
                end
            end
        end
        if t == 'type_alias_declaration' then
            local anm = n:field('name')[1]
            local at = anm and vim.treesitter.get_node_text(anm, src)
            if at and at:match('^[%w_$]+$') then
                local set = {}
                local function names(x)
                    if x:type() == 'type_identifier' then
                        local nm = vim.treesitter.get_node_text(x, src)
                        if nm and nm:match('^[%w_$]+$') and nm ~= at then set[nm] = true end
                    end
                    for ch in x:iter_children() do if ch:named() then names(ch) end end
                end
                names(n)
                alias_names[at] = set
            end
        end
        if t == 'interface_declaration' or t == 'class_declaration' then
            local onm = n:field('name')[1]
            if onm then
                local ot = vim.treesitter.get_node_text(onm, src)
                if ot and ot:match('^[%w_$]+$') then owner = ot end
            end
        end
        if t == 'function_signature' or t == 'function_declaration'
            or t == 'class_declaration' or t == 'interface_declaration'
            or t == 'variable_declarator' or t == 'method_signature'
            or t == 'property_signature' then
            local nm = n:field('name')[1]
            if nm then
                local nmt = vim.treesitter.get_node_text(nm, src)
                if nmt and nmt:match('^[%w_$]+$') then
                    -- the interface-keyed entry, when this member is declared
                    -- inside one and is not the interface itself
                    if owner and owner ~= nmt then
                        local ok2 = owner .. '.' .. nmt
                        owner_members[owner] = owner_members[owner] or {}
                        owner_members[owner][nmt] = true
                        if not sigs[ok2] then
                            sigs[ok2] = { arities = {}, ret = ret_of(n, src) }
                            nmem = nmem + 1
                            if sigs[ok2].ret then nret = nret + 1 end
                            local pt2 = type_of(n, src)
                            if pt2 then prop_type[ok2] = pt2 end
                        end
                    end
                    local key = nsname .. '.' .. nmt
                    if not sigs[key] then
                        sigs[key] = { arities = {}, ret = ret_of(n, src) }
                        vocab[nmt] = true
                        nmem = nmem + 1
                        found = found + 1
                        if sigs[key].ret then nret = nret + 1 end
                        -- remember what this package-level name IS, so a nested
                        -- namespace (`sinon.assert.calledOnce`) can be flattened
                        local pt = type_of(n, src)
                        if pt then prop_type[key] = pt end
                    end
                end
            end
        end
        for ch in n:iter_children() do if ch:named() then walk(ch, owner) end end
    end
    walk(tree:root(), nil)
    if found > 0 and not nsset[nsname] then
        nsset[nsname] = true
        namespaces[#namespaces + 1] = nsname
        npkg = npkg + 1
    end
end
for _, f in ipairs(fetched) do absorb(f.ns, f.src) end

-- ── FLATTEN ONE LEVEL OF PROPERTY-TYPE INDIRECTION ──────────────────────────
-- ★★★ A NESTED NAMESPACE IS A PATH THE SURFACE CAN STATE (CART-0804). sinon
-- declares `assert: SinonAssert` on its root interface and `calledOnce(...)` on
-- `SinonAssert`, so the corpus's `sinon.assert.calledOnce(spy)` — 1090 sites on
-- ghost, with notCalled at 731 and calledWith at 571 — is TWO facts the surface
-- already holds and no key that joins them. This joins them at DISTILL time and
-- writes `sinon.assert.calledOnce` as an ordinary key.
--
-- ⚠ WHY HERE AND NOT IN mint_path. The alternative is to let the profile accept
-- `sinon.<anything in vocab>` on a three-segment path, and that mints a claim the
-- .d.ts never made — a minted node is a GUARANTEE that this member exists at this
-- path. Flattening keeps the oracle exact: every emitted key is a path the
-- declarations state, spelled out. ONE level only; deeper nesting is rarer than
-- the ambiguity it would buy.
--- an alias resolves when its definition mentions exactly ONE type that this
--- surface knows as an interface: `type SinonStubbedFunction<T> = T extends (...)
--- ? SinonStub<A,R> : SinonStub` names SinonStub on both branches, so the
--- conditional never has to be evaluated to answer what it yields. Two candidates
--- or none, and it stays unresolved rather than guessed.
local function resolve_alias(name, depth)
    if not name or (depth or 0) > 3 then return name end
    if owner_members[name] then return name end
    local set = alias_names[name]
    if not set then return name end
    local one
    for n2 in pairs(set) do
        if owner_members[n2] then
            if one and one ~= n2 then return name end
            one = n2
        end
    end
    if one then return resolve_alias(one, (depth or 0) + 1) end
    return name
end

-- ── THE RETURN TYPE OF A CALLABLE PROPERTY, KEYED BY ARITY ──────────────────
-- ★★★ `sinon.stub` had no return type and that is where the volume is: the
-- .d.ts declares it as `stub: SinonStubStatic`, a PROPERTY type — sinon.stub does
-- not RETURN a SinonStubStatic, it IS one — and SinonStubStatic's three call
-- signatures return three different types, one per arity:
--     ()             -> SinonStub
--     (obj)          -> SinonStubbedInstance
--     (obj, method)  -> SinonStubbedFunction   (an alias, resolving to SinonStub)
-- ⚠ A SINGLE `ret` HERE WOULD BE A GUESS, and picking the majority answer would
-- make `sinon.stub(obj).reset()` claim sinon's own `reset` when it means the
-- stubbed object's. The arity is not ambiguity — IT IS THE KEY, the call site
-- states it, and resolve_returns reads the determining call's argument count. So
-- store the whole map and let the call decide; `ret` is filled only when every
-- overload agrees, which is what a caller without an argument count can honestly
-- use.
local nrets = 0
for key, ty in pairs(prop_type) do
    local cs = call_sigs[resolve_alias(ty)]
    if cs and not sigs[key].ret then
        local rets, one, unanimous = {}, nil, true
        for arity, r in pairs(cs) do
            local rr = resolve_alias(r)
            rets[arity] = rr
            if one and one ~= rr then unanimous = false end
            one = one or rr
        end
        if next(rets) then
            sigs[key].rets = rets
            if unanimous then sigs[key].ret = one end
            nrets = nrets + 1
        end
    end
end

local nflat = 0
for key, ty in pairs(prop_type) do
    for member in pairs(owner_members[ty] or {}) do
        local flat = key .. '.' .. member
        if not sigs[flat] then
            sigs[flat] = { arities = {}, ret = sigs[ty .. '.' .. member]
                and sigs[ty .. '.' .. member].ret or nil }
            vocab[member] = true
            nflat = nflat + 1
        end
    end
end

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
    stamp = ('npm-%d-%d'):format(npkg, nmem),
    sig_kind = 'javascript', sig_root = 'unpkg',
    types = {}, namespaces = namespaces, nsset = nsset,
    free = {}, vocab = vocab, sigs = sigs,
}))
fd:close()
print(('npmdistill: %d packages, %d members (+%d nested paths flattened),'
    .. ' %d with a declared return type, %d callable properties typed BY ARITY -> %s')
    :format(npkg, nmem, nflat, nret, nrets, out:gsub('^' .. vim.pesc(repo) .. '/', '')))
