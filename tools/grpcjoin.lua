-- grpcjoin — WHO IMPLEMENTS AND WHO CALLS EACH RPC, across languages, joined on
-- the gRPC WIRE PATH. The cross-service question a per-language server cannot
-- represent, asked of one polyglot root (CART-0825).
--
--   nvim --headless -u NONE -l tools/grpcjoin.lua [<corpus-name>|<dir>]
--
-- ★★★ THE KEY IS THE WIRE PATH, NOT THE METHOD NAME. `AddItem` is ambiguous
-- across nine services; `/hipstershop.CartService/AddItem` is what the runtime
-- itself dispatches on, and BOTH generated stubs write it as a literal. This is
-- the XMPP lesson repeating exactly: joining ejabberd to converse.js by macro
-- NAME found 8 pairs, joining by URI found 30 — a DIFFERENT set. A boundary's
-- identity is the string the boundary uses, never the name a language gives it.
--
-- ⚠ ADAPTERS DO NOT RUN HEADLESSLY (CART-0679). `ts.extract` runs no post-pass,
-- so this calls `proto.attach` itself and then ASSERTS that rpc nodes exist
-- before joining — because a join over a graph with no contract in it reports
-- zero bindings, and zero reads as a finding rather than as a fault (the
-- store-headless rule: point a probe that returns zero at its own detector).

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local proto = require 'cartograph.proto'
local xlang = require 'cartograph.xlang'
local tiers = require 'cartograph.tier'

local arg1 = arg and arg[1]
local root = repo .. '/lua'
if arg1 then
    local ok, corpora = pcall(dofile, repo .. '/tools/corpora.lua')
    if ok and corpora[arg1] and corpora[arg1].root then root = corpora[arg1].root
    else root = vim.fn.expand(arg1) end
end
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end

local data = ts.extract(root)
local ps = proto.attach(data)

print(('grpcjoin %s'):format(root:gsub('.*/', '')))
print('  ' .. (proto.summary(ps) or 'no .proto files in this root'))
if ps.files == 0 then
    print('  nothing to join: the contract is what this joins TO, and there is none.')
    os.exit(0)
end

-- the export side has to be in the graph before the linker runs, and a joiner
-- that skipped this would report 0 bindings over an empty contract
local nrpc = 0
for _, n in ipairs(data.nodes) do if n.pb == 'rpc' then nrpc = nrpc + 1 end end
if nrpc == 0 then
    print('  ⚠ FAULT, not a finding: the contract parsed but minted no rpc nodes.')
    os.exit(2)
end

