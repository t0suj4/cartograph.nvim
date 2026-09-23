-- The Kubernetes manifest adapter: a deployment manifest is a DECLARED layer
-- beside the source and the contract, and it carries two things nothing in
-- cartograph reads today — the IDENTITY that maps a running service back to its
-- code, and the DECLARED service topology. Session post-pass, same family as
-- proto.lua / django.lua / symfony.lua. CART-0830.
--
-- ★★★ THIS IS THE PRE-`instance`-KIND CUT, AND IT SAYS SO. The user-authored
-- design at `cartograph-design/runtime-topology/03-instances-and-identity.md`
-- proposes FOUR node kinds for this domain — `instance` (the thing that
-- restarts), `workload` (the stable declared thing), `listener` (a bound
-- socket), `principal` (an authenticated identity) — and none of them exists in
-- `validate.NODE_KINDS`. Adding one is a SCHEMA change and belongs to CART-0140,
-- which owns that design. So this mints no new kind: the manifest FILE becomes a
-- `module` node, exactly as proto.lua does for a .proto, and the parts that need
-- no node at all — the identity map — ride on `data.k8s`.
-- ⚠ A `workload` node is the right long-term home for a Deployment. When
-- CART-0140 lands it, the identity map here is its input, not its competitor.
--
-- ★★ AND THE DECLARED TOPOLOGY IS A `use` EDGE, NOT AN `import`, ON MEASURED
-- GROUNDS. The k8s design calls these SOFT edges — "everything that binds
-- without owning" — and `import` is read at eight-plus sites including
-- store.lua:99, whose `imports_out` feeds portability's stage-map reachability
-- walk and preflight's spec cone. A yaml manifest declaring a dependency on
-- another service must not enter those walks. `use` is read at three sites and
-- carries the weaker "X refers to Y" meaning this needs.
--
-- ⚠ SCOPE: `kubernetes-manifests/*.yaml`-shaped plain manifests only. helm-chart/
-- and kustomize/ hold TEMPLATED yaml (`{{ .Values.x }}`) that does not parse to
-- values, and a reader that silently produced half a graph from them would be
-- the exact defect this file's refusal counter exists to prevent. A document
-- with no `kind:` is refused and COUNTED.

local M = {}

-- ★ THE IMAGE -> SOURCE MAPPING IS AN ORACLE, NOT A NAME MATCH. skaffold.yaml
-- declares `- image: cartservice / context: src/cartservice/src` — the one
-- service of twelve whose directory is NOT its image name. Matching on the name
-- would be right eleven times and wrong once, which is the worst kind of wrong:
-- it looks like it works. When no skaffold file is present the mapping is simply
-- absent, and `dir` stays nil rather than being guessed.
local function skaffold_map(root)
    local out = {}
    for _, name in ipairs({ 'skaffold.yaml', 'skaffold.yml' }) do
        local fd = io.open(root .. '/' .. name, 'r')
        if fd then
            local src = fd:read('a'); fd:close()
            local image
            for line in src:gmatch('[^\n]+') do
                local im = line:match('^%s*%-?%s*image:%s*([%w%._%-/]+)%s*$')
                local ctx = line:match('^%s*context:%s*([%w%._%-/]+)%s*$')
                if im then image = im:match('([^/]+)$') end
                if ctx and image then out[image] = ctx:gsub('/+$', ''); image = nil end
            end
            break
        end
    end
    return out
end

-- ── the yaml reader. Same parser ansible.lua uses; absent parser = absent
-- feature, reported rather than silently empty.
local function parse_docs(src)
    local ok, root = pcall(function ()
        return vim.treesitter.get_string_parser(src, 'yaml'):parse()[1]:root()
    end)
    if not ok or not root then return nil, 'yaml parse failed' end
    return root
end

