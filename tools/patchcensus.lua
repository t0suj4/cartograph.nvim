-- MONKEY-PATCH CENSUS (CART-0618) — where does this code modify a table it did
-- not define, and is that an OVERRIDE or an EXTENSION?
--
--   nvim --headless -u NONE -l tools/patchcensus.lua <corpus|path> [--show <bucket>]
--     buckets: override · extension · unknown · hook
--
-- ★★ A MONKEY-PATCH IS NOT A SYNTACTIC SHAPE, and finding that out is the whole
-- reason this file is not fifteen lines. It is "you modified a table you did not
-- define", and BOTH halves of that vary per ecosystem:
--
--   ACQUISITION — how the table was obtained
--       a `require` binding      the import edge carries the bound name
--       a REGISTRY retrieval     LibStub("X") / :GetModule("Y") — c.registry
--                                already holds the node this resolves to
--       a global / an unknown    neither, and still not ours
--   MODIFICATION — how the change is spelled
--       an ASSIGNMENT            `mod.member = f` — a def node named `X.member`
--       a HOOK CALL              `hooksecurefunc(t, "m", f)` — DECLARED in the
--                                ecosystem spec, never hardcoded here
--
-- THE MEASUREMENT THAT FORCED THAT DESIGN, and it corrected me twice. The first
-- cut knew only the assignment form and only the `require` acquisition. On our own
-- tree it found 4 sites (3 override, 1 extension) and looked fine. On
-- ~/work/wow_addons it found ZERO — and zero was not absence:
--
--     require(         0 occurrences in 2.27M lines
--     hooksecurefunc   249 calls across 113 files
--     LibStub          4867 retrievals
--
-- The corpus holds 249 monkey-patches and the predicate could not see one of them,
-- because it was built on one ecosystem's module system and reported the honest
-- absence of its own vocabulary. A predicate that finds nothing is not evidence
-- that nothing is there — it is evidence about the predicate, and the only way to
-- tell the two apart is to go and count the idiom by hand.
--
-- ★ THE HOOK FORMS ARE DECLARED DATA (the convergence rule): a form is a call
-- name plus which argument carries the table and which names the member, and it
-- lives in spec/ecosystem/<name>.lua. Hardcoding `hooksecurefunc` here would have
-- been the wrong-shaped fix, and it is exactly what an unmeasured version of this
-- would have shipped.
--
-- ── THE TAXONOMY IS THE PRODUCT ──────────────────────────────────────────────
--   OVERRIDE   the target module DECLARES that member. You are replacing behaviour
--              other callers depend on, and resolution now has two candidates for
--              one name — which is CART-0616, i.e. this class is not hypothetical,
--              it has already produced five wrong edges on our own tree.
--   EXTENSION  the target does not declare it. You are adding to somebody else's
--              namespace: a different hazard, the silent collision on the day
--              upstream adds a member with that name.
--   UNKNOWN    the table was not resolved to a file, so neither question can be
--              asked. Reported as its own bucket, never folded into extension —
--              "the module lacks it" and "we could not look" are different facts.
--
-- ⚠ AN OVERRIDE IS NOT AUTOMATICALLY A DEFECT. A test that patches, uses and
-- RESTORES is a legitimate scoped override, and the restore is what makes it safe.
-- That save/patch/restore is an acquire/use/release — the shape `member-leak`
-- already lints — so the unrestored ones are the interesting subset. Detecting
-- the restore is NOT built here: this census sizes the population first, which is
-- the order the mock-detection idea (CART-0617) skipped and had to come back to.
--
-- WHAT THIS DOES NOT MEASURE, stated because a missing check is not a clean bill:
--   * the restore half, per above — so no site here is called a leak.
--   * a table reached through a chain (`a.b.c.member = f`); only a single-identifier
--     receiver is classified.
--   * ecosystems whose hook forms nobody has declared yet. The report prints which
--     ecosystem it read and how many forms it found, so a zero from an undeclared
--     ecosystem cannot be read as a zero from the corpus.
local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local eco = require 'cartograph.spec.ecosystem'

local target = arg[1]
if not target then
    print('usage: nvim --headless -u NONE -l tools/patchcensus.lua <corpus|path> [--show override|extension|unknown|hook]')
    os.exit(2)
end
local show
for i = 2, #(arg or {}) do if arg[i] == '--show' then show = arg[i + 1] end end

local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then
    print('not a directory: ' .. root)
    os.exit(2)
end

-- Every declared hook form, across every ecosystem that ships one. Keyed by call
-- name; a name may carry several forms (an arity-2 and an arity-3 spelling of
-- hooksecurefunc mean different things), so the value is a list.
local HOOKS, nforms, ecos = {}, 0, {}
for _, name in ipairs(eco.names()) do
    local spec = eco.load(name)
    for _, h in ipairs((spec or {}).hooks or {}) do
        HOOKS[h.call] = HOOKS[h.call] or {}
        table.insert(HOOKS[h.call], h)
        nforms = nforms + 1
        ecos[name] = true
    end
end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)

local byid, declares, defined_here = {}, {}, {}
for _, n in ipairs(data.nodes) do
    byid[n.id] = n
    if n.file and n.name and (n.kind == 'function' or n.kind == 'method') then
        -- a file's declared members, INCLUDING re-export alt keys (CART-0612):
        -- `M.dir = dir_of` names a member the file exports under a key that is not
        -- the def's own name, and reading n.name alone misclassified an override
        -- as an extension the first time this was run.
        local function note(nm)
            local _, mem = nm:match('^([%w_]+)[%.:]([%w_]+)$')
            if mem then
                declares[n.file] = declares[n.file] or {}
                declares[n.file][mem] = true
            end
        end
        note(n.name)
        for _, k in ipairs(n.altkeys or {}) do note(k) end
    end
    -- a table this file DEFINES is not somebody else's to patch
    if n.file and n.kind == 'var' and n.name then
        defined_here[n.file .. '\0' .. n.name] = true
    end