local before = #data.edges
local st = xlang.link(data)
print(('  xlang: %d export(s) declared · %d link(s) · %d edge(s) added')
    :format(st.exports or 0, st.links or 0, #data.edges - before))

local byid = {}
for _, n in ipairs(data.nodes) do byid[n.id] = n end

-- ── the four columns. DECLARED-AT is per SITE (a vendored copy is a real second
-- declaration); BOUND-BY is per binding SITE, deduplicated by file so three
-- copies of one contract do not read as three callers.
local wires, order = {}, {}
for _, n in ipairs(data.nodes) do
    if n.pb == 'rpc' then
        local w = wires[n.wire]
        if not w then w = { decl = 0, files = {}, nfiles = 0, langs = {} }
            wires[n.wire] = w; order[#order + 1] = n.wire end
        w.decl = w.decl + 1
    end
end
table.sort(order)

local function lang_of(file)
    local ext = file and file:match('%.([%w]+)$')
    if not ext then return nil end
    for lang, sp in pairs(ts.spec or {}) do
        for _, e in ipairs(sp.exts or {}) do
            if e:lower() == ext:lower() then return lang end
        end
    end
    return nil
end

for _, e in ipairs(data.edges) do
    local t = byid[e.to]
    if e.xlang and t and t.pb == 'rpc' then
        local w = wires[t.wire]
        local f = byid[e.from]
        local file = (f and f.file) or e.from
        if w and not w.files[file] then
            w.files[file] = true; w.nfiles = w.nfiles + 1
            local l = lang_of(file) or '?'
            w.langs[l] = (w.langs[l] or 0) + 1
        end
    end
end

print('')
print('  wire path                                      declared  bound by')
local bound, unbound = 0, {}
for _, wp in ipairs(order) do
    local w = wires[wp]
    if w.nfiles > 0 then bound = bound + 1 else unbound[#unbound + 1] = wp end
    local ls = {}
    for l, n in pairs(w.langs) do ls[#ls + 1] = ('%s x%d'):format(l, n) end
    table.sort(ls)
    print(('  %-46s %8d  %s'):format(wp:sub(1, 46), w.decl,
        w.nfiles > 0 and table.concat(ls, ' · ') or '— nothing names it'))
end
print(('  %d of %d wire path(s) bound'):format(bound, #order))

-- ── ★★ THE UNBOUND COLUMN, AND ITS REASONS RENDER IDENTICALLY AS ABSENCE.
-- "Nobody calls this rpc" and "we cannot read the code that does" are opposite
-- statements and the same empty cell, which is the absence-rendered-as-silence
-- class this repo keeps rediscovering. So the reasons are MEASURED here, per
-- language, rather than left to the reader.
--
-- ★★★ AND EACH ONE NOW CARRIES ITS KIND FROM `tier.ABSENCE` (CART-0831). This
-- tool is why that table exists: it had FIVE warrants written as five
-- paragraphs of prose, no shared vocabulary with otelobserve's window and no
-- way for a reader to ask "which kind of absence is this" of either. Naming
-- the kind is not a relabelling — `is_absence` is asserted below, so a typo
-- fails loudly the way agent.lua's envelope check does, and the five reasons
-- became the taxonomy's own falsifier: FOUR fit, and the java one did not fit
-- anything, which is where `unbuilt` came from.
--
-- ⚠ AND ONE WORD HAD TO GO. The no-parser row below used to read "a language
-- with no spec is dark" — but on the OBSERVATION axis `dark` is a declared
-- warrant meaning a probe was ATTEMPTED AND REFUSED. One word, two axes, which
-- is precisely the collision tier.lua's header warns about for `torn`. The
-- reading-axis name for it is `frontier`. tests/tier_spec.lua reads the table
-- below and fails if a WARRANT word reappears in it, so this cannot silently
-- come back.
local files_by_lang, unread = {}, {}
do
    local seen = {}
    local function walk(rel)
        for name, t in vim.fs.dir(rel == '' and root or (root .. '/' .. rel)) do
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'directory' then
                    if not (ts.EXCLUDE_DIRS or {})[name:lower()] then walk(r) end
                else
                    local l = lang_of(r)
                    if l then files_by_lang[l] = (files_by_lang[l] or 0) + 1
                    elseif r:match('%.%w+$') and not seen[r:match('%.(%w+)$')] then
                        local ext = r:match('%.(%w+)$')
                        seen[ext] = true
                        unread[ext] = true
                    end
                end
            end
        end
    end
    walk('')
end
local bind_langs = {}
for _, w in pairs(wires) do for l in pairs(w.langs) do bind_langs[l] = true end end
print('')
print('  LANGUAGES PRESENT vs LANGUAGES THAT PRODUCED A BINDING')
local ls = {}
for l in pairs(files_by_lang) do ls[#ls + 1] = l end
table.sort(ls)
for _, l in ipairs(ls) do
    print(('    %-12s %4d file(s)   %s'):format(l, files_by_lang[l],
        bind_langs[l] and 'binds' or 'NO BINDING — see below'))
end
local ue = {}
for e in pairs(unread) do ue[#ue + 1] = e end
table.sort(ue)
if #ue > 0 then
    print(('    unread extensions in this tree: %s'):format(table.concat(ue, ' ')))
end

-- THE FIVE WARRANTS, each with the `tier.ABSENCE` kind it carries. ⚠ THE KIND
-- IS THE CLAIM'S SCOPE, so read `licenses` before acting on any of them: only
-- `absent` licenses acting at all, and the runtime-loaded row below is `absent`
-- ONLY ABOUT THE KEY — the reference exists, at another granularity.
local WARRANTS = {
    { kind = 'unavailable', why = {
        'the wire path must reach the graph as a CALL-ARGUMENT LITERAL.',
        'grpc-python passes it directly (`channel.unary_unary(\'/pkg.Svc/M\', …)`)',
        'and argv reads it. grpc-go binds it to a `const` and passes the',
        'IDENTIFIER (`Invoke(ctx, Svc_M_FullMethodName, …)`), which argv reports',
        'as {k=\'local\', name=\'Svc_M_FullMethodName\'} — the name, not the value,',
        'because a Go const literal never enters the graph. That is CART-0826,',
        'and the identifier is a GENERATOR CONVENTION, a lower rung than this',
        'exact key, so it is not silently mixed in.',
        '→ `unavailable`: the file was read, the call was extracted, the DATA',
        '  CLASS (a const\'s literal value) was not.' } },
    { kind = 'unbuilt', why = {
        'a language whose stubs are GENERATED AT BUILD TIME contributes no file',
        'to read at all (java here: no *Grpc.java in the tree).',
        '→ `unbuilt`, AND THIS IS THE ROW THAT MINTED THAT KIND (CART-0831).',
        '  The reading was COMPLETE over the tree, so the taxonomy said `absent`',
        '  — which licenses ACTING, and acting is exactly wrong: protoc writes',
        '  the file at build time. Not `frontier` either; the region was not',
        '  skipped, it does not exist yet. A reading complete over the artifacts',
        '  read is not complete over the system when something PRODUCES more.' } },
    { kind = 'frontier', why = {
        'a language with no spec cannot be read at all (`unread extensions`',
        'above).',
        '→ `frontier`, the no-parser case — see the note above on the word this',
        '  row used to use instead.' } },
    { kind = 'frontier', why = {
        'THE STUB MAY BE AN INSTALLED DEPENDENCY, OUTSIDE THE ROOT. That is why',
        'Health/Check is unbound on microservices-demo and it is NOT',
        'unreferenced: recommendation_server.py:31 does `from grpc_health.v1',
        'import health_pb2_grpc` and implements the servicer, but the file',
        'carrying the literal ships in a pip package.',
        '→ `frontier`, outside-the-root. An honest frontier.' } },
    { kind = 'absent', why = {
        'THE CONTRACT MAY BE LOADED AT RUNTIME, so no wire path is ever',
        'written. Node does exactly this — paymentservice/server.js:71',
        '`protoLoader.loadSync(path.join(protoRoot, \'demo.proto\'))` — and names',
        'the .proto FILE instead.',
        '→ `absent` ABOUT THE KEY ONLY: no call-argument literal names this wire',
        '  path anywhere, and that reading IS complete. It is NOT absent as a',
        '  reference — the join exists at SERVICE rather than METHOD',
        '  granularity, which is CART-0827 rather than a gap here.' } },
}

print('')
print('  ⚠ WHY A PRESENT LANGUAGE MAY STILL BIND NOTHING — measured, not assumed.')
print('    Each reason carries its tier.ABSENCE kind and that kind\'s LICENSE:')
for _, w in ipairs(WARRANTS) do
    -- the mirror of agent.lua's envelope check: a kind this table invents but
    -- the taxonomy does not declare is a FAULT in this tool, not a finding
    if not tiers.is_absence(w.kind) then
        print(('  ⚠ FAULT: %q is not a declared tier.ABSENCE kind'):format(w.kind))
        os.exit(2)
    end
    print(('    · [%s, licenses %s]'):format(w.kind, tiers.licenses(w.kind)))
    for _, line in ipairs(w.why) do print('      ' .. line) end
end
if #unbound > 0 then
    print('')
    print(('  UNBOUND WIRE PATHS (%d) — open the named instance before believing'):format(#unbound))
    print('  any of them is genuinely unreferenced. On microservices-demo the one')
    print('  unbound path is Health/Check, and opening it says "implemented, via a')
    print('  pip package we do not fold" — the opposite of unreferenced:')
    for _, wp in ipairs(unbound) do print('    ' .. wp) end
end
