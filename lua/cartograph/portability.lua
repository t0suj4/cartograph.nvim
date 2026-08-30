-- PORTABILITY ([[cartograph-portability-lever]]): score this codebase's EXTERNAL
-- SURFACE against a target environment. "Will it run on <runtime>, and if not,
-- WHERE does it break?"
--
-- The whole verb is one intersection, which is why it is small: externals.lua
-- already computes what the code uses but does not define, and every L2 profile
-- already declares what a runtime provides (vocab / free / namespaces / types /
-- sigs). Porting is the difference between those two sets.
--
-- The design note called for hand-authored `<runtime>-provides` sets. It turned
-- out none were needed: a profile IS a provides set, so the audit reads the
-- artifacts that already ship and any new distilled profile becomes a target for
-- free.
--
-- The A-to-B DIFF needs TWO name-queryable profiles for the SAME language, and
-- ★ ONE SHIPPED PAIR QUALIFIES: `lua-factorio-11` -> `lua-factorio`. Run it.
--
-- That sentence is the one this module got WRONG for four weeks, so it now carries
-- its own check and tools/docaudit.lua re-reads it every run. The check calls the
-- diff's OWN precondition, not a copy of it: if the pair stops qualifying, the
-- fence says so instead of this header quietly becoming true again.
--
-- @claim qualifying-profile-pair: lua-factorio-11 -> lua-factorio still qualifies for the reference diff
--   check: require('cartograph.portability').diffable_pair('lua-factorio-11', 'lua-factorio')
--
--     port.reference_diff(store, 'lua-factorio-11', 'lua-factorio')
--
-- On ~/git/Von-Neumann (2026-08-27) that reports lost=10 gained=0 kept=17, and the
-- lost list is the Factorio 2.0 `global` -> `storage` rename with a file per name:
-- global.savedRailbots, global.cage_sound, global.previousPositions,
-- global.playersNeedZoom, plus game.active_mods and game.item_prototypes.
--
-- ⚠ THIS PARAGRAPH USED TO SAY "no shipped pair qualifies today … the move report
-- cannot be demonstrated on the artifacts in the tree", and that was FALSE from the
-- moment the second factorio artifact landed (1 August). The cost was not academic:
-- a session read it, believed the version axis did not exist, and filed three
-- tickets around a mechanism that was already here — one of them a P1 whose premise
-- was simply wrong (CART-0587, CART-0595). A CAVEAT THAT SAYS "CANNOT BE
-- DEMONSTRATED" IS THE EXACT THING THAT STOPS THE NEXT READER RUNNING IT, so it has
-- to be re-checked whenever an artifact lands, and it is cheaper to name the
-- working pair than to describe the space of pairs that would work.
--
-- Still true, and the reason M.diff alone is not enough: it scores the REQUIREMENT
-- set, which is call-derived, so a 1.1 -> 2.0 move reports 0 lost — everything that
-- actually changed is READ, never called. M.reference_diff scores
-- externals.references under both profiles instead. Both refuse clearly rather than
-- producing a meaningless "everything is lost"; ruby-core is signature-keyed and
-- ruby-rails/zig-std are other languages, so those still do not pair.
--
-- HONESTY — a portability claim is easy to overstate, so:
--   · Buckets are PROVIDED and NOT-IN-PROFILE. Never "missing": a name absent
--     from a profile may be supplied by a dependency (a gem, an npm package) or
--     simply absent from a partial artifact. Which of those it is, this cannot
--     know, and the report says so instead of ruling.
--   · The profile's own size is printed. A verdict against a 134-symbol profile
--     is worth less than one against 3,260, and the reader is entitled to that.
--   · Only the SILENT external surface is scored (calls that resolved to nothing
--     and were not even refused). Anything the project itself defines is out of
--     scope by construction, so a project method never counts as a blocker.
--   · A profile whose language differs from the code's is refused outright,
--     rather than reporting every name as not-provided.

local M = {}

--- Does `prof` provide `name`? Returns the EVIDENCE (which part of the profile
--- answered) or nil. Several sources because profile artifacts differ: a
--- distilled zig std is free-function-heavy, a hand-authored Factorio profile is
--- namespace-heavy, and an RBS-derived one is signature-keyed.
function M.provides(prof, name)
    if not (prof and name and name ~= '') then return nil end
    if prof.vocab and prof.vocab[name] then return 'vocab' end
    if prof.free and prof.free[name] then return 'free fn' end
    if prof.sigs and prof.sigs[name] then return 'signature' end
    local root, rest = name:match('^([%w_]+)[%.:#]+(.+)$')
    if root then
        -- A FULLY ENUMERATED CLASS ANSWERS FOR ITSELF, and must be consulted BEFORE
        -- the namespace prefix below. The prefix says only "this root is a known
        -- global", which is the right answer for a DISPOSITION (the call is external,
        -- not project) but the wrong one for PORTABILITY: it made
        -- `game.entity_prototypes` count as provided by `namespace game` and so
        -- hid the single clearest piece of porting work in the corpus — that name
        -- was renamed to prototypes.entity in 2.0.
        -- Only a SINGLE-segment member is adjudicated: a deeper chain
        -- (`game.surfaces[1].create_entity`) continues into receiver-typed territory
        -- the artifact cannot follow, so it keeps the prefix answer.
        local cls = (prof.global2class or {})[root]
        if cls and (prof.api_complete or {})[cls] and rest:match('^[%w_]+$') then
            if (prof.api_members or {})[cls .. '::' .. rest] then
                return 'member of ' .. cls
            end
            return nil -- enumerated and NOT there: genuinely absent
        end
        if prof.nsset and prof.nsset[root] then return 'namespace ' .. root end
        if prof.namespaces and prof.namespaces[root] then return 'namespace ' .. root end
        local ty = prof.types and prof.types[root]
        if ty then
            local mem = ty.members
            if mem then
                if mem[rest] then return 'member of ' .. root end
                for _, m in ipairs(mem) do
                    if m == rest then return 'member of ' .. root end
                end
            end
            return 'type ' .. root
        end
        -- NO tail-only fallback. `game.print` must not count as provided by
        -- LuaJIT merely because `print` is a base function: for a DOTTED name the
        -- profile has to provide the ROOT, or it does not provide the name.
        -- Dropping this cost some true positives where a receiver's type is
        -- unknown (`user.save` under rails), and that is the safe direction —
        -- claiming something is provided when it is not would HIDE a blocker,
        -- while under-claiming only over-reports the work.
    end
    return nil
end

--- THE ROSTER: every artifact that ships. Derived, not listed, so a newly distilled
--- profile appears here with no edit.
---
--- NOT the list of things you may audit against — that is M.targets(), and the
--- difference is the whole of CART-0209. This roster is what EXISTS; a target is what
--- can ANSWER. Consumers wanting the second must say so.
function M.runtimes()
    local dir = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]+$')
        .. '/spec/profile'
    local out, seen = {}, {}
    for _, pat in ipairs({ '*.lua', '*.mpack' }) do
        for _, f in ipairs(vim.fn.globpath(dir, pat, false, true)) do
            local name = vim.fn.fnamemodify(f, ':t:r')
            if name ~= 'init' and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    table.sort(out)
    return out
end

--- Can this artifact answer a NAME query at all? An RBS-derived profile is keyed
--- by signature (`String#chomp`), so asking it about a callee name matches almost
--- nothing — and a resulting "0% covered" would read as a claim about the RUNTIME
--- when it is a fact about the ARTIFACT. Ranking says so instead.
function M.name_queryable(prof)
    for _, field in ipairs({ 'vocab', 'free', 'nsset', 'namespaces' }) do
        if next(prof[field] or {}) ~= nil then return true end
    end
    return false
end

--- Can it answer a DOTTED name (`game.print`)? A separate question from the above,
--- and the distinction is load-bearing: a distilled factorio artifact carried 3 free
--- functions — enough for name_queryable to say yes — while every dotted lookup
--- returned nil because its member table was emitted under the wrong field name. The
--- fence therefore passed and the MOVE diff reported "0 LOST" on a mod with two real
--- breaking changes. Bare-name queryability is not evidence of dotted-name
--- queryability, so the two predicates stay separate rather than one being widened.
--- Mirrors the sources provides() consults for a `root.rest` name.
function M.dotted_queryable(prof)
    if next(prof.api_members or {}) ~= nil then return true end
    if next(prof.types or {}) ~= nil then return true end
    for _, field in ipairs({ 'nsset', 'namespaces' }) do
        if next(prof[field] or {}) ~= nil then return true end
    end
    return false
end

-- ── WHAT MAY BE A TARGET (CART-0209) ────────────────────────────────────────
-- The three predicates above answer three DIFFERENT questions, and the reason this
-- section exists is that they disagree — so "is this artifact a target" has no
-- answer until you say a target FOR WHAT. The command asks two:
--   NAMES  audit / report / MOVE diff — needs a bare AND a dotted name surface
--   DATA   the prototype-stage diff  — needs a prototype surface
--
-- MEASURED over every shipped artifact (2026-08-04), which is what makes this a
-- partition and not a guess:
--   6 environments   name+dotted, no prototypes  → a NAMES target
--   2 prototype-api  neither name surface, 2744/3579 own_props → a DATA target
--   3 runtime-api    name-queryable on 3 free functions, dotted NO
--   1 ruby-core      none of the three (RBS, signature-keyed)
--
-- SO `ingredient = true` IS THE WRONG AXIS, and filtering on it would have removed a
-- WORKING target: both prototype artifacts declare the marker and both are exactly
-- what the data-stage diff is aimed at. The marker says "not a NAME surface", which is
-- one question of two. The runtime-api trio, meanwhile, carries NO marker at all and
-- is the artifact CART-0209 was filed about.
--
-- WHY THE LIST NOW MATCHES THE FENCE. M.diff already refuses an artifact that fails
-- either name predicate; the LIST offered it anyway, so completion tempted the reader
-- into a refusal (or, before the fences, into a serene "0 LOST"). A list that cannot
-- tempt you beats a fence that fires — and deriving the list from the fence's own
-- predicates means the two cannot drift.

--- WHICH QUESTIONS this artifact can be a target for: { names = bool, data = bool }.
function M.target_kinds(prof)
    if not prof then return { names = false, data = false } end
    return {
        names = M.name_queryable(prof) and M.dotted_queryable(prof),
        data = M.prototype_queryable(prof) and true or false,
    }
end

--- WHY an artifact can be no target at all — the MECHANISM, with NO artifact name in
--- it, so a caller can either prefix one (a refusal about a specific pick) or GROUP
--- identical reasons (a report listing five). Phrased to follow "<name> is ".
local function target_refusal(prof)
    if M.name_queryable(prof) then
        -- THE CART-0209 ARTIFACT. It holds the whole API — 291 members — but keyed by
        -- CLASS (`LuaGameScript::print`), a key space no CALL NAME can ever match,
        -- and its member table sits under the distiller's own spelling that provides()
        -- deliberately does not read. So it is name-queryable on a handful of free
        -- functions and blind to everything it actually contains: measured 0 of 92 on
        -- a corpus where the hand profile republishing the SAME data answers 33.
        -- NO COUNT IN THE SENTENCE, deliberately: the measure belongs to the ARTIFACT
        -- and the mechanism is SHARED, so keeping them apart is what lets three
        -- artifacts share one paragraph instead of printing it three times over.
        return 'an INGREDIENT, not a target: its symbols are keyed by class'
            .. ' (LuaGameScript::print) and no call name can match that key space, so'
            .. ' it would score 0% against a surface it holds but cannot spend — a'
            .. ' hand-authored profile republishes it, audit that instead'
    end
    return 'not a target: it has no name surface and no prototype surface — it is'
        .. ' signature-keyed (String#chomp) or a distilled ingredient, so a verdict'
        .. ' against it would call every name unknown'
end

--- WHY a DATA-only artifact is not on a NAMES list. Not a refusal — it names the OTHER
--- DOOR, because this artifact is precisely the target of the data-stage diff. A
--- reason that says only "cannot adjudicate a name" is true and useless.
local function data_only_reason()
    return 'a DATA-STAGE artifact with no name surface at all — pass TWO'
        .. ' prototype-stage artifacts to diff the data stage instead'
end

--- HOW BIG this artifact is, in ITS OWN currency. profile_size counts vocab/free/sigs
--- and so reports 0 for a prototype artifact holding 2744 properties — which is how
--- the old report came to label one "signature-keyed artifact (0 sigs)", a sentence
--- wrong in both halves.
local function measure_of(prof)
    if M.prototype_queryable(prof) then
        local np, npr = 0, 0
        for _ in pairs(prof.prototypes or {}) do np = np + 1 end
        for _ in pairs(prof.own_props or {}) do npr = npr + 1 end
        return ('%d prototypes, %d properties'):format(np, npr)
    end
    return ('%d symbols'):format(M.profile_size(prof))
end

--- Is `runtime` offerable as a target, and for what? Returns (prof, kinds) or
--- (nil, reason). The reason names the MECHANISM, because every one of these
--- artifacts is genuinely useful somewhere else — a refusal here is "wrong question",
--- never "worthless file".
function M.targetable(runtime)
    if type(runtime) ~= 'string' or runtime == '' then
        return nil, 'not a profile name'
    end
    local prof = require('cartograph.spec.profile').load(runtime)
    if not prof then
        return nil, ('no profile named %q (profiles ship under spec/profile/)')
            :format(runtime)
    end
    local kinds = M.target_kinds(prof)
    if kinds.names or kinds.data then return prof, kinds end
    return nil, ('%s (%s) is %s'):format(runtime, measure_of(prof),
        target_refusal(prof))
end

