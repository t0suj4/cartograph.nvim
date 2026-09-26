-- postpass — THE ENRICHMENT PASSES THAT RUN AFTER EXTRACTION, declared once (CART-0847).
--
-- ★ WHY THIS IS A LIST IN A MODULE AND NOT A BLOCK IN init.lua. Each pass below claims facts extraction did not:
-- sql reads SQL out of string literals, erlreg reads the `{iq_handler, …}` tuples a callback returns, xlang links
-- string-keyed dispatch, the framework and deployment layers read files no spec claims. Until this they were
-- a sequence of calls inline in the open path, so nothing ELSE could ask "what does the graph look like after
-- them". The L2 loss report (tools/lossreport.lua) has to measure the FINAL graph, or it accuses extraction of
-- losing every fact a pass picks up later — the ticket's named false-positive source — and copying the
-- sequence into the tool would be a second list to drift. So the sequence lives here and both run it.
--
-- ORDER IS LOAD-BEARING: helmfile runs before k8s and CLAIMS its files; k8s runs before proto so the `deploys`
-- edges exist while the contract is bound. Each entry: { name, run(data) -> results…, say(results…) ->
-- message, level | nil }. `say` is the open path's one-line summary; a pass with nothing to report says nil.
local M = {}

local INFO, WARN = vim.log.levels.INFO, vim.log.levels.WARN

