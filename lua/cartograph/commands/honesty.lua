-- :Cartograph command group — honesty and resolution reports (|cartograph-cmd-honesty|)
--
-- Registered by cartograph.commands, which owns the shared helpers and passes
-- them in: this module rebinds them as locals under the SAME names, so every
-- callback body reads exactly as it did when they all lived in one function.

local M = {}

function M.register(H)
    local cmd, live, whole_graph, mat_df, scratch, txn_module, reveal_at =
        H.cmd, H.live, H.whole_graph, H.mat_df, H.scratch, H.txn_module,
        H.reveal_at
    -- not every group uses every helper; keep the binding uniform
    local _ = cmd and live and whole_graph and mat_df and scratch


    -- cartograph on cartograph: the self-analysis dashboard (census + LSP
    -- serving-consistency + lint incl. the Band seam-guard) in a scratch
    -- buffer, and the in-process LSP attached so gd/gr/K work on this graph.
    cmd('CartographDogfood', function ()
        local store = live() if not store then return end
        local lines = require('cartograph.dogfood').run(store)
        local id = require('cartograph.lsp').attach()
        if id then lines[#lines + 1] = ''; lines[#lines + 1] = ('LSP attached (client %d) — gd/gr/K on this graph'):format(id) end
        scratch(lines)
    end, { desc = 'cartograph: self-analysis dashboard + attach the LSP read surface' })

    -- ── field-harvest: the disagreement harvest — field resolutions vs lua-ls ─
    cmd('CartographFieldHarvest', function ()
        local store = live() if not store then return end
        vim.notify('cartograph: harvesting field resolutions vs lua-ls (async)…',
            vim.log.levels.INFO)
        require('cartograph.fieldharvest').harvest(store, {}, function (stats, why)
            scratch(require('cartograph.fieldharvest').report(stats, why))
        end)
    end, { desc = 'cartograph: DISAGREEMENT HARVEST — compares the field linker\'s self.field read→write resolutions to lua-ls go-to-definition over the loaded graph. Agree = confidence; a CONFLICT is a real bug on ONE side (the north-star success bar). Bounded-scope (lua-ls indexing) — best per-addon / per-file' })

    -- ── the honesty census: how well is this graph actually resolved ─
    cmd('CartographCensus', function ()
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        scratch(require('cartograph.census').report(store.data))
    end, { desc = 'cartograph: epistemic census — edge trust tiers + refusals by rule (the analyzer work-list)' })

    -- ── derived-index integrity: the Log/View rule, executable ───────
    cmd('CartographAudit', function ()
        local store = live() if not store then return end
        local out, why = store.audit()
        if not out then
            return vim.notify('cartograph: audit skipped — ' .. why,
                vim.log.levels.WARN)
        end
        if #out == 0 then
            return vim.notify('cartograph: indexes match a fresh derive (clean)',
                vim.log.levels.INFO)
        end
        table.insert(out, 1, ('index drift — %d divergence(s) vs a fresh derive:')
            :format(#out))
        scratch(out)
    end, { desc = 'cartograph: diff live indexes against a fresh derive (catches in-place writer drift)' })

    -- ── escalation-on-hedge: confirm the ~ hotspots vs lua-ls ────────
    cmd('CartographEscalate', function (o)
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        local esc = require 'cartograph.escalate'
        vim.notify('cartograph: escalating hedge-saturated fns to lua-ls…',
            vim.log.levels.INFO)
        -- ASYNC: lua-ls's workspace load no longer freezes the editor. The
        -- generation gates the anti-thrash cache; --all widens past the
        -- saturated work-list to the whole graph.
        esc.run_async(store.data, { generation = store.generation, all = o.bang },
            function (f, why)
                if not f then
                    return vim.notify('cartograph: escalate — ' .. tostring(why),
                        vim.log.levels.WARN)
                end
                local byid = {}
                for _, n in ipairs(store.data.nodes) do byid[n.id] = n end
                local function nameof(id) return byid[id] and byid[id].name or tostring(id) end
                require('cartograph.panes.symbols').render() -- upgraded ~→proven show
                -- in-buffer surface: conflicts (★ error) + refuted (warn) as signs
                local n = require('cartograph.diag').publish(
                    esc.diagnostics(f, store.abs, nameof), 'escalate')
                scratch(esc.report(f, nameof))
                if n > 0 then
                    vim.notify(('cartograph: %d conflict/refuted finding(s) on in-buffer signs')
                        :format(n), vim.log.levels.INFO)
                end
            end)
    end, { bang = true, desc = 'cartograph: escalate hedge-saturated fns to lua-ls (async) — confirmed/CONFLICT/refuted/recovered; ! = whole graph' })

    -- ── why did registry discovery (not) find a verb? ───────────────
    cmd('CartographDiscover', function (o)
        local store = live() if not store then return end
        local g = require 'cartograph.greenspun'
        local xl = require 'cartograph.xlang'
        local deep = o.bang and { deep = true } or nil
        local lines = g.explain(store.data, o.args ~= '' and o.args or nil, deep)
        -- the bang is the BUTTON: apply what deep discovery found beyond
        -- the bindings already in force, then restore the exact location
        if o.bang and o.args == '' then
            local have = {}
            for _, b in ipairs(xl.effective_bindings(store.data)) do
                for _, v in ipairs(type(b.export.verb) == 'table'
                    and b.export.verb or { b.export.verb }) do
                    have[v] = true
                end
            end
            local fresh = {}
            for _, b in ipairs(g.registries(store.data, { deep = true })) do
                if not have[b.export.verb] then fresh[#fresh + 1] = b end
            end
            if #fresh > 0 then
                local loc = store.loc_provider and store.loc_provider.get()
                local stats = xl.link(store.data, fresh)
                store.ingest(store.data)
                require('cartograph.toc').attach(store)
                if loc and store.loc_provider then store.loc_provider.set(loc) end
                local names = {}
                for _, b in ipairs(fresh) do names[#names + 1] = b.export.verb end
                lines[#lines + 1] = ''
                lines[#lines + 1] = ('APPLIED %d deep binding(s): %s — %d handler(s) resolved, %d site(s) linked')
                    :format(#fresh, table.concat(names, ', '), stats.exports, stats.links)
            else
                lines[#lines + 1] = ''
                lines[#lines + 1] = 'deep discovery found nothing beyond the bindings already in force'
            end
        end
        scratch(lines)
    end, { nargs = '?', bang = true,
        desc = 'cartograph: explain registry discovery; ! runs the deep tier and applies it' })

    -- ── the epistemic ladder: how much of the graph is trustworthy ──
    cmd('CartographLadder', function ()
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        scratch(require('cartograph.ladder').report(store))
    end, { desc = 'cartograph: the call graph\'s epistemic distribution + heaviest refusals' })

    -- ── the VERSION FLOOR: which language version this code needs, and what
    --    supporting an older one would cost. Re-reads and re-parses files, so
    --    it needs no call graph — deliberately NO whole_graph guard.
    cmd('CartographVersionFloor', function ()
        local store = live() if not store then return end
        scratch(require('cartograph.versionfloor').report(store))
    end, { desc = 'cartograph: the version floor as an ATTRIBUTED SET — which language version this code needs and WHY (the feature and the site holding it up) — plus the downgrade ladder, pricing each older target in sites-to-fix. A LOWER bound: syntax only, stdlib version gates not modelled' })

    -- ── NAME-LEVEL EVIDENCE: which files mention a name, off the mention
    --    postings. Deliberately NO whole_graph guard: it needs the mention index,
    --    not the call graph, so it still answers where resolution REFUSED — and a
    --    refused call still tells you the name occurs. It never claims to BE
    --    references: the report states what a mention is, and shows the resolved
    --    subset AS a subset when a call graph exists. On a graph with no mention
    --    index (the thin index — index_only skips the pass that builds it) it
    --    REFUSES rather than reporting zero mentions.
    cmd('CartographMentions', function (o)
        local store = live() if not store then return end
        -- <cword> by default: the vim idiom, no new keybinding for this
        local name = o.fargs[1] or vim.fn.expand('<cword>')
        -- the asking file confines the answer, exactly as resolution would. Buffer
        -- path -> graph-relative key by the root prefix (the open.lua idiom; there
        -- is no store.rel). Nil when the buffer is outside the graph or carries no
        -- mention index — confine by nothing rather than by the wrong scope.
        local from
        local abs, root = vim.api.nvim_buf_get_name(0), (store.data or {}).root
        if root and abs:sub(1, #root + 1) == root .. '/' then
            from = abs:sub(#root + 2)
        end
        if from and not ((store.data or {}).names or {})[from] then from = nil end
        scratch(require('cartograph.mentions').report(store, name, from))
    end, { nargs = '?', desc = 'cartograph: which files MENTION a name (default: the word under the cursor), from the mention index — so it still answers where RESOLUTION refused, since a refused call still tells you the name occurs. Scope-confined to the asking file\'s resolution scope, and split into its resolved subset when a call graph exists. Name-level evidence, never references: a mention is an identifier occurrence, not a claim that two files name the same thing. REFUSES on a graph with no mention index (the thin index) rather than reporting zero' })

    -- ── THE CODE'S OWN PROFILE: the symmetric inverse of an environment one.
    --    Unifies porting, version floor and the dependency manifest into one
    --    requirement set, so all three are set algebra over the same currency.
    cmd('CartographRequires', function ()
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        scratch(require('cartograph.portability').requires_report(store))
    end, { desc = 'cartograph: the code\'s OWN profile — what it REQUIRES (external names + version floor), which shipped environment covers most of that set (tightest environment), and the requirement set grouped by who provides it (dependency manifest). Coverage, never a verdict' })

    -- ── PORTABILITY: the external surface scored against a target runtime.
    --    Needs the whole graph — the surface IS the unresolved calls, so on the
    --    thin index "provided by nothing" would be an artefact of no call graph.
    cmd('CartographPortability', function (o)
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        local from, to = o.fargs[1], o.fargs[2]
        local port = require 'cartograph.portability'
        if not from then
            -- NO TARGET NAMED = PRINT THE LIST, not a usage string. Completion narrows
            -- the offered set silently (CART-0209), so a reader who has not pressed
            -- <Tab> is told which artifacts answer which question — and which ones ship
            -- and answer neither, with why. A usage line taught nothing.
            return scratch(port.roster_report())
        end
        -- ! = ALSO the READ surface. Opt-in behind the bang because references
        -- re-parse every function (~3.5 ms each), which a default verb must not do
        -- to a large corpus — the same reason portability.report gates it on opts.
        -- It is the bang and not a flag word because the other verbs here already
        -- spend it on "the more expensive answer" (escalate !, hedges !).
        -- two targets = the MOVE between them; direction matters
        local lines
        -- DISPATCH ON THE STAGE the artifacts DECLARE, not on a flag the user has to
        -- remember. A prototype-api pair answers a DATA-STAGE question (which
        -- properties of the prototypes this mod declares stopped existing); a runtime
        -- pair answers a NAME question. Routing a proto pair through the calls diff
        -- printed a refusal, which was honest but no longer necessary — the answer
        -- exists now (CART-0213).
        local pm = require 'cartograph.spec.profile'
        if to and port.prototype_queryable(pm.load(from))
            and port.prototype_queryable(pm.load(to)) then
            lines = port.prototype_diff_report(store, from, to)
        elseif to then
            lines = port.diff_report(store, from, to)
            if o.bang then
                -- READS are where a port actually breaks (`global.foo` is never
                -- called), so the reads diff is the worklist the calls diff cannot
                -- produce. Appended, not substituted: both halves are the answer.
                lines[#lines + 1] = ''
                vim.list_extend(lines, port.reference_diff_report(store, from, to))
            end
        else
            lines = port.report(store, from, o.bang and { references = true } or nil)
        end
        scratch(lines)
    end, { nargs = '*', bang = true, complete = function ()
        -- TARGETS, not the whole roster (CART-0209). Completion is where a reader
        -- learns what is auditable, so offering an artifact that cannot answer either
        -- question this verb asks taught a wrong list and then refused it. The
        -- prototype-api artifacts ARE still offered — they answer the DATA-stage
        -- question — which is why the filter is on what an artifact can ANSWER rather
        -- than on its `ingredient` marker.
        return require('cartograph.portability').targets()
    end, desc = 'cartograph: score the external surface against a target environment profile — which names it PROVIDES and which are not in it (candidate porting work, with call counts). With TWO targets, diff the MOVE from the first to the second: the names that change status ARE the work. ! adds the READ surface (names touched but never called — where a port actually breaks; re-parses every function, so it is opt-in), and marks any read whose root another file also binds rather than silently dropping it. Reads on a RECEIVER are adjudicated too, by the member name alone — that test needs no receiver, so it does not wait on typing one. TWO PROTOTYPE-STAGE targets diff the DATA STAGE instead — which declared prototypes\' properties stopped existing, separating a write from a deletion that no longer deletes. Not-in-profile is not "missing": a dependency may supply it' })

    -- ── the EXTERNAL SURFACE: names used but defined nowhere here, with the
    --    shape inferred backward from usage (the boundary map + write-side seed)
    cmd('CartographExternals', function ()
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        scratch(require('cartograph.externals').report(store))
    end, { desc = 'cartograph: the external boundary — unresolved names + their used-shape (~)' })

    -- ── THE PACKAGE WORLD OUTSIDE THIS REPO: what the install holds ──
    --    Needs no graph — it reads a package directory, not a corpus, and is the
    --    thing to run BEFORE extracting one (which is why it does not call live()).
    cmd('CartographRoster', function (o)
        local eco = o.fargs[1] or 'lua-factorio'
        -- a root the spec marks NOT DERIVABLE can only come from config, so this
        -- passes the overrides through — that is what lets the report state HOW each
        -- root was established (override / autodetected / unspecified) instead of
        -- just printing a path.
        local roots = (require('cartograph.config').ecosystem_roots or {})[eco] or {}
        scratch(require('cartograph.roster').report(eco, {
            dir = o.fargs[2], user = roots.user, install = roots.install,
        }))
    end, { nargs = '*', complete = function ()
        return require('cartograph.spec.ecosystem').names()
    end, desc = 'cartograph: the package ROSTER of an installed ecosystem (default lua-factorio; an optional second arg is a package directory) — packages by form, which ones LOAD, both cheap guesses at identity scored against the manifest, and every declared dependency judged against this install. Findings are split ACTIVE vs LATENT by enablement: a conflict between two disabled packages is a fact about the install, not a fault in it. Reads a directory, not a graph, so it needs no extraction — but a large mods dir costs seconds' })

    -- ── which project shape was detected, and what it changed ──────
    cmd('CartographShapes', function ()
        local st = require 'cartograph.store'
        local root = (st.data and st.data.root) or vim.fn.getcwd()
        scratch(require('cartograph.shapes').explain(root))
    end, { desc = 'cartograph: explain project-shape detection for this root' })
end

return M