end

-- file -> bind -> imported file
local binds = {}
for _, e in ipairs(data.edges or {}) do
    if e.kind == 'import' and e.bind then
        binds[e.from] = binds[e.from] or {}
        binds[e.from][e.bind] = e.to
    end
end

--- Where did `recv` in `file` come from? Returns (kind, target-file-or-nil).
--- ACQUISITION-AGNOSTIC BY CONSTRUCTION: the caller asks one question and every
--- module system this graph understands gets a chance to answer it.
local function acquire(file, recv)
    if not recv then return 'none' end
    local imp = binds[file] and binds[file][recv]
    if imp then return 'require', imp end
    if defined_here[file .. '\0' .. recv] then return 'own' end
    return 'foreign'
end

local B = { override = {}, extension = {}, unknown = {}, hook = {} }
local own = 0

--- Classify one patch site against the table it targets.
local function classify(bucketrow, tfile)
    if not tfile then return 'unknown' end
    local d = declares[tfile]
    if d == nil then return 'unknown' end
    return d[bucketrow.member] and 'override' or 'extension'
end

-- ── form 1: the ASSIGNMENT (`mod.member = f`) ───────────────────────────────
for _, n in ipairs(data.nodes) do
    if n.file and n.name and (n.kind == 'function' or n.kind == 'method') then
        local recv, mem = n.name:match('^([%w_]+)[%.:]([%w_]+)$')
        if recv then
            local how, tfile = acquire(n.file, recv)
            if how == 'require' then
                local row = { file = n.file, name = n.name, member = mem,
                    target = tfile, how = how, form = 'assign' }
                local k = classify(row, tfile)
                table.insert(B[k], row)
            elseif how == 'own' then
                own = own + 1
            end
        end
    end
end

-- ── form 2: the DECLARED HOOK CALL ──────────────────────────────────────────
for _, call in ipairs(data.calls) do
    local forms = call.callee and HOOKS[call.callee]
    if forms and not call.method then
        local argv = call.argv or {}
        for _, h in ipairs(forms) do
            if not h.arity or #argv == h.arity then
                local ma = h.member_arg and argv[h.member_arg]
                local ta = h.table_arg and argv[h.table_arg]
                local member = ma and ma.k == 'lit' and ma.v or nil
                local recv = ta and (ta.name or (ta.k == 'expr' and nil)) or nil
                local how, tfile = acquire(call.file, recv)
                local row = { file = call.file, line = call.line, member = member,
                    recv = recv, target = tfile, how = how, form = h.kind or 'hook',
                    name = call.full }
                table.insert(B.hook, row)
                if how == 'require' and member then
                    local k = classify(row, tfile)
                    table.insert(B[k], row)
                end
                break
            end
        end
    end
end

local total = #B.override + #B.extension + #B.unknown
print(('MONKEY-PATCH CENSUS — %s'):format(root))
print('')
print('A monkey-patch is "you modified a table you did not define". Two forms:')
print('an ASSIGNMENT onto a required module, and a DECLARED HOOK CALL.')
print(('hook forms read from spec/ecosystem: %d form(s) from %s')
    :format(nforms, next(ecos) and table.concat(vim.tbl_keys(ecos), ' ') or '(none declared)'))
print('  a zero below from an ecosystem that declares NO form is a fact about the')
print('  declaration, not about the corpus — that mistake is why this line prints.')
print('')
print(('CLASSIFIED (target file known): %d'):format(total))
print(('  OVERRIDE   %5d   the target DECLARES this member — you are replacing it'):format(#B.override))
print(('  extension  %5d   it does not — you are adding to its namespace'):format(#B.extension))
print(('  unknown    %5d   the table did not resolve to a file; neither question asked'):format(#B.unknown))
print('')
print(('HOOK CALL SITES (all acquisitions): %d'):format(#B.hook))
local byhow = {}
for _, r in ipairs(B.hook) do byhow[r.how] = (byhow[r.how] or 0) + 1 end
local HOWNOTE = {
    own = '(the file defines this table — NOT a patch)',
    require = '(a required module — classifiable above)',
    foreign = '(a named table this file does not define — a patch, target unresolved)',
    -- ⚠ THE HONEST HOLE, and it is the majority on wow: argv classifies a BARE
    -- GLOBAL receiver as kind `expr` with no name, so `hooksecurefunc(GameTooltip,
    -- "SetUnit", f)` is a patch we can SEE and cannot NAME. Globals are precisely
    -- WoW's module system, so this is not a tail case there. Reading it needs the
    -- expression IR rather than argv, which is the next step and is not built.
    none = '(receiver unreadable from argv — a bare global reads as `expr`, unnamed)',
}
for _, k in ipairs({ 'require', 'own', 'foreign', 'none' }) do
    if byhow[k] then
        print(('    receiver %-8s %5d   %s'):format(k, byhow[k], HOWNOTE[k] or ''))
    end
end
print(('  assignments onto a table the file DEFINES (not patches): %d'):format(own))

if show and B[show] then
    print('')
    print(('── %s (%d) ──'):format(show, #B[show]))
    for i, r in ipairs(B[show]) do
        if i > 50 then print(('  … %d more'):format(#B[show] - 50)); break end
        print(('  %-46s %-22s %-9s -> %s'):format(
            r.file .. (r.line and (':' .. r.line) or ''),
            tostring(r.name), r.form, tostring(r.target or r.recv or '?')))
    end
elseif show then
    print(('no such bucket: %s'):format(show))
    os.exit(2)
end
