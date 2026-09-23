-- planguards — the obligations a write plan declares, and the driver runs.
--
-- ★★ A GUARD IS NOT A VERB (CART-0769). A verb is something a caller CHOOSES to
-- call, so a guard that is a verb is a guard a caller can SKIP — and then the
-- safety property lives in the caller's discipline, which is the failure mode
-- this codebase keeps meeting under other names ("the guarantee was the UI's,
-- and making the verb agent-drivable removed it without replacing it",
-- moveapply.plan_ids). A verb also ANSWERS a question and carries its own
-- tier/absence/refusal; a guard decides whether an answer may be ACTED ON.
--
-- ★ THE PRECEDENT IS `edit_of`, AND THE ARGUMENT IS THE SAME SENTENCE. CART-0375
-- moved the edit callback off each verb's closure and onto the plan, because "a
-- caller holding a plan could not run it without knowing which module built it,
-- and that is the whole blocker for a generic driver". Substitute "guard" for
-- "edit_of". Before this module the state was:
--   FRESHNESS  txn.verify — generation, disk stamp, unsaved buffers, refspecs.
--              Shared, on the protocol. The one that was already right.
--   SYNTAX     `parses_clean`, THREE implementations across five modules, and
--              ABSENT from moveapply and clonemerge — the two that were then
--              measured writing unparseable files (CART-0770, CART-0773).
--   SEMANTIC   certificate.check / neutrality. Opt-in, unrelated machinery.
--   HAZARDS    advisory strings for a human. NEVER blocking, and measured
--              failing exactly that way: the grocy witness carried 24 hazards,
--              all about call sites, NONE about the method landing outside its
--              class. HAZARD PRESENCE IS NOT EVIDENCE THE BREAKAGE WAS FLAGGED.
-- Nothing enumerated which verb owed which guard, which is why two of eleven had
-- none and it took a census to notice.
--
-- ★★ THE LAW THE FAMILIES ARE ALL INSTANCES OF, stated here because nothing else
-- states it: A WRITE AUTHORISED BY A DERIVED FACT MUST RE-DERIVE THAT FACT AFTER
-- THE WRITE. `clones.render` re-MATCHES because a match authorised it;
-- `txn.verify`'s refspecs re-RESOLVE because a resolution authorised the plan;
-- `certificate.check` re-RUNS because the edit claimed behavioural neutrality.
-- Three altitudes, one shape, parameterised by WHICH FACT gets re-derived. The
-- rung ladder that falls out of it (parses / same kind / re-derives its own
-- authorisation) is deliberately NOT built here — this increment is rung 0.

local M = {}

M.PASS = 'pass'
M.FAIL = 'fail'
--- ⚠⚠ THE THIRD VALUE, AND IT IS THE ONE THAT MAKES THIS HONEST. "I did not
--- check" must not render the same as "I checked and it was fine" — that is an
--- absence rendered as silence, the defect class this project names elsewhere as
--- ABSENT vs UNAVAILABLE. A guard that cannot speak about a file says so.
M.NO_CLAIM = 'no-claim'

--- name -> fn(store, plan, before, after) -> rows
--- Each row is { verdict, file, why? }. A guard returns a row PER FILE rather
--- than one verdict, because "the plan failed" is not actionable and "`parses`
--- failed on controllers/BaseController.php" is.
M.GUARDS = {}

local function parses(text, lang)
    if not lang or not text then return nil end
    local ok, p = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not p then return nil end
    local okt, tree = pcall(function () return p:parse()[1] end)
    if not okt or not tree then return false end
    return not tree:root():has_error()
end

