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
if #names > limit then
    local t = {}
    for k = 1, limit do t[k] = names[k] end
    names = t
end
if #names == 0 then print('npmdistill: no dependencies declared'); os.exit(2) end
print(('npmdistill: %s — %d packages from %s/package.json')
    :format(target, #names, mdir:gsub('^' .. vim.pesc(vim.env.HOME or ''), '~')))

-- ── the fetch: two text GETs per package, no install, no execution ──────────
local function get(url)
    local r = vim.fn.system({ 'curl', '-sSL', '--max-time', '10', url })
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
    local plain = txt:match('^([%w_$]+)$')
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
                        if not sigs[ok2] then
                            sigs[ok2] = { arities = {}, ret = ret_of(n, src) }
                            nmem = nmem + 1
                            if sigs[ok2].ret then nret = nret + 1 end
                        end
                    end
                    local key = nsname .. '.' .. nmt
                    if not sigs[key] then
                        sigs[key] = { arities = {}, ret = ret_of(n, src) }
                        vocab[nmt] = true
                        nmem = nmem + 1
                        found = found + 1
                        if sigs[key].ret then nret = nret + 1 end
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
print(('npmdistill: %d packages, %d members, %d WITH A DECLARED RETURN TYPE -> %s')
    :format(npkg, nmem, nret, out:gsub('^' .. vim.pesc(repo) .. '/', '')))
