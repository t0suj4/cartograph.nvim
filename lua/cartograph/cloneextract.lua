-- Extract-helper: the verified transaction that factors a value-parameterizable
-- near-clone PAIR into a shared parameterized helper ([[cartograph-record-fold-arc]]
-- prereq #4). It rides the move/merge txn contract (plan → dryrun → apply-with-journal,
-- refusing on any drift), and adds two synthesis gates: the result must PARSE cleanly and
-- must contain the helper + both rewritten call sites.
--
-- Two placements:
--   SAME-FILE — the helper is a `local function` inserted before the earlier copy; both
--     bodies become `return helper(…)`.
--   CROSS-FILE — the helper becomes `M.helper` in a NEW shared module (plan.create); each
--     copy's file gains `local <alias> = require '<mod>'` and its body becomes
--     `return <alias>.helper(…)`. The require path is a language guess (root-relative) so
--     it rides as a HAZARD to verify — the same honesty extract-module uses.
--
-- SOUNDNESS rests on the prereqs, each verified before a plan is built:
--   • VALUE-parameterizable (clones.analyze_pair): every divergence is a leaf value with a
--     source range → it lifts to a parameter.
--   • BODY-EXTRACTABLE (untangle.body_extractable) for BOTH copies: top-level, no vararg,
--     no self-recursion. CROSS-FILE additionally requires every FREE READ to be a global
--     (not a source-file local — that would break on the move), and — on a FACTORIO project
--     — that no free read is a phase-bound global (data / game / script / …) unless every
--     destination phase is that global's own (else the shared home loads into a phase where
--     the global doesn't exist; phase = entry-cone reachability, see phases_of).
--   • The rewrite is a TAIL CALL (`return helper(…)`), preserving every return.
-- HARD CONSTRAINTS (refuse with a reason otherwise): a supported language (Lua, or
-- JavaScript same-file — see EXTRACT), equal param count, single-line holes inside the
-- body, a clean multi-line body, a free helper name. The only language-specific part is
-- the SYNTHESIS syntax (EXTRACT table); the analysis + gates are language-agnostic.

local M = {}

local clones = require 'cartograph.clones'
local un = require 'cartograph.untangle'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'

local function indent_of(line) return (line or ''):match('^%s*') or '' end

-- @langs lua javascript
-- The table below IS the declaration made machine-readable, and the two are not
-- equal: javascript has no `module` form, so a CROSS-FILE extraction refuses
-- there while a same-file helper is synthesised. A third language is an entry
-- here, not a wider claim.