M.PASSES = {
    -- cross-language boundaries (string-key dispatch) run BEFORE the oracles — their edge rebuild preserves
    -- xlang refs (e.xlang). Registries the project invented for itself are DISCOVERED and linked the same way
    -- (config.discover = false disables).
    { name = 'xlang',
        run = function (data)
            local xl = require 'cartograph.xlang'
            return xl.link(data, xl.effective_bindings(data))
        end,
        say = function (x)
            if x and x.links > 0 then return ('linked %d cross-language call sites'):format(x.links), INFO end
        end },
    -- string-embedded SQL: tables become entities with usage sites
    { name = 'sql',
        run = function (data) return require('cartograph.sql').attach(data) end,
        say = function (sq)
            if sq and sq.tables > 0 then
                return ('%d SQL tables from %d embedded queries'):format(sq.tables, sq.queries), INFO
            end
        end },
    -- Django URL loop: routes as entities, templates linked in
    { name = 'django',
        run = function (data) return require('cartograph.django').attach(data) end,
        say = function (dj)
            if dj and dj.routes > 0 then
                return ('django — %d routes, %d templates, %d links; %d unregistered, %d unused, %d duplicate')
                    :format(dj.routes, dj.templates, dj.links, #dj.unregistered, #dj.unused, #dj.duplicate), INFO
            end
        end },
    -- Symfony URL loop: yaml routes as entities, twig + code linked
    { name = 'symfony',
        run = function (data) return require('cartograph.symfony').attach(data) end,
        say = function (sf)
            if not (sf and sf.routes > 0) then return nil end
            local audit = sf.partial
                and (('%d refs unmatched (discovery PARTIAL: %d resource imports/generators unseen)'):format(
                    sf.unmatched, sf.imports))
                or (('%d unregistered, %d unused, %d duplicate'):format(
                    #sf.unregistered, #sf.unused, #sf.duplicate))
            return ('symfony — %d routes (%d wired, %d external), %d templates, %d links; %s'):format(
                sf.routes, sf.controllers, sf.external, sf.templates, sf.links, audit), INFO
        end },
    -- Ansible notify↔handler loop + include graph
    { name = 'ansible',
        run = function (data) return require('cartograph.ansible').attach(data) end,
        say = function (an)
            if an and (an.handlers > 0 or an.includes > 0) then
                return ('ansible — %d handlers, %d notifies (%d linked, %d no-op, %d dynamic), %d includes,'
                    .. ' %d vars (%d links, %d unused); %d dead handlers, %d broken includes'):format(
                    an.handlers, an.notifies, an.links, #an.noop, an.dynamic, an.includes, an.vars,
                    an.var_links, #an.unused_vars, #an.dead, #an.broken), INFO
            end
        end },
    -- the DEPLOYMENT layer: kubernetes manifests are claimed by no spec either, and they carry the identity that
    -- maps a running service back to its code plus the declared service topology (CART-0830).
    -- the HELM RELEASE layer (CART-1042): a helmfile repo holds releases and layered values, not manifests. It
    -- runs FIRST and CLAIMS its files, so k8s does not count every values file as a failed manifest (113 of 113
    -- on jenkins-infra's repo).
    { name = 'helmfile',
        run = function (data) return require('cartograph.helmfile').attach(data) end,
        say = function (r) return require('cartograph.helmfile').summary(r), INFO end },
    -- the DECLARED CLOUD layer (CART-1042): Terraform read and EVALUATED statically — a DNS record's host is its
    -- name plus a zone that may be a module output three hops away; what needs Terraform to run (computed ids,
    -- for_each) is reported unknown.
    { name = 'terraform',
        run = function (data) return require('cartograph.terraform').attach(data) end,
        say = function (r) return require('cartograph.terraform').summary(r), INFO end },
    -- the MAVEN BUILD layer (CART-1051): POMs read as XML data and put through Maven's model builder statically —
    -- inheritance, interpolation (holes kept by class), profiles as vantages, dependencyManagement as linking;
    -- inter-module `use` edges.
    { name = 'pom',
        run = function (data) return require('cartograph.pom').attach(data) end,
        say = function (r) return require('cartograph.pom').summary(r), INFO end },
    -- runs BEFORE proto/xlang-bound contracts so the `deploys` edges exist while the contract is being bound;
    -- skips the files helmfile claimed
    { name = 'k8s',
        run = function (data)
            local k8s = require 'cartograph.k8s'
            local kopts
            if data.helmfile then
                local rest = {}
                for _, f in ipairs(k8s.find(data.root)) do
                    if not data.helmfile.claimed[f] then rest[#rest + 1] = f end
                end
                kopts = { files = rest }
            end
            return k8s.attach(data, kopts)
        end,
        say = function (kb)
            local line = require('cartograph.k8s').summary(kb)
            if line then return line, kb.refused > 0 and WARN or INFO end
        end },
    -- the gRPC/protobuf CONTRACT: .proto files are claimed by no spec, so their services and rpcs enter the
    -- graph here (CART-0824). One rpc = one `method` node, SITE-ANCHORED — a vendored copy of a .proto is a
    -- second real declaration, and reunifying the copies by qualified name belongs to the cross-service join.
    { name = 'proto',
        run = function (data) return require('cartograph.proto').attach(data) end,
        say = function (pb)
            local line = require('cartograph.proto').summary(pb)
            if line then return line, pb.refused > 0 and WARN or INFO end
        end },
    -- ★ THE SECOND REGISTRATION CARRIER (CART-0846): erlang registers IQ handlers by CALL and by a TUPLE RETURNED
    -- FROM A CALLBACK, and argv reads only the call. This reads the tuple against the interpretation gen_mod.erl
    -- states in executable code, and mints the SAME handler edge the call path mints — using xlang's own exported
    -- resolver, never a synthetic call (dec/36).
    { name = 'erlreg',
        run = function (data) return require('cartograph.erlreg').attach(data) end,
        say = function (er)
            local line = require('cartograph.erlreg').summary(er)
            if line then return line, #er.refused > 0 and WARN or INFO end
        end },
    -- a configured database: its tables join the graph and the code's SQL entities link to them (session pass)
    { name = 'dblink',
        run = function (data) return require('cartograph.dblink').attach(data) end,
        say = function (dbl, dberr)
            if dbl then
                return ('db link — %d matched, %d missing, %d unused%s'):format(dbl.matched, #dbl.missing,
                    #dbl.unused, dbl.prefix and (" (prefix '%s')"):format(dbl.prefix) or ''), INFO
            elseif dberr then
                return 'db link failed — ' .. dberr, WARN
            end
        end },
}

--- Run every pass over `data`, in order. `opts.say(msg, level)` receives each pass's summary line (the open path
--- notifies with it); `opts.skip` = { [name] = true } leaves a pass out (the loss report skips the session-bound
--- `dblink`). Returns { [name] = { results… } }.
function M.run(data, opts)
    opts = opts or {}
    local out = {}
    for _, p in ipairs(M.PASSES) do
        if not (opts.skip and opts.skip[p.name]) then
            local r = { p.run(data) }
            out[p.name] = r
            if opts.say then
                local msg, level = p.say(unpack(r))
                if msg then opts.say(msg, level) end
            end
        end
    end
    return out
end

return M
