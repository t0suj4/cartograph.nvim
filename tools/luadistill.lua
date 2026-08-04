-- luadistill — mint a `luajit` L2 profile by INTROSPECTING the interpreter this
-- runs in, rather than by transcribing a manual. The distinction matters: a
-- hand-typed provides-set is a claim, while `for k in pairs(string)` is a
-- measurement of the runtime that will actually execute the code.
--
-- Motivation ([[cartograph-portability-lever]]): the A-to-B move diff needs TWO
-- name-queryable profiles for ONE language, and only `lua-factorio` shipped. This
-- is its sibling, so "which parts of this mod need Factorio rather than plain
-- Lua?" becomes answerable — and the answer is derived from artifacts, not
-- authored.
--
-- HONESTY about what this profile IS:
--   · the surface of the LuaJIT embedded in the nvim that ran the distiller —
--     recorded in `version` and `stamp`, not implied.
--   · nvim's own additions are EXCLUDED by an explicit deny-list, because a
--     profile called `luajit` must not quietly promise `vim`.
--   · namespaces are taken as the interpreter presents them; a member list is
--     whatever the table actually holds, so nothing is asserted that is absent.
--
--   nvim --headless -u NONE -l tools/luadistill.lua        -- writes the .mpack
--   nvim --headless -u NONE -l tools/luadistill.lua --show -- print, write nothing
--   nvim --headless -u NONE -l tools/luadistill.lua --meta <dir>  -- signature source
--
-- ── TWO SOURCES, TWO TIERS, AND THEY CHECK EACH OTHER (CART-0266) ────────────
-- Introspection measures WHICH NAMES EXIST and can never say what they accept or
-- return: a C function carries no signature at runtime. So the top absent callees
-- across our corpora are the most documented API there is — match 432, concat 222,
-- sort 211, close 193, open 180, sub 145, write 143 on `self`, every one of them
-- 100% frontier for a stub. The missing half is DECLARED, and lua-language-server
-- ships it as `@meta` annotations the CART-0240 reader already parses.
--
-- THE TIERS DIFFER AND MUST STAY LABELLED. `for k in pairs(string)` is a MEASUREMENT
-- of the interpreter that will run the code; an `@meta` docblock is a CLAIM (CART-0240
-- shipped `annotation-mismatch` precisely because docblocks lie). So signatures land
-- as `sig_kind = 'annotation'` and never upgrade a name's existence.
--
-- WHICH MAKES THE CROSS-CHECK FREE, and it is the reason both live in one distiller
-- rather than two: the join is exact (`string` × `format`), so each source audits the
-- other and BOTH directions are informative. A member the interpreter has and the meta
-- does not = an honest signature gap. A member the meta declares and this interpreter
-- lacks = a claim about a runtime we are not on, REPORTED and not merged. Neither is
-- silently dropped, because a missing signature and an absent signature SOURCE must
-- never render the same way (`sig_source` records which).

local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local OUT = REPO .. '/lua/cartograph/spec/profile/luajit.mpack'
-- lua-language-server's own @meta definitions. A PATH, not a vendored copy: the
-- artifact records which one it read, and an upgrade re-distills.
local META = vim.fn.expand('~/.local/lib/lua-language-server/meta/template')

local SHOW = false
local argv = arg or {}
local ai = 1
while ai <= #argv do
    local a = argv[ai]
    if a == '--show' then SHOW = true
    elseif a == '--meta' then
        ai = ai + 1
        META = argv[ai] and vim.fn.expand(argv[ai]) or ''
    else print('luadistill: unknown argument ' .. a); os.exit(2) end
    ai = ai + 1
end

-- what nvim injects, and must not ride along under the name `luajit`
local DENY = { vim = true, _G = true, arg = true, unpack = false }
-- LuaJIT ships these beyond 5.1's set; they are part of the runtime, so they stay
local NAMESPACES = { string = true, table = true, math = true, os = true,
    io = true, coroutine = true, debug = true, package = true,
    bit = true, jit = true, ffi = true }