--- THE SYNTAX GUARD, AS A DELTA RATHER THAN AN ABSOLUTE — and that is not a
--- refinement, it is what makes it correct.
---
--- ★★ A WHOLE-FILE PARSE IS THE WRONG QUESTION FOR A CONTAINER FORMAT. A `.vue`
--- or `.svelte` file's `parse_lang` is `javascript`, because the graph parses its
--- `<script>` BLOCKS — but the whole file has never been javascript and never
--- will be. MEASURED on this repo's own fixtures: the three shipped
--- `parses_clean` copies (cloneextract, optapply, extractapply) all answer
--- "REFUSE" on `App.vue`, `Board.svelte` and `Leaf.vue` BEFORE ANY EDIT, so any
--- verb editing an SFC is permanently blocked by its own gate. Migrating them to
--- this form is a FIX, not a refactor.
---
--- ★ AND THE DELTA FORM NEEDED NO CONTAINER AWARENESS TO GET THERE. Ask whether
--- the edit BROKE something, not whether the result is perfect: if the file did
--- not parse as this language beforehand, there is nothing to compare and the
--- guard declines to claim. That also means it never blocks an edit to an
--- already-broken file — additive, the same argument as moveapply's
--- `enclosing_syntax` (CART-0770).
---
--- ⚠ WHAT IT DOES NOT CLAIM: that the edit is CORRECT. A moved nested function
--- parses perfectly and has lost its upvalues. This is rung 0.
M.GUARDS.parses = function (_, _, before, after)
    local ts = require 'cartograph.providers.treesitter'
    local rows, rels = {}, {}
    for rel in pairs(after or {}) do rels[#rels + 1] = rel end
    table.sort(rels) -- a total order, or the report is not a fact
    for _, rel in ipairs(rels) do
        local lang = ts.parse_lang(rel)
        if not lang then
            rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel,
                why = 'no parser is registered for this path' }
        else
            -- `before[rel] == false` is the CREATE case: there is no prior text,
            -- so the result must stand on its own.
            local pre = (before or {})[rel]
            local pre_ok = (pre ~= nil and pre ~= false) and parses(pre, lang) or nil
            if pre_ok == false then
                rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel,
                    why = ('this file does not parse as %s BEFORE the edit either '
                        .. '(a container format, or already broken), so there is '
                        .. 'nothing to compare against'):format(lang) }
            elseif pre_ok == nil and pre ~= false then
                rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel,
                    why = ('the %s parser is unavailable here'):format(lang) }
            else
                local post = parses(after[rel] or '', lang)
                if post == false then
                    rows[#rows + 1] = { verdict = M.FAIL, file = rel,
                        why = ('the edited file no longer parses as %s'):format(lang) }
                elseif post == nil then
                    rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel,
                        why = ('the %s parser is unavailable here'):format(lang) }
                else
                    rows[#rows + 1] = { verdict = M.PASS, file = rel }
                end
            end
        end
    end
    return rows
end

--- ★★ THE LAW ITSELF, AS A GUARD (CART-0769 increment 2). `parses` above is rung
--- 0: the file still compiles. This is rung 2 — THE WRITE RE-DERIVES THE FACT
--- THAT AUTHORISED IT. A `declare` plan exists because a payload matched a
--- container's element template, so after the write: reparse, find the container
--- again, rebuild the template, and match the member that is now there.
---
--- ★ IT IS DELIBERATELY NOT `clones.render`'s snippet check, and building it as a
--- guard rather than a callback is the point. Step C verified that a MEMBER
--- parses and fits — which says nothing about whether the FILE still holds a
--- well-shaped container with it inside. A valid member with the wrong separator,
--- or on the wrong side of a delimiter, passes the snippet check and fails this
--- one. Two assertions, both needed; and as a DECLARED obligation the caller
--- cannot drop it by forgetting an argument.
---
--- ⚠ THE CONTAINER MOVED. The insertion shifted every span after it, so the plan
--- carries the container's exact START POSITION and this re-finds it from there
--- rather than trusting a stale span: an insertion happens AFTER the start, so
--- the start is the durable half of the span and the end is not.
--- ⚠ POSITION, NOT LINE. Containers NEST and one line can begin two of them, so
--- a line-addressed search returns the outermost and judges a container that was
--- never edited. The corpus oracle caught exactly that, reporting it as three
--- unrelated-looking failure classes with one cause.
M.GUARDS['shape-preserved'] = function (_, plan, _, after)
    local sh = plan and plan.shape
    if not sh or not sh.file then
        return { { verdict = M.FAIL, why = 'the plan declares `shape-preserved` '
            .. 'but carries no `shape` to re-derive' } }
    end
    local text = (after or {})[sh.file]
    if type(text) ~= 'string' then
        return { { verdict = M.NO_CLAIM, file = sh.file,
            why = 'the plan does not produce text for this file' } }
    end
    local ok, why = require('cartograph.declare')
        .verify(text, sh.lang, sh.container_sl, sh.container_sc)
    if ok then return { { verdict = M.PASS, file = sh.file } } end
    -- ⚠ A PARSER THAT IS NOT INSTALLED IS NOT A FAILING SHAPE. Distinguishing
    -- them is the same three-valued honesty `parses` states above; collapsing
    -- them would refuse every write in a language whose grammar is absent.
    if why and (why:find('cannot parse') or why:find('no parser')
        or why:find('no container syntax')) then
        return { { verdict = M.NO_CLAIM, file = sh.file, why = why } }
    end
    return { { verdict = M.FAIL, file = sh.file, why = why or 'the shape did not survive' } }
end

--- THE CODE OF A FILE, WITH ITS COMMENTS REMOVED — the leaf (type, text)
--- sequence of the parse tree, skipping comment nodes. Two texts with the same
--- skeleton differ only in what was skipped.
---
--- ★ EXPORTED because `annotate` validates a candidate comment PREFIX with it:
--- splice a probe line into a real file and require the skeleton to be
--- unchanged. That is the same question the guard below asks AFTER a write,
--- asked BEFORE one — so a prefix that would trip the guard is refused at PLAN
--- time with a reason about the STYLE rather than about a failed guard. The
--- CART-0773 shape: the decision early and specific, the guard as backstop.
---@return string|nil skeleton, nil when the language has no parser here
function M.code_skeleton(text, lang)
    if type(text) ~= 'string' or not lang then return nil end
    local okp, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not okp or not parser then return nil end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return nil end
    local tsutil = require 'cartograph.spec.tsutil'
    local out = {}
    local lines = vim.split(text, '\n', { plain = true })
    local function walk(nd)
        if tsutil.is_comment(nd) then return end
        local kids = 0
        for c in nd:iter_children() do kids = kids + 1; walk(c) end
        if kids == 0 then
            local sr, sc, er, ec = nd:range()
            local t = (sr == er) and (lines[sr + 1] or ''):sub(sc + 1, ec) or nd:type()
            out[#out + 1] = nd:type() .. '\31' .. t
        end
    end
    walk(tree:root())
    return table.concat(out, '\30')
end

--- ★★★ THE EDIT WAS ONLY PROSE — and `parses` CANNOT ANSWER THIS (CART-0780).
--- An `annotate` plan is authorised by "this text is a comment", so the write
--- must re-derive that it stayed one. The hazard is specific: prose containing a
--- comment terminator can close the comment early and turn the rest into CODE,
--- and the result can parse PERFECTLY — so rung 0 passes and the file means
--- something else.
---
--- ⚠ MEASURED SCOPE, so nobody over-trusts it: through `annotate` this is a
--- BACKSTOP, not the primary barrier. The prefix is validated before use and
--- every line is prefixed, which designs the escape out for line comments (in
--- lua `-- oops --[[` is an ordinary comment, since a long comment needs `--[[`
--- at the comment's start). It is here for the prefix or grammar that breaks
--- that assumption, and it is driven directly in the spec because the verb can
--- no longer produce the failure.
---
--- ⚠ NO CLAIM WITHOUT A PARSER, like `parses` — a language whose grammar is
--- absent gets NO-CLAIM rather than a pass.
M.GUARDS['comment-inert'] = function (_, plan, before, after)
    local ts = require 'cartograph.providers.treesitter'
    local rows = {}
    for _, rel in ipairs((plan and plan.touched) or {}) do
        local lang = ts.parse_lang(rel)
        local b, a = (before or {})[rel], (after or {})[rel]
        if not lang or type(b) ~= 'string' or type(a) ~= 'string' then
            rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel,
                why = 'no parser, or no before/after text, so inertness cannot be checked' }
        else
            local sb, sa = M.code_skeleton(b, lang), M.code_skeleton(a, lang)
            if not sb or not sa then
                rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel,
                    why = ('the %s parser is unavailable here'):format(lang) }
            elseif sb == sa then
                rows[#rows + 1] = { verdict = M.PASS, file = rel }
            else
                rows[#rows + 1] = { verdict = M.FAIL, file = rel,
                    why = 'the edit was supposed to be prose only, and it changed the CODE '
                        .. '— a comment opener or terminator in the text has escaped' }
            end
        end
    end
    return rows
end

--- Run a plan's declared guards over a (before, after) pair.
--- ONE function, called by BOTH `txn.dryrun` and `txn.execute`, so the preview
--- and the write cannot disagree about what was checked.
---@return table rows, table|nil first_failure
--- THE SPAN-CAS, AS A GUARD (CART-0982). Every replacement's captured old text is
--- still exactly what sits at its range, and every deleted line is still the line the
--- plan captured.
---
--- ★★ IT WAS `optapply.apply`'s OWN CODE, and moving it here is what lets the driver
--- be generic — but it is also the only place the check has ever been TESTED, because
--- no test drove "span drifted" while it lived in the verb (CART-0982 measured four
--- verb-specific gates, none with a firing test).
---
--- ⚠ `plan.stamps` ALREADY REFUSES A FILE THAT CHANGED ON DISK, so this is not a
--- duplicate of it: a stamp is whole-file and this is span-grained, and the case it
--- catches is a plan built against a DIFFERENT REGION of a file that some other plan
--- in the same session legitimately rewrote.
---
--- ⚠ RANGES ARE 0-BASED (treesitter/`at` convention, unlike flow's 1-based rows), so
--- the 1-based Lua string index is char+1 and the reported line is line+1.
M.GUARDS['spans-unchanged'] = function (_, plan, before, _)
    local at = require 'cartograph.at'
    local rel = plan.rel
    if not rel then
        return { { verdict = M.NO_CLAIM,
            why = 'the plan names no single file to check spans in' } }
    end
    local text = before and before[rel]
    if type(text) ~= 'string' then
        return { { verdict = M.NO_CLAIM, file = rel,
            why = 'no before-content was read for this file' } }
    end
    local lines = vim.split(text, '\n', { plain = true })
    for _, r in ipairs(plan.reps or {}) do
        local sl0 = at.sl(r.at)
        local cur = (lines[sl0 + 1] or ''):sub(at.sc(r.at) + 1, at.ec(r.at))
        if cur ~= r.old then
            return { { verdict = M.FAIL, file = rel,
                why = ('span drifted at line %d (expected `%s`, found `%s`) — re-plan')
                    :format(sl0 + 1, tostring(r.old), cur) } }
        end
    end
    for _, d in ipairs(plan.dels or {}) do
        for i = d.s, d.e do
            if (lines[i + 1] or '\0') ~= (d.old and d.old[i - d.s + 1]) then
                return { { verdict = M.FAIL, file = rel,
                    why = ('span drifted at line %d (delete target changed) — re-plan')
                        :format(i + 1) } }
            end
        end
    end
    return { { verdict = M.PASS, file = rel } }
end

--- WHAT THE PLANNER PROMISED THE RESULT WOULD CONTAIN (CART-0982).
---
--- ★★★ THE PLANNER STATES THE EXPECTATION; THE GUARD CHECKS IT. `cloneextract.apply`
--- used to rebuild the patterns itself at apply time, which meant the driver had to
--- know the verb's language table and the plan's shape — the same coupling that made
--- a generic `txn_apply` impossible. The planner already knows both, so it writes
--- `plan.expect` down and this guard needs neither.
---
--- ⚠ IT IS A SYNTHESIS CHECK, NOT A CORRECTNESS ONE. "The helper I said I would write
--- is in the result, and the call sites I said I would rewrite are there" catches a
--- synthesis BUG — a generator that silently produced nothing. It says nothing about
--- whether the extraction preserves behaviour.
M.GUARDS.synthesized = function (_, plan, _, after)
    local e = plan.expect
    if type(e) ~= 'table' then
        return { { verdict = M.NO_CLAIM, why = 'the plan states no expectation' } }
    end
    local rows = {}
    if type(e.def) == 'table' then
        local text = (after or {})[e.def.file] or ''
        rows[#rows + 1] = text:find(e.def.needle, 1, true)
            and { verdict = M.PASS, file = e.def.file }
            or { verdict = M.FAIL, file = e.def.file,
                why = ('the definition the plan promised (`%s`) is missing from the'
                    .. ' result — a synthesis bug, not your code'):format(e.def.needle) }
    end
    if type(e.calls) == 'table' then
        local n = 0
        for _, rel in ipairs(plan.touched or {}) do
            if rel ~= e.calls.skip then
                local s, init = (after or {})[rel] or '', 1
                while true do
                    local i = s:find(e.calls.needle, init, true)
                    if not i then break end
                    n = n + 1; init = i + 1
                end
            end
        end
        rows[#rows + 1] = n >= e.calls.n
            and { verdict = M.PASS }
            or { verdict = M.FAIL,
                why = ('%d of %d call site(s) to `%s` are missing from the result'
                    .. ' — a synthesis bug, not your code')
                    :format(e.calls.n - n, e.calls.n, e.calls.needle) }
    end
    if #rows == 0 then
        rows[1] = { verdict = M.NO_CLAIM, why = 'the expectation names nothing to check' }
    end
    return rows
end

--- THE CAPTURED SOURCE LINES ARE STILL THERE (CART-0982's remainder). `reorder` moves a
--- statement range it read at plan time; if those lines changed since, the move is
--- against text that no longer exists. It was `reorder.apply`'s own code, and it is the
--- last verb-specific gate outside the plan.
---
--- ⚠⚠ `hoistclosure` HAS `src_lines` AND `src_s0` AND MUST NOT DECLARE THIS GUARD. Its
--- lines are DE-INDENTED at plan time ("so it sits cleanly at module level"), so they are
--- deliberately NOT what the file says and every comparison would fail. Two verbs, two
--- fields with the same names and different meanings — the guard checks a CONTRACT, not
--- a field name, and only a verb whose lines are verbatim may claim it.
M.GUARDS['source-lines-unchanged'] = function (_, plan, before, _)
    local rel = plan.file
    if not rel or type(plan.src_lines) ~= 'table' or plan.src_s0 == nil then
        return { { verdict = M.NO_CLAIM,
            why = 'the plan captured no source lines to compare' } }
    end
    local text = before and before[rel]
    if type(text) ~= 'string' then
        return { { verdict = M.NO_CLAIM, file = rel,
            why = 'no before-content was read for this file' } }
    end
    local lines = vim.split(text, '\n', { plain = true })
    for i, want in ipairs(plan.src_lines) do
        if lines[plan.src_s0 + i] ~= want then
            return { { verdict = M.FAIL, file = rel,
                why = ('the captured source line %d changed since planning — re-plan')
                    :format(plan.src_s0 + i) } }
        end
    end
    return { { verdict = M.PASS, file = rel } }
end

--- ★★★ NO REFERENCE WAS RE-POINTED (CART-1038) — the law at the level of NAMES.
--- `parses` says the file still compiles; this says every name still means what it meant.
--- Both texts are resolved by the algebra's Lua scope graph (`rebind`), and each reference
--- in the result is paired with its counterpart before the edit: unchanged text by the
--- diff, MOVED text by the origins the plan declares. A reference whose binding changed
--- when its token did not (a capture), or a local-reading name renamed to a free one (a
--- partial rename), fails the guard.
---
--- ★★ A MOVE DECLARES ITS ORIGINS, OR IT IS UNCHECKED TEXT. `plan.origins[rel]` is a list of
--- `{ op = <index into plan.files[rel].ops>, segs = { {off, len, from} } }`: these bytes of
--- that op's new text (joined by newlines) are a verbatim copy of `from` in the before-text.
--- The op's position in the result is computed from the ops' own line arithmetic (what
--- `cloneextract.edits_for` applies), and EVERY SEGMENT IS RE-READ FROM THE RESULT AND
--- COMPARED: a plan whose origins do not match the text it produced fails here as a
--- synthesis bug, rather than being checked against positions that are not there.
--- ⚠ LUA-ONLY: another language is a NO_CLAIM, and so is a file that did not parse before.
local function line_starts0(text) -- 0-based line -> byte offset
    local st = { [0] = 0 }
    local n = 0
    for i = 1, #text do if text:byte(i) == 10 then n = n + 1; st[n] = i end end
    return st
end
local function absolute_origins(plan, rel, pre, post)
    local fo = plan.origins and plan.origins[rel]
    if not fo then return nil end
    local ops = plan.files and plan.files[rel] and plan.files[rel].ops or {}
    local st = line_starts0(post)
    local out = {}
    for g, entry in ipairs(fo) do
        local op = ops[entry.op]
        if not op then
            return nil, ('the plan declares origins for op %s, which it does not have'):format(tostring(entry.op))
        end
        local shift = 0
        for _, o in ipairs(ops) do
            if o.from0b < op.from0b then shift = shift + #o.new - (o.to0b - o.from0b + 1) end
        end
        local base = st[op.from0b + shift]
        if not base then return nil, ('op %d lands past the end of the result'):format(entry.op) end
        for _, sg in ipairs(entry.segs or {}) do
            local a = { off = base + sg.off, len = sg.len, from = sg.from, group = g }
            if post:sub(a.off + 1, a.off + a.len) ~= pre:sub(sg.from + 1, sg.from + sg.len) then
                return nil, ('the result does not hold the text the plan says op %d copied from byte %d'
                    .. ' — a synthesis bug, not your code'):format(entry.op, sg.from)
            end
            out[#out + 1] = a
        end
    end
    return out
end
--- The line hunks the ops make, in vim.diff's `indices` form — and CHECKED: every line
--- outside an op must be the same line in the result, or the ops do not describe the edit.
local function op_hunks(plan, rel, pre, post)
    local ops = {}
    for _, o in ipairs(plan.files[rel].ops) do ops[#ops + 1] = o end
    table.sort(ops, function (x, y) return x.from0b < y.from0b end)
    local la = vim.split(pre, '\n', { plain = true })
    local lb = vim.split(post, '\n', { plain = true })
    local hunks, shift, a = {}, 0, 0 -- a: next unchecked 0-based before-line
    local function same_until(upto)
        while a < upto do
            if la[a + 1] ~= lb[a + shift + 1] then return false end
            a = a + 1
        end
        return true
    end
    for _, o in ipairs(ops) do
        if not same_until(o.from0b) then return nil end
        local ac, bc = o.to0b - o.from0b + 1, #o.new
        local afirst, bfirst = o.from0b + 1, o.from0b + shift + 1
        hunks[#hunks + 1] = { ac == 0 and afirst - 1 or afirst, ac, bc == 0 and bfirst - 1 or bfirst, bc }
        a = o.to0b + 1
        shift = shift + bc - ac
    end
    if not same_until(#la) then return nil end
    return hunks
end
M.GUARDS['bindings-preserved'] = function (_, plan, before, after)
    local ts = require 'cartograph.providers.treesitter'
    local rebind = require 'cartograph.rebind'
    local rows, rels = {}, {}
    for rel in pairs(after or {}) do rels[#rels + 1] = rel end
    table.sort(rels)
    for _, rel in ipairs(rels) do
        local pre, post = (before or {})[rel], after[rel]
        if ts.parse_lang(rel) ~= 'lua' then
            rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel,
                why = 'the binding check is Lua-only (the scope graph is Lua\'s mapping)' }
        elseif type(pre) ~= 'string' then
            rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel,
                why = 'a created file has no before-text to compare bindings against' }
        else
            local origins, owhy = absolute_origins(plan, rel, pre, post)
            if owhy then
                rows[#rows + 1] = { verdict = M.FAIL, file = rel, why = owhy }
            else
                local hunks
                if origins then
                    hunks = op_hunks(plan, rel, pre, post)
                    if not hunks then
                        rows[#rows + 1] = { verdict = M.FAIL, file = rel,
                            why = 'the result differs from the before-text outside the lines the plan says it'
                                .. ' replaced — a synthesis bug, not your code' }
                        goto continue
                    end
                end
                local v, vwhy = rebind.check(pre, post, { file = rel, origins = origins, hunks = hunks })
                if not v then
                    rows[#rows + 1] = { verdict = M.NO_CLAIM, file = rel, why = tostring(vwhy) }
                elseif not v.ok then
                    local r = v.refusals[1]
                    rows[#rows + 1] = { verdict = M.FAIL, file = rel, refusals = v.refusals,
                        why = r.why .. (#v.refusals > 1 and (' (and %d more)'):format(#v.refusals - 1) or '') }
                else
                    rows[#rows + 1] = { verdict = M.PASS, file = rel, counts = v.counts,
                        -- ⚠ WHAT WAS NOT CHECKED IS SAID: a new name with no origin has no
                        -- before to compare with (an insertion, or a move that declared none)
                        unchecked = v.counts.introduced > 0 and v.counts.introduced or nil }
                end
            end
        end
        ::continue::
    end
    return rows
end

function M.run(store, plan, before, after)
    local rows = {}
    for _, name in ipairs((plan and plan.guards) or {}) do
        local g = M.GUARDS[name]
        if not g then
            -- an unknown guard is a REFUSAL, not a skip: a plan naming a guard
            -- that does not exist has declared an obligation nobody can meet,
            -- and silently passing it would be the worst of both
            rows[#rows + 1] = { guard = name, verdict = M.FAIL,
                why = 'no such guard is registered' }
        else
            local ok, out = pcall(g, store, plan, before, after)
            if not ok then
                rows[#rows + 1] = { guard = name, verdict = M.FAIL,
                    why = 'the guard raised: ' .. tostring(out) }
            else
                for _, r in ipairs(out or {}) do
                    r.guard = name
                    rows[#rows + 1] = r
                end
            end
        end
    end
    for _, r in ipairs(rows) do
        if r.verdict == M.FAIL then return rows, r end
    end
    return rows, nil
end

--- The refusal string for a failure row — names the GUARD and the FILE, because
--- "it failed" sends a caller looking and "`parses` failed on x.php" does not.
function M.refusal(row)
    return ('guard `%s` failed%s: %s'):format(row.guard,
        row.file and (' on ' .. row.file) or '', row.why or 'no reason given')
end

--- The verdicts as display lines, for the surfaces a person or an agent reads a preview in.
--- ⚠ THE PREVIEW COMPUTED THESE AND NOTHING SHOWED THEM (CART-1038): `txn.dryrun` has stored
--- `plan.guard_verdicts` since CART-0769, and neither `:CartographDiff` nor `txn_preview` read
--- the field — so a guard FAIL was first seen as an apply refusal, after the review it was
--- meant to inform.
--- @return table lines  a summary line, then one line per row that is not PASS
function M.lines(rows)
    local out, pass = {}, 0
    for _, r in ipairs(rows or {}) do
        if r.verdict == M.PASS then pass = pass + 1
        else
            out[#out + 1] = ('guard `%s` %s%s: %s'):format(tostring(r.guard),
                r.verdict == M.FAIL and 'FAILS' or 'makes no claim',
                r.file and (' on ' .. r.file) or '', r.why or 'no reason given')
        end
    end
    local fails = 0
    for _, r in ipairs(rows or {}) do if r.verdict == M.FAIL then fails = fails + 1 end end
    table.insert(out, 1, ('guards: %d passed, %d failed, %d made no claim%s'):format(pass, fails,
        #out - fails, fails > 0 and ' — the apply will REFUSE' or ''))
    return out
end

--- Rows that are not PASS — what a preview should show. A NO_CLAIM is included
--- deliberately: it is the guard telling you it did not look.
function M.notable(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do
        if r.verdict ~= M.PASS then out[#out + 1] = r end
    end
    return out
end

return M
