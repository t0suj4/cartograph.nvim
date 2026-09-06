-- Extract-function APPLY: the txn face of the pure `extract` engine, the way
-- optapply is the txn face of `optimize` and moveapply is the write half of the
-- move-set. extract.lua COMPUTES the extraction (params from live-in, returns
-- from live-out, the new function text, the call that replaces the selection)
-- and splices lines; this module is what makes that splice a TRANSACTION —
-- generation + ref + file-stamp CAS, a parse-clean gate, journal-first commit,
-- and the refresh splice, all of it the same ladder every other write verb
-- rides ([[refactor-cockpit-design]]).
--
-- WHY IT EXISTS: the extract engine shipped with three separate report surfaces
-- computing a plan (a source-pane selection, :CartographUntangle's per-concern
-- candidates, :CartographUntangleModule's per-cluster candidates) and NO way to
-- stage any of them. The one path that did write — the source pane — called
-- vim.fn.writefile straight to disk: no journal, so no :CartographUndo; no CAS,
-- so a file edited since the plan was computed was silently clobbered; no parse
-- gate, so a bad splice landed broken; and no refresh, which is why it had to
-- tell the user to regenerate the graph by hand. That was the only write in the
-- plugin outside txn.lua, and this module retires it (CART-0125).
--
-- The plan IS an extract.plan plus txn metadata: `edits_for` hands the staged
-- plan straight back to extract.apply, which reads exactly the fields carried
-- (insert_before / new_fn / call / replace). One splice implementation, so the
-- dry-run diff, the applied bytes and the pure-engine tests cannot diverge.
--
-- Use headless (agent-drivable — plan → preview → verified apply, no cockpit;
-- [[cartograph-apply-for-agent]]):
--   local ea = require 'cartograph.extractapply'
--   local plan, why = ea.plan(store, fn_id, { first = 12, last = 15 }, 'sum')
--   if not plan then return why end            -- the engine's refusal, verbatim
--   print(table.concat(select(2, ea.preview(store, plan))[plan.file], '\n'))
--   local entry, err = ea.apply(store, plan)   -- journalled; parse-verified

local M = {}
local at = require 'cartograph.at'
local txn = require 'cartograph.txn'

--- Wrap a pure extract.plan into a staged transaction plan. The extract.plan's
--- own fields ride VERBATIM so extract.apply can consume the txn plan directly.
local function stage(store, node, exp, how)
    local root = store.data.root
    return txn.protocol({
        verb = 'extract-fn', generation = store.generation,
        guards = { 'parses' }, -- CART-0769: every text-editing verb owes rung 0
        file = node.file, fn = node.name or '?', fn_id = node.id,
        ref = store.ref_of(node.id), how = how,
        name = exp.name, params = exp.params, returns = exp.returns,
        new_fn = exp.new_fn, call = exp.call,
        replace = exp.replace, insert_before = exp.insert_before,
        hazards = exp.hazards,
        touched = { node.file },
        stamps = { [node.file] = txn.disk_stamp(root, node.file) },
    }, M.edits_for)
end

-- the enclosing function's frame, shared by every entry point: 1-based first
-- body line, last body line, its source, and the scope-correct reaching info.
-- Shadow safety (df-strangler step-5): CFG reaching attributes a shadowed
-- name's later uses to defs by ROW, so extract.plan drops a false return (or
-- refuses an unsure one) instead of emitting split-variable code.
local function frame(store, node)
    local all = store.content(node)
    if not all then return nil, 'cannot read ' .. node.file end
    local flow = require 'cartograph.flow'
    local fl = flow.present(node) and flow.record(node)
    local rows, reaching
    if fl then rows, reaching = fl.stmts, flow.reaching_cfg(fl) end
    -- The enclosing fn's declared parameters: invisible to dataflow (a parameter
    -- has no defining statement, so no dep edge), and the helper lands at module
    -- scope where they are NOT in scope — so extract.plan must be told, or it
    -- drops them from the interface and emits a nil-global read (CART-0125).
    --
    -- ONLY flow's list, and deliberately NOT `node.params` as a fallback:
    -- node.params is nil for a function with NO parameters (measured), so it
    -- conflates "none" with "not recorded" — the very conflation extract.plan's
    -- nil-refuses guard exists to catch. fl.params distinguishes them ({} vs
    -- nil). Passing nil through is correct: flow absent ⇒ df absent (df is
    -- derived from flow.coarse), so extract.plan refuses on the df check first
    -- and no reachable extraction is lost.
    return { lines = all, fn_start = at.sl(node.range) + 1,
        body_end = at.el(node.range), rows = rows, reaching = reaching,
        params = fl and fl.params or nil }
end

