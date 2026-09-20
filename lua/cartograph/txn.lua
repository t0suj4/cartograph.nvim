-- Shared transaction substrate: the refusal ladder and the journaled
-- write loop that every apply verb rides (clone-merge, move today;
-- extract-module and remote edits later). A verb brings a PLAN — refs,
-- stamps, the generation, its edits — and this module keeps the
-- contract: verify late-bound, refuse loudly with the reason, journal
-- before any byte moves, splice the touched files back after.

local M = {}
local atr = require 'cartograph.at'
local transport = require 'cartograph.transport' -- single owner of the validity key (stamp)

--- LEXICAL containment: is `rel` a plain path inside the project root?
--- ★ THE ONE PLACE THAT DECIDES IT, and it lives here because `root .. '/' .. rel`
--- is COMPOSED here — read_file, disk_stamp and the write loop all do it. The rule
--- that makes the composition safe belongs with the composition. moveapply guarded
--- exactly one of its two entry points (plan_extract_ids had the check, M.plan never
--- did), so a MOVE could name `../x.lua` and apply wrote outside the project,
--- creating parent directories on the way (CART-0577). A caller-side check that one
--- caller forgets is not a guard; this is the backstop that cannot be forgotten.
---
--- ★ LEXICAL, AND THAT WORD IS LOAD-BEARING. It rejects an absolute path and any
--- `..` SEGMENT. It does NOT resolve symlinks, so a symlinked directory inside the
--- root still leads out and this function will not say so. What is claimed:
--- containment against a CALLER-SUPPLIED PATH. What is NOT claimed: containment
--- against a hostile tree. Do not let a later reader mistake the second for the first.
---
--- A `..` SEGMENT, not the substring: `a..b.lua` is a legal filename that escapes
--- nothing, and refusing it would be a refusal with no premise behind it.
--- @return boolean ok, string? why
function M.contained(rel)
    if type(rel) ~= 'string' or rel == '' then
        return false, 'empty path'
    end
    if rel:match('^/') or rel:match('^%a:[/\\]') then
        return false, ('%s is absolute — the path must be relative to the project root')
            :format(rel)
    end
    for seg in rel:gmatch('[^/\\]+') do
        if seg == '..' then
            return false, ('%s escapes the project root'):format(rel)
        end
    end
    return true
end

--- Every path a plan will touch or CREATE must be contained. A plan is a SET of
--- writes, so checking only its `dest` is checking one member of it.
--- @return boolean ok, string? why
function M.contain_plan(plan)
    for _, rel in ipairs((plan and plan.touched) or {}) do
        local ok, why = M.contained(rel)
        if not ok then return false, 'refusing to write outside the project: ' .. why end
    end
    for rel in pairs((plan and plan.creates) or {}) do
        local ok, why = M.contained(rel)
        if not ok then return false, 'refusing to create outside the project: ' .. why end
    end
    return true
end

function M.read_file(root, rel)
    local fd = io.open(root .. '/' .. rel, 'r')
    if not fd then return nil end
    local text = fd:read('a')
    fd:close()
    return text
end

function M.disk_stamp(root, rel)
    return transport.stamp(root .. '/' .. rel)
end