--- The artifacts that may be audited against, optionally for ONE question
--- ('names' | 'data'). Drives the command's completion.
function M.targets(kind)
    local out = {}
    for _, rt in ipairs(M.runtimes()) do
        local _, kinds = M.targetable(rt)
        if type(kinds) == 'table' and (not kind or kinds[kind]) then
            out[#out + 1] = rt
        end
    end
    return out
end

--- THE WHOLE ROSTER, dispositioned — rows of { runtime, lang, kinds, reason }. What
--- targets() drops is not silence: a report can print WHICH artifacts it did not
--- score and WHY, which is the difference between "no shipped profile covers this"
--- and "five of them were quietly skipped".
function M.target_roster()
    local pm = require 'cartograph.spec.profile'
    local out = {}
    for _, rt in ipairs(M.runtimes()) do
        local prof, k = M.targetable(rt)
        local p = prof or pm.load(rt)
        -- THE REASON IS NAME-FREE HERE, unlike targetable's, so a report can group the
        -- artifacts that share a mechanism; the measure travels beside it instead
        out[#out + 1] = { runtime = rt, lang = p and p.lang,
            size = p and M.profile_size(p) or 0,
            measure = p and measure_of(p) or nil,
            kinds = type(k) == 'table' and k or nil,
            reason = (not prof) and p and target_refusal(p) or nil }
    end
    return out
end

-- ── THE STAGE PARTITION (CART-0216) ─────────────────────────────────────────
-- A profile is scoped by ROOT (which profile a tree activates) and by LANGUAGE.
-- Neither can express an environment that is DISJOINT WITHIN one root and one
-- language — a Factorio mod, where `game` exists at runtime and not while
-- prototypes are being defined, and `data` the other way round. A profile may now
-- declare `stages`; one that does not behaves exactly as before.
--
-- Two halves, and they are deliberately separate functions: SELECTING a file's
-- stage needs the graph (the import edges), while ADJUDICATING a name against a
-- stage is pure. Fusing them would put a store parameter into provides().

--- WHICH STAGE(S) each file belongs to. An ENTRY file matches one of the profile's
--- declared patterns; every other file inherits from whatever entry can REACH it
--- over the import graph. Returns nil when the profile declares no stages.
--- Otherwise { by_file = {file -> {stage -> true}}, orphans = sorted list,
--- entries = {file -> stage}, shared = sorted list of multi-stage files }.
---
--- REACHABILITY, NOT A PATH GLOB, for two reasons. A glob over `prototypes/` would
--- be one mod's layout dressed up as a rule, and a glob cannot express the case
--- that matters most: a helper required by BOTH data.lua and control.lua is loaded
--- in both environments, so it may use only what BOTH provide.
---
--- ORPHANS ARE RETURNED, NOT DROPPED. A file no entry reaches has no stage, and
--- that is a fact about our reading (dead code, a file loaded by a mechanism we do
--- not model, or another language entirely). Silently skipping it would be the
--- absence-rendered-as-silence class: no findings would read as no problems.
function M.stage_map(store, prof)
    if not (prof and prof.stages and #prof.stages > 0) then return nil end
    local data = (store or {}).data or {}
    local imports = {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'import' and e.from and e.to then
            local l = imports[e.from]
            if not l then l = {}; imports[e.from] = l end
            l[#l + 1] = e.to
        end
    end
    -- THE FILE SET IS THIS PROFILE'S LANGUAGE ONLY, and both exclusions are load-
    -- bearing. A PROFILE-MINTED node carries the profile NAME where a file goes
    -- (`lua-factorio`, kind='external'), which has no extension and is not a file at
    -- all — it appeared in the orphan list on the first run. And a file of another
    -- language belongs to the LANGUAGE axis (`other-language`), so counting it here
    -- too would report one fact twice under two names.
    local files = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.file then
            local ext = n.file:match('%.([%w]+)$')
            local lang = ext and ext_lang()[ext:lower()]
            if lang and (not prof.lang or lang == prof.lang) then files[n.file] = true end
        end
    end

    local res = { by_file = {}, orphans = {}, entries = {}, shared = {} }
    for _, st in ipairs(prof.stages) do
        local queue = {}
        for f in pairs(files) do
            for _, pat in ipairs(st.entry or {}) do
                if f:match(pat) then
                    queue[#queue + 1] = f
                    res.entries[f] = st.name
                    break
                end
            end
        end
        local seen = {}
        for _, f in ipairs(queue) do seen[f] = true end
        local i = 1
        while i <= #queue do
            local f = queue[i]; i = i + 1
            res.by_file[f] = res.by_file[f] or {}
            res.by_file[f][st.name] = true
            for _, to in ipairs(imports[f] or {}) do
                if not seen[to] then seen[to] = true; queue[#queue + 1] = to end
            end
        end
    end
    for f in pairs(files) do
        local s = res.by_file[f]
        if not s then
            res.orphans[#res.orphans + 1] = f
        else
            local n = 0; for _ in pairs(s) do n = n + 1 end
            if n > 1 then res.shared[#res.shared + 1] = f end
        end
    end
    table.sort(res.orphans); table.sort(res.shared)
    return res
end

--- The stages whose surface holds the ROOT of `name`, or nil when the name is not
--- stage-scoped at all — a bare name, a SHARED namespace (`string`, `table`,
--- `defines`), or a root the profile never modelled. nil means "the partition has
--- nothing to say about this", which is not the same as a refusal and must not be
--- reported as one.
function M.stage_owners_of(prof, name)
    local owners = prof and prof.stage_owners
    if not (owners and name) then return nil end
    local root = name:match('^([%w_]+)[%.:#]')
    if not root then return nil end
    return owners[root]
end

--- THE THIRD OUTCOME. Returns 'provided' | 'out-of-region' | nil, plus the stages
--- that do hold the name. nil = the partition has no opinion (see above).
---
--- THE RULE IS INTERSECTION, NOT MEMBERSHIP: a file loaded at two stages must
--- satisfy BOTH, so EVERY stage the file belongs to has to provide the name. Using
--- "any stage provides it" would bless a helper that works when control.lua pulls
--- it in and crashes when data.lua does — which is exactly the bug a stage axis
--- exists to catch.
---
--- "Exists, but not at this stage" is a FINDING, and a stronger statement than "not
--- provided" — the same reason a version DIFF beats an absence. It must never render
--- as an absence.
function M.region_verdict(prof, name, stageset)
    local owners = M.stage_owners_of(prof, name)
    if not owners then return nil end
    if not stageset or next(stageset) == nil then return nil end -- stage unknown: do not rule
    for s in pairs(stageset) do
        if not owners[s] then
            local list = {}
            for o in pairs(owners) do list[#list + 1] = o end
            table.sort(list)
            return 'out-of-region', list, s
        end
    end
    return 'provided', nil, nil
end

--- Is this call site evaluated when the FILE IS LOADED — i.e. at module level
--- rather than inside a function body? Only a module-level site is decidable by a
--- stage partition: Lua runs a function body when it is CALLED, so a runtime-only
--- name inside a function of a data-stage file is a violation only if something
--- calls that function at the data stage, which needs per-stage call reachability.
local function module_level(store, c)
    local callrec = require 'cartograph.callrec'
    local owner = callrec.fn(c)
    if not owner then return true end -- no enclosing function at all
    local nd = store.node and store.node(owner)
    if not nd then return true end
    return nd.kind ~= 'function' and nd.kind ~= 'method'
end

--- Is `root` a LOCAL at this call site — a parameter, an assigned local, or a loop
--- binding — rather than the environment's global of that name? Mirrors the locality
--- set externals.references builds, for the same reason.
---
--- MEASURED NECESSITY: without this, ALL FIVE of the factorio corpus's out-of-region
--- findings are false. Four are `data` as a function PARAMETER carrying event data
--- (`function teleport_to_zone(data) … data.player.teleport(…)`); one is `data` as a
--- module-level local holding GUI state. `data` is a data-stage global in the
--- partition and those files are runtime-stage, so every one looked like a violation.
---
--- CALLED ONLY WHEN A FINDING IS ABOUT TO BE EMITTED, which is what makes it
--- affordable: expr.of re-parses the enclosing function (~3.5 ms), so paying that per
--- SITE would cost seconds on a large corpus (719 sites on this one), while paying it
--- per CANDIDATE FINDING costs nothing in the normal case of none. Sound in the only
--- direction that matters — a shadowed local can turn a real finding into silence but
--- never the reverse, so checking late can only remove false positives.
local function shadowed_local(store, c, root)
    local callrec = require 'cartograph.callrec'
    local expr = require 'cartograph.expr'
    store._stage_shadow = store._stage_shadow or {}
    local owner, is_mod = callrec.fn(c), false
    if not owner then
        -- a MODULE-level call: the enclosing scope is the module's statement run
        for _, n in ipairs((store.data or {}).nodes or {}) do
            if n.kind == 'module' and n.file == callrec.file(c) then
                owner, is_mod = n.id, true; break
            end
        end
        if not owner then return false end
    else
        local nd = store.node and store.node(owner)
        is_mod = nd ~= nil and nd.kind == 'module'
    end
    local set = store._stage_shadow[owner]
    if set == nil then
        set = {}
        local ok, eo = pcall(is_mod and expr.of_module or expr.of, store, owner)
        local fl = ok and eo and eo.fl
        if fl then
            for _, pn in ipairs(fl.params or {}) do set[pn] = true end
            for _, r in ipairs(fl.stmts or {}) do
                for _, d in ipairs(r.def or {}) do set[d] = true end
            end
            for bn in pairs((ok and eo and eo.bound) or {}) do set[bn] = true end
        end
        store._stage_shadow[owner] = set
    end
    return set[root] == true
end

--- EVERY SITE where a stage-scoped name is used, judged against the stage its file
--- is loaded at. Returns nil when the profile declares no stages, else a list of
--- { name, file, line, loaded_at, provided_at } plus `sites` (how many were judged)
--- and `shadowed` (how many candidate findings a local of that name refuted).
---
--- WHY THIS WALKS CALL RECORDS AND NOT THE REQUIREMENT SET. requires() is built
--- from the SILENT external surface — calls that resolved to nothing and were not
--- even refused — and a name the profile PROVIDES is never in it: `game.print`
--- either MINTS to LuaGameScript::print (so it resolves) or is refused as `vocab`.
--- Either way it never reaches requires(), which means the requirement set cannot
--- see exactly the names a stage partition exists to judge. Measured: wiring the
--- check to requires() found nothing on a fixture built to contain two obvious
--- violations.
---
--- SOUNDNESS: a call that resolved to a PROJECT-DEFINED node is skipped. `game` may
--- be someone's local variable, and if resolution found a real definition for it
--- then this is not the environment's `game` at all. Minted profile nodes (whose
--- `file` is the profile's own runtime name) and unresolved/refused calls are the
--- uses of the global.
function M.stage_sites(store, prof)
    local sm = M.stage_map(store, prof)
    if not sm then return nil end
    local callrec = require 'cartograph.callrec'
    local data = (store or {}).data or {}
    local out, judged, shadowed, withheld =
        { sites = 0, shadowed = 0, withheld = 0 }, 0, 0, 0
    for _, c in callrec.each(data) do
        local full = callrec.full(c)
        local root = full and full:match('^([%w_]+)[%.:]')
        local owners = root and prof.stage_owners and prof.stage_owners[root]
        if owners then
            local to = callrec.to(c)
            local target = to and store.node and store.node(to)
            local is_project = target and target.file and target.file ~= prof.runtime
                and sm.by_file[target.file] ~= nil
            if not is_project then
                local file = callrec.file(c)
                local at = file and sm.by_file[file]
                if at and next(at) then
                    judged = judged + 1
                    local verdict, provided_at = M.region_verdict(prof, full, at)
                    -- the locality check is LAST, so it costs per candidate finding
                    -- rather than per site. A local named `data` or `game` is not the
                    -- environment's global of that name and must not be judged.
                    if verdict == 'out-of-region' and shadowed_local(store, c, root) then
                        shadowed = shadowed + 1
                    elseif verdict == 'out-of-region' and not module_level(store, c) then
                        -- INSIDE A FUNCTION BODY, so it is NOT DECIDABLE here. Lua
                        -- evaluates a body only when the function is CALLED, so a
                        -- runtime-only name inside a function of a data-stage-loaded
                        -- file is a violation only if that function is called at the
                        -- data stage — which needs per-stage call reachability. And the
                        -- Factorio idiom for a stage-agnostic helper is to NIL-GUARD
                        -- the global: space-exploration/scripts/log.lua:32 is literally
                        -- `if Log.debug_prints and game then game.print(…) end`.
                        -- Measured: judging these produced 17 findings on the factorio
                        -- corpus and every one was false. Withheld and COUNTED, never
                        -- silently dropped.
                        withheld = withheld + 1
                    elseif verdict == 'out-of-region' then
                        local loaded = {}
                        for s in pairs(at) do loaded[#loaded + 1] = s end
                        table.sort(loaded)
                        out[#out + 1] = { name = full, file = file, line = c.line,
                            loaded_at = loaded, provided_at = provided_at }
                    end
                end
            end
        end
    end
    out.sites, out.shadowed, out.withheld = judged, shadowed, withheld
    table.sort(out, function (a, b)
        if a.name ~= b.name then return a.name < b.name end
        if (a.file or '') ~= (b.file or '') then return (a.file or '') < (b.file or '') end
        return (a.line or 0) < (b.line or 0)
    end)
    return out, sm
end

--- How many symbols the profile actually claims — the weight of any verdict.
function M.profile_size(prof)
    local n = 0
    for _, field in ipairs({ 'vocab', 'free', 'sigs' }) do
        for _ in pairs(prof[field] or {}) do n = n + 1 end
    end
    return n
end

--- THE SYMMETRIC INVERSION ([[cartograph-portability-lever]] keystone): the code
--- has a profile too. An environment profile says what it PROVIDES; this derives
--- what the code REQUIRES, in the same currency — so every question downstream
--- is set algebra over the two:
---   portability to T      = requires.names ⊆ T.provides
---   version floor         = max of requires.features
---   tightest environment  = the smallest T that covers requires.names  (M.rank)
---   dependency manifest   = requires.names grouped by WHO provides them (M.manifest)
--- Returns { names = {name -> calls}, where = {name -> file}, files = {name -> sorted
--- list of files}, langs = set, features = {version facts}, floor, total }.
---
--- `where` IS A SAMPLE, `files` IS THE POPULATION — the same split externals.references
--- makes, for the same reason (CART-0215). `where` keeps its historical meaning, the
--- ALPHABETICALLY FIRST file of the base, so no existing count moves; anything asking
--- which environment a name lives in must read `files`, because until it existed the
--- honest answer was unavailable and the audit picked by filename order.
---
--- GRANULARITY, stated because it bounds what can be built on this: `files` comes from
--- the BASE's file set, so `data.raw` and `data.extend` share one list. That is the
--- right grain for the environment question — the base (`game`, `data`, `script`) is
--- exactly what a stage partition scopes — and the wrong grain for anything per-member.
function M.requires(store)
    local externals = require 'cartograph.externals'
    local s = externals.surface(store)
    local r = { names = {}, where = {}, files = {}, langs = {}, total = 0 }
    local fileset = {}
    for base, e in pairs(s.bases) do
        local first
        for f in pairs(e.files) do
            if not first or f < first then first = f end
        end
        local function add(name, n)
            r.names[name] = (r.names[name] or 0) + n
            r.where[name] = r.where[name] or first
            local fs = fileset[name]
            if not fs then fs = {}; fileset[name] = fs end
            for f in pairs(e.files) do fs[f] = true end
        end
        -- a bare call names the base itself; members name base.member. Both can
        -- occur for one base (`Foo()` and `Foo.bar()`), so neither is exclusive.
        if e.bare > 0 or next(e.members) == nil then add(base, e.bare > 0 and e.bare or e.calls) end
        for m, n in pairs(e.members) do add(base .. '.' .. m, n) end
    end
    for _ in pairs(r.names) do r.total = r.total + 1 end
    for name, fs in pairs(fileset) do
        local l = {}
        for f in pairs(fs) do l[#l + 1] = f end
        table.sort(l)
        r.files[name] = l
    end
    -- the VERSION half of the same requirement set
    local ts = require 'cartograph.providers.treesitter'
    local ext2lang = {}
    for lang, sp in pairs(ts.spec) do
        for _, e in ipairs(sp.exts or {}) do ext2lang[e] = lang end
    end
    for _, n in ipairs((store.data or {}).nodes or {}) do
        local e = n.file and n.file:match('%.([%w]+)$')
        local l = e and ext2lang[e:lower()]
        if l then r.langs[l] = true end
    end
    local vf = require 'cartograph.versionfloor'
    r.features = vf.facts(store)
    for _, f in ipairs(r.features) do
        if not r.floor or vf.older(r.floor, f.v) then r.floor = f.v end
    end
    r.scale = nil
    for l in pairs(r.langs) do
        if vf.SCALE[l] then r.scale = vf.SCALE[l] end
    end
    return r
end

--- Rank every shipped profile of a matching language by how much of the code's
--- requirement set it covers — the "tightest environment" query. COVERAGE, not a
--- verdict: a profile covering everything is not proof the code runs there, only
--- that this boundary holds no counter-evidence.
---
--- Returns (ranked, req, skipped). ONLY NAMES-TARGETS ARE RANKED, and the rest are
--- RETURNED rather than dropped (CART-0209): scoring the three runtime-api artifacts
--- printed `lua-factorio-api-20  0.0% covered`, which reads as a claim that Factorio
--- 2.0 provides none of this mod's names when it is a fact about a key space. Nor may
--- they vanish — five skipped artifacts and a silent list is the
--- absence-rendered-as-silence class, so `skipped` carries each one's reason.
function M.rank(store)
    local pm = require 'cartograph.spec.profile'
    local req = M.requires(store)
    local out, skipped = {}, {}
    for _, runtime in ipairs(M.runtimes()) do
        local prof = pm.load(runtime)
        if prof and (not prof.lang or req.langs[prof.lang])
            and not M.target_kinds(prof).names then
            -- the reason carries NO artifact name, so the report can group the three
            -- runtime-api artifacts under one sentence instead of printing it thrice
            local data = M.target_kinds(prof).data
            skipped[#skipped + 1] = { runtime = runtime, size = M.profile_size(prof),
                data = data, measure = measure_of(prof),
                reason = data and data_only_reason() or target_refusal(prof) }
        elseif prof and (not prof.lang or req.langs[prof.lang]) then
            local hit, miss = 0, 0
            for name in pairs(req.names) do
                if M.provides(prof, name) then
                    hit = hit + 1
                else
                    miss = miss + 1
                end
            end
            out[#out + 1] = { runtime = runtime, size = M.profile_size(prof),
                provided = hit, unknown = miss, queryable = M.name_queryable(prof),
                pct = (hit + miss) > 0 and (hit / (hit + miss) * 100) or 0 }
        end
    end
    -- best coverage first; on a tie the SMALLER profile is the tighter fit
    table.sort(out, function (a, b)
        -- a non-queryable artifact is not "worst", it is UNRANKABLE: sink it so
        -- it never reads as the tightest or the loosest fit
        if a.queryable ~= b.queryable then return a.queryable end
        if math.abs(a.pct - b.pct) > 0.001 then return a.pct > b.pct end
        return a.size < b.size
    end)
    table.sort(skipped, function (a, b) return a.runtime < b.runtime end)
    return out, req, skipped
end

--- Group the requirement set by WHO provides it — the dependency manifest. A name
--- no shipped profile claims is left in its own bucket, NOT called external: it
--- is most often a sibling module or a third-party dependency.
---
--- NAMES-TARGETS ONLY, same as rank. An ingredient claiming 3 free functions would
--- otherwise appear as a co-owner (`lua-factorio+lua-factorio-api`) of the names it
--- shares with the profile that republishes it — a provider group naming a file that
--- is an input to another entry in the same list.
function M.manifest(store)
    local pm = require 'cartograph.spec.profile'
    local req = M.requires(store)
    local profs = {}
    for _, runtime in ipairs(M.runtimes()) do
        local p = pm.load(runtime)
        if p and (not p.lang or req.langs[p.lang]) and M.target_kinds(p).names then
            profs[#profs + 1] = { runtime = runtime, prof = p }
        end
    end
    local groups, unclaimed = {}, {}
    for name, calls in pairs(req.names) do
        local owners = {}
        for _, e in ipairs(profs) do
            if M.provides(e.prof, name) then
                owners[#owners + 1] = e.runtime
            end
        end
        if #owners == 0 then
            unclaimed[#unclaimed + 1] = { name = name, calls = calls }
        else
            local key = table.concat(owners, '+')
            groups[key] = groups[key] or { names = 0, calls = 0 }
            groups[key].names = groups[key].names + 1
            groups[key].calls = groups[key].calls + calls
        end
    end
    table.sort(unclaimed, function (a, b)
        if a.calls ~= b.calls then return a.calls > b.calls end
        return a.name < b.name
    end)
    return groups, unclaimed, req
end

--- WHY A NAME IS NOT IN THE PROFILE — which is a different question from whether
--- the environment has it, and conflating the two is how a list of things the
--- artifact cannot see got labelled "candidate porting work".
---
--- MEASURED on lua-factorio (2026-07-26), which is what these buckets are shaped
--- by rather than guessed at:
---   · the artifact distils METHODS ONLY. LuaGameScript::get_player and ::print are
---     in it; ::tick, ::players, ::surfaces, ::entity_prototypes are NOT. So a miss
---     on a global's member says nothing — game.entity_prototypes (genuinely renamed
---     in 2.0) is indistinguishable from game.tick (perfectly fine in 2.0).
---   · it models GLOBAL-ROOTED calls only (tools/factoriodistill.lua:6-11 says so),
---     so a receiver-typed name has no representation at all. On the Von Neumann mod
---     that is 66 of 92 names.
---   · Factorio EXTENDS the Lua stdlib namespaces (table.deepcopy via lualib) and
---     the profile omits those, so even a "complete" stdlib namespace is not a
---     closed set to test against.
---
--- THAT HAS CHANGED for the enumerated classes. The distiller now emits attributes
--- as well as methods (220 members, 104 of them attributes, across 9 classes) and
--- DECLARES which classes are fully enumerated. Inside a complete class a miss IS
--- evidence: `game.entity_prototypes` is absent from 2.0.72 because it was renamed
--- to prototypes.entity, while `game.tick` is present — the two are now
--- distinguishable, which is precisely what the methods-only artifact could not do.
--- So `absent` exists, and ONLY for names a complete class could have held. Every
--- other miss keeps its blindness label, because the artifact still models
--- global-rooted calls only and the stdlib namespaces are still not closed sets.
--- Returns 'other-language' | 'absent' | 'receiver-typed' |
--- 'unenumerated-namespace' | 'unclaimed-bare'. `where` is where the name was seen —
--- ONE file or a LIST of them; a name from files of ANOTHER language is not the
--- profile's business at all — one zipper.py in a Factorio mod put 13 python names in
--- this list, and calling them "a sibling module or a third-party dependency" was a
--- label I knew to be wrong. The audit-level guard only refuses when the profile's
--- language is absent ENTIRELY, so a mixed corpus reaches here.
---
--- THE SAMPLED VERDICT IS GONE (CART-0215). This used to take one file, because
--- requires() kept only the alphabetically first, so a name seen in two languages was
--- classified by whichever filename sorted first. Now the whole population decides,
--- and the rule is the honest one: a name is another language's business only if NO
--- file it appears in is this profile's language. A helper called from both zipper.py
--- and control.lua is squarely the lua profile's business, and the old form could
--- rule that out on filename order alone.
-- ── THE RECEIVER AXIS (CART-0587) ───────────────────────────────────────────
-- `receiver-typed` was the largest non-answer on every Factorio corpus (48 of 92
-- names / 101 calls on Von-Neumann) and it was ONE bucket saying "no
-- representation at all". lua/cartograph/classmatch.lua supplies the missing key:
-- an unresolved base's observed member set picks a class out of the environment's
-- DECLARED class table, and the target's class-keyed member set is exactly the key
-- space portability could never reach. So a receiver-typed name becomes
-- adjudicable — hedged twice over, and split by WHY when it is not.
--
-- ★ THE HEADLINE FINDING, and it is structural rather than a property of this
-- corpus. `requires()` builds its names FROM externals.surface, so every
-- `base.member` it holds contributed head(member) to that base's SHAPE; and
-- `determined` MEANS one class declares every member of the shape. Therefore a
-- determined base's class declares every one of its members BY CONSTRUCTION, and
-- ADJUDICABLE-ABSENT IS STRUCTURALLY EMPTY down this path. Measured: 27 present, 8
-- chain, 7 ambiguous, 6 no-match, 0 absent. Nothing here can mint porting work, and
-- a build of this feature that reported some would be reporting a bug.
--
-- WHAT IT IS WORTH ANYWAY, stated so the group text does not overclaim: the
-- evidence is at the BASE, not the name. A 2.0 removal among a base's members would
-- have broken the subset match and dropped the base into `no-match` or `near-miss`
-- — so a determined base is a statement that NONE of its members is a removal. It
-- is not 27 independent verifications, and the report says so.
--
-- THE ONE PATH THAT COULD EVER MINT AN ABSENCE is the NEAR MISS: a shape one member
-- away from a single overlapping class. Von-Neumann has zero (15 of 15 no-match
-- bases are UNRELATED), so nothing is built on it here beyond keeping it a separate
-- bucket — folding a near miss into "not an API object" would mislabel the only
-- future absence signal there is.

--- The class-table context an audit adjudicates receivers against, or (nil, why).
--- `why` NAMES THE MECHANISM: an unavailable axis must read as unavailable, never
--- as an empty result (which is what a bare `receiver-typed` list looks like).
---
--- ★ THE VERSION/LANGUAGE GUARD IS THE WHOLE SAFETY ARGUMENT. classmatch answers
--- from whichever artifact carries a class table, which today is the 2.0.72 export.
--- Adjudicating a 1.1 audit — or a ruby one — against it would turn a version
--- mismatch into confident member verdicts, which is the failure mode of 44b8a2a
--- (v5 keys read against a v6 document, 104 confident nonsenses). So the table must
--- describe the SAME language at the SAME version as the profile being reported on,
--- and when it does not, the axis is simply absent and says why.
function M.receiver_context(store, prof, origin)
    local cm = require 'cartograph.classmatch'
    local ct, why = cm.table(nil)
    if not ct then return nil, ('no class table to adjudicate receivers with (%s)')
        :format(tostring(why)) end
    local m = ct.meta or {}
    if prof.lang and m.lang and m.lang ~= prof.lang then
        return nil, ('the only class table available describes %s (%s), not %s')
            :format(tostring(m.lang), tostring(m.artifact), tostring(prof.lang))
    end
    if tostring(m.version) ~= tostring(prof.version) then
        return nil, ('the only class table available is %s %s, and this verdict is'
            .. ' about %s — a class table from another version would turn a version'
            .. ' mismatch into member verdicts, so receivers are left unadjudicated')
            :format(tostring(m.artifact), tostring(m.version), tostring(prof.version))
    end
    local surf = require('cartograph.externals').surface(store)
    local ev = {}
    for base, e in pairs(surf.bases or {}) do ev[base] = cm.match(e.members, ct) end
    local rc = { ct = ct, ev = ev, meta = m, tier = cm.TIER,
        to_space = cm.space(ct) }
    -- THE ORIGIN SIDE (CART-0631): a class table for the version being ported FROM,
    -- so a member name can be decided against both spaces. Optional, and its
    -- absence leaves every zero-match name exactly where it was.
    --
    -- ⚠ FENCED THE SAME WAY THE TARGET IS, and for a sharper reason. This verdict
    -- is a DIFFERENCE between two artifacts, so an origin table from the wrong
    -- version does not merely weaken it — it manufactures removals out of the
    -- version skew itself, which is the one failure the whole axis exists to
    -- avoid. `from_why` is REPORTED, never silently dropped: an origin that could
    -- not be loaded must not read as an origin that found nothing.
    if origin then
        local oct, owhy = cm.table(origin)
        if not oct then
            rc.from_why = ('no class table for the origin %s (%s)')
                :format(tostring(origin), tostring(owhy))
        else
            local om = oct.meta or {}
            if m.lang and om.lang and om.lang ~= m.lang then
                rc.from_why = ('the origin class table describes %s, the target %s')
                    :format(tostring(om.lang), tostring(m.lang))
            elseif tostring(om.version) == tostring(m.version) then
                rc.from_why = ('the origin and target class tables are both %s %s —'
                    .. ' a version diffed against itself decides nothing')
                    :format(tostring(om.artifact), tostring(om.version))
            else
                rc.from_ct, rc.from_meta = oct, om
                rc.from_space = cm.space(oct)
                -- THE ORIGIN-SIDE SHAPE MATCH, built here for the same reason `ev`
                -- is: one subset test per BASE, not per name. CART-0632.
                rc.ev_from = {}
                for base, e in pairs(surf.bases or {}) do
                    rc.ev_from[base] = cm.match(e.members, oct)
                end
            end
        end
    end
    return rc
end

--- ADJUDICATE ONE RECEIVER-TYPED NAME against a class table. PURE: everything it
--- needs arrives as arguments, so every branch — including the ones a real corpus
--- cannot currently produce — is directly constructible in a spec.
--- Returns (reason, detail) or nil when the name is not receiver-shaped / has no
--- evidence, in which case the caller keeps the unrefined `receiver-typed`.
---
--- ★ AMBIGUOUS AND ZERO GET THEIR OWN REASONS AND NEVER THE ABSENT ONE. "Several
--- classes declare this shape" and "no class does" are two ways of NOT KNOWING; a
--- build that folded either into "the target lacks it" would invent porting work
--- out of its own uncertainty, which is the failure this whole axis exists to
--- avoid. They are not even adjacent in the code — each returns its own key.
function M.receiver_verdict(ct, name, ev)
    if not ct or not ev then return nil end
    local base, rest = name:match('^([%w_]+)[.:](.+)$')
    if not base or not rest then return nil end
    -- the base's class declares the FIRST segment; `player.character.insert` is a
    -- chain whose first hop is the attribute `character` (classmatch.head)
    local hop = rest:match('^([%w_]+)')
    if not hop then return nil end
    local deep = rest:find('[.:]', #hop + 1) ~= nil
    local d = { base = base, member = hop, chain = deep and rest or nil,
        n = ev.n, outcome = ev.outcome }
    if ev.outcome == 'determined' then
        d.class, d.tier, d.hedge = ev.class, ev.tier, ev.hedge
        local c = ct.classes[ev.class]
        if not (c and c.all[hop]) then
            -- STRUCTURALLY UNREACHABLE from a real surface today (see the header):
            -- the shape that picked this class contains `hop`. Kept, and specced
            -- through this pure entry point, because the day the shape and the
            -- adjudicated name come from different populations this is the branch
            -- that must exist — a silent fold into `present` would be the bug.
            return 'receiver-class-absent', d
        end
        return (deep and 'receiver-class-chain' or 'receiver-class-present'), d
    elseif ev.outcome == 'ambiguous' then
        d.ncand, d.candidates = ev.ncand, ev.candidates
        return 'receiver-ambiguous', d
    elseif ev.outcome == 'zero' then
        d.nearest, d.distance, d.overlap = ev.nearest, ev.distance, ev.overlap
        -- THE PREDICATE IS classmatch's, NOT A RE-DERIVATION. Its definition is
        -- load-bearing and was measured wrong once already (minimum-miss over ALL
        -- classes calls every single-member base "one away"); a second copy here
        -- would be a second chance to get it wrong.
        return (require('cartograph.classmatch').unrelated(ev)
            and 'receiver-nomatch' or 'receiver-nearmiss'), d
    end
    -- 'no-shape' cannot arise for a dotted name (the member IS the shape), so this
    -- is a matcher that changed under us: keep the unrefined bucket rather than
    -- guessing which of the refined ones it meant.
    return nil
end

--- THE CLASS-SPACE VERDICT (CART-0631) — decide a member name against BOTH
--- versions' whole class spaces, WITHOUT typing the receiver.
---
--- ★★ THE SOUNDNESS IS ASYMMETRIC AND IT FAVOURS A PORT. If NO class in the
--- target declares the name, no amount of receiver typing could have saved the
--- call — so the REMOVAL verdict holds without knowing what the receiver is. The
--- PRESENCE direction is weaker: a name existing on SOME target class does not
--- prove it exists on the RIGHT one, which is why `supplied` here is not
--- "present in the target" but the strictly stronger SUBSET test below.
---
--- Returns (verdict, detail) or nil when either space is missing:
---   member-removed        declared in the source, by NO class in the target.
---                         A port item. Sound.
---   not-a-runtime-member  declared by no class in EITHER — a mod library or the
---                         language's own stdlib. NOT a port item, and NOT a
---                         frontier: it is a decided "this was never API".
---   member-supplied       every class that declared it still does. Sound: any
---                         receiver that worked before still works.
---   member-moved          the target still declares it, but NOT on every class
---                         that used to. A receiver-dependent hazard — the one
---                         outcome that genuinely needs the receiver, and it must
---                         NOT be folded into either neighbour.
---
--- ⚠ THE FOUR ARE NOT THREE. `member-moved` looks like `member-supplied` from a
--- presence test and like `member-removed` from the receiver's point of view, and
--- it is neither: folding it up invents porting work, folding it down hides a real
--- break. Measured 1.1.110 -> 2.0.77: 1474 supplied, 273 removed, 87 MOVED — the
--- moved bucket is 5% of the space and would be invisible under a presence test.
function M.class_space_verdict(from_space, to_space, member)
    if not from_space or not to_space or type(member) ~= 'string' then return nil end
    local a, b = from_space[member], to_space[member]
    if not a and not b then return 'not-a-runtime-member', { from_n = 0, to_n = 0 } end
    local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
    local na, nb = count(a), count(b)
    if a and not b then
        local cls = {}
        for cn in pairs(a) do cls[#cls + 1] = cn end
        table.sort(cls)
        return 'member-removed', { from_n = na, to_n = 0, from_classes = cls }
    end
    if not a and b then return nil end -- gained: says nothing about porting FROM
    local lost = {}
    for cn in pairs(a) do if not b[cn] then lost[#lost + 1] = cn end end
    if #lost == 0 then return 'member-supplied', { from_n = na, to_n = nb } end
    table.sort(lost)
    return 'member-moved', { from_n = na, to_n = nb, lost_classes = lost }
end

--- THE SHAPE-MOVE VERDICT (CART-0632) — did the base's WHOLE OBSERVED SHAPE
--- survive the move, for every class the receiver could have been?
---
--- ★★ THE UNIT OF A PORT QUESTION ABOUT A RECEIVER IS THE SHAPE, NOT THE MEMBER,
--- and the evidence that was missing is the ORIGIN's candidate set. Match the
--- observed members against BOTH class tables:
---     O = classes in the ORIGIN declaring every observed member
---     T = classes in the TARGET declaring every observed member
---     O \ T = the plausible origin receivers that no longer support this shape
---
--- ⚠ TWO EARLIER FORMULATIONS OF THIS TEST ARE VACUOUS BY CONSTRUCTION, and both
--- look like features. (1) "does every candidate declare the member" — the
--- candidate set was BUILT by requiring every observed member, so it is always
--- yes; measured 7 of 7 on Von-Neumann. (2) "did any candidate lose it" — a
--- candidate is a TARGET class that declares it, so none can have. Only the
--- ORIGIN-side match carries information, and nothing computed it.
---
--- Returns (verdict, detail) or nil when either side has no candidates:
---   shape-survives   O ⊆ T. Every class the receiver could have been still
---                    declares everything this code does with it. ★ SOUND
---                    WITHOUT RESOLVING THE AMBIGUITY — the port's own premise
---                    is that the code worked under the origin, so the real
---                    receiver was in O.
---   shape-broken     O ∩ T = ∅. NO plausible origin receiver supports the shape
---                    any more. Real porting work, whichever class it was.
---   shape-at-risk    some of O dropped out. The named classes are the ones that
---                    break; whether this call does depends on which it is.
---
--- ⚠ THE SCOPE OF `shape-survives` IS THE OBSERVED SHAPE, NEVER THE RECEIVER. It
--- says every use THIS CODE MAKES survives, not that nothing about the object
--- changed — the shape is what the mod happens to touch. `n` rides in the detail
--- for the same reason classmatch publishes it: a one-member shape admits a broad
--- candidate set and the conclusion is correspondingly weak.
function M.shape_move_verdict(ev_from, ev_to, to_ct, hop)
    local function cands(ev)
        if not ev then return nil end
        if ev.class then return { ev.class } end
        return ev.candidates
    end
    local O, T = cands(ev_from), cands(ev_to)
    if not O or #O == 0 or not T or #T == 0 then return nil end
    if not to_ct or type(hop) ~= 'string' then return nil end
    -- ⚠ THE VERDICT IS PER NAME, NOT PER BASE, and the first cut got this wrong.
    -- `railbotUnit`'s shape {set_command, surface} is supported by no 2.0 class, so
    -- a base-level answer marked ALL THREE names on it as broken — including
    -- `railbotUnit.surface.create_entity`, which is fine, because LuaEntity kept
    -- `surface` and only lost `set_command`. A shape verdict is how the RECEIVER
    -- HYPOTHESIS SET is computed; what breaks is decided one member at a time.
    local kept, lost = {}, {}
    for _, c in ipairs(O) do
        local cls = to_ct.classes and to_ct.classes[c]
        if cls and cls.all[hop] then kept[#kept + 1] = c else lost[#lost + 1] = c end
    end
    if #lost == 0 then return nil end -- this member survives on every candidate
    local d = { n = ev_to.n, n_origin = #O, origin_classes = O,
        lost_classes = lost, kept_classes = kept, member = hop }
    if #kept == 0 then return 'shape-broken', d end
    return 'shape-at-risk', d
end

--- THE SAME VERDICT FOR A WHOLE DOTTED NAME, not one member. A chain
--- (`event.element.parent.destroy`) is several member accesses and ALL of them
--- must survive the move, so the name is decided by its strongest segment.
---
--- PRECEDENCE: removed > moved > supplied > not-a-runtime-member. Removed wins
--- because one broken hop breaks the call; not-a-runtime-member LOSES to
--- everything because it is the weakest claim in a mixed chain — a chain with one
--- real class member and one event-table field did not stop being API.
---
--- ⚠ SEGMENTING IS FENCED, because these names are not all identifiers. A
--- call-shaped key (`crash_site.createEntity{name="…"}.set_recipe`) has a TABLE
--- LITERAL in the middle, and splitting it on dots would invent members out of
--- whatever the literal contains. So a PURE dotted chain is decomposed and
--- anything else contributes only its TRAILING member — the one actually invoked.
--- `segments` rides in the detail so a reader can see which names were asked
--- about rather than trusting that the split did what it looks like.
function M.class_space_name(from_space, to_space, name)
    if not from_space or not to_space or type(name) ~= 'string' then return nil end
    local base, rest = name:match('^([%w_]+)[.:](.+)$')
    if not base or not rest then return nil end
    local segs = {}
    -- ⚠ THE OBVIOUS PATTERN IS NOT A LUA PATTERN. `^[%w_]+([.:][%w_]+)*$` reads
    -- like a dotted-chain test and is not one: Lua has no group repetition, so `*`
    -- applies to the closing paren and the match simply fails. Every chain then
    -- fell through to the trailing-member branch and the decomposition was dead
    -- code that looked alive — a spec on `segments` is what caught it. The
    -- CHARACTER-SET test says the same thing and is expressible: a pure chain
    -- contains nothing but name characters and separators.
    if rest:match('^[%w_%.:]+$') then
        for seg in rest:gmatch('[%w_]+') do segs[#segs + 1] = seg end
    else
        local last = rest:match('([%w_]+)$')
        if last then segs[1] = last end
    end
    if #segs == 0 then return nil end
    local RANK = { ['member-removed'] = 4, ['member-moved'] = 3,
        ['member-supplied'] = 2, ['not-a-runtime-member'] = 1 }
    local best, bestd, bestseg
    for _, seg in ipairs(segs) do
        local v, d = M.class_space_verdict(from_space, to_space, seg)
        if v and (not best or RANK[v] > RANK[best]) then best, bestd, bestseg = v, d, seg end
    end
    if not best then return nil end
    bestd.segments, bestd.member = segs, bestseg
    return best, bestd
end

--- One rendered cell of receiver evidence, for the item line. THE HEDGE IS IN THE
--- TEXT, not only in the bucket: `~` is the project's mark for a hypothesis and `n`
--- is the quantity that decides how much to believe it (classmatch's two known
--- wrong answers are BOTH n=1, and it deliberately hardcodes no threshold).
function M.receiver_cell(d)
    if not d then return '' end
    -- ⚠ THE CLASS-SPACE VERDICTS MUST NOT WEAR THE RECEIVER'S CELL (CART-0631).
    -- They are refined OUT of a zero-match, so `d` still carries that evidence, and
    -- rendering it printed `n=1 no overlapping class` — a FRONTIER statement — on a
    -- row asserting a sound removal. The reader is then told the tool found nothing
    -- and that the name is gone, on the same line. What belongs here is where the
    -- member USED to live, which is the fact the verdict actually rests on.
    if d.origin_classes and d.lost_classes and #d.lost_classes > 0 then
        -- the shape-move rows: WHICH classes could it have been, and which broke
        if #d.lost_classes == #d.origin_classes then
            return ('was %s, none of which still declares %s (n=%d)')
                :format(table.concat(d.origin_classes, ' or '),
                    tostring(d.member), d.n or 0)
        end
        return ('%s lose it, %d other candidate(s) keep it (n=%d)')
            :format(table.concat(d.lost_classes, ', '),
                #d.origin_classes - #d.lost_classes, d.n or 0)
    end
    if d.from_classes then
        return ('was on %s, on no target class'):format(table.concat(d.from_classes, ', '))
    elseif d.lost_classes then
        return ('lost by %s, kept by %d other(s)')
            :format(table.concat(d.lost_classes, ', '), (d.to_n or 0))
    elseif d.from_n == 0 and d.to_n == 0 then
        return 'declared by no class in either version'
    elseif d.from_n and d.to_n and not d.class then
        return ('on %d class(es) before, %d after'):format(d.from_n, d.to_n)
    end
    if d.class then
        return ('~%s n=%d%s'):format(d.class, d.n or 0,
            (d.n == 1) and ' SINGLE-MEMBER HYPOTHESIS' or '')
    elseif d.ncand then
        return ('%d candidate classes n=%d'):format(d.ncand, d.n or 0)
    elseif d.outcome == 'zero' then
        local near = (d.nearest or {})[1]
        return near and ('n=%d nearest ~%s, %d away'):format(d.n or 0, near.class,
            near.missing) or ('n=%d no overlapping class'):format(d.n or 0)
    end
    return ''
end

function M.unknown_reason(prof, name, where, rctx)
    local files = type(where) == 'table' and where or { where }
    if prof.lang then
        local known, mine = false, false
        for _, f in ipairs(files) do
            local ext = type(f) == 'string' and f:match('%.([%w]+)$')
            local lang = ext and ext_lang()[ext:lower()]
            if lang then
                known = true
                if lang == prof.lang then mine = true end
            end
        end
        if known and not mine then return 'other-language' end
    end
    local root, member = name:match('^([%w_]+)[.:]([%w_]+)$')
    -- ABSENT: the root is a global whose documented class is FULLY enumerated, and
    -- the member is not in it. The only bucket that is evidence about the target
    -- rather than about the artifact.
    if root and member then
        local cls = (prof.global2class or {})[root]
        if cls and (prof.api_complete or {})[cls]
            and not (prof.api_members or {})[cls .. '::' .. member] then
            return 'absent'
        end
    end
    -- THE RECEIVER AXIS. Reached only after every question that is NOT about a
    -- receiver has been settled above — another language's name, and a member of a
    -- FULLY ENUMERATED global's class, both keep their answers. `rctx` is optional
    -- and its absence is exactly the pre-CART-0587 behaviour, so a caller that
    -- cannot supply a class table (or an environment where none applies) still gets
    -- the bucket it always got rather than a silent nil.
    local function receiver(nm)
        if not rctx then return 'receiver-typed' end
        local b = nm:match('^([%w_]+)[.:]')
        local why, d = M.receiver_verdict(rctx.ct, nm, b and rctx.ev[b])
        -- THE CLASS-SPACE REFINEMENT (CART-0631). Reached ONLY for a name the
        -- receiver axis could not type — a zero-match base, which is where a real
        -- removal was found hiding as a frontier. A name whose receiver IS typed
        -- keeps that answer: the class-space test is strictly weaker evidence
        -- about a known receiver than the receiver's own class table entry.
        --
        -- ⚠ AMBIGUOUS IS DELIBERATELY NOT REFINED. classmatch has narrowed it to
        -- 2-6 candidate classes and the decisive question there is whether EVERY
        -- candidate declares the member — a different and stronger test than "any
        -- class anywhere does". Answering the weak question over the strong one
        -- would trade a narrow honest hedge for a broad confident guess.
        -- THE SHAPE-MOVE TEST (CART-0632) runs for a name whose receiver WAS
        -- typed — the opposite population to the class-space refinement below.
        -- It only REPLACES the bucket when it finds porting work: `shape-survives`
        -- leaves `receiver-class-present` / `receiver-ambiguous` exactly where they
        -- were and rides along as evidence, because losing the class hypothesis to
        -- gain a weaker word would be a bad trade.
        --
        -- ⚠ APPLIED TO DETERMINED AND AMBIGUOUS ALIKE, and the measurement is why:
        -- Von-Neumann's one at-risk base (`railbotUnit`, shape {set_command,
        -- surface}) is 1.1-AMBIGUOUS but 2.0-DETERMINED, so it sits in the
        -- class-present bucket today. An ambiguous-only build would have missed the
        -- single real finding this axis produces. The determined bucket has the
        -- identical weakness and its own text already admits it.
        -- the three buckets that rest on a TARGET-side match and nothing else.
        -- `receiver-class-absent` is deliberately NOT here: it is already porting
        -- work on its own evidence, and overriding it would swap a sharper verdict
        -- for a broader one.
        local SHAPE_TESTABLE = { ['receiver-class-present'] = true,
            ['receiver-class-chain'] = true, ['receiver-ambiguous'] = true }
        if b and rctx.ev_from and why and SHAPE_TESTABLE[why] then
            local hop = d and d.member
            local sv, sd = M.shape_move_verdict(rctx.ev_from[b], rctx.ev[b],
                rctx.ct, hop)
            if sv then
                d = d or {}
                for k, v in pairs(sd) do if d[k] == nil then d[k] = v end end
                d.receiver_was = why
                return sv, d
            end
        end
        if (why == 'receiver-nomatch' or why == 'receiver-nearmiss')
            and rctx.from_space then
            local cv, cd = M.class_space_name(rctx.from_space, rctx.to_space, nm)
            if cv then
                if d then for k, v in pairs(d) do if cd[k] == nil then cd[k] = v end end end
                cd.receiver_was = why
                return cv, cd
            end
        end
        if why then return why, d end
        return 'receiver-typed'
    end
    if not root then
        -- a dotted CHAIN (a.b.c) or a call-shaped key: still receiver-typed, since
        -- nothing but the first segment could ever be a modelled namespace
        local first = name:match('^([%w_]+)[.:]')
        if first and not (prof.nsset or {})[first] then return receiver(name) end
        if first then return 'unenumerated-namespace' end
        return 'unclaimed-bare'
    end
    if (prof.nsset or {})[root] then return 'unenumerated-namespace' end
    return receiver(name)
end

-- ext -> language, from the specs themselves (memoised: the spec table does not
-- change within a process)
local _ext_lang
function ext_lang()
    if _ext_lang then return _ext_lang end
    _ext_lang = {}
    local ok, ts = pcall(require, 'cartograph.providers.treesitter')
    if ok then
        for lang, sp in pairs(ts.spec or {}) do
            for _, e in ipairs(sp.exts or {}) do _ext_lang[e:lower()] = lang end
        end
    end
    return _ext_lang
end

local ext_lang

-- A name's provenance as one report cell: the first file, plus a COUNT of the others.
-- Naming one file out of several and staying silent about the rest is the class this
-- repo keeps rediscovering (absence rendered as silence) — the reader cannot tell
-- "seen here" from "seen here and in four more", and the difference is exactly what a
-- stage or language question turns on. `files` may be nil (a caller that only kept a
-- sample), in which case this degrades to that sample and claims nothing.
local function where_text(files, sample)
    local first = (files and files[1]) or sample or ''
    local n = files and #files or 0
    if n > 1 then return ('%s (+%d)'):format(first, n - 1) end
    return first
end
--- A long reason as report lines: first line prefixed, continuations indented under
--- it. Reasons NAME THE MECHANISM, so they are sentences rather than labels, and a
--- 250-column line in a scratch buffer is a reason nobody reads.
local function reason_lines(prefix, text, cont)
    local out, line = {}, prefix
    local first = true
    for word in text:gmatch('%S+') do
        if not first and #line + 1 + #word > 78 then
            out[#out + 1] = line
            line = cont .. word
        else
            line = first and (line .. word) or (line .. ' ' .. word)
        end
        first = false
    end
    out[#out + 1] = line
    return out
end

-- HOISTED above the reports (it used to sit between two of them, so M.report
-- referenced a local that was still nil at call time the moment it needed one).
-- ⚠ EVERY KEY HERE MUST APPEAR IN M.REASON_ORDER. The report walks the ORDER,
-- so a key with text and no slot builds a group that is never printed and the
-- reader silently sees fewer names than the header counts. tests fence the pair.
M.REASON_TEXT = {
    ['absent'] = 'ABSENT FROM THE TARGET — the documented class for this global is'
        .. ' FULLY enumerated (methods and attributes) and does not hold the name.'
        .. ' This is the group that is real porting work.',
    ['other-language'] = 'ANOTHER LANGUAGE — seen in files this profile does not'
        .. ' describe, so it is not the profile\'s business. Scoring them here was'
        .. ' noise: exclude those files, or score them against their own runtime.',
    ['receiver-typed'] = 'RECEIVER-TYPED, UNADJUDICATED — the artifact models'
        .. ' global-rooted calls only, so these have no representation in it at all,'
        .. ' and no class table for THIS environment version was available to match'
        .. ' the receiver\'s shape against. Their absence is not evidence about the'
        .. ' target. (The header above says which class table was missing and why.)',
    -- ── the receiver axis (CART-0587). EVERY ONE OF THESE RIDES A HYPOTHESIS: the
    -- class was picked by matching the base's OBSERVED member set against the
    -- environment's declared class table, on the `inferred` rung, never `stdlib`.
    -- None of them may read like the authoritative `provided by` section below.
    ['receiver-class-absent'] = 'RECEIVER-TYPED, HYPOTHESISED CLASS LACKS THE MEMBER —'
        .. ' the base\'s observed shape picks exactly one declared class, and that'
        .. ' class does not declare this member. CANDIDATE porting work, and STRICTLY'
        .. ' WEAKER than the ABSENT group above: that one rests on a global the'
        .. ' profile NAMES, this one on a shape-match hypothesis that is measured'
        .. ' wrong at low member counts. Check `n` on each line before believing it.',
    ['receiver-nearmiss'] = 'RECEIVER-TYPED, NEAR MISS — no class declares the whole'
        .. ' observed shape, but one is within a single member of it. NOT adjudicated:'
        .. ' this is the one pattern that could mean "the target removed that member",'
        .. ' and it is equally what a mod that decorates an API object looks like.'
        .. ' Kept apart from the no-match group precisely so it is not mislabelled.',
    ['receiver-nomatch'] = 'RECEIVER-TYPED, NOT AN API OBJECT — no class declares the'
        .. ' observed shape and none comes within one member of it, so the base is'
        .. ' most likely a mod-local table. NOT adjudicable, and for a DIFFERENT'
        .. ' reason than the rest: there is no class to look the member up in. ⚠ A'
        .. ' member the target REMOVED produces this same signal (nothing declares'
        .. ' it), and telling the two apart needs a class table for the OLD version.'
        .. ' ⚠ THAT LAST SENTENCE USED TO END "which the 1.1 artifact does not carry"'
        .. ' AND IT IS NO LONGER TRUE — the 1.1 artifact carries 97 classes since the'
        .. ' CART-0586 re-distil, and CART-0631 uses them. Pass an origin profile and'
        .. ' these names are decided; this group is what is left when none was given.',
    ['receiver-ambiguous'] = 'RECEIVER-TYPED, AMBIGUOUS CLASS — several declared'
        .. ' classes declare every member observed on the base, so the shape does not'
        .. ' pick one. NOT adjudicable, and explicitly NOT missing: "I cannot tell'
        .. ' which class" must never be rendered as "the target lacks it".',
    ['receiver-class-chain'] = 'RECEIVER-TYPED, FIRST HOP ONLY — the base\'s shape picks'
        .. ' one class and that class declares the FIRST segment, but the name'
        .. ' continues through it (a.b.c) and the class table carries member NAMES'
        .. ' without member TYPES, so the deeper hop cannot be followed. Partially'
        .. ' adjudicated; the tail is not.',
    ['receiver-class-present'] = 'RECEIVER-TYPED, CONSISTENT WITH THE TARGET — the'
        .. ' base\'s observed shape picks exactly one declared class and that class'
        .. ' declares this member. ★ READ THIS WEAKLY: the class was CHOSEN because'
        .. ' it declares every member observed on the base, so "it declares this one"'
        .. ' is not independent evidence. What the match does say is at the BASE:'
        .. ' had the target removed ANY member used on it, no class would have'
        .. ' matched and the base would appear in a group above. Not `provided` —'
        .. ' that count means a symbol the profile NAMES.',
    -- ── the class-space axis (CART-0631). These need NO receiver: they ask the
    -- two versions' whole class spaces about a member NAME. The removal direction
    -- is SOUND (no class declares it, so no receiver could have reached it); the
    -- supplied direction is the strictly stronger SUBSET test, never bare presence.
    ['member-removed'] = 'REMOVED FROM THE TARGET\'S CLASS SPACE — the origin version'
        .. ' declares this member on at least one class and the target declares it on'
        .. ' NONE. ★ THIS NEEDS NO RECEIVER AND IS SOUND WITHOUT ONE: if no class in'
        .. ' the target has the name, no receiver could have reached it. Real porting'
        .. ' work, on the same footing as ABSENT above, and reached only for names the'
        .. ' receiver axis could not type.',
    ['member-moved'] = 'MOVED OFF SOME CLASSES — the target still declares this member,'
        .. ' but NOT on every class that used to declare it. Whether the call breaks'
        .. ' depends on which class the receiver actually is, which is exactly what'
        .. ' could not be determined. ⚠ NOT foldable into either neighbour: it reads as'
        .. ' SUPPLIED to a presence test and as REMOVED from the losing class\'s point'
        .. ' of view, and it is neither. The lost classes are named on each line.',
    ['member-supplied'] = 'SUPPLIED BY THE TARGET — every class that declared this'
        .. ' member in the origin still declares it. Sound whichever class the receiver'
        .. ' is, which is why this is a SUBSET test and not "some class has the name":'
        .. ' bare presence would have swallowed the MOVED group above.',
    ['not-a-runtime-member'] = 'NOT A RUNTIME MEMBER — no class in EITHER version'
        .. ' declares this name, so it never was part of the environment. A mod'
        .. ' library or the language\'s own stdlib. ★ A DECIDED ANSWER, not a'
        .. ' frontier: it was previously indistinguishable from "we could not type the'
        .. ' receiver", and it is no work at all rather than unknown work.',
    -- ── the shape-move axis (CART-0632). The unit is the base's OBSERVED SHAPE and
    -- the missing evidence was the ORIGIN's candidate set: which classes declared
    -- everything this code does with the base, BEFORE the move.
    ['shape-broken'] = 'NO PLAUSIBLE RECEIVER STILL HAS THIS MEMBER — the base\'s'
        .. ' whole observed shape names the classes it could have been under the'
        .. ' ORIGIN, and NONE of them declares this member in the target. ★ SOUND'
        .. ' WITHOUT RESOLVING THE RECEIVER: the port\'s premise is that this code'
        .. ' ran under the origin, so the real class was one of them, and every one'
        .. ' of them lost this member. Real porting work; the classes are named.',
    ['shape-at-risk'] = 'SOME PLAUSIBLE RECEIVERS LOST THIS MEMBER — of the classes'
        .. ' the base could have been under the origin, some no longer declare it.'
        .. ' Whether this call breaks depends on which one the receiver actually is,'
        .. ' and that is what the shape does not pin down. ⚠ THE VERDICT IS PER'
        .. ' MEMBER, NOT PER BASE: a sibling call on the same base may be perfectly'
        .. ' fine, which is why they are listed separately rather than condemned'
        .. ' together. The losing classes are named on each line.',
    ['unenumerated-namespace'] = 'NAMESPACE MEMBER, NOT ENUMERATED — the root IS a'
        .. ' modelled namespace but the artifact distils METHODS only (and omits'
        .. ' lualib extensions), so a miss here says nothing either way.',
    ['unclaimed-bare'] = 'BARE AND UNCLAIMED — no shipped profile claims these.'
        .. ' Most often a sibling module or a third-party dependency, NOT a gap in'
        .. ' the environment.',
}

--- THE PRESENTATION ORDER of the reason groups, and the report's ONLY list of
--- them. `absent` FIRST: it is the one group that says anything about the target on
--- the profile's own authority. Then the receiver axis, ordered by how much it
--- CLAIMS — the hedged near-porting-work first, the merely consistent last — so a
--- reader who stops after two groups has read the strongest statements.
M.REASON_ORDER = { 'absent', 'member-removed', 'shape-broken',
    'receiver-class-absent', 'shape-at-risk', 'member-moved',
    'receiver-nearmiss', 'receiver-nomatch',
    'receiver-ambiguous', 'receiver-class-chain', 'receiver-class-present',
    'member-supplied', 'receiver-typed', 'unenumerated-namespace',
    'not-a-runtime-member', 'unclaimed-bare', 'other-language' }

--- Audit the open graph against a target runtime profile.
--- Returns (result, err) where result = { runtime, size, provided, unknown,
--- entries = { {name, calls, provided, why, files} } }.
function M.audit(store, runtime, opts)
    local prof = require('cartograph.spec.profile').load(runtime)
    if not prof then
        return nil, ('no profile named %q (profiles ship under spec/profile/)'):format(runtime)
    end
    -- A profile for another language would mark EVERY name not-provided, which
    -- looks like a devastating verdict and means nothing. Refuse instead.
    local ts = require 'cartograph.providers.treesitter'
    local ext2lang = {}
    for lang, sp in pairs(ts.spec) do
        for _, e in ipairs(sp.exts or {}) do ext2lang[e] = lang end
    end
    local present = {}
    for _, n in ipairs((store.data or {}).nodes or {}) do
        local e = n.file and n.file:match('%.([%w]+)$')
        local l = e and ext2lang[e:lower()]
        if l then present[l] = true end
    end
    if prof.lang and next(present) and not present[prof.lang] then
        local got = {}
        for l in pairs(present) do got[#got + 1] = l end
        table.sort(got)
        return nil, ('%s is a %s profile, but this graph is %s — nothing to compare')
            :format(runtime, prof.lang, table.concat(got, '/'))
    end
    -- …AND THE SAME REFUSAL FOR AN ARTIFACT THAT CANNOT ANSWER A NAME QUESTION
    -- (CART-0209). M.diff was fenced and this, the SINGLE-target path, was not — so
    -- `:CartographPortability lua-factorio-api-11` printed a header asserting 294
    -- claimed symbols and then 92 names of "candidate porting work", every one of them
    -- an artifact-shaped fact. The fence is the same predicates diff uses, so the two
    -- verbs cannot disagree about what is auditable.
    local _, kinds = M.targetable(runtime)
    if type(kinds) == 'string' then
        return nil, kinds
    elseif not kinds.names then
        -- the SAME sentence the report prints, from the same function: a verb and a
        -- report disagreeing about why an artifact was skipped is how one of them
        -- ends up carrying a label borrowed from an unrelated case
        return nil, ('%s (%s) is %s'):format(runtime, measure_of(prof),
            data_only_reason())
    end
    -- one requirement set, scored against this profile: the audit is now just
    -- `requires ∩ provides`, which is what the keystone says it should be
    local req = M.requires(store)
    local res = { runtime = runtime, lang = prof.lang, version = prof.version,
        size = M.profile_size(prof), provided = 0, unknown = 0, entries = {},
        out_of_region = {} }
    -- THE STAGE PARTITION (CART-0216), only when the profile declares one. Its
    -- population is the CALL SITES, not this requirement set: a name the profile
    -- provides never reaches requires() (it mints or is refused), so the axis has to
    -- read the calls directly. See stage_sites.
    local sites, sm = M.stage_sites(store, prof)
    res.stages = sm
    if sites then
        res.out_of_region = sites
        res.stage_sites = sites.sites
        res.stage_shadowed, res.stage_withheld = sites.shadowed, sites.withheld
    end
    -- THE RECEIVER AXIS (CART-0587), built ONCE for the whole audit: it needs the
    -- external surface and a 148-class subset test per base, and a per-name rebuild
    -- would pay both 92 times. Unavailable is a REPORTED state, not a silent skip —
    -- `res.receiver.why` is printed, because a bucket that quietly stops refining
    -- looks exactly like a bucket with nothing to refine.
    -- THE ORIGIN, NAMED OR DERIVED. An explicit `opts.from` always wins; otherwise
    -- the manifest's own declaration picks it (M.origin_for), because the tree
    -- already says which version it targets and asking twice would be a worse
    -- interface than reading it. `auto` records which happened, so a reader never
    -- has to guess whether an origin was chosen for them.
    local from, auto, ofwhy = opts and opts.from, false, nil
    if not from then
        from, ofwhy = M.origin_for(store, runtime)
        auto = from ~= nil
    end
    local rctx, rwhy = M.receiver_context(store, prof, from)
    res.receiver = { available = rctx ~= nil, why = rwhy,
        meta = rctx and rctx.meta or nil, tier = rctx and rctx.tier or nil }
    -- THE ORIGIN IS REPORTED WHETHER OR NOT IT LOADED (CART-0631), for the reason
    -- res.receiver.why exists: a refinement that quietly did not run looks exactly
    -- like one with nothing to refine. `asked` distinguishes the third state — no
    -- origin was named at all — from an origin that was named and refused.
    res.origin = { asked = from, auto = auto or nil,
        available = (rctx and rctx.from_space) ~= nil,
        why = (rctx and rctx.from_why) or (not from and ofwhy) or nil,
        meta = rctx and rctx.from_meta or nil }
    for name, n in pairs(req.names) do
        local w = M.provides(prof, name)
        local files = req.files[name] or { req.where[name] }
        local why, rdet
        if w == nil then why, rdet = M.unknown_reason(prof, name, files, rctx) end
        local entry = { name = name, calls = n,
            provided = w ~= nil, why = w,
            -- the class hypothesis this entry's reason rests on (class, n, the
            -- candidate list, the nearest classes) — carried on the ENTRY so a
            -- consumer reading entries alone sees the hedge, not just the bucket
            receiver = rdet,
            -- EVERY file, not the sampled one: `files` is what a stage/language
            -- question has to read (CART-0215). Falls back to the sample so an
            -- entry always carries at least one, as it always has.
            files = files,
            reason = why }
        res.entries[#res.entries + 1] = entry
        -- `provided` KEEPS ITS MEANING — "the environment holds this name" — so no
        -- existing count moves. An entry whose name appears in the out-of-region site
        -- list is TAGGED, so a consumer reading entries alone still sees the third
        -- disposition rather than a bare "provided".
        if w and res.out_of_region then
            for _, s in ipairs(res.out_of_region) do
                if s.name == name then entry.region = 'out-of-region'; break end
            end
        end
        if w then res.provided = res.provided + 1 else res.unknown = res.unknown + 1 end
    end
    table.sort(res.entries, function (a, b)
        if a.provided ~= b.provided then return not a.provided end -- unknown first
        if a.calls ~= b.calls then return a.calls > b.calls end
        return a.name < b.name
    end)
    return res
end

--- MOVING between environments: audit the SAME requirement set under two
--- profiles and diff the outcomes. The names whose status changes are the porting
--- work — which is why this is small: requires() already guarantees both sides
--- score the same set, so nothing can drift between them.
--- Returns (result, err); result = { from, to, lost, gained, kept, neither }.
function M.diff(store, from, to)
    local a, erra = M.audit(store, from)
    if not a then return nil, erra end
    local b, errb = M.audit(store, to)
    if not b then return nil, errb end
    local pm = require 'cartograph.spec.profile'
    for _, rt in ipairs({ from, to }) do
        local prof = pm.load(rt)
        if prof and not M.name_queryable(prof) then
            return nil, ('%s is a signature-keyed artifact with no name surface —'
                .. ' a diff against it would call everything lost'):format(rt)
        end
        -- …and the same refusal for the DOTTED surface, which is where a port
        -- actually lives (`global.x`, `game.entity_prototypes`). Without this a
        -- profile whose member table is unreadable still passes the bare-name fence
        -- on a handful of free functions and then reports a serene "0 LOST" — which
        -- is what happened, on a mod with two real breaking changes. Refusing is the
        -- honest answer: the diff cannot see the surface it is being asked about.
        if prof and not M.dotted_queryable(prof) then
            return nil, ('%s cannot adjudicate a DOTTED name (no api_members / types /'
                .. ' namespaces) — a MOVE diff against it would report every rename as'
                .. ' unchanged'):format(rt)
        end
    end
    local res = M.diff_entries(a, b)
    res.size_from, res.size_to = M.profile_size(pm.load(from)), M.profile_size(pm.load(to))
    return res
end

--- The pure comparison of two audit results — the whole semantic of a move, with
--- no disk in it, so it is testable without inventing profile artifacts. Both
--- audits score the SAME requirement set, so a name present in one and absent
--- from the other is a genuine status change rather than a set mismatch.
function M.diff_entries(a, b)
    local bystatus = {}
    for _, e in ipairs(b.entries) do bystatus[e.name] = e.provided end
    local res = { from = a.runtime, to = b.runtime, lost = {}, gained = {},
        kept = 0, neither = 0 }
    for _, e in ipairs(a.entries) do
        local inB = bystatus[e.name]
        if e.provided and not inB then
            res.lost[#res.lost + 1] = { name = e.name, calls = e.calls, why = e.why,
                file = e.files and e.files[1], files = e.files }
        elseif not e.provided and inB then
            res.gained[#res.gained + 1] = { name = e.name, calls = e.calls }
        elseif e.provided then
            res.kept = res.kept + 1
        else
            res.neither = res.neither + 1
        end
    end
    local function bycalls(x, y)
        if x.calls ~= y.calls then return x.calls > y.calls end
        return x.name < y.name
    end
    table.sort(res.lost, bycalls)
    table.sort(res.gained, bycalls)
    return res
end

--- The diff as lines. Direction matters and the wording says so.
function M.diff_report(store, from, to, opts)
    local res, err = M.diff(store, from, to)
    if not res then return { 'portability: ' .. err } end
    local cap = (opts and opts.cap) or 20
    local L = {}
    L[#L + 1] = ('portability — MOVING FROM %s TO %s'):format(res.from, res.to)
    L[#L + 1] = ('  %d name(s) LOST, %d gained, %d provided by both, %d by neither')
        :format(#res.lost, #res.gained, res.kept, res.neither)
    L[#L + 1] = ('  profiles claim %d and %d symbols — a thin target inflates "lost"')
        :format(res.size_from, res.size_to)
    L[#L + 1] = ''
    if #res.lost == 0 then
        L[#L + 1] = ('  nothing %s provides is absent from %s'):format(res.from, res.to)
    else
        L[#L + 1] = ('  LOST — %s provides these, %s does not (the porting work):')
            :format(res.from, res.to)
        for i = 1, math.min(cap, #res.lost) do
            local e = res.lost[i]
            L[#L + 1] = ('    %-34s %4d call(s)  %s'):format(e.name, e.calls,
                where_text(e.files, e.file))
        end
        if #res.lost > cap then
            L[#L + 1] = ('    … +%d more'):format(#res.lost - cap)
        end
        L[#L + 1] = '  Still NOT "missing": the target artifact may simply be thinner,'
        L[#L + 1] = '  and a dependency may supply the name in either environment.'
    end
    if #res.gained > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('  GAINED — %s provides these and %s did not:'):format(res.to, res.from)
        if #res.gained > #res.lost then
            -- lua-factorio ⊇ luajit, so that move only loses. ruby-rails does NOT
            -- contain plain ruby core, so it gains — read that as the profiles
            -- covering different ground, not as the target being richer.
            L[#L + 1] = '    (more gained than lost: these two profiles OVERLAP rather'
            L[#L + 1] = '    than nest, so this is a coverage difference between the'
            L[#L + 1] = '    artifacts — not evidence that the target is richer)'
        end
        for i = 1, math.min(5, #res.gained) do
            L[#L + 1] = ('    %-34s %4d call(s)'):format(res.gained[i].name, res.gained[i].calls)
        end
        if #res.gained > 5 then
            L[#L + 1] = ('    … +%d more'):format(#res.gained - 5)
        end
    end
    return L
end

--- THE VERSION THIS CODE DECLARES IT TARGETS, on the same ruler as the profile
--- being scored against — or nil. The link is by NAME: a runtime called
--- `lua-factorio` has an ecosystem spec of the same name, whose `version_scale`
--- says which ruler its environment versions sit on, and versionfloor reads the
--- declaration out of the package manifest.
---
--- This is the fact that turns "score against some profile" into "you are porting
--- 1.1 -> 2.0". It was sitting in info.json, in a file the resolver ALREADY parses,
--- and the report never read it — so the header printed the artifact's version and
--- said nothing about the code's.
function M.declared_for(store, runtime)
    local root = (store.data or {}).root
    if not root or root:match('^%w+://') then return nil end
    local ok_e, ecomod = pcall(require, 'cartograph.spec.ecosystem')
    if not ok_e then return nil end
    local eco = ecomod.load(runtime)
    local scale = eco and (eco.identity or {}).version_scale
    if not scale then return nil end
    return require('cartograph.versionfloor').declared(root, scale)
end

--- THE ORIGIN ARTIFACT FOR A DECLARED MOVE (CART-0631) — which shipped class
--- table describes the version this code SAYS it targets, or nil with the reason.
---
--- ★ THE CALLER ALREADY TOLD US. `M.declared_for` reads factorio_version "1.1" out
--- of info.json; a profile is per MINOR (apifetch: patch releases share one), so
--- the origin is the artifact whose class table sits on that minor. Making the
--- user name it twice — once in the manifest, once on the command — would be
--- asking for a fact the tree already carries.
---
--- ⚠ MATCHED ON THE MINOR AND NOTHING LOOSER. A declared "1.1" accepts 1.1.110 and
--- refuses 2.0.77; it does NOT fall back to "the only class table around", because
--- the whole verdict is a DIFFERENCE and a wrong origin manufactures removals out
--- of version skew. No origin is a fine answer — a wrong one is not.
function M.origin_for(store, runtime)
    local decl = M.declared_for(store, runtime)
    if not decl then return nil, 'the tree declares no environment version' end
    local minor = tostring(decl.raw):match('^(%d+%.%d+)')
    if not minor then
        return nil, ('the declared version %q is not major.minor'):format(tostring(decl.raw))
    end
    local cm = require 'cartograph.classmatch'
    local prof = require 'cartograph.spec.profile'
    local tried = {}
    for _, name in ipairs(cm.ARTIFACTS or {}) do
        local art = prof.load(name)
        if art and tostring(art.version):match('^' .. vim.pesc(minor) .. '%.') then
            local ct = cm.table(name)
            if ct then return name, nil, decl end
            tried[#tried + 1] = name .. ' (no class table)'
        end
    end
    return nil, ('%s declares %s %s but no shipped artifact carries a class table for'
        .. ' that minor%s'):format(tostring(decl.source), tostring(decl.scale),
        tostring(decl.raw), #tried > 0 and (' — tried ' .. table.concat(tried, ', ')) or '')
end

--- WHY A REFERENCED name is not provided. Sharper than the call-side classifier,
--- and only because references are LOCALITY-FILTERED: externals.references already
--- dropped anything rooted at a parameter, a local, or a project def, so a root the
--- profile does not know is not "some receiver" — it is a global the target
--- environment does not define. That is the strongest porting signal available:
--- `global.savedRailbots` reads a 1.1 global that 2.0 removed in favour of
--- `storage`, and on the Von Neumann mod there are 44 such reads.
--- Returns 'unknown-root' | 'absent' | 'unenumerated-namespace'.
function M.ref_reason(prof, name)
    local root, member = name:match('^([%w_]+)%.([%w_]+)')
    if not root then return 'unknown-root' end
    local cls = (prof.global2class or {})[root]
    if cls and (prof.api_complete or {})[cls] then
        if member and not (prof.api_members or {})[cls .. '::' .. member] then
            return 'absent'
        end
        return 'unenumerated-namespace'
    end
    if (prof.nsset or {})[root] then return 'unenumerated-namespace' end
    return 'unknown-root'
end

local REF_TEXT = {
    ['unknown-root'] = 'ROOT NOT IN THE TARGET — the environment does not define this'
        .. ' global at all. Not a receiver: references are locality-filtered, so a'
        .. ' parameter or local was already excluded. This is real porting work.',
    ['absent'] = 'MEMBER ABSENT — the root is a documented global whose class is'
        .. ' fully enumerated, and it does not hold this member. Real porting work.',
    ['unenumerated-namespace'] = 'PRESENT, or not adjudicable — the root is known and'
        .. ' the member either exists or sits in a namespace the artifact does not'
        .. ' enumerate.',
}

--- The REFERENCE surface, adjudicated. Separate from the call audit on purpose: a
--- read and a call are different evidence, and folding them would move every
--- existing count. Returns display lines, or {} when nothing is referenced.
function M.reference_report(store, runtime, opts)
    local prof = require('cartograph.spec.profile').load(runtime)
    if not prof then return {} end
    local refs = require('cartograph.externals').references(store)
    if refs.total == 0 then
        -- A TYPED EMPTY, not silence (CART-0224 step 2). Returning {} here made the
        -- whole section vanish, so a user who paid for the expensive opt-in could not
        -- tell "this corpus reads nothing external" from "we do not model this
        -- language's reads at all". Measured on a ruby corpus: 2303 functions, 0 with
        -- an expression record, section absent entirely.
        if (refs.unmodelled or 0) > 0 and (refs.analysed or 0) == 0 then
            local ls = {}
            for l, n in pairs(refs.unmodelled_langs or {}) do
                ls[#ls + 1] = ('%s (%d fn)'):format(l, n)
            end
            table.sort(ls)
            return { '', '  REFERENCED but not called — NOT COMPUTED for this corpus:',
                ('    the expression layer does not model %s, so %d function(s) were'):format(
                    #ls > 0 and table.concat(ls, ', ') or 'this language',
                    refs.unmodelled),
                '    never examined. This is not "no external reads" — it is no answer.' }
        end
        return { '', '  REFERENCED but not called — none: '
            .. ('%d function(s) examined and no qualified read of an undefined name found')
                :format(refs.analysed or 0) }
    end
    local cap = (opts and opts.cap) or 12
    local groups = {}
    for name, n in pairs(refs.names) do
        local why = M.ref_reason(prof, name)
        local g = groups[why]
        if not g then g = { n = 0, reads = 0, items = {} }; groups[why] = g end
        g.n = g.n + 1; g.reads = g.reads + n
        g.items[#g.items + 1] = { name = name, reads = n, file = refs.where[name],
            files = refs.files[name] }
    end
    local L = { '' }
    L[#L + 1] = ('  REFERENCED but not called — %d name(s) read, never invoked:')
        :format(refs.total)
    L[#L + 1] = '    (a second surface: the call audit above cannot see these, because'
    L[#L + 1] = '     a name that is read and never called produces no call record.)'
    if (refs.withheld or 0) > 0 then
        L[#L + 1] = ('    %d name(s) WITHHELD — their root is touched in only one'):format(refs.withheld)
        L[#L + 1] = '     function, where a loop-bound local is indistinguishable from a'
        L[#L + 1] = '     global until per-language binder nodes are specified.'
    end
    for _, key in ipairs({ 'unknown-root', 'absent', 'unenumerated-namespace' }) do
        local g = groups[key]
        if g then
            table.sort(g.items, function (a, b)
                if a.reads ~= b.reads then return a.reads > b.reads end
                return a.name < b.name
            end)
            L[#L + 1] = ''
            L[#L + 1] = ('    %d name(s), %d read(s) — %s'):format(g.n, g.reads,
                REF_TEXT[key])
            for i = 1, math.min(cap, #g.items) do
                local e = g.items[i]
                L[#L + 1] = ('      %-36s %4d read(s)  %s'):format(e.name, e.reads,
                    where_text(e.files, e.file))
            end
            if #g.items > cap then
                L[#L + 1] = ('      … and %d more'):format(#g.items - cap)
            end
        end
    end
    return L
end

--- MAY these two runtimes be reference-diffed at all? The PRECONDITION of
--- M.reference_diff, lifted out as a predicate for two callers: one that wants to
--- ask before running, and this module's own header claim, which is checked by
--- tools/docaudit.lua. Lifted rather than restated — a check that reimplements
--- what it checks drifts away from it, which is the exact failure this fence
--- exists for (CART-0595). Returns (true, nil, prof_from, prof_to) or
--- (false, reason).
function M.diffable_pair(from, to)
    local pm = require 'cartograph.spec.profile'
    local a, b = pm.load(from), pm.load(to)
    if not a then return false, ('unknown runtime %q'):format(from) end
    if not b then return false, ('unknown runtime %q'):format(to) end
    if a.lang ~= b.lang then
        return false, ('%s is %s and %s is %s — different languages'):format(
            from, tostring(a.lang), to, tostring(b.lang))
    end
    -- THE READS DIFF NEEDS THE DOTTED FENCE MOST. A read that breaks a port is almost
    -- always dotted (`global.x`, `game.entity_prototypes`), so a profile that cannot
    -- adjudicate a dotted name reports "nothing read here was removed" — the most
    -- reassuring sentence in the tool, from the artifact least able to say it. The
    -- calls diff refuses for the same reason; leaving this path unfenced meant the
    -- refusal was printed for calls and contradicted for reads in one report.
    for rt, prof in pairs({ [from] = a, [to] = b }) do
        if not M.dotted_queryable(prof) then
            return false, ('%s cannot adjudicate a DOTTED name (no api_members / types /'
                .. ' namespaces) — the READ surface is where a port breaks, so a diff'
                .. ' against it would call every rename unchanged'):format(rt)
        end
    end
    return true, nil, a, b
end

--- THE VERSION DIFF OVER THE READ SURFACE — the strongest evidence this tool can
--- produce about a port. M.diff scores the requirement set, which is CALL-derived, so
--- on a 1.1 -> 2.0 move it reported 0 lost: every name that actually changed
--- (`game.entity_prototypes`, `global.*`) is READ, never called. This scores
--- externals.references under both profiles instead and reports STATUS CHANGES.
---
--- A change beats an absence. "2.0 does not hold this name" can be a fact about the
--- artifact; "1.1 held it and 2.0 does not" is a fact about the environments, and it
--- survives both artifacts being incomplete in the same way.
--- Returns (result, err); result = { from, to, lost = {…}, gained = {…}, kept }.
function M.reference_diff(store, from, to)
    local ok, why, a, b = M.diffable_pair(from, to)
    if not ok then return nil, why end
    local refs = require('cartograph.externals').references(store)
    local res = { from = from, to = to, lost = {}, gained = {}, kept = 0, neither = 0 }
    for name, n in pairs(refs.names) do
        local in_a, in_b = M.provides(a, name), M.provides(b, name)
        if in_a and not in_b then
            res.lost[#res.lost + 1] = { name = name, reads = n,
                file = refs.where[name], files = refs.files[name], was = in_a }
        elseif in_b and not in_a then
            res.gained[#res.gained + 1] = { name = name, reads = n,
                file = refs.where[name], files = refs.files[name], now = in_b }
        elseif in_a then res.kept = res.kept + 1
        else res.neither = res.neither + 1 end
    end
    local function bycount(x, y)
        if x.reads ~= y.reads then return x.reads > y.reads end
        return x.name < y.name
    end
    table.sort(res.lost, bycount); table.sort(res.gained, bycount)
    return res
end

--- The reference diff as lines. Direction matters and the wording says so.
function M.reference_diff_report(store, from, to, opts)
    local res, err = M.reference_diff(store, from, to)
    if not res then return { 'reference diff: ' .. err } end
    local cap = (opts and opts.cap) or 15
    local L = { ('reference diff — READS moving from %s to %s'):format(res.from, res.to) }
    L[#L + 1] = ('  %d LOST, %d gained, %d unchanged, %d in neither'):format(
        #res.lost, #res.gained, res.kept, res.neither)
    if #res.lost == 0 then
        L[#L + 1] = '  nothing read here was removed between these versions'
    else
        L[#L + 1] = ''
        L[#L + 1] = '  LOST — present in the OLD environment, absent from the new. This is'
        L[#L + 1] = '  the port worklist: a status CHANGE, not an artifact gap.'
        for i = 1, math.min(cap, #res.lost) do
            local e = res.lost[i]
            L[#L + 1] = ('    %-34s %4d read(s)  was: %-18s %s'):format(e.name,
                e.reads, e.was, where_text(e.files, e.file))
        end
        if #res.lost > cap then
            L[#L + 1] = ('    … and %d more'):format(#res.lost - cap)
        end
    end
    if #res.gained > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('  GAINED — %d name(s) the NEW environment holds and the old did'
            .. ' not (already-migrated code, or a name that moved here):'):format(#res.gained)
        for i = 1, math.min(5, #res.gained) do
            L[#L + 1] = ('    %-34s %4d read(s)  %s'):format(res.gained[i].name,
                res.gained[i].reads, where_text(res.gained[i].files,
                    res.gained[i].file))
        end
    end
    return L
end

-- ── THE THIRD SURFACE: the DATA STAGE (CART-0213) ────────────────────────────
-- M.diff scores CALLS, M.reference_diff scores READS, and both are name surfaces.
-- A declarative-data stage is neither: a Factorio mod's data stage is a set of
-- PROTOTYPES whose properties are table keys and field assignments, so no dotted
-- name exists to adjudicate. That is why prototype-api.json ships as an INGREDIENT
-- (see tools/prototypedistill.lua) rather than as a portability target.
--
-- WHY THE OBVIOUS CROSS-REFERENCE FAILS, and what replaces it. Matching a removed
-- property NAME against every `key =` in the tree over-reports uselessly, because a
-- property removed from a few prototypes shares its name with the same property
-- still present on many others: measured on Von-Neumann, `height` matched 44 sites
-- and was lost by exactly ONE prototype, while `name` matched 26 and was never lost
-- at all. The fix is that a prototype CARRIES ITS OWN DISCRIMINATOR — it is copied
-- out of `data.raw[<typename>][<name>]`, or patches one in place — so each property
-- is checked against the property set of the prototype that actually owns it. No
-- receiver typing, no inference, no heuristic.
--
-- WHAT IT CANNOT SEE, stated because a data-stage reading is a LOWER BOUND: the
-- expression IR models a table constructor as an opaque allocation, so a prototype
-- written as a bare literal (`data:extend{{type="x", …}}`) has invisible keys —
-- basis='literal', 24 of Von-Neumann's 54 records. Those are reported as UNREAD,
-- never as clean. Same for a record whose overrides an opaque call may have
-- rewritten (complete=false).

--- A prototype's usable property set: its OWN properties UNION every ancestor's,
--- since the API declares inheritance rather than flattening it. Returns
--- {prop -> 'required'|'optional'} or nil when the name is unknown.
local function proto_props(prof, pn)
    if not pn then return nil end
    prof._propcache = prof._propcache or {}
    local hit = prof._propcache[pn]
    if hit ~= nil then return hit or nil end
    local out, seen, cur, any = {}, {}, pn, false
    while cur and not seen[cur] do
        seen[cur] = true
        if (prof.prototypes or {})[cur] then any = true end
        for k, req in pairs(prof.own_props or {}) do
            local owner, p = k:match('^(.-)::(.+)$')
            if owner == cur and out[p] == nil then out[p] = req end
        end
        cur = (prof.parent or {})[cur]
    end
    local res = any and out or false
    prof._propcache[pn] = res
    return res or nil
end

--- THE PROPERTY SET OF ANY DECLARED TYPE — prototype or CONCEPT (CART-0633), with
--- its parent closure. `proto_props` above answers only for prototypes, because
--- until the distiller emitted `concept_props` there was nothing else to answer for.
function M.type_props(prof, tn)
    if not tn then return nil end
    prof._tpcache = prof._tpcache or {}
    local hit = prof._tpcache[tn]
    if hit ~= nil then return hit or nil end
    local out, seen, cur, any = {}, {}, tn, false
    while cur and not seen[cur] do
        seen[cur] = true
        if (prof.prototypes or {})[cur] or (prof.concept_types or {})[cur] then any = true end
        for _, tbl in ipairs({ prof.own_props or {}, prof.concept_props or {} }) do
            for k, req in pairs(tbl) do
                local owner, pr = k:match('^(.-)::(.+)$')
                if owner == cur and out[pr] == nil then out[pr] = req end
            end
        end
        cur = (prof.parent or {})[cur] or (prof.concept_parent or {})[cur]
    end
    local res = any and out or false
    prof._tpcache[tn] = res
    return res or nil
end

--- WALK A NESTED PATH DOWN THE DECLARED TYPE CHAIN (CART-0633).
--- `animation.layers.hr_version` on a CraftingMachinePrototype: `animation` is an
--- Animation4Way, `layers` on it is an `Animation[]` (the array is transparent —
--- prototypedistill already unwrapped it), and `hr_version` is the property to
--- adjudicate against Animation.
---
--- Returns (owner_type, property) — the type the LAST segment must belong to — or
--- nil plus the segment that could not be resolved.
---
--- ⚠ AN UNRESOLVED HOP IS A REFUSAL, NEVER A PASS. `prop_type` is absent whenever the
--- api declares a union, a dictionary or a tuple (the distiller records only the forms
--- naming exactly one type), and treating absence as "nothing to check here" would
--- turn every un-modelled shape into a silent clean bill. The caller counts these.
function M.walk_path(prof, root, path)
    local segs = {}
    for seg in path:gmatch('[^%.]+') do segs[#segs + 1] = seg end
    if #segs < 2 then return nil, path end
    local cur = root
    for i = 1, #segs - 1 do
        local nxt = (prof.prop_type or {})[cur .. '::' .. segs[i]]
        if not nxt then
            -- the property may be declared by an ANCESTOR, which prop_type keys by
            -- the declaring owner rather than the leaf type
            local seen, up = {}, cur
            while up and not seen[up] and not nxt do
                seen[up] = true
                up = (prof.parent or {})[up] or (prof.concept_parent or {})[up]
                if up then nxt = (prof.prop_type or {})[up .. '::' .. segs[i]] end
            end
        end
        if not nxt then return nil, segs[i] end
        cur = nxt
    end
    return cur, segs[#segs]
end

--- Can this artifact answer a DATA-STAGE question? A third predicate beside
--- name_queryable and dotted_queryable, and separate for the same reason: a runtime
--- artifact answers neither of the others' questions here, and silently scoring a
--- mod's prototypes against one would report every property as fine.
function M.prototype_queryable(prof)
    return prof ~= nil and prof.stage == 'prototype'
        and next(prof.typenames or {}) ~= nil
        and next(prof.own_props or {}) ~= nil
end

--- THE DATA-STAGE DIFF: which properties the mod actually sets stop existing
--- between two prototype-api versions. Returns (result, err); result =
---   { from, to, lost = {…}, gone_type = {…}, kept, unknown_prop,
---     unread = {…}, hedged = {…}, untyped, records }
--- `lost` is the worklist: each entry names the file, line, prototype, typename and
--- property, and whether the property was REQUIRED (a required property that
--- vanished is a different repair from an optional one).
function M.prototype_diff(store, from, to)
    local pm = require 'cartograph.spec.profile'
    local a, b = pm.load(from), pm.load(to)
    if not a then return nil, ('unknown runtime %q'):format(from) end
    if not b then return nil, ('unknown runtime %q'):format(to) end
    for rt, prof in pairs({ [from] = a, [to] = b }) do
        if not M.prototype_queryable(prof) then
            return nil, ('%s cannot answer a DATA-STAGE question (needs a'
                .. ' stage="prototype" artifact with typenames + own_props; a runtime'
                .. ' profile would call every property fine)'):format(rt)
        end
    end
    local protos = require('cartograph.prototypes').all(store)
    if not protos then
        return nil, 'no data stage here — the prototype reading needs an env profile'
            .. ' with a declared prototype adapter'
    end
    local res = { from = from, to = to, lost = {}, stale_delete = {}, gone_type = {},
        kept = 0, unknown_prop = 0, unread = {}, hedged = {}, untyped = 0, records = 0,
        unwalked = 0, unregistered = 0 }
    for _, m in ipairs(protos) do
        for _, p in ipairs(m.protos) do
            res.records = res.records + 1
            -- a copied prototype names its type in `data.raw[<type>][<name>]`; an
            -- inline LITERAL names it in its own `type=` key (CART-0220). Both are
            -- the prototype's own discriminator, so both are exact.
            local ty = (p.base and p.base.type) or (p.patch and p.patch.type)
                or p.declared_type
            local pn_a = ty and a.typenames[ty]
            local pn_b = ty and b.typenames[ty]
            -- UNREAD and UNTYPED are kept DISJOINT: a table-literal prototype has no
            -- base to take a typename from, so every literal is also untyped, and
            -- reporting both counts would double-count the same records — 24 + 28
            -- against 54, which reads as more unadjudicable prototypes than exist.
            -- Each record gets exactly one reason.
            if p.container then
                -- an ARRAY that held prototypes: its elements were expanded into their
                -- own records above, so counting the container too would double-count
                -- the group and then report the container as unadjudicable
                res.records = res.records - 1
            elseif p.basis == 'literal' and not p.declared_type then
                -- ⚠ IS THIS A PROTOTYPE AT ALL? (CART-0637). The reader treats every
                -- table literal bound to a local in a data-stage file as a prototype
                -- CANDIDATE, and in a data-stage file most table literals are not
                -- prototypes — sprite fragments, style tables, colour maps, module
                -- tables. Counting them as unadjudicable prototypes inflated this
                -- frontier about TENFOLD: measured over 135 mods / 7386 records, 1536
                -- unreadable literals of which 1502 NEVER REACHED `data:extend` OR
                -- `data.raw`. On Von-Neumann it was 20 of 20 — `dataRawTypeList`,
                -- `recipeCategoryMap`, `animations`, not one a prototype.
                --
                -- ★★ AN OVERSTATED LOWER BOUND READS AS CAUTION AND COSTS NOTHING
                -- VISIBLE, which is why it survived a whole port exercise. It costs
                -- two things: the instrument looks blinder than it is, and the ~2%
                -- that IS a real gap is buried under noise nobody can sift.
                --
                -- NOT DROPPED, RE-BUCKETED. A literal that should have been
                -- registered and is not is a real finding of a different kind (dead
                -- prototype code), and this count is the only place it could surface.
                if p.registered then
                    res.unread[#res.unread + 1] = { file = m.file, line = p.line,
                        why = (p.unreadable_keys or 0) > 0
                            and 'a table literal whose keys are COMPUTED, so the property'
                                .. ' names are not knowable'
                            or 'a table literal with no `type=` key, so no prototype owns'
                                .. ' its properties' }
                else
                    res.unregistered = (res.unregistered or 0) + 1
                end
            elseif not ty then
                res.untyped = res.untyped + 1
            elseif pn_a and not pn_b then
                -- the data.raw KEY itself is gone: every property under it moves
                res.gone_type[#res.gone_type + 1] = { file = m.file, line = p.line,
                    typename = ty, was = pn_a, name = p.name }
            end
            if p.complete == false then
                local callee = (p.frontiers[1] or {}).callee
                res.hedged[#res.hedged + 1] = { file = m.file, line = p.line,
                    callee = callee }
            end
            local props_a, props_b = proto_props(a, pn_a), proto_props(b, pn_b)
            if props_a and props_b then
                -- BOTH lists: a literal's own constructor entries (`fields`) and any
                -- later mutation (`overrides`). They are separate in the record because
                -- construction is not mutation; the property question wants the union.
                local entries = {}
                for _, ov in ipairs(p.fields or {}) do entries[#entries + 1] = ov end
                for _, ov in ipairs(p.overrides or {}) do entries[#entries + 1] = ov end
                for _, ov in ipairs(entries) do
                    -- the FIRST segment is the property; a deeper path
                    -- (`minable.result`) names a field of the property's own type,
                    -- which needs the concept types and is not adjudicated here
                    local prop = ov.path and ov.path:match('^([%w_]+)')
                    if prop then
                        local in_a, in_b = props_a[prop], props_b[prop]
                        if in_a and not in_b then
                            -- WRITE vs DELETE, and the difference decides the repair.
                            -- `ty == 'nil'` is the expression IR's DECLARED encoding of
                            -- a nil literal (expr.lua:11, a closed schema), so this is
                            -- reading the schema rather than sniffing a value — the
                            -- IR carries a sentinel for nil whose `tostring` is "nil",
                            -- and my first attempt tested `value == nil`, which is
                            -- never true and silently classified all nine deletions
                            -- below as writes.
                            -- 9 of Von-Neumann's 10 hits are deletions, so calling them
                            -- all "a value written to a property that is gone" would be
                            -- a worklist that is 90% wrong about what to do.
                            --
                            -- A DELETION IS STILL WORK, though, and the sneakier kind:
                            -- `x.animation = nil` removed the animation in 1.1; in 2.0
                            -- the property is gone, so the line deletes NOTHING and the
                            -- entity silently keeps its graphics. No crash, no error,
                            -- changed behaviour — which is why these are reported
                            -- separately rather than filtered out.
                            local entry = { file = m.file, line = ov.line,
                                typename = ty, proto = pn_a, prop = prop,
                                required = in_a == 'required', name = p.name,
                                path = ov.path, hedged = p.complete == false }
                            if ov.ty == 'nil' then
                                res.stale_delete[#res.stale_delete + 1] = entry
                            else
                                entry.value = ov.value
                                res.lost[#res.lost + 1] = entry
                            end
                        elseif in_a then
                            res.kept = res.kept + 1
                        else
                            -- in NEITHER version: a property another mod adds, or a
                            -- misspelling. NOT porting work, so it is counted and
                            -- never listed as such.
                            res.unknown_prop = res.unknown_prop + 1
                        end
                    end
                end
                -- ── NESTED WRITES (CART-0633) ────────────────────────────────
                -- Everything above adjudicates the FIRST path segment against the
                -- prototype that owns it. Factorio's data stage is deeply nested, so
                -- that missed a whole class: `working_sound.fade_in_ticks` is a
                -- WorkingSound property, `animation.layers.hr_version` an Animation
                -- one, and 2.0 removed both. The path is walked down the declared
                -- type chain and the LAST segment adjudicated against the type it
                -- lands in — the same typed question, one or more levels down.
                for _, ov in ipairs(p.nested or {}) do
                    local ta, pa = M.walk_path(a, pn_a, ov.path)
                    local tb, pb = M.walk_path(b, pn_b, ov.path)
                    if not (ta and tb) then
                        -- ⚠ COUNTED, NEVER SKIPPED. An unresolvable hop means the api
                        -- declares that property as a union/dictionary/tuple, which the
                        -- distiller deliberately does not reduce to one type. Silence
                        -- here would read as "checked and fine".
                        res.unwalked = (res.unwalked or 0) + 1
                    else
                        local pra, prb = M.type_props(a, ta), M.type_props(b, tb)
                        if pra and prb then
                            local ia, ib = pra[pa], prb[pb]
                            if ia and not ib then
                                local entry = { file = m.file, line = ov.line,
                                    typename = ty, proto = pn_a, prop = ov.path,
                                    owner_type = ta, required = ia == 'required',
                                    name = p.name, path = ov.path, nested = true,
                                    hedged = p.complete == false }
                                if ov.ty == 'nil' then
                                    res.stale_delete[#res.stale_delete + 1] = entry
                                else
                                    entry.value = ov.value
                                    res.lost[#res.lost + 1] = entry
                                end
                            elseif ia then res.kept = res.kept + 1
                            else res.unknown_prop = res.unknown_prop + 1 end
                        else
                            res.unwalked = (res.unwalked or 0) + 1
                        end
                    end
                end
            end
        end
    end
    local function rank(x, y)
        if x.required ~= y.required then return x.required end -- required first
        if x.prop ~= y.prop then return x.prop < y.prop end
        return (x.file or '') .. tostring(x.line) < (y.file or '') .. tostring(y.line)
    end
    table.sort(res.lost, rank); table.sort(res.stale_delete, rank)
    return res
end

--- The data-stage diff as lines.
function M.prototype_diff_report(store, from, to, opts)
    local res, err = M.prototype_diff(store, from, to)
    if not res then return { 'prototype diff: ' .. err } end
    local cap = (opts and opts.cap) or 20
    local L = { ('prototype diff — the DATA STAGE moving from %s to %s'):format(
        res.from, res.to) }
    L[#L + 1] = ('  %d prototype(s) read; %d write(s) and %d deletion(s) hit a removed'
        .. ' property, %d unchanged, %d in neither version'):format(res.records,
        #res.lost, #res.stale_delete, res.kept, res.unknown_prop)
    local function listing(items, label, note)
        if #items == 0 then return end
        L[#L + 1] = ''
        L[#L + 1] = ('  %s — %d:'):format(label, #items)
        for _, n in ipairs(note) do L[#L + 1] = '    ' .. n end
        for i = 1, math.min(cap, #items) do
            local e = items[i]
            L[#L + 1] = ('    %-31s %-22s %s:%s%s%s'):format(e.prop,
                e.typename, e.file or '?', tostring(e.line or '?'),
                e.required and '  [REQUIRED]' or '',
                e.hedged and '  (hedged: an opaque call may have rewritten this)' or '')
        end
        if #items > cap then
            L[#L + 1] = ('    … and %d more'):format(#items - cap)
        end
    end
    if #res.lost == 0 and #res.stale_delete == 0 then
        L[#L + 1] = '  no property this mod sets was removed between these versions'
    end
    listing(res.lost, 'WRITES TO A REMOVED PROPERTY', {
        'a VALUE is assigned to a property the new version does not have, so the',
        'write goes nowhere. Each is checked against the property set of the',
        'prototype that OWNS it, so this is a worklist and not a name match.' })
    listing(res.stale_delete, 'DELETIONS THAT NO LONGER DELETE', {
        'the line assigns `nil` to remove the property. The property is gone in the',
        'new version, so the line now removes NOTHING and the prototype silently',
        'keeps whatever the deletion used to suppress — no crash, changed behaviour.',
        'Lower urgency than a write, but do not mistake it for a no-op.' })
    if #res.gone_type > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('  THE data.raw KEY ITSELF IS GONE for %d prototype(s) — every'
            .. ' property under it moves:'):format(#res.gone_type)
        for i = 1, math.min(8, #res.gone_type) do
            local e = res.gone_type[i]
            L[#L + 1] = ('    %-26s was %s   %s:%s'):format(e.typename, e.was,
                e.file or '?', tostring(e.line or '?'))
        end
    end
    -- THE LOWER BOUND, stated rather than implied. A data-stage reading that printed
    -- only its findings would read as a clean bill of health for the 24 prototypes it
    -- literally cannot see.
    -- THE NON-PROTOTYPES, reported OUTSIDE the lower bound and with a name that does
    -- not call them prototypes (CART-0637). They are not a gap in the reading; they
    -- are tables this reader speculatively considered and correctly could not type.
    -- Kept visible because a literal that SHOULD have been registered and is not is a
    -- real finding of another kind, and this line is the only place it surfaces.
    if (res.unregistered or 0) > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('  (%d table literal(s) in data-stage files never reach'
            .. ' `data:extend` or `data.raw` — sprite fragments, style tables, module'
            .. ' tables. NOT prototypes and NOT part of the bound below.)')
            :format(res.unregistered)
    end
    if #res.unread > 0 or #res.hedged > 0 or res.untyped > 0
        or (res.unwalked or 0) > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('  THIS IS A LOWER BOUND — %d of %d prototype(s) could not be'
            .. ' adjudicated at all:'):format(#res.unread + res.untyped, res.records)
        if #res.unread > 0 then
            L[#L + 1] = ('    %d prototype(s) with NO READABLE TYPENAME — a literal'
                .. ' with no `type=` anywhere, or one whose keys are COMPUTED. Their'
                .. ' properties were not checked at all (not "no findings"):')
                :format(#res.unread)
            for i = 1, math.min(5, #res.unread) do
                L[#L + 1] = ('      %s:%s'):format(res.unread[i].file or '?',
                    tostring(res.unread[i].line or '?'))
            end
            if #res.unread > 5 then
                L[#L + 1] = ('      … and %d more'):format(#res.unread - 5)
            end
        end
        if res.untyped > 0 then
            L[#L + 1] = ('    %d further prototype(s) whose TYPENAME is unknown — copied'
                .. ' from a local we could not resolve, so no property set applies')
                :format(res.untyped)
        end
        if #res.hedged > 0 then
            -- ⚠ "table(s)", NOT "prototype(s)" — the same overclaim CART-0637 fixed
            -- above, and it CANNOT be filtered the same way. An unregistered literal
            -- is normally not a prototype, but one passed to an opaque call is
            -- genuinely ambiguous: THE CALL MAY BE THE REGISTRATION. Measured over
            -- 135 mods, 11 of 1320 `data:extend` sites sit inside a function, so a
            -- registration wrapper is rare but real. These stay in the bound.
            L[#L + 1] = ('    %d table(s) passed to an OPAQUE CALL, which lua semantics'
                .. ' say may have rewritten anything — and which may itself be the'
                .. ' registration, so these stay in the bound whether or not a'
                .. ' `data:extend` was seen:'):format(#res.hedged)
            for i = 1, math.min(4, #res.hedged) do
                L[#L + 1] = ('      %s:%s via %s'):format(res.hedged[i].file or '?',
                    tostring(res.hedged[i].line or '?'),
                    res.hedged[i].callee or '?')
            end
        end
        -- NESTED COVERAGE, stated on the same footing (CART-0633). The nested walk
        -- resolves a path down the DECLARED type chain, and the chain breaks wherever
        -- the api types a property as a union, a dictionary or a tuple — the
        -- distiller records only the forms naming exactly one type, and a consumer
        -- that picked one would adjudicate against a type the mod never wrote.
        -- ⚠ THIS LINE IS THE POINT OF THE WHOLE BLOCK: before it existed the nested
        -- class was checked or not checked with no way to tell which, which is worse
        -- than not checking at all.
        if (res.unwalked or 0) > 0 then
            L[#L + 1] = ('    %d NESTED write(s) whose path could not be walked to a'
                .. ' single declared type (a union/dictionary/tuple hop, e.g.'
                .. ' `Animation4Way`), so the property was not checked'):format(
                res.unwalked)
        end
    end
    return L
end

--- Display lines. `opts.cap` limits the not-in-profile list (default 25).
--- `opts.references` appends the READ surface (see reference_report): opt-in because
--- it re-parses every function (~3.5 ms each), which a default verb should not do to
--- a large corpus.
function M.report(store, runtime, opts)
    local res, err = M.audit(store, runtime)
    if not res then return { 'portability: ' .. err } end
    local cap = (opts and opts.cap) or 25
    local L = {}
    local decl = M.declared_for(store, runtime)
    if decl then
        -- both ends NAMED, on one ruler: the code's declared target and the
        -- artifact's version. Without this the header stated only the artifact's,
        -- which reads as a claim about the environment rather than about a MOVE.
        L[#L + 1] = ('portability — MOVING FROM %s %s (declared in %s) TO %s%s')
            :format(decl.scale, decl.raw, decl.source, res.runtime,
                res.version and (' ' .. tostring(res.version)) or '')
        L[#L + 1] = ('  %d of %d external name(s) provided by the target')
            :format(res.provided, res.provided + res.unknown)
    else
        L[#L + 1] = ('portability — %s%s: %d of %d external name(s) provided')
            :format(res.runtime, res.version and (' ' .. tostring(res.version)) or '',
                res.provided, res.provided + res.unknown)
    end
    L[#L + 1] = ('  the profile claims %d symbols; a verdict is only as good as that')
        :format(res.size)
    -- THE ORIGIN LINE (CART-0631), printed in ALL THREE states for the reason
    -- res.receiver.why is printed: an axis that quietly did not run looks exactly
    -- like one with nothing to find, and this one turns frontiers into verdicts.
    if res.origin and res.origin.available then
        L[#L + 1] = ('  CLASS SPACES: comparing against %s %s%s — a member no class in'
            .. ' the target declares is a REMOVAL, and needs no receiver')
            :format(tostring((res.origin.meta or {}).artifact),
                tostring((res.origin.meta or {}).version),
                res.origin.auto and ' (from the manifest)' or '')
    elseif res.origin and res.origin.why then
        L[#L + 1] = ('  CLASS SPACES: not compared — %s. Names whose receiver cannot be'
            .. ' typed stay unadjudicated rather than being called removed.')
            :format(res.origin.why)
    end
    -- THE STAGE PARTITION (CART-0216). Reported BEFORE the not-in-profile list,
    -- because "exists, but not at this stage" is a stronger statement than "not
    -- provided" and would be buried under it. The typed-empty rule applies in both
    -- directions: a profile with no partition says so, and a partition that found
    -- nothing says THAT rather than staying silent.
    if res.stages then
        local nfiles = 0
        for _ in pairs(res.stages.by_file) do nfiles = nfiles + 1 end
        L[#L + 1] = ''
        if #res.out_of_region == 0 then
            L[#L + 1] = ('  STAGES: %d file(s) placed in a load stage, %d stage-scoped'
                .. ' call site(s) judged; none is used outside the stage that provides'
                .. ' it'):format(nfiles, res.stage_sites or 0)
            -- what the judgement REFUSED to rule on, stated rather than implied: a
            -- clean stage report has to say what it declined, or "none" reads as
            -- "everything checked".
            if (res.stage_withheld or 0) > 0 then
                L[#L + 1] = ('    %d candidate(s) WITHHELD — inside a function body, so'
                    .. ' whether that stage ever evaluates them needs per-stage call'
                    .. ' reachability (and the Factorio idiom is to nil-guard the'
                    .. ' global: `if game then game.print(…) end`)')
                    :format(res.stage_withheld)
            end
            if (res.stage_shadowed or 0) > 0 then
                L[#L + 1] = ('    %d candidate(s) were a LOCAL of that name, not the'
                    .. ' environment global — a parameter or an assigned local')
                    :format(res.stage_shadowed)
            end
        else
            L[#L + 1] = ('  USED OUTSIDE ITS STAGE — %d site(s) of %d judged, and these'
                .. ' are not absences:'):format(#res.out_of_region,
                res.stage_sites or 0)
            L[#L + 1] = '    the environment HAS the name, in a different load stage'
            L[#L + 1] = '    than the file is loaded in. A stronger claim than'
            L[#L + 1] = '    not-provided, and a crash rather than a missing feature.'
            L[#L + 1] = ('    (MODULE-LEVEL sites only. %d withheld inside a function'
                .. ' body, %d were a local of that name.)'):format(
                res.stage_withheld or 0, res.stage_shadowed or 0)
            for i = 1, math.min(cap, #res.out_of_region) do
                local e = res.out_of_region[i]
                L[#L + 1] = ('    %-30s %s:%s'):format(e.name, e.file,
                    tostring(e.line or '?'))
                L[#L + 1] = ('      loaded at %s; provided at %s'):format(
                    table.concat(e.loaded_at, '+'),
                    table.concat(e.provided_at or {}, '+'))
            end
            if #res.out_of_region > cap then
                L[#L + 1] = ('    … and %d more'):format(#res.out_of_region - cap)
            end
        end
        -- what the partition could NOT place. A file no entry reaches has no stage,
        -- so nothing above ruled on it — saying so is the difference between "no
        -- findings" and "not checked".
        if #res.stages.orphans > 0 then
            L[#L + 1] = ('    %d file(s) reached by NO entry point, so no stage applies'
                .. ' and nothing above ruled on them (dead code, another language, or'
                .. ' a load mechanism we do not model): %s'):format(
                #res.stages.orphans,
                table.concat(res.stages.orphans, ', '):sub(1, 120))
        end
        if #res.stages.shared > 0 then
            L[#L + 1] = ('    %d file(s) loaded at MORE THAN ONE stage, so they are'
                .. ' held to the INTERSECTION of what those stages provide: %s')
                :format(#res.stages.shared,
                    table.concat(res.stages.shared, ', '):sub(1, 120))
        end
    end
    L[#L + 1] = ''
    local shown = 0
    if res.unknown == 0 then
        L[#L + 1] = '  every external name is accounted for by this profile'
    else
        -- GROUPED BY WHY, and NOT called porting work. This list used to be headed
        -- "candidate porting work", which was wrong for every entry rather than for
        -- most: with a methods-only artifact that models global-rooted calls, a miss
        -- is never evidence the target lacks the name. Saying which KIND of blindness
        -- produced each miss is the honest form, and it names what would fix it.
        L[#L + 1] = ('  NOT IN %s — %d name(s) the artifact cannot adjudicate,'
            .. ' grouped by WHY:'):format(res.runtime, res.unknown)
        -- the general disclaimer stays, above the per-group reasons: NOT-IN-PROFILE
        -- is not "missing", and a reader who skims past the groups should still meet
        -- that in one line
        L[#L + 1] = '    (NOT-IN-PROFILE is not "missing" — a dependency may supply'
            .. ' it, or the artifact may not model it at all.)'
        -- WHAT ADJUDICATED THE RECEIVERS, or why nothing did. Printed before the
        -- groups because it decides what the receiver groups below can mean at all.
        if res.receiver and res.receiver.available then
            local rm = res.receiver.meta or {}
            vim.list_extend(L, reason_lines('    receivers: ',
                ('adjudicated by SHAPE MATCH against %s (%s, api v%s) — one `%s`-rung'
                .. ' HYPOTHESIS per BASE, never a resolution, so every receiver verdict'
                .. ' below is weaker than the ABSENT group and weaker than `provided`.'
                .. ' The `~Class n=N` cell on each line is the hypothesis it rests on;'
                .. ' `n` is how many members had to agree, and a single-member match is'
                .. ' measured wrong often enough to be marked as such.')
                :format(tostring(rm.artifact), tostring(rm.version),
                    tostring(rm.api_version), tostring(res.receiver.tier)), '      '))
            -- THE CENSUS, so the split is legible without reading every group
            local c, order2 = {}, { 'receiver-class-absent', 'receiver-nearmiss',
                'receiver-nomatch', 'receiver-ambiguous', 'receiver-class-chain',
                'receiver-class-present', 'receiver-typed' }
            local tot, totcalls, refined, refcalls = 0, 0, 0, 0
            local smoved, smcalls = 0, 0
            for _, e in ipairs(res.entries) do
                if e.reason and e.reason:match('^receiver%-') then
                    c[e.reason] = c[e.reason] or { 0, 0 }
                    c[e.reason][1] = c[e.reason][1] + 1
                    c[e.reason][2] = c[e.reason][2] + e.calls
                    tot, totcalls = tot + 1, totcalls + e.calls
                elseif e.receiver and e.receiver.receiver_was
                    and e.reason and e.reason:match('^shape%-') then
                    -- TYPED, then decided by the SHAPE-MOVE axis. A DIFFERENT
                    -- population and a different mechanism from the class-space
                    -- refinement below: these names HAD a receiver hypothesis, and
                    -- it is the origin-side candidate set that condemned them. One
                    -- count covering both would name the wrong instrument for
                    -- whichever half the reader is looking at.
                    smoved, smcalls = smoved + 1, smcalls + e.calls
                elseif e.receiver and e.receiver.receiver_was then
                    -- RAISED BY THIS AXIS AND DECIDED BY ANOTHER (CART-0631). Counted
                    -- separately rather than dropped: this census used to be every
                    -- name the receiver axis touched, and after the class-space
                    -- refinement it silently became a SUBSET. A reader comparing two
                    -- runs would see the total fall with nothing to explain it, which
                    -- is the absence-rendered-as-silence class in its own report.
                    refined, refcalls = refined + 1, refcalls + e.calls
                end
            end
            local parts = {}
            for _, k in ipairs(order2) do
                if c[k] then parts[#parts + 1] = ('%s %d/%dc')
                    :format(k:gsub('^receiver%-', ''), c[k][1], c[k][2]) end
            end
            L[#L + 1] = ('      %d receiver-typed name(s), %d call(s): %s')
                :format(tot, totcalls, table.concat(parts, ' · '))
            if refined > 0 then
                L[#L + 1] = ('      + %d name(s), %d call(s) the shape match could not'
                    .. ' type and the CLASS SPACES decided — listed in their own groups')
                    :format(refined, refcalls)
            end
            if smoved > 0 then
                L[#L + 1] = ('      + %d name(s), %d call(s) typed here and then'
                    .. ' condemned by the ORIGIN-side candidate set (shape move)')
                    :format(smoved, smcalls)
            end
        elseif res.receiver then
            vim.list_extend(L, reason_lines(
                '    receivers NOT adjudicated — ', tostring(res.receiver.why), '      '))
        end
        -- `absent` FIRST: it is the only group that says anything about the target
        -- on the profile's own authority. Then the receiver axis, ordered by how
        -- much it claims — the hedged near-porting-work first, the merely consistent
        -- last. EVERY KEY REASON_TEXT DEFINES MUST APPEAR HERE: a reason present on
        -- an entry and absent from this list builds a group that is never printed,
        -- which is the absence-rendered-as-silence class this file keeps fencing.
        local groups, order = {}, vim.deepcopy(M.REASON_ORDER)
        for _, e in ipairs(res.entries) do
            if not e.provided then
                local g = groups[e.reason]
                if not g then g = { n = 0, calls = 0, items = {} }; groups[e.reason] = g end
                g.n = g.n + 1; g.calls = g.calls + e.calls
                g.items[#g.items + 1] = e
            end
        end
        local per = math.max(3, math.floor(cap / 3))
        -- EVERY group prints, registered or not. The ordered list above is a
        -- PRESENTATION order; treating it as the filter meant a new reason key could
        -- be attached to entries and never appear, so the reader would see a smaller
        -- population than the count in the header and have no way to know why.
        local unregistered = {}
        for key in pairs(groups) do
            local found = false
            for _, k in ipairs(order) do if k == key then found = true end end
            if not found then unregistered[#unregistered + 1] = key end
        end
        table.sort(unregistered)
        vim.list_extend(order, unregistered)
        for _, key in ipairs(order) do
            local g = groups[key]
            if g then
                L[#L + 1] = ''
                vim.list_extend(L, reason_lines(
                    ('    %d name(s), %d call(s) — '):format(g.n, g.calls),
                    M.REASON_TEXT[key] or ('UNLABELLED REASON %q — this key has no text'
                        .. ' in REASON_TEXT, which is a bug in this file, not a fact'
                        .. ' about the code being audited'):format(key), '      '))
                for i = 1, math.min(per, #g.items) do
                    local e = g.items[i]
                    L[#L + 1] = ('      %-36s %4d call(s)  %-34s %s'):format(e.name,
                        e.calls, where_text(e.files), M.receiver_cell(e.receiver))
                    shown = shown + 1
                end
                if #g.items > per then
                    L[#L + 1] = ('      … and %d more'):format(#g.items - per)
                end
            end
        end
        L[#L + 1] = ''
        if not groups['absent'] then
            L[#L + 1] = '  no ABSENT group: nothing here is a name a fully-enumerated'
            L[#L + 1] = '  class could have held, so nothing is evidence about the target.'
        end
        -- AND THE SAME SENTENCE FOR THE RECEIVER AXIS, because its empty absent
        -- group is STRUCTURAL rather than lucky and a reader must not take it for a
        -- clean bill of health. A base's class is picked BY declaring every member
        -- observed on it, so a determined base can never lack one of them; the only
        -- shape a target removal can take here is a base that failed to match.
        if res.receiver and res.receiver.available and not groups['receiver-class-absent'] then
            vim.list_extend(L, reason_lines('  no hypothesised-class ABSENT group, and'
                .. ' that is STRUCTURAL: ',
                'a class is selected by declaring EVERY member observed on the base, so'
                .. ' a determined base cannot lack one of them. A member the target'
                .. ' removed does not show up here as an absence — it shows up as a'
                .. ' base that matched NO class, in the near-miss or not-an-API-object'
                .. ' group above. Read those, not this line.', '  '))
        end
    end
    L[#L + 1] = ''
    vim.list_extend(L, reason_lines(('  provided by %s: %d name(s) — '):format(
        res.runtime, res.provided),
        'the AUTHORITATIVE count, and deliberately unmoved by the receiver axis: it'
        .. ' means a symbol the profile NAMES, and folding a shape-match hypothesis'
        .. ' into it would both change what the number means and make a version DIFF'
        .. ' report every receiver as GAINED (the 1.1 artifact carries no class table,'
        .. ' so only one end of a move could ever match).', '    '))
    for _, e in ipairs(res.entries) do
        if e.provided then
            L[#L + 1] = ('    %-38s %4d call(s)  via %s'):format(e.name, e.calls, e.why)
            break
        end
    end
    if res.provided > 1 then
        L[#L + 1] = ('    … and %d more'):format(res.provided - 1)
    end
    -- THE OTHER END OF A DECLARED MOVE. When the code declares a target version and
    -- no profile for it is loadable, the report says so and says it is OBTAINABLE —
    -- rather than silently scoring against one end, which can only ever produce an
    -- absence. Nothing is contacted here: this reads local state and names a command.
    if decl and decl.v then
        -- `local a, b = cond and f()` TRUNCATES f() to one value, so the guard cannot
        -- live in the expression — `min` came back nil and this whole block silently
        -- did nothing. Second time this bit in one session (see spec/lua.lua's
        -- require-form match), which is why it is written out here.
        local maj, min = decl.v:match('^(%d+)%.(%d+)')
        local other = (maj and min) and (runtime .. '-' .. maj .. min) or nil
        local have_other = other
            and require('cartograph.spec.profile').load(other) ~= nil
        if other and have_other then
            L[#L + 1] = ''
            L[#L + 1] = ('  BOTH ENDS present: a version DIFF is available against %s,')
                :format(other)
            L[#L + 1] = '  which reports status CHANGES rather than absences.'
        elseif other then
            L[#L + 1] = ''
            L[#L + 1] = ('  the OLD end (%s) is not present, so only absences can be'):format(other)
            L[#L + 1] = '  reported here, never changes. This environment publishes its own'
            L[#L + 1] = '  API description — `tools/apifetch.lua` lists what is fetchable'
            L[#L + 1] = '  (it contacts nothing until asked). A profile module for the'
            L[#L + 1] = '  version is also needed; the artifact alone is not a profile.'
        end
    end

    -- THE SECOND SURFACE. Names that are READ and never called cannot appear above:
    -- the audit is built from call records. Opt-in because it re-parses every
    -- function; announced always, so its absence is never mistaken for emptiness.
    if opts and opts.references then
        vim.list_extend(L, M.reference_report(store, runtime, opts))
    else
        L[#L + 1] = ''
        L[#L + 1] = '  a READ surface also exists (names touched but never called —'
        L[#L + 1] = '  where a renamed attribute or a removed global lives). Not shown:'
        L[#L + 1] = '  it re-parses every function (~3.5 ms each). Pass references=true.'
    end
    return L
end

--- THE ROSTER AS A REPORT — what you may audit against, and what ships that you may
--- not. This is what the verb prints when no target is named: completion narrows the
--- list silently, and a reader who has not pressed <Tab> deserves to be told WHY four
--- of the twelve artifacts on disk are not offered. Needs no graph.
function M.roster_report()
    local rows = M.target_roster()
    local L = { ('portability TARGETS — %d artifact(s) ship; a target is one that can'):format(#rows),
        '  ANSWER the question you ask, which is not the same set:' }
    local bykind = { names = {}, data = {} }
    local refused, order = {}, {}
    for _, r in ipairs(rows) do
        if r.kinds and r.kinds.names then
            local g = bykind.names
            g[#g + 1] = ('%s (%s, %s)'):format(r.runtime, r.lang or '?', r.measure
                or (r.size .. ' symbols'))
        elseif r.kinds and r.kinds.data then
            local g = bykind.data
            g[#g + 1] = ('%s (%s, %s)'):format(r.runtime, r.lang or '?',
                r.measure or '?')
        else
            local why = r.reason or 'no disposition'
            if not refused[why] then refused[why] = {}; order[#order + 1] = why end
            local g = refused[why]
            g[#g + 1] = r.runtime
        end
    end
    L[#L + 1] = ''
    L[#L + 1] = '  NAMES — audit one, or diff the MOVE between two of the same language:'
    for _, t in ipairs(bykind.names) do L[#L + 1] = '    ' .. t end
    L[#L + 1] = ''
    L[#L + 1] = '  DATA STAGE — pass TWO of these to diff declared prototypes instead:'
    for _, t in ipairs(bykind.data) do L[#L + 1] = '    ' .. t end
    if #order > 0 then
        L[#L + 1] = ''
        L[#L + 1] = '  NOT A TARGET — these ship and are load-bearing elsewhere; each'
        L[#L + 1] = '  reason below says where, because none of them is a useless file:'
        for _, why in ipairs(order) do
            L[#L + 1] = '    ' .. table.concat(refused[why], ', ')
            -- the reason is name-free, so it is printed ONCE for the group; it already
            -- reads as a predicate of each artifact named above it
            vim.list_extend(L, reason_lines('      — ', why, '        '))
        end
    end
    return L
end

--- The code's OWN profile as a report: what it requires, which shipped
--- environment covers most of it, and where each requirement comes from.
function M.requires_report(store)
    local ranked, req, skipped = M.rank(store)
    local groups, unclaimed = M.manifest(store)
    local langs = {}
    for l in pairs(req.langs) do langs[#langs + 1] = l end
    table.sort(langs)
    local L = {}
    L[#L + 1] = ("this code REQUIRES — %s: %d external name(s)%s"):format(
        table.concat(langs, '/'), req.total,
        req.floor and (', version floor ' .. (req.scale and (req.scale .. ' ') or '')
            .. req.floor) or '')
    L[#L + 1] = '  the inverse of an environment profile: the same currency, other'
    L[#L + 1] = '  direction, so the questions below are set algebra over the two.'
    L[#L + 1] = ''
    L[#L + 1] = '  TIGHTEST ENVIRONMENT — shipped profiles by coverage of that set:'
    if #ranked == 0 then
        L[#L + 1] = '    (no shipped profile targets this language)'
    end
    for _, r in ipairs(ranked) do
        L[#L + 1] = ('    %-16s %5.1f%% covered  (%d of %d; profile claims %d)')
            :format(r.runtime, r.pct, r.provided, r.provided + r.unknown, r.size)
    end
    if #ranked > 0 then
        L[#L + 1] = '    coverage is not a verdict: full coverage means this boundary'
        L[#L + 1] = '    holds no counter-evidence, not that the code runs there.'
    end
    -- WHAT WAS NOT RANKED, AND WHY. These artifacts ship for this language and were
    -- deliberately not scored; printing the list is what keeps that from reading as
    -- "only three profiles exist". Each reason names the mechanism, because every one
    -- of them is load-bearing somewhere else (an input to a hand profile, the
    -- data-stage diff's own target, the signature source hover reads).
    if #skipped > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('  NOT RANKED — %d shipped artifact(s) of this language answer no'):format(#skipped)
        L[#L + 1] = '  NAME query, so each is not rankable here rather than 0% covered:'
        -- GROUPED BY REASON, in roster order. Three artifacts share one mechanism, and
        -- printing the same paragraph three times is how a reader learns to skip it.
        local order, byreason = {}, {}
        for _, s in ipairs(skipped) do
            if not byreason[s.reason] then
                byreason[s.reason] = {}
                order[#order + 1] = s.reason
            end
            local g = byreason[s.reason]
            g[#g + 1] = ('%s (%s)'):format(s.runtime, s.measure)
        end
        for _, why in ipairs(order) do
            L[#L + 1] = '    ' .. table.concat(byreason[why], ', ')
            vim.list_extend(L, reason_lines('      — ', why, '        '))
        end
    end
    L[#L + 1] = ''
    L[#L + 1] = '  DEPENDENCY MANIFEST — the requirement set grouped by who provides it:'
    local keys = {}
    for k in pairs(groups) do keys[#keys + 1] = k end
    table.sort(keys, function (a, b) return groups[a].names > groups[b].names end)
    for _, k in ipairs(keys) do
        L[#L + 1] = ('    %-28s %4d name(s), %5d call(s)'):format(k,
            groups[k].names, groups[k].calls)
    end
    L[#L + 1] = ('    %-28s %4d name(s)'):format('claimed by no profile', #unclaimed)
    L[#L + 1] = '      — most often a sibling module or a third-party dependency,'
    L[#L + 1] = '        NOT evidence that anything is missing. Top by call volume:'
    for i = 1, math.min(10, #unclaimed) do
        L[#L + 1] = ('        %-34s %4d call(s)'):format(unclaimed[i].name,
            unclaimed[i].calls)
    end
    return L
end

return M