local free, namespaces, nsset, types, vocab = {}, {}, {}, {}, {}
local callable = {}    -- ns -> member -> true when the INTERPRETER holds a function
local n_members = 0

for k, v in pairs(_G) do
    if not DENY[k] then
        if type(v) == 'function' then
            free[k] = true
            vocab[k] = true
        elseif type(v) == 'table' and NAMESPACES[k] then
            namespaces[k] = true
            nsset[k] = true
            vocab[k] = true
            local members = {}
            local ok = pcall(function ()
                for mk, mv in pairs(v) do
                    if type(mk) == 'string' then
                        members[mk] = true
                        vocab[mk] = true
                        n_members = n_members + 1
                        -- THE MEMBER'S KIND, kept because a signature question is only
                        -- meaningful for a FUNCTION: math.pi and io.stdout are members
                        -- with a type and no signature, and counting them as a
                        -- signature GAP over-reports the gap by exactly those 18.
                        callable[k] = callable[k] or {}
                        callable[k][mk] = (type(mv) == 'function') or nil
                    end
                end
            end)
            if not ok then members = {} end -- a table that refuses iteration
            types[k] = { members = members }
        end
    end
end

local version = (type(jit) == 'table' and jit.version) or _VERSION or 'lua'

-- ── THE DECLARED HALF: signatures out of lua-language-server's @meta ──────────

package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
local annot = require 'cartograph.annot'
local TAG = '^%s*%-%-%-@([%a_]+)%s*(.*)$'   -- spec/lua.lua's annot_tag, verbatim

-- THE PREPROCESSOR IS EVALUATED, NOT PATTERN-MATCHED. The meta guards divergent
-- definitions of one function with `---#if VERSION >= 5.3 or JIT then … #else … #end`,
-- and 23 distinct conditions appear. They are Lua EXPRESSIONS, so the honest reader
-- runs them in a sandbox holding this interpreter's own VERSION/JIT — the same
-- semantics lua-ls uses — rather than guessing at their meaning. Guessing here would
-- silently pick the wrong arm of `string.dump`, and a wrong signature is worse than
-- none: the whole point of the tier discipline is that a claim can be checked.
local ENV = {
    VERSION = tonumber(_VERSION:match('([%d%.]+)')) or 5.1,
    JIT = type(jit) == 'table' or false,
}
local function cond_true(expr)
    local body = expr:gsub('%f[%w]DISABLE%s*%(%s*%)', 'true')
    local f = loadstring('return (' .. body .. ')')
    if not f then return nil end                    -- unparseable = UNKNOWN, not false
    setfenv(f, ENV)
    local ok, v = pcall(f)
    if not ok then return nil end
    return v and true or false
end

local sigs, canon, owners_of = {}, {}, {}
local dups, disabled_files = {}, {}
local n_sig, n_amb, n_unparsed, n_disabled, n_dup = 0, 0, 0, 0, 0
local meta_names = {}       -- owner -> member -> true, as DECLARED

-- A TYPE THAT SPANS LINES IS NOT A TYPE THIS READER HAS. `unpack`'s param is declared
-- as a table literal type opened on the `@param` line and closed several lines later:
--   ---@param list {
--   ---  [1]?: T1, …
--   ---}
-- annot.lua reads ONE line by design, so it hands back `{`. Emitting that would put a
-- string that is not a type into a signature — the fabrication this whole artifact is
-- supposed to avoid — so an unbalanced type is recorded as UNKNOWN with a flag, and
-- counted. Refusing beats truncating: `any` is honest, `{` is a lie with a shape.
local n_multiline = 0
local function usable_type(t)
    if not t then return nil end
    local depth = 0
    for ch in t:gmatch('[{}%(%)<>%[%]]') do
        if ch == '{' or ch == '(' or ch == '<' or ch == '[' then depth = depth + 1
        else depth = depth - 1 end
    end
    if depth ~= 0 then
        n_multiline = n_multiline + 1
        return nil, true
    end
    return t
