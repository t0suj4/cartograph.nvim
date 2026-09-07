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

-- ── ★★ THE UNBOUND COLUMN, AND ITS THREE REASONS RENDER IDENTICALLY AS ABSENCE.
-- "Nobody calls this rpc" and "we cannot read the code that does" are opposite
-- statements and the same empty cell, which is the absence-rendered-as-silence
-- class this repo keeps rediscovering. So the reasons are MEASURED here, per
-- language, rather than left to the reader.
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

print('')
print('  ⚠ WHY A PRESENT LANGUAGE MAY STILL BIND NOTHING — measured, not assumed:')
print('    · the wire path must reach the graph as a CALL-ARGUMENT LITERAL.')
print('      grpc-python passes it directly (`channel.unary_unary(\'/pkg.Svc/M\'')
print('      , …)`) and argv reads it. grpc-go binds it to a `const` and passes')
print('      the IDENTIFIER (`Invoke(ctx, Svc_M_FullMethodName, …)`), which argv')
print('      reports as {k=\'local\', name=\'Svc_M_FullMethodName\'} — the name,')
print('      not the value, because a Go const literal never enters the graph.')
print('      That is CART-0826, and the identifier is a GENERATOR CONVENTION, a')
print('      lower rung than this exact key, so it is not silently mixed in.')
print('    · a language whose stubs are GENERATED AT BUILD TIME contributes no')
print('      file to read at all (java here: no *Grpc.java in the tree).')
print('    · a language with no spec is dark (`unread extensions` above).')
print('    · THE STUB MAY BE AN INSTALLED DEPENDENCY, OUTSIDE THE ROOT. That is')
print('      why Health/Check is unbound on microservices-demo and it is NOT')
print('      unreferenced: recommendation_server.py:31 does `from grpc_health.v1')
print('      import health_pb2_grpc` and implements the servicer, but the file')
print('      carrying the literal ships in a pip package. An honest frontier.')
print('    · THE CONTRACT MAY BE LOADED AT RUNTIME, so no wire path is ever')
print('      written. Node does exactly this — paymentservice/server.js:71')
print('      `protoLoader.loadSync(path.join(protoRoot, \'demo.proto\'))` — and')
print('      names the .proto FILE instead. That IS joinable, at SERVICE rather')
print('      than METHOD granularity, and is CART-0827 rather than a gap here.')
if #unbound > 0 then
    print('')
    print(('  UNBOUND WIRE PATHS (%d) — open the named instance before believing'):format(#unbound))
    print('  any of them is genuinely unreferenced. On microservices-demo the one')
    print('  unbound path is Health/Check, and opening it says "implemented, via a')
    print('  pip package we do not fold" — the opposite of unreferenced:')
    for _, wp in ipairs(unbound) do print('    ' .. wp) end
end