--- Read one manifest's text into a list of documents:
---   { kind, name, app, image, ports = {n}, env = { NAME = value }, sa }
--- ⚠ TEXTUAL, DELIBERATELY, AND BOUNDED TO WHAT A MANIFEST SPELLS FLATLY. The
--- yaml tree is available and is used to REFUSE (a document that does not parse
--- is counted), but the fields wanted here are scalar leaves under known keys,
--- and walking the tree for them buys nothing a keyed line read does not give.
--- What it must not do is guess: a value carrying `{{` is a TEMPLATE and the
--- document is refused whole.
function M.read(src)
    local docs, refused, why = {}, 0, {}
    local ok = parse_docs(src)
    if not ok then return docs, 1, { 'yaml parse failed' } end
    for chunk in (src .. '\n---\n'):gmatch('(.-)\n%-%-%-%s*\n') do
        if chunk:match('%S') then
            local d = { ports = {}, env = {} }
            if chunk:find('{{', 1, true) then
                -- a helm/kustomize template: the values are not here
                refused = refused + 1
                if #why < 6 then why[#why + 1] = 'templated ({{ }})' end
            else
                d.kind = chunk:match('\nkind:%s*([%w]+)') or chunk:match('^kind:%s*([%w]+)')
                -- metadata.name is the FIRST `name:` at two-space indent
                d.name = chunk:match('\nmetadata:\n%s+name:%s*([%w%._%-]+)')
                d.app = chunk:match('\n%s+app:%s*([%w%._%-]+)')
                d.image = chunk:match('\n%s+image:%s*([%w%._%-/:]+)')
                d.sa = chunk:match('\n%s+serviceAccountName:%s*([%w%._%-]+)')
                for p in chunk:gmatch('\n%s+containerPort:%s*(%d+)') do
                    d.ports[#d.ports + 1] = tonumber(p)
                end
                for p in chunk:gmatch('\n%s+%- port:%s*(%d+)') do
                    d.ports[#d.ports + 1] = tonumber(p)
                end
                -- env is a LIST of {name, value} pairs, so the two lines pair up
                local pend
                for line in chunk:gmatch('[^\n]+') do
                    local n = line:match('^%s*%-%s*name:%s*([%w_]+)%s*$')
                    local v = line:match('^%s*value:%s*"?([^"]*)"?%s*$')
                    if n then pend = n
                    elseif v and pend then d.env[pend] = v; pend = nil end
                end
                if d.kind then docs[#docs + 1] = d
                else
                    refused = refused + 1
                    if #why < 6 then why[#why + 1] = 'no kind:' end
                end
            end
        end
    end
    return docs, refused, why
end

-- ── ENUMERATION: reuse the WALK's exclusion set (see proto.lua). This is the
-- fifth adapter that must find files no spec claims, and the fourth to be
-- written after ansible hardcoded its own list; sharing the set is the half
-- that drifts. Unifying the walks is CART-0817's.
function M.find(root, tp)
    tp = tp or require 'cartograph.transport'
    local ts = require 'cartograph.providers.treesitter'
    local ex = ts.EXCLUDE_DIRS or {}
    local out = {}
    local function rec(rel)
        for name, t in tp.dir(rel == '' and root or (root .. '/' .. rel)) do
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'directory' then
                    -- ⚠ helm-chart/ and kustomize/ hold TEMPLATED yaml. They are
                    -- not excluded here (the reader refuses a templated document
                    -- and counts it), so the refusal is VISIBLE rather than a
                    -- silent directory skip — CART-0817's own complaint.
                    if not ex[name:lower()] then rec(r) end
                elseif name:match('%.ya?ml$') then
                    out[#out + 1] = r
                end
            end
        end
    end
    rec('')
    table.sort(out) -- an artifact field: order is output (CART-0790)
    return out
end

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

--- Mint the declared deployment layer into `data`. Idempotent under refresh.
--- Sets `data.k8s = { services = { name -> {file, image, dir, ports, addrs} },
--- edges, docs, files, refused, refusals }` and returns it.
function M.attach(data, opts)
    local stats = { files = 0, docs = 0, services = 0, edges = 0, refused = 0,
        refusals = {}, services_map = {}, unmapped = {}, variants = {},
        dangling = {} }
    if not data or not data.root then data.k8s = nil; return stats end

    local ids, nodes = {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if n.k8 then ids[n.id] = true else nodes[#nodes + 1] = n end
    end
    if next(ids) then
        local edges = {}
        for _, e in ipairs(data.edges or {}) do
            if not (e.k8 or ids[e.from] or ids[e.to]) then edges[#edges + 1] = e end
        end
        data.nodes, data.edges = nodes, edges
    end

    local files = (opts and opts.files) or M.find(data.root, opts and opts.transport)
    if #files == 0 then data.k8s = nil; return stats end
    data.nodes = data.nodes or {}
    data.edges = data.edges or {}
    local img2dir = skaffold_map(data.root)

    -- ★★★ PASS 1, AND THE ROSTER IS KEYED BY DEPLOYMENT VARIANT. A repo routinely
    -- declares the SAME system several times over — microservices-demo carries
    -- `kubernetes-manifests/`, `release/`, `helm-chart/templates/` and
    -- `kustomize/`, and a first cut that keyed services by NAME alone merged
    -- them: currencyservice came back with `ports=7000,7000,7000`, one port per
    -- variant, as though it listened three times. They are ALTERNATIVE
    -- declarations of one system, not one system, and conflating them destroys
    -- the very comparison this layer is for — the k8s design's live-vs-declared
    -- and GitOps-drift findings are about exactly that disagreement.
    -- The variant is the manifest's DIRECTORY, which is measured rather than
    -- named: no list of known layouts, no guess.
    for _, rel in ipairs(files) do
        local fd = io.open(data.root .. '/' .. rel, 'r')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        if src then
            local docs, refused, why = M.read(src)
            stats.refused = stats.refused + refused
            for _, w in ipairs(why) do
                if #stats.refusals < 10 then
                    stats.refusals[#stats.refusals + 1] = rel .. ': ' .. w
                end
            end
            if #docs > 0 then
                stats.files = stats.files + 1
                stats.docs = stats.docs + #docs
                local variant = rel:match('^(.*)/[^/]+$') or '.'
                stats.variants[variant] = (stats.variants[variant] or 0) + 1
                data.nodes[#data.nodes + 1] = { id = rel, name = rel,
                    kind = 'module', file = rel, range = R0, order = 0,
                    k8 = 'manifest' }
                for _, d in ipairs(docs) do
                    local key = d.name or d.app
                    if key and (d.kind == 'Deployment' or d.kind == 'Service') then
                        local vk = variant .. '\31' .. key
                        local s = stats.services_map[vk]
                        if not s then
                            s = { name = key, variant = variant, files = {},
                                ports = {}, addrs = {} }
                            stats.services_map[vk] = s
                            stats.services = stats.services + 1
                        end
                        s.files[#s.files + 1] = rel
                        if d.image then
                            -- ⚠ THE BASENAME ON BOTH SIDES. A release bundle
                            -- pins the registry path
                            -- (`us-central1-docker.pkg.dev/.../adservice`) while
                            -- skaffold names the artifact bare, so keying on the
                            -- full string mapped ONE service of fifteen and the
                            -- other fourteen looked like a missing oracle rather
                            -- than a key mismatch.
                            s.image = d.image:gsub(':.*$', ''):match('([^/]+)$')
                            -- ★ the ORACLE, never a name match
                            s.dir = img2dir[s.image]
                            if not s.dir then stats.unmapped[s.image] = true end
                        end
                        for _, p in ipairs(d.ports) do s.ports[#s.ports + 1] = p end
                        for k, v in pairs(d.env) do
                            -- a declared peer address: `NAME_SERVICE_ADDR: host:port`
                            local host = k:match('_SERVICE_ADDR$') and v:match('^([%w%._%-]+):')
                            if host then s.addrs[host] = v end
                        end
                    end
                end
            end
        end
    end

    -- pass 2: the DECLARED TOPOLOGY. A `*_SERVICE_ADDR` naming a service this
    -- roster knows is an edge; one naming anything else is a peer OUTSIDE the
    -- manifests and gets no fabricated target — the same refusal proto.lua makes
    -- for an import pointing out of the root.
    for _, s in pairs(stats.services_map) do
        for host in pairs(s.addrs) do
            -- WITHIN THE VARIANT: a manifest names a peer by its in-cluster DNS
            -- name, which resolves inside its own deployment, not across two.
            local peer = stats.services_map[s.variant .. '\31' .. host]
            if peer and peer ~= s and s.files[1] and peer.files[1] then
                data.edges[#data.edges + 1] = { from = s.files[1], to = peer.files[1],
                    kind = 'use', k8 = 'declares', at = {} }
                stats.edges = stats.edges + 1
            elseif not peer then
                -- ★★ A ONE-SIDED DECLARED EDGE, which is the k8s design's A4
                -- bipartite-completeness shape and the first lint this layer
                -- affords: a workload names a peer its own deployment does not
                -- contain. FOUND ON THE FIRST RUN — kubernetes-manifests/
                -- frontend.yaml:83 declares SHOPPING_ASSISTANT_SERVICE_ADDR and
                -- that variant ships no shoppingassistantservice (it is an
                -- optional kustomize component).
                -- ⚠ IT IS NOT AUTOMATICALLY A BUG, and the design says so in as
                -- many words: "unreferenced statically" != "dead", and the
                -- mirror holds — a declared peer may be supplied by an overlay,
                -- a feature flag, or an operator. Surfaced with its variant,
                -- never resolved into a fabricated edge.
                stats.dangling[#stats.dangling + 1] =
                    ('%s declares %s, absent from %s'):format(s.name, host, s.variant)
            end
        end
    end

    -- ── ★★★ PASS 3: THE EDGE THAT FUSES THE LAYER TO THE CODE. Without it the
    -- deployment is an ISLAND — measured on microservices-demo, the composed
    -- graph had 42 deployment->deployment edges and ZERO deployment->source, so
    -- the manifests were 68 nodes nobody could reach from a source file and
    -- nothing could reach from them. A manifest deploys an IMAGE, skaffold
    -- declares which directory BUILDS that image, and the source modules under
    -- that directory are what the manifest is about. One edge per service, every
    -- one of them oracle-backed; a service whose image skaffold does not name
    -- (redis, busybox) gets none, because it has no source here to point at.
    -- ⚠ DIRECTION: manifest -> source. The deployment REFERS to the code; the
    -- code does not know it is deployed.
    local bydir = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'module' and n.file and not n.pb and not n.k8 then
            local d = n.file:match('^(.*)/[^/]+$')
            while d and d ~= '' do
                bydir[d] = bydir[d] or {}
                table.insert(bydir[d], n.id)
                d = d:match('^(.*)/[^/]+$')
            end
        end
    end
    for _, s in pairs(stats.services_map) do
        local mods = s.dir and (bydir[s.dir] or bydir[(s.dir:gsub('^src/', ''))])
        if mods and s.files[1] then
            for _, m in ipairs(mods) do
                data.edges[#data.edges + 1] = { from = s.files[1], to = m,
                    kind = 'use', k8 = 'deploys', at = {} }
                stats.deploys = (stats.deploys or 0) + 1
            end
        end
    end

    data.k8s = stats
    return stats
end

--- service name -> source directory, the join a runtime observation needs.
--- `service.name` in an OTel span is declared in NEITHER the source NOR the
--- manifests (CART-0829), so this is the only place the mapping can come from —
--- and it comes from skaffold's declared build context, not from a guess.
function M.dir_of(data, service)
    local k = data and data.k8s
    for _, s in pairs(k and k.services_map or {}) do
        if s.name == service and s.dir then return s.dir, s.variant end
    end
    return nil
end

function M.summary(s)
    -- ⚠ A REFUSAL-ONLY RESULT IS STILL A RESULT (CART-1043): with no manifest read but documents
    -- refused, the old `files == 0 -> nil` made the refusal counter silent exactly when the whole
    -- layer was refused (113 of 113 helmfile/values documents on jenkins-infra).
    if s and s.files == 0 and (s.refused or 0) > 0 then
        return ('k8s: 0 manifests read, %d document(s) refused (%s)'):format(s.refused,
            table.concat(s.refusals or {}, '; '):sub(1, 160))
    end
    if not s or s.files == 0 then return nil end
    local unm = {}
    for i in pairs(s.unmapped) do unm[#unm + 1] = i end
    table.sort(unm)
    local mapped = 0
    for _, sv in pairs(s.services_map) do if sv.dir then mapped = mapped + 1 end end
    local vs = {}
    for v, n in pairs(s.variants) do vs[#vs + 1] = ('%s(%d)'):format(v, n) end
    table.sort(vs)
    return ('k8s: %d manifest(s) in %d deployment variant(s) [%s], %d document(s)'
        .. ' — %d service decl(s) (%d mapped to a source dir), %d declared'
        .. ' edge(s), %d deploys-edge(s) into the source%s%s')
        :format(s.files, #vs, table.concat(vs, ' '), s.docs, s.services, mapped, s.edges,
            s.deploys or 0,
            #unm > 0 and (' · %d image(s) with no skaffold context: %s')
                :format(#unm, table.concat(unm, ' ')) or '',
            s.refused > 0 and (' · %d REFUSED document(s): %s')
                :format(s.refused, table.concat(s.refusals, ' ')) or '')
        .. (#s.dangling > 0 and ('\n  ⚠ %d declared peer(s) absent from their own'
            .. ' deployment (one-sided edge, NOT automatically a bug): %s')
            :format(#s.dangling, table.concat(s.dangling, ' · ')) or '')
end

return M