-- a function/method node, or nil + why
local function fnode(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return nil, 'no such node' end
    if node.kind ~= 'function' and node.kind ~= 'method' then
        return nil, 'not a function'
    end
    return node
end

--- Plan extracting the line range `sel` ({first,last}, 1-based FILE lines) of
--- function `fn_id` into a new local function `name`. Returns the staged plan,
--- or (nil, reason) — the engine's own refusal text, unaltered: it names the
--- reason (the selection cuts a control-structure body, contains a control
--- escape, splits a shadowed variable).
function M.plan(store, fn_id, sel, name)
    local node, why = fnode(store, fn_id)
    if not node then return nil, why end
    if not (name and name:match('^[%a_][%w_]*$')) then
        return nil, 'a helper name is required (an identifier)'
    end
    local fr, ferr = frame(store, node)
    if not fr then return nil, ferr end
    local exp = require('cartograph.extract').plan {
        df = require('cartograph.df').get(node), sel = sel,
        fn_start = fr.fn_start, body_end = fr.body_end, file_lines = fr.lines,
        name = name, reaching = fr.reaching, flow_rows = fr.rows,
        fn_params = fr.params }
    if not exp.ok then return nil, exp.reason end
    return stage(store, node, exp,
        ('L%d-%d of %s'):format(sel.first, sel.last, node.name or '?'))
end

--- Plan extracting CONCERN `c` of `fn_id` — the handoff :CartographUntangle's
--- "extract candidates" listing dry-runs. `c` is a comp id, or the letter the
--- report prints (A/B/C…). untangle picks the boundary and extract.plan
--- validates the mechanics independently — the disagreement oracle — so a
--- concern the report calls independent can still be refused here, and that
--- refusal is the honest answer, not a bug ([[cartograph-untangle-pdg]]).
function M.plan_concern(store, fn_id, c, name)
    local node, why = fnode(store, fn_id)
    if not node then return nil, why end
    local un = require 'cartograph.untangle'
    local flow = require 'cartograph.flow'
    local fl = flow.record(node)
    if not (fl and fl.stmts and #fl.stmts > 0) then
        return nil, ('%s has no fine flow (not an imperative body?)')
            :format(node.name or fn_id)
    end
    local comp = M.comp_of(c)
    if not comp then return nil, 'concern must be a letter (A/B/C…) or a comp id' end
    local edges, opaque = un.effect_edges(store, fn_id, fl)
    local res = un.analyze_flow(fl, edges, opaque)
    if comp >= res.ncomp then
        return nil, ('%s has %d concern(s) — no %s'):format(node.name or fn_id,
            res.ncomp, M.letter(comp))
    end
    local exp = un.extract_plan(store, fn_id, res, comp, name)
    if not exp.ok then return nil, exp.reason end
    -- the concern's own hedge is a DISCLOSURE, not a refusal: the mechanics are
    -- clean, but an unresolved effect could couple it to another concern. Rides
    -- the plan as a hazard so the plan bar and the diff both carry it.
    local plan = stage(store, node, exp,
        ('concern %s of %s'):format(M.letter(comp), node.name or '?'))
    if not res.certified or res.hedged[comp] then
        table.insert(plan.hazards, 1, ('concern %s is ~ NOT certified — an unresolved'
            .. ' effect could couple it to another concern (:CartographUntangle names'
            .. ' the blocking statements)'):format(M.letter(comp)))
    end
    return plan
end

--- 'A' → 0, 'b' → 1, 3 → 3. The report letters are the user's handle on a comp
--- id, so every verb that takes one accepts either spelling.
function M.comp_of(c)
    if type(c) == 'number' then return c >= 0 and math.floor(c) or nil end
    if type(c) ~= 'string' then return nil end
    local n = tonumber(c)
    if n then return n >= 0 and math.floor(n) or nil end
    if #c == 1 and c:match('%a') then return c:upper():byte() - 65 end
    return nil
end

function M.letter(c) return string.char(65 + (c % 26)) end

--- The edit callback: the pure engine's own splice, over the transaction's
--- before-content. One implementation — the diff shown and the bytes written
--- are the same code the extract_spec tests pin.
function M.edits_for(plan)
    return function (rel, before)
        if rel ~= plan.file then return before end
        local lines = vim.split(before, '\n', { plain = true })
        return table.concat(
            require('cartograph.extract').apply(plan, lines), '\n')
    end
end

function M.preview(store, plan)
    return txn.dryrun(store, plan)
end

function M.apply(store, plan)
    if next(store.moveset or {}) then
        return nil, 'a move-set is staged — apply or clear it first'
    end
    -- txn.verify's file-stamp CAS covers the whole file, so the selected span
    -- is guaranteed intact — no separate span-CAS needed (hoistclosure's note).
    local bad = txn.verify(store, plan,
        { { id = plan.fn_id, name = plan.fn, ref = plan.ref, what = 'function' } })
    if bad then return nil, bad end
    -- the result must parse: this splices a new function definition and rewrites
    -- a statement range, so a boundary the analysis mis-read shows up here
    local _, after = M.preview(store, plan)
    local text = after and after[plan.file] or ''
    local lang = require('cartograph.providers.treesitter').lang_of(plan.file)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang or 'lua')
    if not (ok and parser and not parser:parse()[1]:root():has_error()) then
        return nil, 'the extracted result does not parse — refusing'
    end
    return txn.execute(store, plan,
        { name = plan.name, from = plan.fn })
end

return M
