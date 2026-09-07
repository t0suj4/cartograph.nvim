-- otelobserve — THE RUNTIME TIER FROM OUTSIDE THE PROCESS. Reads OpenTelemetry
-- spans emitted by a running polyglot stack and diffs them against the STATIC
-- gRPC contract graph, producing `confirm.lua`'s tiers over a system cartograph
-- is not inside (CART-0829).
--
--   nvim --headless -u NONE -l tools/otelobserve.lua <corpus|dir> --spans <file>
--
-- ★★★ WHY THIS IS THE SECOND LIVE TARGET CART-0056 ASKED FOR. The runtime tier
-- exists and is the ladder's SOUND TOP (`tier.lua` `confirmed`), and until now
-- it had exactly one producer: `tools/observe.lua`, a Lua call hook on the nvim
-- cartograph is running inside. That is self-shaped by construction — it can
-- only see a process it is in, in one language. This observes FIVE languages
-- across TWELVE processes over a wire protocol, and the mechanism it feeds is
-- unchanged: confirm.apply / confirm.diff already speak CONFIRM and RECOVER.
--
-- ★★ AND THE ADDRESS TRANSLATION WAS SOLVED BY ACCIDENT. `confirm.apply` keys on
-- `from\31to` NODE IDS. A span names a WIRE PATH
-- (`hipstershop.CartService/AddItem`), and CART-0824's proto adapter mints a
-- node carrying exactly that in `n.wire`. The contract front end built for a
-- static question is what makes a runtime event addressable.
--
-- ⚠⚠ SOUNDNESS, AND IT IS THE WHOLE DISCIPLINE (confirm.lua's own spec):
-- OBSERVED ⊆ STATIC. Observation CONFIRMS and RECOVERS; ABSENCE NEVER REFUTES.
-- A run exercises SOME paths. An rpc that no span named is NOT dead — it is
-- not-yet-called, and this report says so in those words rather than leaving an
-- empty cell to be read as a finding. See CART-0140, whose subject is that a
-- live fact DECAYS and that `confirmed` is the top rung for PRESENCE and the
-- bottom rung for ABSENCE.
--
-- ⚠ THE GRANULARITY MISMATCH IS REAL AND IS REPORTED, NOT PAPERED OVER. A span
-- gives a SERVICE-granular origin (`service.name`, a resource attribute — the
-- calling function is not in the span) and a METHOD-granular target. The static
-- graph is node-granular on both sides. So an observation names a service and
-- an rpc, and the edge this can honestly emit runs from the service's own
-- module node. Where the service cannot be mapped to exactly one module, the
-- observation is REPORTED and no edge is fabricated.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local proto = require 'cartograph.proto'
local xlang = require 'cartograph.xlang'
local confirm = require 'cartograph.confirm'

local target, spanfile, coarse
local i = 1
while arg and arg[i] do
    if arg[i] == '--spans' then spanfile = arg[i + 1]; i = i + 2
    elseif arg[i] == '--coarse' then coarse = true; i = i + 1
    elseif not target then target = arg[i]; i = i + 1
    else i = i + 1 end
end
if not (target and spanfile) then
    print('usage: otelobserve <corpus|dir> --spans <otlp-json-file> [--coarse]')
    os.exit(2)
end
local reg = dofile(repo .. '/tools/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end

-- ── READ THE SPANS. The collector's `file` exporter writes OTLP/JSON, one
-- envelope per line. Everything below is derived from the envelope; nothing is
-- assumed about which services exist.
local function attr(list, key)
    for _, a in ipairs(list or {}) do
        if a.key == key then
            local v = a.value or {}
            return v.stringValue or v.intValue or v.boolValue
        end
    end
end

-- ⚠ THE OTLP ENUM, AND I HAD IT BACKWARDS. SpanKind is
-- UNSPECIFIED=0, INTERNAL=1, SERVER=2, CLIENT=3, PRODUCER=4, CONSUMER=5 — so 2
-- is the SERVER side, not the client. The first live run printed
-- `ListProducts  server: recommendationservice | client: productcatalogservice`,
-- which is exactly inverted, and nothing but reading WHICH SERVICE PLAYED WHICH
-- ROLE would have caught it: both columns were populated, both counts were
-- right, and the totals were unaffected. A fixture written from the same wrong
-- belief agreed with it.
local KIND = { [2] = 'server', [3] = 'client',
    SPAN_KIND_SERVER = 'server', SPAN_KIND_CLIENT = 'client' }

local obs, nspans, nlines, bad = {}, 0, 0, 0
local fd = io.open(vim.fn.expand(spanfile), 'r')
if not fd then print('cannot read ' .. spanfile); os.exit(2) end
for line in fd:lines() do
    if line:match('%S') then
        nlines = nlines + 1
        local ok, env = pcall(vim.json.decode, line)
        if not ok or type(env) ~= 'table' then bad = bad + 1 else
            for _, rs in ipairs(env.resourceSpans or {}) do
                local svc = attr((rs.resource or {}).attributes, 'service.name') or '?'
                for _, ss in ipairs(rs.scopeSpans or {}) do
                    for _, sp in ipairs(ss.spans or {}) do
                        nspans = nspans + 1
                        -- otelgrpc names the span after the full method and ALSO
                        -- sets rpc.service/rpc.method. Prefer the attributes —
                        -- the span NAME is a display convention and has changed
                        -- across otelgrpc versions; the attributes are the
                        -- semantic convention.
                        local rsvc = attr(sp.attributes, 'rpc.service')
                        local rmeth = attr(sp.attributes, 'rpc.method')
                        local wire
                        if rsvc and rmeth then wire = '/' .. rsvc .. '/' .. rmeth
                        elseif sp.name and sp.name:find('/') then
                            wire = sp.name:sub(1, 1) == '/' and sp.name or ('/' .. sp.name)
                        end
                        if wire then
                            local k = KIND[sp.kind] or 'other'
                            obs[wire] = obs[wire] or { client = {}, server = {}, n = 0 }
                            obs[wire].n = obs[wire].n + 1
                            local side = obs[wire][k]
                            if side then side[svc] = (side[svc] or 0) + 1 end
                        end
                    end
                end
            end
        end
    end
end
fd:close()

print(('otelobserve %s'):format(root:gsub('.*/', '')))
print(('  spans: %d envelope line(s), %d span(s), %d undecodable')
    :format(nlines, nspans, bad))
-- ★ A PROBE THAT RETURNS ZERO POINTS AT ITS OWN DETECTOR FIRST. No spans is a
-- FAULT in the harness (nothing ran, the collector never received, the file is
-- the wrong one) and reads exactly like "the system made no calls".
if nspans == 0 then
    print('  ⚠ FAULT, not a finding: no spans. Nothing was observed, which is')
    print('    not the same as nothing having happened.')
    os.exit(2)
end

local data = ts.extract(root)
local ps = proto.attach(data)
print('  ' .. (proto.summary(ps) or 'no .proto files in this root'))
local wires = {}
for _, n in ipairs(data.nodes) do
    if n.pb == 'rpc' then
        wires[n.wire] = wires[n.wire] or {}
        table.insert(wires[n.wire], n.id)
    end
end
local nwire = 0
for _ in pairs(wires) do nwire = nwire + 1 end
if nwire == 0 then
    print('  ⚠ FAULT: the contract minted no rpc nodes, so nothing is addressable.')
    os.exit(2)
end
xlang.link(data)

-- ── ★★★ MAP A SPAN'S SERVICE TO CODE, AND THE MAPPING IS DECLARED, NOT GUESSED.
-- CART-0829 measured that a span's `service.name` exists in NEITHER the source
-- NOR the manifests, so the first live run mapped nothing and correctly refused.
-- `cartograph.k8s` (CART-0830) supplies it from the deployment layer: a
-- Deployment's `image:` joined through skaffold's declared build CONTEXT. That
-- join is an oracle — skaffold says `cartservice -> src/cartservice/src`, the one
-- service of twelve whose directory is not its image name, so a name match would
-- be right eleven times and silently wrong once.
-- ⚠ WITH NO MANIFESTS, THE FALLBACK IS THE FIRST PATH SEGMENT, which IS a name
-- match and is marked as such in the report. It is a convention, not a
-- declaration, and it must not be mistaken for the oracle above it.
local k8s = require 'cartograph.k8s'
local ks = k8s.attach(data)
if ks and ks.files > 0 then print('  ' .. (k8s.summary(ks) or '')) end
local mods_by_dir = {}
for _, n in ipairs(data.nodes) do
    if n.kind == 'module' and n.file and not n.pb and not n.k8 then
        local seg = n.file:match('^([^/]+)')
        if seg then
            mods_by_dir[seg] = mods_by_dir[seg] or {}
            table.insert(mods_by_dir[seg], n.id)
        end
        -- also index by the FULL declared directory, so `src/cartservice/src`
        -- resolves as well as `src`
        for d in n.file:gmatch('()/') do
            local pre = n.file:sub(1, d - 1)
            mods_by_dir[pre] = mods_by_dir[pre] or {}
            table.insert(mods_by_dir[pre], n.id)
        end
    end
end
local declared_ident, guessed_ident = {}, {}
local mods_by_svc = setmetatable({}, { __index = function (_, svc)
    local dir = k8s.dir_of(data, svc)
    if dir then
        -- the manifest root and the extraction root may differ (we fold `src/`
        -- while skaffold's context is `src/<svc>`), so try the declared path and
        -- then its tail
        local hit = mods_by_dir[dir] or mods_by_dir[dir:gsub('^src/', '')]
        if hit then declared_ident[svc] = dir; return hit end
    end
    local hit = mods_by_dir[svc]
    if hit then guessed_ident[svc] = true end
    return hit
end })

print('')
print('  wire path                                      static   observed')
local order = {}
for w in pairs(wires) do order[#order + 1] = w end
for w in pairs(obs) do if not wires[w] then order[#order + 1] = w end end
table.sort(order)
local confirmed_w, recovered_w, unobserved = 0, 0, 0
for _, w in ipairs(order) do
    local decl = wires[w] and #wires[w] or 0
    local o = obs[w]
    local parts = {}
    for _, side in ipairs({ 'server', 'client' }) do
        local names = {}
        for s, n in pairs(o and o[side] or {}) do names[#names + 1] = ('%s x%d'):format(s, n) end
        table.sort(names)
        if #names > 0 then parts[#parts + 1] = side .. ': ' .. table.concat(names, ', ') end
    end
    local state
    if decl > 0 and o then state = 'CONFIRM'; confirmed_w = confirmed_w + 1
    elseif o then state = 'RECOVER'; recovered_w = recovered_w + 1
    else state = 'not observed'; unobserved = unobserved + 1 end
    print(('  %-46s %4s %-9s %s'):format(w:sub(1, 46),
        decl > 0 and tostring(decl) or '—', state, table.concat(parts, ' | ')))
end
print(('  %d confirmed · %d recovered (observed, not in the contract) · %d not observed')
    :format(confirmed_w, recovered_w, unobserved))
print('  ⚠ `not observed` IS NOT `unused`. A run exercises some paths; absence')
print('    never refutes. These rpcs were not called during THIS workload.')

-- ── FEED confirm.apply, AND PREFER THE EDGE THE STATIC JOIN ALREADY MADE.
-- ★★ This is what separates a CONFIRMATION from a fabrication. An observation
-- says "service S exercised wire W". If the static graph already holds an edge
-- X -> rpc(W) where X lives in S's tree — the binding CART-0825 made from the
-- generated stub — then the observation CONFIRMS THAT EDGE, at the graph's own
-- node granularity, and the top rung is earned rather than asserted. Only when
-- no such edge exists does this fall back to the service's module nodes, and
-- that fallback is a RECOVER: an edge the static side did not have.
local static_in = {}   -- rpc node id -> { from-node-id, ... }, xlang edges only
local nodefile = {}
for _, n in ipairs(data.nodes) do nodefile[n.id] = n.file end
for _, e in ipairs(data.edges) do
    if e.xlang and e.to then
        static_in[e.to] = static_in[e.to] or {}
        table.insert(static_in[e.to], e.from)
    end
end
local observed_edges, skipped, via_static, via_module = {}, {}, 0, 0
for w, o in pairs(obs) do
    local tos = wires[w]
    if tos then
        for _, side in ipairs({ 'client', 'server' }) do
            for svc in pairs(o[side]) do
                local hit = false
                -- ⚠ THE PREFIX IS THE DECLARED DIRECTORY, NOT THE FIRST PATH
                -- SEGMENT. Comparing `f:match('^([^/]+)')` to the service name
                -- only holds when the extraction root IS the services' parent;
                -- run on the repo root instead and every path starts `src/`, so
                -- the static-edge preference matched nothing and every
                -- confirmation silently became a report-only fallback. The
                -- deployment layer already knows the directory — use it.
                local dd = k8s.dir_of(data, svc)
                if dd then declared_ident[svc] = dd end
                local pref = dd or svc
                for _, t in ipairs(tos) do
                    for _, from in ipairs(static_in[t] or {}) do
                        local f = nodefile[from] or from
                        if f:sub(1, #pref) == pref
                            or f:match('^([^/]+)') == svc then
                            observed_edges[from .. '\31' .. t] = true
                            hit = true; via_static = via_static + 1
                        end
                    end
                end
                if not hit then
                    -- ⚠⚠ NO STATIC EDGE FROM THIS SERVICE TO THIS RPC, AND THE
                    -- DEFAULT IS TO REPORT RATHER THAN MATERIALISE. The
                    -- observation says "service S exercised wire W" and the
                    -- graph has no node at service granularity, so the only
                    -- edge available is every module of S to every copy of W —
                    -- 6 files x 3 vendored copies = 18 edges from ONE span.
                    -- That is not a recovery, it is an N x M smear asserting
                    -- that each of those files relates to that rpc, which the
                    -- span does not say. An observation that cannot be
                    -- addressed at the graph's granularity is REPORTED; the
                    -- same refusal proto.lua makes for an import pointing out
                    -- of the root. `--coarse` opts in and the count is printed
                    -- either way, so the cost of the smear is never hidden.
                    local froms = mods_by_svc[svc]
                    if froms and #froms > 0 then
                        for _, f in ipairs(froms) do
                            for _, t in ipairs(tos) do
                                if coarse then observed_edges[f .. '\31' .. t] = true end
                                via_module = via_module + 1
                            end
                        end
                    else
                        skipped[svc] = true
                    end
                end
            end
        end
    end
end
local nobs = 0
for _ in pairs(observed_edges) do nobs = nobs + 1 end
local res = confirm.apply(data, observed_edges)
print('')
print(('  confirm.apply: %d observed edge key(s) -> %d CONFIRMED, %d RECOVERED')
    :format(nobs, res.confirmed, res.recovered))
print(('    %d key(s) took a STATIC edge the join already had — node-granular,')
    :format(via_static))
print('    which is the confirmation the tier exists for.')
print(('    %d further (service-module x rpc-copy) pair(s) were %s: no static edge')
    :format(via_module, coarse and 'MATERIALISED (--coarse)' or 'REPORTED ONLY'))
print('    from that service reaches that rpc, and a span names a SERVICE, not a')
print('    function. Materialising them smears one observation over every file of')
print('    the caller; `--coarse` opts in.')
local di, gi = {}, {}
for k, v in pairs(declared_ident) do di[#di + 1] = k .. '->' .. v end
for k in pairs(guessed_ident) do gi[#gi + 1] = k end
table.sort(di); table.sort(gi)
if #di > 0 then
    print(('  identity from the DEPLOYMENT (skaffold context, declared): %s')
        :format(table.concat(di, ' ')))
end
if #gi > 0 then
    print(('  ⚠ identity by PATH-SEGMENT NAME MATCH (a convention, no manifest'
        .. ' declared it): %s'):format(table.concat(gi, ' ')))
end
local sk = {}
for s in pairs(skipped) do sk[#sk + 1] = s end
table.sort(sk)
if #sk > 0 then
    print(('  ⚠ %d service(s) observed but NOT MAPPED to a module, so no edge was')
        :format(#sk))
    print('    fabricated for them: ' .. table.concat(sk, ' '))
    print('    (a span names a SERVICE; the graph is node-granular. Reported, not guessed.)')
end
print('')
print('  ⚠ AN OBSERVATION IS SERVICE-GRANULAR ON THE `from` SIDE: a span carries')
print('    `service.name` as a RESOURCE attribute and never names the calling')
print('    function. So only an observation that lands on an edge the static')
print('    graph ALREADY HAS is materialised — the rest are facts about a')
print('    service, and the graph has no node at that granularity. Either way')
print('    these edges are a session-live OVERLAY confirm.lua never folds or')
print('    caches, because a live fact decays (CART-0140).')