-- Per-language SYNTHESIS syntax — the only language-specific part of the transaction
-- (the body span, hole substitution, params, and gates are all language-agnostic). Each
-- entry: parse (grammar for the parses-clean gate); local_helper(name, params, body,
-- indent) → the same-file helper's lines; ret(callee, args) → the delegating statement
-- (no indent — the caller prepends it); def_pat(name) → a same-file parse-check substring;
-- module(name, params, body) + member_pat(name) → cross-file module member form (nil =
-- cross-file unsupported for this language, e.g. no module wiring in its spec yet).
local EXTRACT = {
    lua = {
        parse = 'lua',
        local_helper = function (name, ps, body, ind)
            local out = { ind .. ('local function %s(%s)'):format(name, ps) }
            for _, l in ipairs(body) do out[#out + 1] = l end
            out[#out + 1] = ind .. 'end'; out[#out + 1] = ''
            return out
        end,
        ret = function (callee, args) return ('return %s(%s)'):format(callee, args) end,
        def_pat = function (name) return ('local function %s('):format(name) end,
        module = function (name, ps, body)
            local out = { 'local M = {}', '', ('function M.%s(%s)'):format(name, ps) }
            for _, l in ipairs(body) do out[#out + 1] = l end
            out[#out + 1] = 'end'; out[#out + 1] = ''; out[#out + 1] = 'return M'; out[#out + 1] = ''
            return out
        end,
        member_pat = function (name) return ('function M.%s('):format(name) end,
        -- CART-0985: the node types whose CHILDREN are statements. A helper is a
        -- statement, so it may only be inserted as a child of one of these.
        stmt_parents = { chunk = true, block = true },
    },
    javascript = {
        parse = 'javascript',
        local_helper = function (name, ps, body, ind)
            local out = { ind .. ('function %s(%s) {'):format(name, ps) }
            for _, l in ipairs(body) do out[#out + 1] = l end
            out[#out + 1] = ind .. '}'; out[#out + 1] = ''
            return out
        end,
        ret = function (callee, args) return ('return %s(%s);'):format(callee, args) end,
        def_pat = function (name) return ('function %s('):format(name) end,
        module = nil, -- no JS module/import wiring in the spec yet → cross-file refused
        -- a member of an object literal or a class body is the JS analogue of a lua
        -- table-constructor field: an expression position, not a statement one.
        stmt_parents = { program = true, statement_block = true },
    },
}
local FILE_LANG = { lua = 'lua', js = 'javascript', jsx = 'javascript',
    cjs = 'javascript', mjs = 'javascript' }
local function lang_of(file) return FILE_LANG[(file:match('%.(%w+)$') or ''):lower()] end

-- a fresh helper name not already a function/method in the given files
local function fresh_name(store, files, base)
    local fset, taken = {}, {}
    for _, f in ipairs(files) do fset[f] = true end
    for _, n in ipairs(store.data.nodes) do
        if fset[n.file] and (n.kind == 'function' or n.kind == 'method') then
            taken[(n.name or ''):match('[%w_]+$') or n.name] = true
        end
    end
    local root = (base or 'shared'):match('[%w_]+$') or 'shared'
    local name, i = root .. '_extracted', 2
    while taken[name] do name = root .. '_extracted' .. i; i = i + 1 end
    return name
end

-- top-level def names in a file (fn/method/var) — the cross-file move must not read these
--- ★★★ WHERE A STATEMENT MAY LEGALLY GO (CART-0985), given a member's signature line.
---
--- The helper is a STATEMENT (`local function f() … end`). Both builders used to insert
--- it beside the member, which is right only when the member's own definition sits at a
--- statement position. MEASURED on `lua/cartograph/spec/odin.lua`, whose whole body is
--- `return { … }`: `body_of` and `params_of` are ENTRIES IN A TABLE CONSTRUCTOR, so the
--- helper landed inside the constructor and the file stopped parsing — one `ERROR` node
--- spanning exactly the inserted lines. The `parses` guard refused it, so nothing was
--- written; this turns a late, unexplained refusal into an insertion point that works.
---
--- ⚠ DROPPING `local` WOULD NOT HAVE FIXED IT, and it is the obvious first guess: a bare
--- `function (…) … end` IS an expression, so it parses — as a POSITIONAL ARRAY ELEMENT
--- of the table, binding no name, leaving every call site reading an undefined global.
--- That trades a parse error for CART-0984's failure mode, which is strictly worse
--- because no guard catches it.
---
--- ★ A MEMBER ALREADY AT STATEMENT LEVEL GETS ITS OWN LINE BACK, unchanged: the walk
--- stops immediately when the node's parent is already a statement container.
--- @return integer|nil line0, string|nil why
local function stmt_line(lines, lang, syn, line0)
    local parents = syn and syn.stmt_parents
    if not parents then return line0 end -- no claim for this language: behave as before
    local src = table.concat(lines, '\n')
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, syn.parse)
    if not okp or not parser then return line0 end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return line0 end
    local text = lines[line0 + 1] or ''
    local col = #(text:match('^%s*') or '')
    local node = tree:root():named_descendant_for_range(line0, col, line0, col)
    if not node then return line0 end
    while node do
        local parent = node:parent()
        if not parent then break end
        if parents[parent:type()] then return (node:range()) end
        node = parent
    end
    return nil, 'no statement context encloses it'
end

--- the file-scope locals of `file`, name -> the 0-based line that binds it
local function file_local_lines(store, file)
    local s = {}
    for _, n in ipairs(store.data.nodes) do
        if n.file == file and n.name and n.range
            and (n.kind == 'function' or n.kind == 'method' or n.kind == 'var') then
            local l = at.sl(n.range)
            if s[n.name] == nil or l < s[n.name] then s[n.name] = l end
        end
    end
    return s
end

--- ⚠⚠ THE HELPER GOES ABOVE THE MEMBERS, SO IT MUST NOT OUTRUN WHAT IT READS. A body
--- that reads a file-local bound at or below the insertion line would find it undefined
--- there — the same call-site-nameability question CART-0984 asks of a hole's VALUE,
--- asked of the helper's own free names. Returns the offending name, or nil.
---
--- ★ IT IS NOT A HOIST-ONLY CHECK, AND MY FIRST CUT WAS. Restricting it to names bound
--- BETWEEN the hoist line and the member made it UNFIRABLE: the hoist target is the
--- outermost statement containing the member, so anything between the two is inside that
--- statement and is not a file-scope binding. A guard that cannot fire is worse than no
--- guard — it reads as coverage. The real question has nothing to do with hoisting: the
--- helper is inserted ABOVE THE EARLIER COPY in every case, so a local bound BETWEEN THE
--- TWO COPIES and read by the shared body was already being outrun, hoist or not.
--- @return string|nil name
local function reads_below(store, ids, file, ins0, skip)
    local lines_of_local = file_local_lines(store, file)
    for _, id in ipairs(ids) do
        local ef = require('cartograph.expr').free(store, id)
        for r in pairs((ef and ef.reads) or {}) do
            if not (skip and skip[r]) then
                local l = lines_of_local[r]
                if l and l >= ins0 then return r end
            end
        end
    end
end

local function file_locals(store, file)
    local s = {}
    for _, n in ipairs(store.data.nodes) do
        if n.file == file and n.name
            and (n.kind == 'function' or n.kind == 'method' or n.kind == 'var') then
            s[n.name] = true
        end
    end
    return s
end

-- ── Factorio phase awareness ([[cartograph-cross-project]]) ─────────────────
-- Factorio globals are PHASE-SCOPED: `data` exists only in the data stage; game/script/
-- rendering/rcon/commands only at runtime (control.lua). A cross-file helper home is
-- required from both copies' files, so it loads in the UNION of their phases — a body that
-- reads a phase-bound global is only safe if every destination phase is that global's own.
local ENTRY_PHASE = { ['control.lua'] = 'runtime',
    ['data.lua'] = 'data', ['data-updates.lua'] = 'data', ['data-final-fixes.lua'] = 'data',
    ['settings.lua'] = 'settings', ['settings-updates.lua'] = 'settings',
    ['settings-final-fixes.lua'] = 'settings' }
-- the UNAMBIGUOUS phase-bound globals (broadly-available names — settings/mods/remote —
-- are left out to avoid over-refusing; the sound-conservative core).
local PHASE_GLOBAL = { data = 'data', game = 'runtime', script = 'runtime',
    rendering = 'runtime', rcon = 'runtime', commands = 'runtime' }

-- Phase membership by entry-cone reachability over the import graph. Returns
-- (true, file → {phase=true}) when the project has phase entries at the mod root, else
-- false. A file reachable from >1 phase's entry is in all of them (a shared helper).
local function phases_of(store)
    local byid, adj = {}, {}
    for _, n in ipairs(store.data.nodes) do byid[n.id] = n end
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'import' then
            local ff = byid[e.from] and byid[e.from].file
            local tf = byid[e.to] and byid[e.to].file
            if ff and tf then adj[ff] = adj[ff] or {}; adj[ff][tf] = true end
        end
    end
    local entries, any = {}, false
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'module' and n.file and not n.file:find('/') then
            local ph = ENTRY_PHASE[n.file:match('[^/]+$') or n.file]
            if ph then entries[#entries + 1] = { f = n.file, ph = ph }; any = true end
        end
    end
    if not any then return false end
    local phaseset = {}
    for _, ent in ipairs(entries) do
        local seen, q, qi = { [ent.f] = true }, { ent.f }, 1
        while qi <= #q do
            local f = q[qi]; qi = qi + 1
            phaseset[f] = phaseset[f] or {}; phaseset[f][ent.ph] = true
            for tf in pairs(adj[f] or {}) do if not seen[tf] then seen[tf] = true; q[#q + 1] = tf end end
        end
    end
    return true, phaseset
end

--- WHAT THE RESULT MUST CONTAIN, stated by the planner for the `synthesized` guard
--- (CART-0982). `apply` used to compute all of this itself, which is why the driver
--- could not be generic: it would have needed this module's language table AND to
--- know whether the plan was a pair or a family.
---
--- ⚠ THE CALL-SITE COUNT IS PER MEMBER, not always two. A family of three rewrites
--- three bodies; demanding exactly two would refuse every family larger than a pair,
--- and for a PAIR it is the same check it always was.
local function expectation(plan, syn)
    local defsite = plan.xfile and plan.create.file
        or (plan.a and plan.a.file) or (plan.members and plan.members[1].file)
    return {
        def = { file = defsite,
            needle = plan.xfile and syn.member_pat(plan.helper)
                or syn.def_pat(plan.helper) },
        calls = { needle = (plan.xfile and plan.helper_call or plan.helper) .. '(',
            n = plan.members and #plan.members or 2,
            -- the created module holds the DEFINITION, so its text is not a call site
            skip = plan.xfile and plan.create.file or nil },
    }
end

local function span_text(lines, r)
    return (lines[at.sl(r) + 1] or ''):sub(at.sc(r) + 1, at.ec(r))
end

-- the 0-based line to insert a new import AFTER (last existing import, else top)
local function import_point(lines, pats)
    local last = 0
    for i, l in ipairs(lines) do
        for _, p in ipairs(pats or {}) do
            if l:match(p) then last = i; break end
        end
    end
    return last
end

-- body statement span [sig, open, close] (0-based) of a fn, or nil if not a clean block
local function body_span(store, id, stmt_lines)
    local node = store.node(id)
    local sig0b = at.sl(node.range)
    local open0b = (stmt_lines[1] or 0) - 1
    local close0b = at.el(node.range) - 1
    if open0b <= sig0b or close0b < open0b then return nil end
    return sig0b, open0b, close0b
end

--- Build a plan to extract `pair` into a helper, or (nil, reason). For a CROSS-FILE pair,
--- opts.dest (a new module's project-relative path) is required.
function M.plan(store, pair, opts)
    if not (pair and pair.a and pair.b) then return nil, 'no near-clone pair' end
    local a, b = pair.a, pair.b
    local xfile = a.file ~= b.file
    local lang = lang_of(a.file)
    if not (lang and lang == lang_of(b.file)) then
        return nil, 'both functions must be in one supported language (Lua, JavaScript)'
    end
    local syn = EXTRACT[lang]
    -- ⚠ THE STORE IS NOT OPTIONAL HERE (CART-0989). `move_purity` needs it, and without
    -- it every non-literal hole comes back `no_store` — so the behavioural verdict said
    -- `unreviewed` for the right fold and the WRONG REASON ("the caller supplied no
    -- store" instead of "`require` is io"). A degraded answer that happens to agree with
    -- the correct one is the most expensive kind to leave in place.
    local analysis = clones.analyze_pair(pair, store)
    if analysis.kind ~= 'value' then
        -- ★ NAME THE CAUSE WHEN THE ANALYSIS HAS ONE. "structural" is a category, not a
        -- reason: it is the same sentence for a shape difference, an inserted statement
        -- and a base the call site cannot name, and only the last of those tells the
        -- caller anything they could act on. CART-0984's `fieldbase` is the first cause
        -- specific enough to be worth saying out loud, and saying it is what keeps a
        -- SOUND refusal from reading like an uninteresting one.
        return nil, ('not value-parameterizable (%s) — nothing to lift cleanly'):format(analysis.kind)
    end
    -- ★★★ A HOLE THE CALL SITE CANNOT WRITE DOWN (CART-0984). A `field` hole does not
    -- lift the field NAME, it lifts THE WHOLE ACCESS — `A.unify` and `A.join` share a
    -- base and differ in one leaf, so the value passed is `A.unify`. That is right
    -- whenever the base is nameable THERE and silently wrong when it is not: measured on
    -- our own tree, folding `M.template_meet <-> M.template_join` emitted
    -- `…(a, b, opts, A.unify, …)` where `A` is `local A = alg.load()` INSIDE the body it
    -- came from. The result PARSES, the helper exists, both call sites exist — every
    -- declared guard passes — and the call site does a global read.
    -- ⚠ NOTHING DOWNSTREAM LOOKS AT A SPAN'S CONTENTS, so this is the only place the
    -- question gets asked. The `name` arm of `anti_unify` has always asked it ("a local
    -- the call site cannot name"); the field arm now marks it and this refuses on it.
    for _, h in ipairs(analysis.holes) do
        if h.unnameable then
            return nil, ('the copies differ in a field NAME, but folding them passes the'
                .. ' whole access, and its base `%s` is a local of the body — not'
                .. ' something the call site can name'):format(tostring(h.unnameable))
        end
    end
    -- ★★★ A WRITE TARGET IS NOT A VALUE (CART-0941). Every hole below becomes an
    -- `hp<i>` parameter, is substituted at each of its sites, and is passed the
    -- text of its first site as the argument. That is right for a READ and wrong
    -- for an assignment TARGET: `self.alpha = alpha` became `hp1 = alpha`, which
    -- assigns to the parameter, DELETES THE FIELD WRITE in both copies, and passes
    -- `self.alpha` read before the write. It parses, so the `parses` guard passed
    -- it; both callers were silently broken.
    --
    -- ⚠ THE TEST IS `target`, NOT `side`. A hole merely UNDER a destination is
    -- fine -- `t[k] = v` with a differing key substitutes correctly, because the
    -- key is already an expression -- and refusing on `side` would forbid that too.
    -- `target` marks only the hole that IS the destination.
    --
    -- ⇒ THIS IS A REFUSAL AND NOT YET A DISPATCH. A differing selector on a
    --   `field` destination has a real factoring, `self[hp] = v` with the SELECTOR
    --   as the argument -- an INDEX write cartograph has no verb for. Until it
    --   does, declining is the honest answer; the reason names the destination
    --   kind so the reader can see which rewrite is missing rather than only that
    --   one is.
    for i, h in ipairs(analysis.holes) do
        if h.target then
            return nil, ('hole %d is the assignment TARGET (a %s hole on a %s'
                .. ' destination) — substituting it would delete the write')
                :format(i, tostring(h.kind), tostring(h.dest))
        end
    end
    local va = un.body_extractable(store, a.id)
    if not va.ok then return nil, ('%s body not liftable: %s'):format(a.name, va.reason) end
    local vb = un.body_extractable(store, b.id)
    if not vb.ok then return nil, ('%s body not liftable: %s'):format(b.name, vb.reason) end
    if #va.params ~= #vb.params then
        return nil, 'the two functions take a different number of parameters'
    end

    local root = store.data.root
    local dest, alias, require_line
    local hazards = {}
    if xfile then
        if not syn.module then
            return nil, ('cross-file extraction is not supported for %s yet (no module wiring)'):format(lang)
        end
        dest = opts and opts.dest
        if not dest then
            return nil, 'cross-file: pass a destination module path (:CartographExtractHelperApply <dir/name.lua>)'
        end
        if dest:sub(1, 1) == '/' or dest:find('%.%.') then
            return nil, 'the destination must be a plain path inside the project'
        end
        if txn.read_file(root, dest) then return nil, dest .. ' already exists — pick a new module path' end
        -- FREE-READ gate: a moved body must read only globals, not source-file locals
        for _, side in ipairs({ { v = va, f = a.file, n = a.name }, { v = vb, f = b.file, n = b.name } }) do
            local loc = file_locals(store, side.f)
            for r in pairs(side.v.reads or {}) do
                if loc[r] then
                    return nil, ('%s reads file-local `%s` — cannot move it to another module')
                        :format(side.n, r)
                end
            end
        end
        -- PHASE gate (Factorio): the shared home loads in the UNION of the two files'
        -- phases, so a phase-bound global read is safe only if every destination phase is
        -- that global's own. Non-Factorio projects have no phase entries → a no-op.
        local found, phaseset = phases_of(store)
        if found then
            local dest_ph, phlist = {}, {}
            for _, f in ipairs({ a.file, b.file }) do
                for p in pairs(phaseset[f] or {}) do
                    if not dest_ph[p] then dest_ph[p] = true; phlist[#phlist + 1] = p end
                end
            end
            table.sort(phlist)
            local nph = #phlist
            for _, side in ipairs({ { v = va, n = a.name }, { v = vb, n = b.name } }) do
                for r in pairs(side.v.reads or {}) do
                    local pg = PHASE_GLOBAL[r]
                    if pg and not (nph == 1 and dest_ph[pg]) then
                        return nil, ('%s reads phase-bound global `%s` (%s phase), but the'
                            .. ' shared module would load across phases {%s} — not phase-safe')
                            :format(side.n, r, pg, table.concat(phlist, ', '))
                    end
                end
            end
        end
        local tsp0 = require 'cartograph.providers.treesitter'
        require_line, alias = tsp0.import_line(a.file, dest,
            tsp0.import_ctx(store.data.root, store.files))
        if not require_line then return nil, 'cannot form a require line for this language' end
        hazards[#hazards + 1] = ('verify the require path in `%s` resolves to %s'):format(require_line, dest)
    end

    local lines_a = vim.split(txn.read_file(root, a.file) or '', '\n', { plain = true })
    local lines_b = xfile and vim.split(txn.read_file(root, b.file) or '', '\n', { plain = true }) or lines_a
    local a_sig, a_open, a_close = body_span(store, a.id, a.lines)
    local b_sig, b_open, b_close = body_span(store, b.id, b.lines)
    if not (a_sig and b_sig) then return nil, 'a body is not a clean multi-line block' end
    if not xfile and not (a_close < b_sig or b_close < a_sig) then
        return nil, 'the two functions overlap (nested?) — cannot extract'
    end

    -- hole PARAMETERS + validation (single-line, inside each body)
    local hp = {}
    for i = 1, #analysis.holes do
        local name = 'hp' .. i
        for _, p in ipairs(va.params) do if p == name then return nil, 'a parameter is already named ' .. name end end
        hp[i] = name
    end
    for i, p in ipairs(analysis.holes) do
        -- ★★★ THE LOOP BELOW IS VACUOUS FOR AN EMPTY SITE LIST (CART-0372), and
        -- `call_line` then indexes `p[sites_key][1]` and hands nil to `at.sl`,
        -- which RAISES. `plan` has a refusal channel used for 4080 of 4294 pairs
        -- on wow with precise reasons; raising on the 4295th loses a whole survey
        -- to one input, which is exactly what happened to the fold queue.
        --
        -- ⚠ A HOLE WITH NO SITE ON ONE SIDE HAS NO ARGUMENT TO PASS at that call,
        -- so there is nothing to guess at — the refusal is the answer, not a
        -- fallback. Checking `[1]` rather than `#` because that is the index
        -- `call_line` actually uses, and a sparse list makes the two disagree.
        if not (p.sites_a and p.sites_a[1] and p.sites_b and p.sites_b[1]) then
            return nil, ('hole %d has no located site on one side — there is no'
                .. ' argument to pass at that call'):format(i)
        end
        for _, side in ipairs({ { s = p.sites_a, open = a_open, close = a_close },
            { s = p.sites_b, open = b_open, close = b_close } }) do
            for _, r in ipairs(side.s) do
                if at.sl(r) ~= at.el(r) then return nil, ('hole %d spans multiple lines'):format(i) end
                if at.sl(r) < side.open or at.sl(r) > side.close then
                    return nil, ('hole %d is outside a body'):format(i)
                end
            end
        end
    end

    local hname = fresh_name(store, xfile and {} or { a.file }, a.name)
    local body_indent = indent_of(lines_a[a_open + 1])

    -- helper body = A's body lines, each hole's A-site replaced by its hp name
    local body = {}
    for i = a_open, a_close do body[#body + 1] = lines_a[i + 1] end
    local subs = {}
    for i, p in ipairs(analysis.holes) do
        for _, r in ipairs(p.sites_a) do
            local off = at.sl(r) - a_open
            subs[off] = subs[off] or {}
            subs[off][#subs[off] + 1] = { sc = at.sc(r), ec = at.ec(r), name = hp[i] }
        end
    end
    for off, list in pairs(subs) do
        table.sort(list, function (x, y) return x.sc > y.sc end)
        local l = body[off + 1]
        for _, s in ipairs(list) do l = l:sub(1, s.sc) .. s.name .. l:sub(s.ec + 1) end
        body[off + 1] = l
    end

    local hparams = {}
    for _, p in ipairs(va.params) do hparams[#hparams + 1] = p end
    for _, name in ipairs(hp) do hparams[#hparams + 1] = name end

    -- a copy's replacement body: `return <callee>(<its params>, <its fillings>)`
    local function call_line(callee, params, sites_key, src)
        local args = {}
        for _, p in ipairs(params) do args[#args + 1] = p end
        for _, p in ipairs(analysis.holes) do args[#args + 1] = span_text(src, p[sites_key][1]) end
        return body_indent .. syn.ret(callee, table.concat(args, ', '))
    end

    local plan = {
        verb = 'extract-helper', generation = store.generation,
        guards = { 'parses', 'synthesized' }, -- CART-0769: every text-editing verb owes rung 0
        helper = hname, nparams = #hp, xfile = xfile, lang = lang,
        files = {}, hazards = hazards,
        a = { id = a.id, name = a.name, ref = store.ref_of(a.id), file = a.file },
        b = { id = b.id, name = b.name, ref = store.ref_of(b.id), file = b.file },
    }

    if not xfile then
        -- helper as a local before the earlier copy; both bodies → return helper(…)
        -- CART-0985: a statement cannot go beside a member that is not one
        local member0 = math.min(a_sig, b_sig)
        local ins0, swhy = stmt_line(lines_a, lang, syn, member0)
        if not ins0 then
            return nil, ('the copies are not defined at a statement position (%s), and the'
                .. ' helper is a statement — there is nowhere in this file to put it')
                :format(tostring(swhy))
        end
        local below = reads_below(store, { a.id, b.id }, a.file, ins0,
            { [a.name] = true, [b.name] = true })
        if below then
            return nil, ('the helper would have to sit above `%s`, which it reads —'
                .. ' hoisting it out of the enclosing expression would leave that'
                .. ' undefined'):format(below)
        end
        local sig_indent = indent_of(lines_a[ins0 + 1])
        local helper = syn.local_helper(hname, table.concat(hparams, ', '), body, sig_indent)
        plan.files[a.file] = { ops = {
            { from0b = ins0, to0b = ins0 - 1, new = helper },
            { from0b = a_open, to0b = a_close, new = { call_line(hname, va.params, 'sites_a', lines_a) } },
            { from0b = b_open, to0b = b_close, new = { call_line(hname, vb.params, 'sites_b', lines_b) } },
        } }
        plan.touched = { a.file }
    else
        -- new module holding the helper as a member; each caller gains a require + a body
        local mod = syn.module(hname, table.concat(hparams, ', '), body)
        plan.create = { file = dest, lines = mod }
        plan.creates = { [dest] = true }
        plan.helper_call = alias .. '.' .. hname
        local ipa = import_point(lines_a, require('cartograph.providers.treesitter').import_pats(a.file))
        local ipb = import_point(lines_b, require('cartograph.providers.treesitter').import_pats(b.file))
        plan.files[a.file] = { ops = {
            { from0b = ipa, to0b = ipa - 1, new = { require_line } },
            { from0b = a_open, to0b = a_close, new = { call_line(plan.helper_call, va.params, 'sites_a', lines_a) } },
        } }
        plan.files[b.file] = { ops = {
            { from0b = ipb, to0b = ipb - 1, new = { require_line } },
            { from0b = b_open, to0b = b_close, new = { call_line(plan.helper_call, vb.params, 'sites_b', lines_b) } },
        } }
        plan.touched = { a.file, b.file, dest }
        table.sort(plan.touched)
    end

    plan.stamps = {}
    for _, f in ipairs(plan.touched) do
        if not (plan.creates and plan.creates[f]) then plan.stamps[f] = txn.disk_stamp(root, f) end
    end
    plan.refspecs = {
        { id = plan.a.id, name = plan.a.name, ref = plan.a.ref, what = 'clone' },
        { id = plan.b.id, name = plan.b.name, ref = plan.b.ref, what = 'clone' },
    }
    plan.expect = expectation(plan, EXTRACT[plan.lang])
    -- ★★★ THE FOLD'S BEHAVIOURAL RADIUS RIDES ON THE PLAN (CART-0989). `analyze_pair`
    -- decides it from the HOLES — the only place an extraction can introduce a delta,
    -- since the rest of the text is identical — so `neutral` means the radius is EMPTY
    -- and nothing needs certifying, and otherwise it names the hole and why.
    -- ⚠ IT IS A DISCLOSURE, NOT A GATE. The user's framing is "declare where we permit
    -- changed behavior and what requires a review": a non-neutral fold is REVIEWABLE,
    -- not refused. Refusing it would throw away a legal refactoring because we cannot
    -- yet prove something about it, which is the opposite of saying what we know.
    plan.behaviour = analysis.behaviour
    -- ★★★ THE NARROWING DECIDES THE CLAIM (CART-0989). `analysis.behaviour` already
    -- says whether any hole can carry a behavioural delta; an all-pure fold is neutral
    -- BY ANALYSIS and claims 'all'. One that is not does NOT get refused — it lands in
    -- the review bucket by name, which is exactly what the user asked the declaration
    -- to distinguish. Measured on our own tree: 5 of 6 plannable folds claim 'all'; the
    -- sixth is `unreviewed` because lifting its hole would move a `require`.
    plan.preserves = (plan.behaviour and plan.behaviour.neutral) and 'all' or 'unreviewed'
    plan.preserves_why = (plan.behaviour and plan.behaviour.why)
        or 'the fold\'s behavioural radius was not established'
    plan.precheck = function (st)
        if next(st.moveset or {}) then
            return 'a move-set is staged — apply or clear it first'
        end
    end
    plan.desc = {
        helper = plan.helper, xfile = plan.xfile,
        a = plan.a and plan.a.ref, b = plan.b and plan.b.ref,
        members = plan.members and #plan.members or nil,
    }
    return txn.protocol(plan, M.edits_for)
end

--- The edit callback (pure splice) — shared by preview and apply.
-- ── THE FAMILY PLAN: one helper for N copies, not C(N,2) proposals ───────────
--
-- ★★★ WHY NOT JUST RUN THE PAIR VERB N TIMES. Asking pairwise over a component
-- of N near-clones gives up to C(N,2) proposals which DISAGREE — measured, 84%
-- of wow's components — and the clique proxy agrees with the MDL partition on
-- only 38%. The family is the unit a human would extract; the pair is a sample
-- of it. So the template comes from `clones.families` (MDL) and the body from
-- `family_helper_text`, VERIFIED by the reparse oracle before a plan exists.
--
-- ⚠ SAME-FILE ONLY IN v1, REFUSED BY NAME OTHERWISE. Cross-file needs a new
-- module, N require lines, the free-read gate over N files, and a phase gate
-- whose union GROWS with N — on Factorio that refuses more often the larger the
-- family. The pair verb already treats cross-file as its own branch; this keeps
-- the split rather than half-doing it. MEASURED: 4 of 7 same-file on our own
-- tree, ~50 of 105 on wow.
--
-- ⚠ ADMISSIBLE MEMBERS ONLY. `liftable` members are nested and need their
-- captures turned into parameters (CART-0904); that changes the signature AND
-- the helper's placement, so v1 refuses them by name rather than guessing.
--
-- ★ PARTIAL IS SOUND HERE, and that is not inherited from the merge verb.
-- `clonemerge` refuses whole because "a partial merge rewrites the callers of a
-- twin that still exists" — dangling references. Extraction has no such
-- failure: the helper exists, the admissible bodies delegate, and a skipped
-- member keeps its own body. Nothing dangles and it parses. INCOMPLETE IS NOT
-- UNSOUND, so `opts.partial` extracts the admissible subset and the plan says
-- exactly who was left behind.

--- Build a plan to extract a FAMILY into one shared helper, or (nil, reason).
---@param store table
---@param fam table a family from `clones.families` / `clones.family_of`
---@param opts table|nil { partial = true to extract the admissible subset }
---@return table|nil plan, string|nil why
function M.plan_family(store, fam, opts)
    opts = opts or {}
    local clones = require 'cartograph.clones'
    if type(fam) ~= 'table' or type(fam.members) ~= 'table' or #fam.members < 2 then
        return nil, 'not a family of two or more'
    end

    local v, vwhy = clones.family_admissibility(fam, store)
    if not v then return nil, vwhy end
    if not v.body then
        return nil, 'no helper body: ' .. tostring(v.body_why)
    end

    -- ★ THE REPARSE ORACLE GATES THE PLAN, not just the display. A rendered
    -- helper that does not read back as its own template is not something to
    -- build a transaction on (CART-0893), and a hole at STATEMENT position
    -- renders text the grammar rejects (CART-0894) — caught here by name.
    local vok, verr, vdet = clones.family_verify(fam, store)
    if not vok then
        -- ⚠ TWO DIFFERENT FACTS, and for a WRITE both refuse. "The oracle cannot
        -- speak" (an anonymous-function donor is an EXPRESSION, so its own text
        -- is not a standalone chunk) is not the same as "the text is wrong" —
        -- but writing text nobody could check is the thing this plan must not
        -- do, so the distinction lands in the MESSAGE, not in the outcome.
        if vdet and vdet.verifiable == false then
            return nil, ('the helper body cannot be VERIFIED (%s) — refusing rather'
                .. ' than writing text nothing checked'):format(tostring(verr)
                :gsub('^not verifiable: ', ''))
        end
        return nil, 'the helper body does not verify: ' .. tostring(verr)
    end

    -- which members are we actually rewriting?
    local take = {}
    for _, i in ipairs(v.admissible) do take[#take + 1] = i end
    -- ★★★ THE CAPTURE LIFT (CART-0878). A member nested in another function is
    -- inadmissible because its body reads that function's locals — but those names
    -- are in scope AT THE CALL SITE, because the replacement lands in the member's
    -- BODY and the member itself stays where it is. So the capture becomes a
    -- PARAMETER and each site passes its own. `family_admissibility` has computed
    -- `liftable` and `lifts` since CART-0904; this is the apply half.
    --
    -- ⚠ OPT-IN, BECAUSE IT CHANGES THE HELPER'S SIGNATURE. The analysis says so in
    -- its own comment — "extractable ONLY IF the captures are lifted, which changes
    -- the signature, so they ride in `liftable`, not `admissible`, and the caller
    -- decides". Folding them in silently would be this verb deciding.
    -- ⚠ AND A TABLE CAPTURE SURVIVES BY REFERENCE, WHICH IS WHY THE WRITE REFUSAL
    -- STILL BINDS. `line_cache[k] = v` mutates the table a parameter points at, so
    -- lifting it preserves the effect; `n = n + 1` on a lifted SCALAR updates a copy
    -- and is silently wrong. The analysis refuses that case (`lift_why` on a write
    -- capture) and this path never sees it.
    local lifted
    if #take < 2 and opts.lift and (v.n_liftable or 0) >= 2 then
        take = {}
        for _, i in ipairs(v.liftable) do take[#take + 1] = i end
        lifted = v.lifts or {}
    end
    if #take < 2 then
        -- ⚠ DO NOT OFFER A FLAG THE CALLER ALREADY PASSED. With `lift` given and
        -- fewer than two liftable members, "pass `lift`" is a remedy that cannot be
        -- followed — the mirror of CART-0973, reintroduced by this very branch. When
        -- the flag is set the reason is `lift_why` or the member count, never the flag.
        if v.n_liftable > 0 and not opts.lift then
            return nil, ('%d member(s) need their captures lifted (%s): pass `lift`'
                .. ' to make them parameters of the helper, which each call site then'
                .. ' passes'):format(v.n_liftable,
                v.lifts and table.concat(v.lifts, ', ') or 'unknown')
        end
        if v.lift_why then
            return nil, ('the captures cannot be lifted: %s'):format(v.lift_why)
        end
        return nil, ('only %d member(s) are extractable; a helper needs two')
            :format(#take)
    end
    if #take < v.n and not opts.partial then
        local names = {}
        for _, rec in ipairs(v.refused) do
            names[#names + 1] = ('%s (%s)'):format(rec.name or '?', rec.reason or '?')
        end
        return nil, ('%d of %d members are not extractable: %s — pass opts.partial'
            .. ' to extract the rest'):format(v.n - #take, v.n,
            table.concat(names, '; '):sub(1, 200))
    end

    -- ⚠ ONE FILE OR MANY, and with N members a file may hold SEVERAL of them —
    -- the ops have to be grouped per file, not per member.
    local file, lang, byfile, files = nil, nil, {}, {}
    for _, i in ipairs(take) do
        local m = fam.members[i]
        if file == nil then file = m.file end
        if not byfile[m.file] then byfile[m.file] = {}; files[#files + 1] = m.file end
        table.insert(byfile[m.file], i)
    end
    table.sort(files)
    local xfile = #files > 1
    lang = lang_of(file)
    if not (lang and EXTRACT[lang]) then
        return nil, ('no synthesis syntax for %s'):format(tostring(lang))
    end
    for _, f in ipairs(files) do
        if lang_of(f) ~= lang then
            return nil, ('the family spans two languages (%s and %s)')
                :format(lang, tostring(lang_of(f)))
        end
    end
    local syn = EXTRACT[lang]
    if xfile and not syn.module then
        return nil, ('cross-file extraction is not supported for %s yet (no module'
            .. ' wiring)'):format(lang)
    end

    -- ── THE CROSS-FILE GATES, N-WAY ────────────────────────────────────────
    local dest, alias, require_line
    local hazards = {}
    if xfile then
        dest = opts.dest
        if not dest then
            return nil, ('the family spans %d files — pass a destination module'
                .. ' path for the shared helper'):format(#files)
        end
        if dest:sub(1, 1) == '/' or dest:find('%.%.') then
            return nil, 'the destination must be a plain path inside the project'
        end
        if txn.read_file(store.data.root, dest) then
            return nil, dest .. ' already exists — pick a new module path'
        end

        -- ★ THE FREE-READ GATE, ONCE PER MEMBER. A moved body may read only
        -- globals: a source-file LOCAL does not exist at the new home. With N
        -- members this is N chances to fail, and one failure is the whole
        -- family's — the helper is shared, so it must be movable for everyone.
        local un = require 'cartograph.untangle'
        for _, i in ipairs(take) do
            local m = fam.members[i]
            local mv = un.body_extractable(store, m.id)
            -- ⚠⚠ THIS GATE WAS VACUOUS FOR EXACTLY THE MEMBERS THE LIFT ENABLES, and
            -- the same early return caused it as caused the lost signature above:
            -- `body_extractable` answers `{ ok = false, nested = true }` and never
            -- reaches its read walk, so `mv.reads` is NIL and the loop below ran zero
            -- times. A lifted cross-file plan therefore passed a gate that had asked
            -- nothing — measured on CART-0878's own witness, whose helper body reads
            -- `callrec` (a file-local `require` in both source files) and which would
            -- have been written into a new module with `callrec` undefined. It parses.
            -- ⇒ `expr.free` answers for ANY function, nested or not, so the lifted
            -- path asks it directly.
            local reads = mv.reads
            if (reads == nil) and lifted then
                local ef = require('cartograph.expr').free(store, m.id)
                reads = ef and ef.reads or nil
                -- the LIFTED names are about to become parameters, so they are not
                -- free at the new home; anything else this body reads still has to
                -- exist there.
                if reads then
                    local r2 = {}
                    for r in pairs(reads) do r2[r] = true end
                    for _, name in ipairs(lifted) do r2[name] = nil end
                    reads = r2
                end
            end
            local loc = file_locals(store, m.file)
            for r in pairs(reads or {}) do
                if loc[r] then
                    return nil, ('%s reads file-local `%s` — it cannot move to a'
                        .. ' shared module'):format(m.name or '?', r)
                end
            end
        end

        -- ★★ THE PHASE GATE GETS STRICTER AS N GROWS, and that is the honest
        -- shape rather than a limitation to apologise for. The shared home loads
        -- in the UNION of every member's file's phases; a phase-bound global is
        -- safe only if every destination phase is that global's own. Two files
        -- may share a phase where five do not, so a family that a PAIR could
        -- extract may be refused — the refusal names the union so the reader can
        -- see why.
        local found, phaseset = phases_of(store)
        if found then
            local dest_ph, phlist = {}, {}
            for _, f in ipairs(files) do
                for p in pairs(phaseset[f] or {}) do
                    if not dest_ph[p] then dest_ph[p] = true; phlist[#phlist + 1] = p end
                end
            end
            table.sort(phlist)
            local nph = #phlist
            for _, i in ipairs(take) do
                local m = fam.members[i]
                local mv = un.body_extractable(store, m.id)
                for r in pairs(mv.reads or {}) do
                    local pg = PHASE_GLOBAL[r]
                    if pg and not (nph == 1 and dest_ph[pg]) then
                        return nil, ('%s reads phase-bound global `%s` (%s phase), but'
                            .. ' the shared module would load across phases {%s} —'
                            .. ' not phase-safe'):format(m.name or '?', r, pg,
                            table.concat(phlist, ', '))
                    end
                end
            end
        end

        local tsp1 = require 'cartograph.providers.treesitter'
        require_line, alias = tsp1.import_line(files[1], dest,
            tsp1.import_ctx(store.data.root, store.files))
        if not require_line then
            return nil, 'cannot form a require line for this language'
        end
        hazards[#hazards + 1] = ('verify the require path in `%s` resolves to %s')
            :format(require_line, dest)
    end

    -- the donor is the FIRST ADMISSIBLE member, because the body text is its own
    local donor_i = take[1]
    local tmpl, twhy = clones.family_template(fam, store, { donor = donor_i })
    if not tmpl then return nil, twhy end

    local root = store.data.root
    -- ⚠ ONE LINE ARRAY PER FILE. A member's filling is read from ITS OWN source,
    -- and cross-file the files differ; a single `lines` would silently slice the
    -- donor's text at another file's coordinates.
    local linesof = {}
    for _, f in ipairs(files) do
        linesof[f] = vim.split(txn.read_file(root, f) or '', '\n', { plain = true })
    end

    -- every member's body span, and the earliest signature line PER FILE (the
    -- same-file helper goes above the first member in that file)
    local spans, earliest = {}, {}
    for _, i in ipairs(take) do
        local m = fam.members[i]
        local sig, open, close = body_span(store, m.id, m.lines or {})
        if not sig then
            return nil, ('%s is not a clean multi-line block'):format(m.name or '?')
        end
        spans[i] = { sig = sig, open = open, close = close, file = m.file }
        if earliest[m.file] == nil or sig < earliest[m.file] then earliest[m.file] = sig end
    end
    -- ⚠ OVERLAP IS FATAL, and with N members it is O(N^2) rather than one check.
    -- Only WITHIN a file: two members in different files cannot overlap, and
    -- comparing their line numbers across files would invent a collision.
    for _, i in ipairs(take) do
        for _, j in ipairs(take) do
            if i ~= j and spans[i].file == spans[j].file
                and not (spans[i].close < spans[j].sig or spans[j].close < spans[i].sig) then
                return nil, ('%s and %s overlap (nested?) — cannot extract')
                    :format(fam.members[i].name or '?', fam.members[j].name or '?')
            end
        end
    end

    -- cross-file the helper lives in a NEW module, so no existing file's names
    -- constrain it; same-file it must not collide in the one file it lands in
    local hname = fresh_name(store, xfile and {} or { file }, fam.members[donor_i].name)
    local hparams = {}
    for _, p in ipairs((v.members[donor_i] or {}).nparams and {} or {}) do hparams[#hparams + 1] = p end
    do  -- the donor's own parameters, then one per hole
        local un = require 'cartograph.untangle'
        local dv = un.body_extractable(store, fam.members[donor_i].id)
        -- ⚠⚠ A NESTED MEMBER HAS NO `dv.params`, AND THE FIRST CUT OF THE LIFT LOST
        -- THE HELPER'S OWN SIGNATURE BECAUSE OF IT. `body_extractable` returns
        -- `{ ok = false, nested = true }` and nothing else the moment it finds an
        -- enclosing function — it never reaches the parameter walk. So the lifted
        -- path takes the DECLARED parameters off the node instead, and the preview
        -- caught it: the helper came out `(p1, p2, data, line_cache)` with `c` free
        -- in its body, which parses and is wrong.
        -- ★ THE CALL SITE CAN PASS THEM because the replacement lands in the member's
        -- BODY — `key_range(c, key)` keeps its own signature and its parameters are
        -- in scope where the delegating call is written.
        local dparams = dv.params
        if (not dparams or #dparams == 0) and lifted then
            dparams = (store.node(fam.members[donor_i].id) or {}).params
        end
        for _, p in ipairs(dparams or {}) do hparams[#hparams + 1] = p end
        for _, h in ipairs(tmpl.order) do hparams[#hparams + 1] = tmpl.params[h] end
        -- the lifted captures come LAST, so an existing signature's positions are
        -- unchanged and the diff reads as an append
        for _, name in ipairs(lifted or {}) do hparams[#hparams + 1] = name end
    end

    -- the helper body: the donor's own text with each hole occurrence replaced
    local body = {}
    for _, l in ipairs(vim.split(v.body, '\n', { plain = true })) do body[#body + 1] = l end
    -- `family_helper_text` renders from the donor's FULL range (signature
    -- included); the helper needs the BODY only, so drop the wrapper lines.
    table.remove(body, 1)
    table.remove(body)

    local plan = {
        verb = 'extract-family', generation = store.generation,
        guards = { 'parses', 'synthesized' },
        helper = hname, nparams = #tmpl.order, xfile = xfile, lang = lang,
        files = {}, hazards = hazards, partial = #take < v.n or nil,
        -- CART-0878: which enclosing locals became parameters. Present only when the
        -- caller opted in, so its absence is not "none were needed".
        lifted = (lifted and #lifted > 0) and lifted or nil,
        members = {}, left = {},
    }
    for _, rec in ipairs(v.refused) do
        plan.left[#plan.left + 1] = { name = rec.name, file = rec.file,
            line = rec.line, reason = rec.reason }
    end

    -- the CALLEE as each site writes it: a bare local same-file, `alias.helper`
    -- through the require cross-file
    local callee = xfile and (alias .. '.' .. hname) or hname
    if xfile then
        plan.create = { file = dest,
            lines = syn.module(hname, table.concat(hparams, ', '), body) }
        plan.creates = { [dest] = true }
        plan.helper_call = callee
    end

    local ops = {}
    for _, f in ipairs(files) do ops[f] = nil end
    local perfile = {}
    for _, f in ipairs(files) do perfile[f] = {} end

    if not xfile then
        -- the helper as a local above the first member in this file
        local mids = {}
        for _, m in ipairs(plan.members) do
            if m.file == file then mids[#mids + 1] = m.id end
        end
        -- CART-0985: a statement cannot go beside a member that is not one
        local member0 = earliest[file]
        local ins0, swhy = stmt_line(linesof[file], lang, syn, member0)
        if not ins0 then
            return nil, ('the copies are not defined at a statement position (%s), and the'
                .. ' helper is a statement — there is nowhere in this file to put it')
                :format(tostring(swhy))
        end
        local mnames = {}
        for _, m in ipairs(plan.members) do if m.name then mnames[m.name] = true end end
        local below = reads_below(store, mids, file, ins0, mnames)
        if below then
            return nil, ('the helper would have to sit above `%s`, which it reads —'
                .. ' hoisting it out of the enclosing expression would leave that'
                .. ' undefined'):format(below)
        end
        local sig_indent = indent_of(linesof[file][ins0 + 1])
        table.insert(perfile[file], { from0b = ins0, to0b = ins0 - 1,
            new = syn.local_helper(hname, table.concat(hparams, ', '), body, sig_indent) })
    else
        -- ⚠ ONE REQUIRE PER FILE, not one per member. A file holding three
        -- members needs the import once, and inserting it three times would
        -- produce three identical requires.
        local tsp = require 'cartograph.providers.treesitter'
        local ictx = tsp.import_ctx(store.data.root, store.files)
        for _, f in ipairs(files) do
            local rl = tsp.import_line(f, dest, ictx)
            if not rl then
                return nil, ('cannot form a require line for %s'):format(f)
            end
            local ip = import_point(linesof[f], tsp.import_pats(f))
            table.insert(perfile[f], { from0b = ip, to0b = ip - 1, new = { rl } })
        end
    end

    local un = require 'cartograph.untangle'
    for _, i in ipairs(take) do
        local m = fam.members[i]
        local mv = un.body_extractable(store, m.id)
        local args = {}
        -- same reason as the helper's signature above: a nested member's own
        -- parameters come off the node, and they are in scope at the call site
        local mparams = mv.params
        if (not mparams or #mparams == 0) and lifted then
            mparams = (store.node(m.id) or {}).params
        end
        for _, p in ipairs(mparams or {}) do args[#args + 1] = p end
        -- ★ EACH MEMBER PASSES ITS OWN FILLING, read from ITS OWN source at the
        -- span the template recorded for it — never the donor's, and never
        -- another file's line array.
        for _, h in ipairs(tmpl.order) do
            local val = (fam.values[i] or {})[h]
            local ext = clones.term_extent(val)
            if not ext then
                return nil, ('%s has no located value for %s'):format(m.name or '?', tmpl.params[h])
            end
            args[#args + 1] = span_text(linesof[m.file], ext)
        end
        -- ★ EACH SITE PASSES THE CAPTURE BY NAME, and the name is the same at every
        -- site by construction: `family_admissibility` only sets `lifts` when every
        -- capturing member agrees on the whole set, and a member capturing nothing is
        -- excluded from `liftable` rather than asked to pass a name it lacks.
        for _, name in ipairs(lifted or {}) do args[#args + 1] = name end
        table.insert(perfile[m.file], { from0b = spans[i].open, to0b = spans[i].close,
            new = { indent_of(linesof[m.file][spans[i].open + 1])
                .. syn.ret(callee, table.concat(args, ', ')) } })
        plan.members[#plan.members + 1] = { id = m.id, name = m.name,
            ref = store.ref_of(m.id), file = m.file }
    end

    for _, f in ipairs(files) do plan.files[f] = { ops = perfile[f] } end
    plan.touched = {}
    for _, f in ipairs(files) do plan.touched[#plan.touched + 1] = f end
    if xfile then plan.touched[#plan.touched + 1] = dest end
    table.sort(plan.touched)
    -- ⚠⚠ THE STAMP CAS WAS MISSING FROM EVERY FAMILY PLAN (CART-0878). `M.plan` sets
    -- `plan.stamps` and this builder did not, so the rung that refuses when a touched
    -- file changed since planning was simply absent — and `txn.verify` indexed nil
    -- rather than saying so. Nobody met it because the family verb could not be applied
    -- at all until today, which is the only reason a missing SAFETY rung stayed quiet.
    -- ⚠ A CREATED FILE HAS NO PRIOR STAMP, exactly as the pair path has it: stamping a
    -- file that does not exist yet would refuse the write it is meant to protect.
    plan.stamps = {}
    for _, f in ipairs(plan.touched) do
        if not (plan.creates and plan.creates[f]) then
            plan.stamps[f] = txn.disk_stamp(store.data.root, f)
        end
    end
    -- ★ THE FAMILY'S OWN SHAPE, DECLARED BY THE BUILDER THAT KNOWS IT. `apply` used to
    -- branch on `plan.members` vs `plan.a`/`plan.b` to rebuild this list, and got it
    -- wrong in the direction that raised (CART-0878).
    plan.refspecs = {}
    for _, m in ipairs(plan.members) do
        plan.refspecs[#plan.refspecs + 1] = { id = m.id, name = m.name,
            ref = m.ref, what = 'clone' }
    end
    plan.expect = expectation(plan, EXTRACT[plan.lang])
    -- ⚠ NO CLAIM, SAID OUT LOUD (CART-0989). The pair builder gets its behavioural
    -- radius from `analyze_pair`'s holes; a FAMILY plan is built from
    -- `family_admissibility`, which computes admissibility rather than per-hole purity,
    -- so there is nothing here to derive it from. Leaving the field ABSENT would render
    -- exactly like "we checked and it is neutral" — the NO_CLAIM-passes defect this arc
    -- has now met three times. It says it did not look.
    plan.behaviour = { neutral = nil,
        why = 'not computed for a family plan: family_admissibility does not carry'
            .. ' per-hole purity, so the radius is unknown rather than empty' }
    -- a family plan cannot yet establish its radius, so it says UNREVIEWED rather than
    -- inheriting the pair path's 'all'. Unknown is not neutral.
    plan.preserves = 'unreviewed'
    plan.preserves_why = plan.behaviour.why
    plan.precheck = function (st)
        if next(st.moveset or {}) then
            return 'a move-set is staged — apply or clear it first'
        end
    end
    plan.desc = {
        helper = plan.helper, xfile = plan.xfile,
        a = plan.a and plan.a.ref, b = plan.b and plan.b.ref,
        members = plan.members and #plan.members or nil,
    }
    -- ★ JOIN THE PLAN PROTOCOL — the one line every builder ends with. Without
    -- it `dryrun` refuses with "this verb has not joined the plan protocol",
    -- which is a correct refusal and an easy one to mistake for a bad plan.
    return txn.protocol(plan, M.edits_for)
end

function M.edits_for(plan)
    return function (rel, before)
        if plan.create and rel == plan.create.file then
            return table.concat(plan.create.lines, '\n')
        end
        local fe = plan.files[rel]
        if not fe then return before end
        local lines = vim.split(before, '\n', { plain = true })
        local ops = {}
        for _, o in ipairs(fe.ops) do ops[#ops + 1] = o end
        table.sort(ops, function (x, y) return x.from0b > y.from0b end) -- bottom-up
        for _, op in ipairs(ops) do
            for _ = op.from0b, op.to0b do table.remove(lines, op.from0b + 1) end
            for i = #op.new, 1, -1 do table.insert(lines, op.from0b + 1, op.new[i]) end
        end
        return table.concat(lines, '\n')
    end
end

function M.preview(store, plan)
    return txn.dryrun(store, plan)
end

--- The module's face on the generic driver (CART-0982). Everything this function used
--- to do by hand — the move-set precondition, the refspecs, the synthesis gates, the
--- journal description — is now declared on the plan by the builder that knows the
--- shape, and `txn.apply` runs any plan without knowing which verb built it.
---
--- ⚠⚠ AND THE SHAPE BRANCH WENT WITH IT, WHICH IS THE POINT. This function was
--- PAIR-ONLY: it read `plan.a`/`plan.b` — the shape `M.plan` builds — while
--- `M.plan_family` builds `plan.members`, so the family verb could PLAN and PREVIEW and
--- never apply, for as long as it existed (CART-0878). It did not refuse; it indexed a
--- nil field. An `apply` that must ask what shape its plan is, is an `apply` that can be
--- wrong about the answer — so the builders declare it and this asks nothing.
function M.apply(store, plan) return txn.apply(store, plan) end
return M
