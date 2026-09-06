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

--- Run a plan's declared guards over a (before, after) pair.
--- ONE function, called by BOTH `txn.dryrun` and `txn.execute`, so the preview
--- and the write cannot disagree about what was checked.
---@return table rows, table|nil first_failure
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
