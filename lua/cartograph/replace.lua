-- replace — swap a definition's text for text the CALLER supplies (CART-0977).
--
-- ★★★ WHY IT EXISTS, AND WHY IT IS LAST. CART-0972 drove every finding surface against
-- every planner's declared arguments. One producer fit no planner at all: `transplant`
-- derives new SOURCE TEXT — the edit a→b applied to c, computed by the algebra and
-- verified by the reader's own round-trip — and the five planners take a node, a node
-- SET, or a container plus a member. None takes bytes. The acceleration map's phrase for
-- it, "derives a real source edit and has nowhere to hand it", was exact.
--
-- ⚠⚠ AND THIS VERB'S GUARANTEE IS STRICTLY WEAKER THAN EVERY OTHER WRITE VERB'S. THAT IS
-- THE MOST IMPORTANT SENTENCE IN THIS FILE. `moveapply` moves text it read from the
-- graph; `optapply` emits a rewrite it derived; `annotate` writes prose it proved inert;
-- `cloneextract` synthesises from a template it computed. Each can re-check WHAT it is
-- about to write, because it built it. This one is handed bytes by a caller and can
-- check only two things:
--     · the result PARSES (rung 0, the delta form — see planguards)
--     · the FILE has not changed since planning (the stamp, which is stronger than a
--       span CAS: any byte moving anywhere in the file invalidates the plan)
-- It CANNOT check that the replacement defines the same name, keeps the same arity,
-- returns the same shape, or has anything whatever to do with what it replaces. A plan
-- that swaps a function for an unrelated one parses perfectly and passes every gate.
--
-- ⇒ SO EVERY PLAN CARRIES THAT AS A HAZARD, unconditionally. Not a note the builder
-- adds when it feels uncertain — a standing declaration of what was not verified,
-- because the thing a caller must not do is read this verb's success as agreement.
-- moveapply's rule one level further out: "a transaction that GUESSES is a transaction
-- that lies", and the only honest way to write text you did not derive is to say you
-- did not derive it.
--
-- ⚠ NOT A REFACTORING VERB, AND NOT A DIFF APPLIER EITHER. It has no opinion about
-- call sites, imports, or what else must change — anything mechanical would be a guess
-- here, and unlike `moveapply` there is no spec hook that could opt in, because the
-- payload's meaning is unknown by construction.

local M = {}
local atr = require 'cartograph.at'
local txn = require 'cartograph.txn'

--- Build a plan that replaces `opts.node`'s definition text with `opts.text`.
--- Returns (plan, nil) or (nil, reason).
function M.plan(store, opts)
    opts = opts or {}
    local n = opts.node and store.node(opts.node)
    if not n then return nil, 'no definition to replace' end
    if not n.file then return nil, tostring(n.name) .. ' has no file' end
    if not n.range then return nil, tostring(n.name) .. ' carries no range to replace' end
    local text = opts.text
    if type(text) ~= 'string' or text:gsub('%s', '') == '' then
        return nil, 'no replacement text'
    end
    local root = store.data.root
    local before = txn.read_file(root, n.file)
    if not before then return nil, 'cannot read ' .. n.file end

    local s, e = atr.sl(n.range), atr.el(n.range)
    local lines = vim.split(before, '\n', { plain = true })
    if not lines[e + 1] then
        return nil, ('%s spans lines %d..%d but %s has %d — the graph is stale, re-open it')
            :format(tostring(n.name), s + 1, e + 1, n.file, #lines)
    end
    -- ★ THE OLD TEXT RIDES ON THE PLAN so a reader can see what is being swapped, and
    -- so a preview's diff is about the definition rather than about the file.
    local old = {}
    for i = s, e do old[#old + 1] = lines[i + 1] end

    local plan = {
        verb = 'replace',
        -- ⚠ `parses` IS THE ONLY GUARD THERE IS, and that is a statement about this
        -- verb rather than an omission. `comment-inert` belongs to prose,
        -- `shape-preserved` to a container whose shape was derived; neither has a
        -- counterpart here, because nothing about the payload was derived.
        guards = { 'parses' },
        generation = store.generation,
        touched = { n.file },
        stamps = { [n.file] = txn.disk_stamp(root, n.file) },
        hazards = {},
        target = { id = n.id, name = n.name, file = n.file, ref = store.ref_of(n.id) },
        at = { s = s, e = e },
        old = old,
        new = vim.split(text, '\n', { plain = true }),
    }
    -- THE STANDING DECLARATION (see the header). Unconditional on purpose.
    plan.hazards[#plan.hazards + 1] = ('the replacement text was supplied, not derived:'
        .. ' this plan verifies that %s still PARSES and that the file has not moved'
        .. ' since planning, and NOTHING about whether the new text defines `%s`, keeps'
        .. ' its arity, or relates to what it replaces'):format(n.file, tostring(n.name))
    plan.refspecs = { { id = plan.target.id, name = plan.target.name,
        ref = plan.target.ref, what = 'definition' } }
    plan.desc = { name = plan.target.name, file = plan.target.file }
    return txn.protocol(plan, M.edits_for)
end

--- The splice: drop the definition's line range, put the new lines at the same index.
--- ⚠ NOT `txn.edit_file`'s `dels`, and the reason is a semantic one rather than a
--- preference. A deletion there SWALLOWS ONE TRAILING BLANK LINE so removals do not
--- leave double blanks behind — correct for a removal and wrong for a replacement,
--- which puts content back where the old content was. `cloneextract.edits_for` splices
--- a body the same way and for the same reason.
function M.edits_for(plan)
    return function (rel, before)
        if rel ~= plan.target.file then return before end
        local lines = vim.split(before, '\n', { plain = true })
        for _ = plan.at.s, plan.at.e do table.remove(lines, plan.at.s + 1) end
        for i = #plan.new, 1, -1 do table.insert(lines, plan.at.s + 1, plan.new[i]) end
        return table.concat(lines, '\n')
    end
end

function M.preview(store, plan) return txn.dryrun(store, plan) end

--- Kept as the module's face on the generic driver (CART-0982).
function M.apply(store, plan) return txn.apply(store, plan) end

return M