end

--- the signature TEXT plus the machine-readable halves. `returns` is the point of
--- the whole exercise (a return-type source); `sig` is what hover shows.
local function sig_of(rows, decl_params)
    local ps, rs = {}, {}
    for _, r in ipairs(rows) do
        local ty, over = usable_type(r.type)
        if r.kind == 'param' and r.name then
            ps[#ps + 1] = { name = r.name, type = ty, opt = r.opt or nil,
                multiline = over }
        elseif r.kind == 'vararg' then
            ps[#ps + 1] = { name = '...', type = ty, multiline = over }
        elseif r.kind == 'return' then
            rs[#rs + 1] = { name = r.name, type = ty, opt = r.opt or nil,
                multiline = over }
        end
    end
    local pt = {}
    for _, p in ipairs(ps) do
        pt[#pt + 1] = ('%s%s: %s'):format(p.name, p.opt and '?' or '',
            p.type or (p.multiline and 'any (multi-line type, unread)') or 'any')
    end
    local rt = {}
    for _, r in ipairs(rs) do
        rt[#rt + 1] = (r.type or 'any') .. (r.opt and '?' or '')
    end
    return {
        sig = ('(%s)%s'):format(table.concat(pt, ', '),
            #rt > 0 and (' -> ' .. table.concat(rt, ', ')) or ''),
        params = ps, returns = rs,
        -- THE DECLARED ARITY, kept beside the annotated one so a consumer can see
        -- them disagree rather than trusting whichever it read first
        arity = decl_params and #decl_params or nil,
    }
end

local meta_files = {}
if META ~= '' and vim.fn.isdirectory(META) == 1 then
    meta_files = vim.fn.globpath(META, '*.lua', false, true)
    table.sort(meta_files)
end
for _, path in ipairs(meta_files) do
    local lines = vim.fn.readfile(path)
    local rel = vim.fn.fnamemodify(path, ':t')
    -- the #if stack: each entry is `true` (emitting) or `false` (skipping)
    local stack, live, disabled = {}, true, false
    local blk, blk_first = {}, nil
    for i, l in ipairs(lines) do
        local cond = l:match('^%-%-%-#if%s+(.-)%s+then')
        if cond then
            local v = cond_true(cond)
            if v == nil then n_unparsed = n_unparsed + 1; v = true end
            -- `#if <cond> then DISABLE() end` is a FILE-level gate, not a block
            if l:find('DISABLE') then
                if v then disabled = true end
            else
                stack[#stack + 1] = v
            end
        elseif l:match('^%-%-%-#else') then
            if #stack > 0 then stack[#stack] = not stack[#stack] end
        elseif l:match('^%-%-%-#end') then
            stack[#stack] = nil
        end
        live = true
        for _, s in ipairs(stack) do if not s then live = false end end

        if l:match('^%s*%-%-%-') then
            if not blk_first then blk_first = i - 1 end
            blk[#blk + 1] = l
        else
            local owner, sep, member, params = l:match(
                '^function%s+([%w_]+)([%.:])([%w_]+)%s*%(([^)]*)%)')
            local bare = (not owner) and l:match('^function%s+([%w_]+)%s*%(')
            if (owner or bare) and live and not disabled then
                local rows = annot.read_block(blk, blk_first or 0, TAG)
                local dp = {}
                for p in (params or ''):gmatch('[%w_%.]+') do dp[#dp + 1] = p end
                -- the KEY IS `Owner#member`, which is what lsp.lua's hover already
                -- looks up (`<runtime>::Owner#member` → path); a free function is
                -- keyed bare, its own owner
                local key = owner and (owner .. '#' .. member) or bare
                local s = sig_of(rows, dp)
                s.file, s.line = rel, (blk_first or (i - 1))
                if sigs[key] then
                    -- TWO SURVIVING DEFINITIONS of one name — measured: `unpack`, which
                    -- basic.lua declares twice as genuine OVERLOADS (list,i,j and list),
                    -- not as a preprocessor arm. So the first is kept and the sig CARRIES
                    -- the count: a consumer reading one signature must be able to see
                    -- that it is one of several, which is the difference between a
                    -- narrowed answer and a silently-lost one.
                    n_dup = n_dup + 1
                    dups[#dups + 1] = key .. ' (' .. rel .. ')'
                    sigs[key].overloads = (sigs[key].overloads or 1) + 1
                else
                    sigs[key] = s
                    n_sig = n_sig + 1
                end
                if owner then
                    meta_names[owner] = meta_names[owner] or {}
                    meta_names[owner][member] = true
                    owners_of[member] = owners_of[member] or {}
                    owners_of[member][owner] = true
                    if sep == ':' then s.method = true end
                end
            end
            if l:match('%S') then blk, blk_first = {}, nil end
        end
    end
    if disabled then
        n_disabled = n_disabled + 1
        disabled_files[#disabled_files + 1] = rel
    end
end

-- ── THE CROSS-CHECK, both directions, neither dropped ────────────────────────
-- Direction 1: a FUNCTION this interpreter holds that the meta does not declare = an
-- honest signature gap. Restricted to functions on purpose (see `callable`).
local gap, only_meta = {}, {}
for ns, t in pairs(types) do
    for m in pairs(t.members or {}) do
        if (callable[ns] or {})[m] and not sigs[ns .. '#' .. m] then
            gap[#gap + 1] = ns .. '.' .. m
        end
    end
end
-- Direction 2: a member the meta DECLARES that this interpreter does not have. These
-- are real (string.pack, math.type, table.pack, coroutine.close — Lua 5.3/5.4), and
-- THE CROSS-CHECK IS WHAT FOUND THEM: the meta has a SECOND version mechanism beside
-- the #if preprocessor — an `---@version >5.3` TAG — which annot.lua ignores by name,
-- correctly, since its tag set is a whitelist of things that carry a TYPE.
--
-- SO THEY ARE MOVED OUT OF `sigs`, NOT DROPPED AND NOT SERVED. Left in, hover would
-- show a 5.4 signature for a function LuaJIT does not have, i.e. fabricate a member of
-- the very runtime this profile measures. Existence is decided by INTROSPECTION (the
-- measurement) and shape by the meta (the claim) — this is the line between them.
-- A CLASS member (`file#close`) has no global to check against and stays in `sigs`
-- unchecked, which is stated rather than hidden.
local absent = {}
for ns, ms in pairs(meta_names) do
    local have = types[ns] and types[ns].members
    for m in pairs(ms) do
        if have and not have[m] then
            only_meta[#only_meta + 1] = ns .. '.' .. m
            local key = ns .. '#' .. m
            absent[key] = sigs[key]
            sigs[key] = nil
            n_sig = n_sig - 1
            -- and it leaves the owner index too, so canon below is computed over what
            -- SURVIVES. Order is load-bearing: `create` is declared by both coroutine
            -- and table, but table.create is 5.5 — filtering first makes the name
            -- unambiguous and earns a canon entry that filtering second would lose.
            if owners_of[m] then
                owners_of[m][ns] = nil
                if not next(owners_of[m]) then owners_of[m] = nil end
            end
        end
    end
end
table.sort(gap); table.sort(only_meta)

-- ── WHICH OWNERS MAY SUPPLY A BARE-NAME CANON ENTRY ─────────────────────────
-- MEASURED, and it is the difference between a useful hedge and a wrong answer. A
-- canon entry lets a call with an unverified receiver (`s:match`) be signed by the
-- only stdlib owner of that member name. Sampling the hedged population on `self`
-- found 176 sites signed from `buf#get`/`buf#put` (LuaJIT's require-only
-- `string.buffer`) and `profile#start` (`jit.profile`) — matched against this repo's
-- own `cv:get`, `store:get`, `timer:start`. Generic member names on an OPTIONAL
-- EXTENSION library are the worst possible source for a name-only rule.
--
-- THE RULE IS DERIVED, NOT A BLOCKLIST — the same shape as CART-0269, where `vim`
-- being in builtins.lua condemned every `vim.api.*` port and the fix was to derive
-- the sink rule from degree rather than name it. An owner is CANON-ELIGIBLE when:
--   1. the INTERPRETER presents it as a namespace (`nsset`) — string, table, math, io…
--   2. or an eligible member DECLARES it as a return type — `io.open` returns `file*`,
--      so `file` is reachable from a namespace the interpreter has, and `file#seek`
--      may sign `fd:seek()`.
-- `string.buffer` and `jit.profile` are require-only submodules: absent from `_G`, so
-- absent from nsset, and never named as a return of anything in it. They are excluded
-- BY THE MEASUREMENT rather than by being listed. Their signatures still SHIP — a
-- direct `buf.get` call would find them — they just cannot answer a name-only query.
local eligible = {}
for ns in pairs(nsset) do eligible[ns] = true end
for _ = 1, 2 do          -- one hop is all the roster needs; two proves it settled
    for key, s in pairs(sigs) do
        local owner = key:match('^([%w_]+)#')
        if owner and eligible[owner] then
            for _, r in ipairs(s.returns or {}) do
                -- lua-ls spells the io handle class `file*`; the declaration is
                -- `function file:close()`, so strip the marker to join them
                local ty = (r.type or ''):gsub('[%*%?]', ''):match('^([%w_]+)$')
                if ty and meta_names[ty] then eligible[ty] = true end
            end
        end
    end
end
local ineligible = {}
for owner in pairs(meta_names) do
    if not eligible[owner] then ineligible[#ineligible + 1] = owner end
end
table.sort(ineligible)

-- CANON: a bare member name → its `Owner#member`, and ONLY when the surviving roster
-- holds exactly one ELIGIBLE owner for it. `match`/`sub`/`format` are unique (string);
-- `close`/`write` are not (file, io). An ambiguous name gets NO canon entry and is
-- REPORTED — where one owner would be a guess, a SET is the honest answer, and
-- [[cartograph-anonymous-types]]' port classes are what could later decide it.
local ambiguous = {}
local n_ext_only = 0
for member, os_ in pairs(owners_of) do
    local list = {}
    for o in pairs(os_) do
        if eligible[o] then list[#list + 1] = o end
    end
    table.sort(list)
    if #list == 0 then
        -- every owner of this name is an extension library: NO name-only answer, and
        -- that is the finding rather than a shortfall
        n_ext_only = n_ext_only + 1
    elseif #list == 1 then
        canon[member] = list[1] .. '#' .. member
    else
        ambiguous[member] = list
        n_amb = n_amb + 1
    end
end

local prof = {
    schema = 1, runtime = 'luajit', lang = 'lua',
    version = version,
    stamp = ('introspected from %s; nvim additions (%s) excluded')
        :format(version, table.concat(vim.tbl_keys(DENY), ' ')),
    free = free, namespaces = namespaces, nsset = nsset, types = types,
    vocab = vocab,
    -- the DECLARED half (CART-0266). `sig_kind` is the tier and it is not
    -- decoration: a consumer must be able to say "by annotation".
    sigs = next(sigs) and sigs or nil,
    canon = next(canon) and canon or nil,
    sig_ambiguous = next(ambiguous) and ambiguous or nil,
    -- DECLARED BUT NOT PRESENT HERE — kept in the artifact rather than dropped on the
    -- floor, so "5.4 has this and we do not" stays answerable (it is the raw material
    -- of a version diff) without ever being served as this runtime's signature.
    sigs_absent = next(absent) and absent or nil,
    sig_root = (n_sig > 0) and META or nil,
    sig_kind = (n_sig > 0) and 'annotation' or nil,
    -- WHETHER A SOURCE WAS PRESENT AT ALL — so "this member has no signature" and
    -- "nothing was distilled" never render the same way
    sig_source = (n_sig > 0)
        and ('lua-language-server @meta: %d file(s) at %s'):format(#meta_files, META)
        or ('NONE — no @meta directory at ' .. (META == '' and '(unset)' or META)),
}

local nfree, nns, nvocab = 0, 0, 0
for _ in pairs(free) do nfree = nfree + 1 end
for _ in pairs(nsset) do nns = nns + 1 end
for _ in pairs(vocab) do nvocab = nvocab + 1 end

print(('luadistill — %s'):format(version))
print(('  free functions   %d'):format(nfree))
print(('  namespaces       %d  (%s)'):format(nns,
    table.concat((function ()
        local ks = vim.tbl_keys(nsset); table.sort(ks); return ks
    end)(), ' ')))
print(('  members          %d'):format(n_members))
print(('  vocab (total)    %d'):format(nvocab))
print('  ── signatures (CART-0266): a CLAIM beside a measurement ──')
print(('  sig source       %s'):format(prof.sig_source))
if n_multiline > 0 then
    print(('  multi-line types %d declared type(s) span lines and are recorded as'
        .. ' UNKNOWN — this reader is one line deep, and `{` is not a type'):format(
        n_multiline))
end
print(('  signatures       %d  (%d unique-name canon, %d AMBIGUOUS)'):format(
    n_sig, (function () local n = 0; for _ in pairs(canon) do n = n + 1 end; return n end)(),
    n_amb))
if n_unparsed > 0 or n_dup > 0 or n_disabled > 0 then
    print(('  preprocessor     %d file(s) DISABLEd for this runtime%s, %d unparseable'
        .. ' condition(s) (kept, not dropped)'):format(n_disabled,
        n_disabled > 0 and (' (' .. table.concat(disabled_files, ' ') .. ')') or '',
        n_unparsed))
    if n_dup > 0 then
        print(('  duplicate keys   %d — TWO surviving definitions of one name, first'
            .. ' kept: %s'):format(n_dup, table.concat(dups, ' ')))
    end
end
-- BOTH DIRECTIONS OF THE CROSS-CHECK, capped for reading but always counted
print(('  no signature     %d introspected member(s) the meta does not declare%s')
    :format(#gap, #gap > 0 and (': ' .. table.concat(gap, ' ', 1,
        math.min(12, #gap)) .. (#gap > 12 and ' …' or '')) or ''))
print(('  not in this rt   %d declared member(s) absent from %s%s'):format(
    #only_meta, version, #only_meta > 0 and (': ' .. table.concat(only_meta, ' ', 1,
        math.min(12, #only_meta)) .. (#only_meta > 12 and ' …' or '')) or ''))
if #ineligible > 0 then
    print(('  canon-INELIGIBLE %d owner(s) may not answer a bare-name query: %s'):format(
        #ineligible, table.concat(ineligible, ' ')))
    print(('    — require-only extension libraries: absent from _G, never named as a'
        .. ' return of anything in it. MEASURED necessity: 176 sites on `self` were'
        .. ' signed buf#get / buf#put / profile#start against this repo\'s own cv:get,'
        .. ' store:get, timer:start. %d member name(s) are extension-only and now'
        .. ' answer nothing.'):format(n_ext_only))
end
if n_amb > 0 then
    local names = {}
    for m, os_ in pairs(ambiguous) do
        names[#names + 1] = ('%s{%s}'):format(m, table.concat(os_, ','))
    end
    table.sort(names)
    print(('  ambiguous        %s'):format(table.concat(names, ' ', 1,
        math.min(10, #names)) .. (#names > 10 and ' …' or '')))
    print('    — a bare call to one of these names has a SET of owners, not an owner;'
        .. ' no canon entry is minted for it')
end

if SHOW then
    print('  --show: nothing written')
    return
end

local blob = vim.mpack.encode(prof)
local fd = assert(io.open(OUT, 'wb'))
fd:write(blob)
fd:close()
print(('  wrote %s (%d bytes)'):format(OUT:sub(#REPO + 2), #blob))
print('  re-run after a LuaJIT upgrade; the profile records which one it saw')