--- ★★ IS THIS DEFINITION AT MODULE LEVEL? The shared predicate behind two write
--- verbs' soundness (CART-0770 for the LIFT, CART-0773 for the DELETE), and it
--- lives here because `txn` is where the plan protocol's shared predicates live
--- (`contained`, `attach_above`). It was moveapply-local for three days and a
--- second copy would have been the first thing this project tells itself not to
--- do.
---
--- A definition's TEXT is what a write verb moves or removes; its CONTAINER is
--- not part of that text. So a definition that is not at module level cannot
--- survive either operation. MEASURED: 369 broken move plans over three corpora,
--- in two surface forms with ONE cause —
--   php   moving `BaseApiController::ApiResponse` appends it AFTER the class's
--         closing brace, and a `protected function` at top level does not parse;
--   lua   moving `color` out of a table constructor takes ITS TRAILING COMMA with
--         it, and `color = function ... end,` at top level does not parse.
-- A class body and a table constructor are the same problem in two syntaxes.
--
-- ★ THE PREDICATE IS SYNTACTIC, NOT SEMANTIC, AND THE FIRST CUT GOT THAT WRONG.
-- "A method is a member of its type" refuses lua's `function M.foo()` — which is
-- a member SEMANTICALLY and a top-level statement SYNTACTICALLY, and is the
-- verb's single commonest legitimate move. That cut refused 129 of 216 working
-- moves on desynced. What actually breaks is being lexically INSIDE something,
-- so the test is: IS THE DEFINITION A DIRECT CHILD OF THE FILE ROOT?
--   php    program > class_declaration > declaration_list > method_declaration
--   lua    chunk > function_declaration                              <- moves
--   lua    chunk > assignment > table_constructor > field > function <- does not
-- Language-general, and it needs no new spec slot: `spec.qualify` already walks
-- to the enclosing class to name `Class::method`, so the graph HAS computed this
-- and kept only the `::` in a string.
--
-- MEASURED, 900 plans over 3 corpora: 368 of 368 broken plans CAUGHT, 0 missed,
-- and 42 previously-accepted plans now refused. Those 42 are overwhelmingly
-- `block < function_declaration` — a NESTED function, which is exactly what the
-- comment above already calls "lexically scoped, and lifting it to another file
-- is meaningless (and unsound)". They parse; they are not sound. So the cost is
-- an over-estimate: a parses-clean oracle cannot see a lost upvalue.
--
-- ⚠ NO CLAIM WHEN IT CANNOT PARSE. A file that will not parse here returns nil
-- (allow) rather than refusing: this is ADDITIVE, everything it cannot speak
-- about was already allowed, and refusing on absence of evidence would take the
-- verb away wherever a parser is missing. (The same three-valued honesty the
-- `parses` guard states explicitly; here the third value is simply `nil`.)
---@param file string   the path, for its language
---@param range table    the definition's range
---@param text string|nil the file's source
---@return string|nil  the enclosing chain, innermost first, or nil at module level
function M.enclosing_syntax(file, range, text)
    if not text then return nil end
    local okp, ts = pcall(require, 'cartograph.providers.treesitter')
    if not okp then return nil end
    local lang = ts.parse_lang(file)
    if not lang then return nil end
    local okr, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not okr or not parser then return nil end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return nil end
    local root = tree:root()
    local okd, d = pcall(root.named_descendant_for_range, root,
        atr.sl(range), atr.sc(range), atr.el(range), atr.ec(range))
    if not okd or not d then return nil end
    local fnt = ts.fn_types(lang) or {}
    while d and d ~= root and not fnt[d:type()] do d = d:parent() end
    if not d or d == root then return nil end
    local chain, p = {}, d:parent()
    while p and p ~= root do chain[#chain + 1] = p:type(); p = p:parent() end
    if #chain == 0 then return nil end
    return table.concat(chain, ' < ')
end

--- Comment adhesion: walk UP from a def's first line over lines that
--- belong to it (comments, decorators, attributes — per-language
--- patterns from the provider); blank lines and code stop the walk.
--- A block that reaches the TOP of the file belongs to the FILE, not
--- the def (license notices, file docblocks) — adhesion declines and
--- says so. `s` and the returned index are 0-based; the second return
--- is true when a top-of-file block was left behind.
function M.attach_above(lines, s, pats)
    local orig = s
    while s > 0 do
        local l = lines[s] or ''
        local hit
        for _, p in ipairs(pats) do
            if l:match(p) then hit = true break end
        end
        if not hit then break end
        s = s - 1
    end
    if s == 0 and orig > 0 then
        return orig, true -- the block touches line 1: a file header
    end
    return s, false
end

--- Apply deletions, token replacements and line insertions to one
--- file's text, bottom-up so earlier line numbers stay valid.
--- dels = {{s, e}} (0-based inclusive; one trailing blank swallowed),
--- reps = {{at, to}} (at = token range), ins = {{after, lines}}
--- (0-based; after = -1 inserts at the very top).
---
--- ⚠⚠ A REPLACEMENT MUST BE SINGLE-LINE, AND THIS NOW SAYS SO INSTEAD OF
--- CORRUPTING (CART-0767). The splice below takes the START line and then takes
--- its tail from the END COLUMN — on that same line. Given a rep spanning lines,
--- the intervening lines survive untouched and the end column is applied to the
--- wrong line. MEASURED on a four-line fixture, replacing (0,5)..(2,4):
---     want   line REPLACED three          (four lines collapse to two)
---     got    line REPLACED one            (and lines 2-4 untouched)
--- ★ NOT EVEN OBVIOUSLY BROKEN — plausible text, silently wrong, no error. The
--- doc line above says `at = token range`, and a token range IS single-line, so
--- every shipped caller is safe; nothing enforced it, and the next verb to pass a
--- NODE range would have inherited this. TWO verbs have already declined a
--- multi-line case by name rather than risk it (moveapply's last-member check,
--- `declare`'s), which is a rule held up by two comments instead of by code.
---
--- It RAISES rather than returning a refusal because `edit_of` is contracted to
--- return text: a nil would arrive downstream as an empty file. `dryrun` and
--- `execute` convert the raise into a named refusal.
function M.edit_file(text, dels, reps, ins)
    local lines = vim.split(text, '\n', { plain = true })
    local edits = {}
    for _, r in ipairs(reps or {}) do
        if atr.sl(r.at) ~= atr.el(r.at) then
            error(('edit_file: a replacement spanning lines %d..%d cannot be '
                .. 'applied — this splice is single-line by construction, and a '
                .. 'multi-line range would silently keep the intervening lines '
                .. '(CART-0767). Pass a token range, or split the edit.')
                :format(atr.sl(r.at) + 1, atr.el(r.at) + 1), 0)
        end
        edits[#edits + 1] = { line = atr.sl(r.at), ord = 2, rep = r }
    end
    for _, d in ipairs(dels or {}) do
        edits[#edits + 1] = { line = d.s, ord = 1, del = d }
    end
    for _, i in ipairs(ins or {}) do
        edits[#edits + 1] = { line = i.after, ord = 3, ins = i }
    end
    table.sort(edits, function (a, b)
        if a.line ~= b.line then return a.line > b.line end
        if a.ord ~= b.ord then return a.ord > b.ord end
        -- two replacements on the SAME line: apply the RIGHTMOST first, so each
        -- in-place splice leaves the earlier columns valid (else the first shifts
        -- them and the second corrupts — a latent bug for any multi-rep-per-line verb)
        if a.rep and b.rep then return atr.sc(a.rep.at) > atr.sc(b.rep.at) end
        return false
    end)
    for _, e in ipairs(edits) do
        if e.rep then
            local l = lines[e.line + 1]
            lines[e.line + 1] = l:sub(1, atr.sc(e.rep.at))
                .. e.rep.to .. l:sub(atr.ec(e.rep.at) + 1)
        elseif e.ins then
            for i = #e.ins.lines, 1, -1 do
                table.insert(lines, e.ins.after + 2, e.ins.lines[i])
            end
        else
            local last = e.del.e
            -- swallow one trailing blank line, so deletions don't
            -- leave double blanks behind
            if lines[last + 2] == '' then last = last + 1 end
            for _ = e.del.s, last do
                table.remove(lines, e.del.s + 1)
            end
        end
    end
    return table.concat(lines, '\n')
end

-- ★ THE PLAN PROTOCOL'S EDIT HALF (CART-0375). Every write verb's plan already carries the
-- same header — { verb, generation, touched, stamps, hazards? } — and every one runs the same
-- ladder here. The ONE thing that was NOT on the plan was `edit_of`, the
-- (rel, before, all_before) -> after callback each verb kept as its own closure and handed in
-- at the call site. A caller holding a plan therefore could not run it without knowing which
-- module built it, and that is the whole blocker for a generic driver.
--
-- Now `plan.edit_of` is part of the protocol: every builder stamps it, and dryrun/execute
-- default to it. An explicit argument still wins (a caller may substitute one), and a plan
-- carrying neither REFUSES BY NAME rather than calling a nil — a verb that has not joined the
-- protocol should say so here, not crash somewhere downstream.
local function resolve_edit(plan, edit_of)
    edit_of = edit_of or plan.edit_of
    if type(edit_of) ~= 'function' then
        return nil, ('the plan carries no edit_of (verb %s) — this verb has not joined the '
            .. 'plan protocol'):format(tostring(plan.verb))
    end
    return edit_of
end

--- Stamp a freshly built plan with its own edit callback and hand it back — the one line
--- every builder ends with, so joining the protocol is a single call rather than a convention
--- to remember. `edits_for` must be a PURE function of the plan (every verb's is): the
--- callback is now constructed at PLAN time and invoked at APPLY time, so anything it read
--- from the store or the disk at construction would silently freeze here.
---@param plan table
---@param edits_for fun(plan: table): fun(rel: string, before: string|boolean, all: table): string?
---@return table plan
function M.protocol(plan, edits_for)
    plan.edit_of = edits_for(plan)
    return plan
end

--- Dry-run a plan: the same before-content read and edit callback the
--- apply uses, but nothing written. Returns (before_map, after_map).
--- `edit_of` is optional — the plan's own is used when it is omitted.
---
--- ★★★ `opts.before` IS WHAT MAKES AN INTERMEDIARY EFFECT PREVIEWABLE (CART-0920).
--- A composition applies step 1 to nothing, step 2 to the result of step 1, and
--- so on; none of those middle states exists on disk, and until now this read the
--- file system unconditionally, so the preview could only ever show what a plan
--- does to the CURRENT tree. The RENDERING side was already virtual — every
--- verb's `edits_for` is called as `f(rel, before, all)` and takes its content as
--- an ARGUMENT — so this loop was the whole of what bound preview to the disk.
---
--- `opts.before` is a partial map `rel -> string | false`; `false` means the file
--- did not exist at that step (a create). Anything it does not mention is read
--- from disk, so a composition supplies only the files its earlier steps touched.
---
--- ⚠⚠ A VIRTUAL PREVIEW IS NOT A DISK PREVIEW, AND MUST NEVER SATISFY AN APPLY
--- GATE. `txn_apply` refuses a plan that "has never been diffed"; that gate exists
--- so nobody writes bytes no caller has seen. A diff taken against content that is
--- not on disk has not shown anyone what the write would do. The rels whose
--- content was SUPPLIED come back as the fourth return value for exactly that
--- reason — a caller that gates on having previewed must check it, and the agent's
--- `txn_preview` passes no opts at all.
---
--- ⚠ THE STAMP GUARANTEE DOES NOT MOVE WITH IT. `plan.stamps` pins each touched
--- file's disk stamp so `execute` can refuse on drift; a supplied before-image has
--- no stamp and cannot acquire one. Composed work must verify the ORIGINAL inputs'
--- stamps once, at the end — which `execute` still does, because it reads the disk
--- itself and never sees these opts.
--- @return table|nil before, table|nil after, string|nil why, table|nil virtual
function M.dryrun(store, plan, edit_of, opts)
    local nope
    edit_of, nope = resolve_edit(plan, edit_of)
    if not edit_of then return nil, nil, nope end
    local root = store.data.root
    local cok, cwhy = M.contain_plan(plan)
    if not cok then return nil, cwhy end
    local supplied = opts and opts.before or nil
    local before, virtual = {}, nil
    for _, rel in ipairs(plan.touched) do
        local t
        if supplied ~= nil and supplied[rel] ~= nil then
            -- ★ `false` IS A VALUE HERE, NOT AN ABSENCE: it says the file did not
            -- exist at this step. Testing truthiness instead of nil-ness would
            -- send a legitimate create back to the disk read below and refuse it.
            t = supplied[rel]
            virtual = virtual or {}
            virtual[#virtual + 1] = rel
        else
            t = M.read_file(root, rel)
            if not t then
                if not (plan.creates and plan.creates[rel]) then
                    return nil, nil, 'cannot read ' .. rel
                end
                t = false
            end
        end
        before[rel] = t
    end
    if virtual then table.sort(virtual) end
    -- ★ AN EDIT CALLBACK THAT RAISES IS A REFUSAL, NOT A CRASH (CART-0767, and
    -- CART-0372 is proof at least one verb's callback raises on real input). The
    -- scorer already pcall'd for this reason; the two paths that actually build
    -- the text did not, so a raise escaped `dryrun` and `execute` to whatever
    -- called them — an ex-command, or an agent verb that would report it as an
    -- internal error rather than as this plan being unbuildable.
    local after = {}
    for _, rel in ipairs(plan.touched) do
        local ok, out = pcall(edit_of, rel, before[rel], before)
        if not ok then
            return nil, nil, ('the edit for %s could not be built: %s')
                :format(rel, tostring(out))
        end
        after[rel] = out
    end
    -- ★ THE PREVIEW COMPUTES THE GUARDS AND DOES NOT REFUSE ON THEM (CART-0769).
    -- A preview of a FAILING plan plus its verdict is more useful than no
    -- preview — seeing the broken text is how you find out why — and `execute`
    -- is where the write happens and where the refusal belongs. Both call
    -- `planguards.run`, so what the preview checked and what the write checks
    -- cannot drift.
    -- ★ THE GUARDS SEE THE HYPOTHETICAL, WHICH IS RIGHT. `planguards.run` works
    -- from the (before, after) TEXT and reads no files, so a virtual step's
    -- guards judge the state that step would produce rather than the one on disk.
    plan.guard_verdicts = require('cartograph.planguards').run(store, plan, before, after)
    return before, after, nil, virtual
end

--- ★ THE PLAN PROTOCOL'S SCORING HALF (CART-0375): what this plan would do to the line count,
--- for ANY verb. Derived from the same (before, after) text the apply writes, so there is
--- exactly ONE shape to understand — text — instead of one per verb.
---
--- WHY THIS LIVES HERE AND NOT IN THE REPORT. `foldrank.delta` used to read
--- `plan.files[rel].ops`, which is cloneextract's shape, and SILENTLY RETURNED 0 for all 247
--- clonemerge plans — a fold queue that would have printed "247 folds, net 0", a work list
--- that looks complete and is worthless. A scorer that does not recognise a plan must REFUSE,
--- never score it zero: an absence rendered as a number is the same defect class as an absence
--- rendered as silence. Hence (nil, why) on every failure path, and a pcall — CART-0372 is
--- proof at least one verb's edit callback raises on real input, and a raise inside the scorer
--- must be a refusal row, not a dead queue.
---
--- Returns (added, removed, net) — net < 0 means the tree shrinks — or (nil, why).
---@param store table
---@param plan table
function M.delta(store, plan)
    local edit_of, nope = resolve_edit(plan, nil)
    if not edit_of then return nil, nope or 'no edit_of' end
    -- dryrun reads DISK NOW, so a stale plan would score fresh text against stale offsets and
    -- report a confident number for an edit that can no longer be applied.
    if plan.generation and store.generation ~= plan.generation then
        return nil, ('the plan is stale (gen %d -> %d) — re-plan')
            :format(plan.generation, store.generation)
    end
    local ok, before, after, derr = pcall(M.dryrun, store, plan, edit_of)
    if not ok then
        return nil, 'the edit callback RAISED: ' .. tostring(before):gsub('^.*/', '')
    end
    if not before or not after then return nil, derr or 'the dry run produced nothing' end
    local added, removed = 0, 0
    for _, rel in ipairs(plan.touched) do
        local b, a = before[rel], after[rel]
        -- a callback that declines a file returns it unchanged (or nil, as characterize does)
        if a ~= nil then
            local bt = b == false and '' or b   -- `false` = a file the plan CREATES
            if bt ~= a then
                for _, h in ipairs(vim.diff(bt, a, { result_type = 'indices' }) or {}) do
                    removed = removed + h[2]    -- count_a: lines the hunk drops
                    added = added + h[4]        -- count_b: lines the hunk introduces
                end
            end
        end
    end
    return added, removed, added - removed
end

--- A unified diff over (before, after) maps — what :CartographApply
--- would write, shown before it writes.
function M.difftext(before, after, order)
    local out = {}
    for _, rel in ipairs(order) do
        local b = before[rel]
        local a = after[rel] or ''
        out[#out + 1] = '--- ' .. (b == false and '/dev/null' or 'a/' .. rel)
        out[#out + 1] = '+++ b/' .. rel
        local d = vim.diff(b == false and '' or b, a,
            { result_type = 'unified', ctxlen = 3 })
        for _, l in ipairs(vim.split(d or '', '\n', { plain = true })) do
            if l ~= '' then out[#out + 1] = l end
        end
    end
    return out
end

--- The refusal ladder's common rungs: a live graph, the same
--- generation the plan was computed against, every ref still resolving
--- to its id witness-clean, file stamps unmoved (CAS), no dirty
--- buffers. `refspecs` = { {id, name, ref, what} }. Returns nil on
--- pass, or the refusal reason.
function M.verify(store, plan, refspecs)
    if store.data.partial then return 'extraction in progress' end
    if store.generation ~= plan.generation then
        return ('the graph changed since planning (gen %d -> %d) — re-plan')
            :format(plan.generation, store.generation)
    end
    -- ★★★ THE PLAN CARRIES THE RESOLUTIONS IT DEPENDS ON (CART-0982). Building
    -- refspecs inside each `apply` is what produced CART-0878's defect 2: cloneextract
    -- read `plan.a`/`plan.b` and raised on a family plan's `plan.members`, because the
    -- apply had to KNOW THE PLAN'S SHAPE to restate a fact the plan already held. The
    -- planner knows the shape; the driver must not have to.
    --
    -- ⚠ AND `or {}` WAS THE VACUOUS DEFAULT, the same `else` in miniature: a planner
    -- that simply forgot its refspecs got a verify that checked NOTHING and passed.
    -- Silence is not "no obligations" — it is an incomplete plan, and it refuses by
    -- name, exactly as `execute` does for a plan declaring no `guards`.
    refspecs = refspecs or plan.refspecs
    if not refspecs then
        return ('the plan for `%s` declares no refspecs — a write verb must name the '
            .. 'resolutions its plan depends on (`plan.refspecs = { ... }`), or say '
            .. '`{}` to declare that it depends on none'):format(tostring(plan.verb))
    end
    for _, spec in ipairs(refspecs) do
        local rid, note = store.resolve_ref(spec.ref)
        if not rid or rid ~= spec.id or note then
            return ('%s %s: %s'):format(spec.what or 'symbol', spec.name,
                note or 'no longer resolves')
        end
    end
    local root = store.data.root
    -- ⚠ A PLAN WITH NO `stamps` IS AN INCOMPLETE PLAN, NOT A PASSING ONE. Indexing a
    -- nil here RAISED, which reaches a caller as an "analysis" error and reads like a
    -- bug in the tree rather than in the plan (CART-0878: plan_family never set them,
    -- and the whole stamp-CAS rung was therefore absent). Refusing by name makes the
    -- omission a contract failure the builder is told about.
    if type(plan.stamps) ~= 'table' then
        return 'the plan carries no file stamps — it cannot be verified against disk'
    end
    for _, rel in ipairs(plan.touched) do
        if M.disk_stamp(root, rel) ~= plan.stamps[rel] then
            return rel .. ' changed on disk since planning — re-plan'
        end
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b)
                and vim.api.nvim_buf_get_name(b) == root .. '/' .. rel
                and vim.bo[b].modified then
                return rel .. ' has unsaved buffer changes — save or discard'
            end
        end
    end
end

--- ★★★ THE GENERIC DRIVER — RUN ANY PLAN WITHOUT KNOWING WHICH VERB BUILT IT.
---
--- USER (CART-0982): "It would be better if we didn't need to write verb's plan
--- semantics by hand". Before this, every write verb hand-wrote the same five steps in
--- its own `apply`, and `agent.txn_apply` kept a TABLE mapping each plan family to the
--- module whose `apply` to call — the fourth copy of one relation, and the third to be
--- wrong (CART-0878: three verbs could plan and preview and never apply).
---
--- ★ THE PRECEDENT IS `edit_of`, AND THE ARGUMENT IS THE SAME SENTENCE AS
--- planguards' (CART-0375/0769). "A caller holding a plan could not run it without
--- knowing which module built it, and that is the whole blocker for a generic driver."
--- Each step that used to be verb code is now something the PLAN declares:
---   refspecs  the resolutions it depends on        -> M.verify
---   guards    the obligations it accepts           -> planguards.run, inside execute
---   edit_of   the edit itself                      -> M.execute
---   desc      what the journal records             -> M.execute
---   precheck  a HOST precondition (optional)       -> here
---   consume   host state it spends (optional)      -> here
---
--- ⚠ `precheck` AND `consume` ARE CLOSURES, DELIBERATELY. Everything above them is
--- data, and data would be better — but a move-set's precondition reads live host
--- state (which symbols are staged right now) and its `consume` MUTATES that state,
--- and neither is a property of the plan that could be written down at plan time. A
--- closure the BUILDER stamps on the plan is still the plan carrying its own
--- semantics; a table in the driver naming which verbs need staging is not.
---
--- ⚠ ORDER IS LOAD-BEARING. `consume` runs AFTER verify and BEFORE execute: the
--- move-set splice must not see a frozen graph, and spending host state before the
--- plan is known to be applicable would leave the caller with neither.
--- @return table|nil entry, string|nil why
function M.apply(store, plan)
    if type(plan) ~= 'table' then return nil, 'not a plan' end
    if plan.precheck then
        local why = plan.precheck(store, plan)
        if why then return nil, why end
    end
    local bad = M.verify(store, plan)
    if bad then return nil, bad end
    if plan.consume then plan.consume(store, plan) end
    return M.execute(store, plan, plan.desc)
end

--- Journal-first commit: read every touched file's before-content,
--- journal.begin, run edit_of(rel, before, all_before) -> after per
--- file, write, journal.commit, clear the staged txn and splice the
--- touched files back through refresh — the same machinery every save
--- uses. Returns the journal entry, or nil + why.
function M.execute(store, plan, desc, edit_of)
    local nope
    edit_of, nope = resolve_edit(plan, edit_of)
    if not edit_of then return nil, nope end
    -- ⚠ A WRITE WITH NO DESCRIPTION REFUSES BY NAME, the same rule `guards`,
    -- `refspecs` and `edit_of` already live under. MEASURED (CART-0982): deleting a
    -- builder's `plan.desc` broke NOTHING — the journal recorded a nil description and
    -- the whole suite stayed green, so the one field of the protocol nobody checked
    -- was the one recording WHY a write happened. The journal is the only thing
    -- between a bad edit and a lost file; an entry that cannot say what it was for is
    -- a worse recovery story than no entry, because it looks like a record.
    desc = desc == nil and plan.desc or desc
    if desc == nil then
        return nil, ('the plan for `%s` carries no description — a write verb must say '
            .. 'what the journal should record (`plan.desc = ...`)'):format(tostring(plan.verb))
    end
    local root = store.data.root
    -- ★ THE BACKSTOP, AND IT MUST PRECEDE journal.begin: refusing after the journal
    -- opens would leave an entry for a write we never meant to make. Every path the
    -- plan touches or creates is checked, not just its dest — a plan is a SET of
    -- writes and one escaping member is enough (CART-0577).
    -- M.dryrun carries the same block on purpose: a preview that accepts what apply
    -- refuses is worse than either refusing, because it is discovered later.
    local cok, cwhy = M.contain_plan(plan)
    if not cok then return nil, cwhy end
    -- ⚠ AFTER THE CONTAINMENT BACKSTOP, NOT BEFORE IT. Placed earlier, this refusal
    -- PREEMPTED the "refusing to write outside the project" one — caught by CART-0577's
    -- own test, which builds an escaping plan and got told about a missing field
    -- instead. A SECURITY refusal must speak before a protocol-completeness one: the
    -- first is about what the plan would DO, the second about how it was written.
    -- ★★★ WHAT THIS PLAN CLAIMS ABOUT BEHAVIOUR (CART-0989). USER: "we could use the
    -- scope work to declare where we permit changed behavior and what requires a review."
    --
    -- `contain_plan` above already does this for the FILESYSTEM: every path a plan
    -- touches must be inside the project, and one escaping member refuses (CART-0577).
    -- This is the same rule one tier up. Until now NOT ONE WRITE VERB DECLARED A
    -- BEHAVIOURAL CLAIM — the five shipped guards are all textual, and `certificate`/
    -- `neutrality`, which RUN the code and compare, are off the ladder entirely. So
    -- `certificate.check`'s `changed` set had nothing to be compared against: a list of
    -- facts with no claim to falsify.
    --
    -- A CLOSED VOCABULARY, because an open one drifts into prose:
    --   'all'         every existing symbol's observable behaviour is unchanged
    --   'none'        NO claim — the payload was supplied, not derived (`replace`)
    --   'unreviewed'  this plan's claim has not been established. NOT a pass: it is
    --                 the REVIEW bucket, and it is what the user asked for by name.
    -- `plan.may_change` is the INTENDED delta — `declare` adds a member, so the
    -- container's contents change ON PURPOSE. Permitted change, stated rather than
    -- smuggled in under 'all'.
    --
    -- ⚠ IT REFUSES WHEN ABSENT, like `guards`/`refspecs`/`desc`. Silence here would
    -- mean "unknown", and rendering unknown as fine is the defect this whole arc is
    -- about. ⚠ AND NOTHING CHECKS THE CLAIM YET (CART-0374's rung): a declaration is
    -- reviewable by READING before it is checkable by running, and the checker arrives
    -- to something already written down.
    local PRESERVES = { all = true, none = true, unreviewed = true }
    -- ⚠ THE nil CHECK IS REDUNDANT FOR CATCHING AND KEPT FOR THE MESSAGE. `PRESERVES[nil]`
    -- is falsy, so the vocabulary check below would refuse an absent claim too — with
    -- "claims `nil`, which is not one of all|none|unreviewed", which describes the value
    -- rather than telling a builder what to write. Measured by revert: disabling this
    -- one leaves the plan refused, by the wrong sentence. Do not delete it as duplication.
    if plan.preserves == nil then
        return nil, ('the plan for `%s` declares no behavioural claim — a write verb '
            .. 'must say what it preserves (`plan.preserves = \'all\'|\'none\'|'
            .. '\'unreviewed\'`)'):format(tostring(plan.verb))
    end
    if not PRESERVES[plan.preserves] then
        return nil, ('the plan for `%s` claims `%s`, which is not one of all|none|'
            .. 'unreviewed'):format(tostring(plan.verb), tostring(plan.preserves))
    end
    local before = {}
    for _, rel in ipairs(plan.touched) do
        local t = M.read_file(root, rel)
        if not t then
            -- a file the plan CREATES has no before; anything else
            -- unreadable refuses (the stamp rung caught most of these)
            if not (plan.creates and plan.creates[rel]) then
                return nil, 'cannot read ' .. rel
            end
            t = false
        end
        before[rel] = t
    end
    -- ★★ THE GUARD RUNG, AND IT MUST PRECEDE journal.begin FOR THE SAME REASON
    -- THE CONTAINMENT BACKSTOP DOES (CART-0769). That is also why the whole
    -- `after` map is computed here rather than inside the write loop: you cannot
    -- refuse a plan you have not finished computing, and refusing after the
    -- journal opens leaves an entry for a write nobody meant to make.
    --
    -- ⚠ A PLAN DECLARING NO GUARDS REFUSES BY NAME. That is not strictness for
    -- its own sake: `resolve_edit` above already refuses a plan carrying no
    -- `edit_of` with "this verb has not joined the plan protocol", and the guard
    -- half is the same protocol. The alternative — treating silence as "no
    -- obligations" — is exactly how moveapply and clonemerge came to write
    -- unparseable files while five sibling verbs checked (CART-0770/0773): a
    -- missing guard looked identical to a guard that passed.
    if not plan.guards then
        return nil, ('the plan for `%s` declares no guards — a write verb must '
            .. 'name the obligations it accepts (`plan.guards = { \'parses\' }`), '
            .. 'or say `{}` to declare that it accepts none')
            :format(tostring(plan.verb))
    end
    local after = {}
    for _, rel in ipairs(plan.touched) do
        -- the same pcall dryrun runs, and for the same reason: a raise here is
        -- this plan refusing to be built, and it must be named rather than
        -- thrown past the caller (CART-0767)
        local ok, out = pcall(edit_of, rel, before[rel], before)
        if not ok then
            return nil, ('the edit for %s could not be built: %s'):format(rel, tostring(out))
        end
        after[rel] = out
    end
    -- ★★ A PLAN THAT CHANGES NOTHING IS REFUSED, AND THE CHECK IS GENERIC (CART-0982).
    -- `optapply` used to answer this per-verb, by counting its own `reps`/`dels`/`ins`
    -- — which is why the same sentence ("nothing applicable") came out of the ROUTER
    -- when an unrelated family reached it by accident and it found none of its fields.
    -- Comparing before to after asks the real question and asks it the same way for
    -- every verb, so no plan shape can answer it by being unrecognised.
    local touches = false
    for _, rel in ipairs(plan.touched) do
        if after[rel] ~= before[rel] then touches = true; break end
    end
    if not touches then
        return nil, ('the plan for `%s` would change nothing — every file it touches'
            .. ' comes out byte-identical'):format(tostring(plan.verb))
    end
    local verdicts, failed = require('cartograph.planguards').run(store, plan, before, after)
    plan.guard_verdicts = verdicts
    if failed then
        return nil, require('cartograph.planguards').refusal(failed)
    end

    local journal = require 'cartograph.journal'
    local entry, jerr = journal.begin(root, plan.verb, desc, before)
    if not entry then return nil, jerr end
    for _, rel in ipairs(plan.touched) do
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(dir, 'p') end
        local fd = io.open(root .. '/' .. rel, 'w')
        if not fd then
            journal.abort(root, entry, 'cannot write ' .. rel)
            return nil, 'cannot write ' .. rel .. ' (journal has before-content)'
        end
        fd:write(after[rel])
        fd:close()
    end
    journal.commit(root, entry, after)
    store.set_txn(nil)
    local ok, why = require('cartograph.refresh').files(plan.touched)
    if not ok then
        -- the writes are committed (journal has them); only the graph is stale
        vim.notify('cartograph: applied, but the graph refresh refused — '
            .. (why or '?') .. ' (:CartographRefresh when clear)', vim.log.levels.WARN)
    end
    vim.cmd('silent! checktime')
    return entry
end

return M
