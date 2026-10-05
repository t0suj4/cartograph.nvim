-- cartograph.edit — ONE EDIT VERB, THE FLOOR (CART-1182): a GROUND rewrite `before -> after` at one site of a value in a
-- world. This first cut is the text / opaque kinds on the graph's own world (the disk, or an overlay the lens holds);
-- the term kinds, namespace addresses beyond the lens and non-disk commits are the ticket's next steps.
--
--   plan(store, { file, before, after })
--     file    the key in the world (a path relative to the graph's root; an absolute path inside it is accepted)
--     before  the text to replace — must occur EXACTLY ONCE (with enough context to be unique). '' = CREATE the file.
--             The whole current content = the OPAQUE kind (a whole-value compare-and-swap).
--     after   what it becomes
--
-- ★ IDEMPOTENT BY CLASSIFYING THE CURRENT STATE AGAINST BOTH IMAGES — looking only for `before` would refuse on a
-- re-run and break `rerun = 'empty'` (the IDEM fence runs every verb twice):
--     pending   before exactly once, after absent     -> the plan
--     done      after exactly once, before absent     -> EMPTY (nothing to write)
--     drifted   anything else                          -> refused BY NAME (the text is neither the pre- nor the post-state)
--   CONTAINMENT decides the order: an INSERT/APPEND (after contains before) is judged by `after` first — `before` is
--   still there after the apply, and judging it first would insert again; a DELETE (before contains after) by `before`
--   first — `after` is there in both states.
--   ⚠ A COINCIDENTAL `after` ELSEWHERE is not "done": when both occur, the state is drifted and the refusal asks for
--   context that makes the site unique. Never a silent no-op.
-- The classification runs AGAIN at stage time, on the text the stage actually sees (a chained preview's overlay world,
-- CART-1160 step 3), so an edit planned in one world and staged in another is judged where it lands.
-- GUARDS are derived, not listed: `parses` is always declared and answers NO CLAIM for a path no parser is registered
-- for (markdown, shell) — the refusal to over-claim is the guard's own. preserves = 'none': the text is SUPPLIED.
local M = {}

local function count(hay, needle)
    if needle == '' then return 0 end
    local n, i = 0, 1
    while true do
        local s, e = hay:find(needle, i, true)
        if not s then return n end
        n, i = n + 1, e + 1
    end
end

--- classify `text` (nil = the file is absent) against the transition -> state, why
function M.classify(text, before, after)
    if before == '' then
        if text == nil then return 'pending' end
        if text == after then return 'done' end
        return 'drifted', 'the file exists and is not the text to create — a create never overwrites'
    end
    if text == nil then return 'drifted', 'the file does not exist' end
    local nb, na = count(text, before), count(text, after)
    local a_has_b, b_has_a = after:find(before, 1, true) ~= nil, before:find(after, 1, true) ~= nil
    if after == '' then -- a pure deletion of `before`
        if nb == 1 then return 'pending' end
        if nb == 0 then return 'done' end
        return 'drifted', ('the text to delete occurs %d times — add context so the site is unique'):format(nb)
    end
    if a_has_b then
        -- INSERT / APPEND: `before` survives inside `after`, so `after` is the witness of done
        if na == 1 then return 'done' end
        if na == 0 and nb == 1 then return 'pending' end
        if na > 1 then return 'drifted', ('the result already occurs %d times — add context so the site is unique'):format(na) end
        return 'drifted', nb == 0 and 'neither the text to edit nor its result is there'
            or ('the text to edit occurs %d times — add context so the site is unique'):format(nb)
    end
    if b_has_a then
        -- DELETE-PART: `after` is present in both states, so `before` decides
        if nb == 1 then return 'pending' end
        if nb == 0 and na >= 1 then return 'done' end
        return 'drifted', ('the text to edit occurs %d times — add context so the site is unique'):format(nb)
    end
    if nb == 1 and na == 0 then return 'pending' end
    if nb == 0 and na == 1 then return 'done' end
    if nb == 0 and na == 0 then return 'drifted', 'neither the text to edit nor its result is there — the file moved on' end
    if nb >= 1 and na >= 1 then
        return 'drifted', 'both the text to edit and its result occur — a coincidental match elsewhere, or a half-applied edit: add context so the site is unique'
    end
    return 'drifted', ('the %s occurs %d times — add context so the site is unique'):format(nb > 1 and 'text to edit' or 'result', math.max(nb, na))
end

--- apply the transition to `text` (the classification is re-run on it) -> new text | text unchanged when done
function M.apply_to(text, before, after)
    local state, why = M.classify(text, before, after)
    if state == 'done' then return text end
    if state ~= 'pending' then error(why or 'drifted', 0) end
    if before == '' then return after end
    local s, e = text:find(before, 1, true)
    return text:sub(1, s - 1) .. after .. text:sub(e + 1)
end

local function rel_of(root, file)
    if type(file) ~= 'string' or file == '' then return nil end
    if file:sub(1, 1) == '/' then
        if file:sub(1, #root + 1) ~= root .. '/' then return nil end
        return file:sub(#root + 2)
    end
    return file
end

function M.plan(store, args)
    args = args or {}
    local txn = require 'cartograph.txn'
    local root = store.data and store.data.root
    if not root then return nil, 'no world is loaded to edit', 'ill-posed' end
    local rel = rel_of(root, args.file)
    if not rel then return nil, ('`file` must name a key inside the world %s'):format(root), 'ill-posed' end
    if type(args.before) ~= 'string' or type(args.after) ~= 'string' then
        return nil, 'an edit needs `before` and `after` text (before = \'\' creates the file)', 'ill-posed'
    end
    if args.before == args.after then return nil, 'before and after are the same text: the edit changes nothing', 'ill-posed' end
    local text = txn.read_file(root, rel)
    -- ★ WITHIN ONE FUNCTION (CART-1176, edit-in): `within` = a durable ref (or a node id) — the transition is judged
    -- and applied on that node's own source SLICE only, so the anchor must be unique inside the function, not in the
    -- file (a snippet that also occurs in a sibling is fine), and the slice is spliced back. Text, so any language.
    local slice_of
    if args.within ~= nil then
        local id = type(args.within) == 'table' and store.resolve_ref(args.within) or args.within
        local n = id and store.node(id)
        if not n then return nil, ('the function to edit within does not resolve (%s)'):format(vim.inspect(args.within)), 'stale' end
        if n.file ~= rel then return nil, ('%s is in %s, not %s'):format(tostring(n.name), tostring(n.file), rel), 'ill-posed' end
        if not text then return nil, ('cannot read %s'):format(rel), 'stale' end
        local atr = require 'cartograph.at'
        local sl, sc, el, ec = atr.sl(n.range), atr.sc(n.range), atr.el(n.range), atr.ec(n.range)
        slice_of = function (t)
            local lines = vim.split(t, '\n', { plain = true })
            local function offset(l, c) local o = 0; for i = 1, l do o = o + #(lines[i] or '') + 1 end; return o + c end
            return offset(sl, sc), offset(el, ec)
        end
        local s0, e0 = slice_of(text)
        local state, why = M.classify(text:sub(s0 + 1, e0), args.before, args.after)
        if state == 'done' then return nil, ('%s already holds this edit'):format(tostring(n.name)), 'empty' end
        if state ~= 'pending' then return nil, ('%s: %s'):format(tostring(n.name), tostring(why)), 'stale' end
    else
        local state, why = M.classify(text, args.before, args.after)
        if state == 'done' then return nil, ('%s already holds this edit'):format(rel), 'empty' end
        if state ~= 'pending' then return nil, ('%s: %s'):format(rel, tostring(why)), 'stale' end
    end
    local creates = args.before == '' and { [rel] = true } or nil
    local plan = {
        verb = 'edit',
        guards = { 'parses' },
        generation = store.generation,
        touched = { rel }, creates = creates, stamps = { [rel] = txn.disk_stamp(root, rel) }, refspecs = {},
        rel = rel, before_text = args.before, after_text = args.after,
        -- the text is SUPPLIED: no behavioural claim
        preserves = 'none', preserves_why = 'the edit applies supplied text; nothing checks what it means',
        hazards = {},
        desc = ('edit %s: %d -> %d bytes at one site%s'):format(rel, #args.before, #args.after, creates and ' (create)' or ''),
    }
    -- ★ A GATED EDIT (CART-1444): `decide = { kind, reason, evidence? }` makes the step a DECISION — it stops until the
    -- run accepts `kind` (or a remembered / signed answer does). For a write tactic whose text embodies a choice the
    -- code cannot make (memoize's residence). The decision key covers the evidence AND the text written, so one answer
    -- never covers another site or another text.
    if type(args.decide) == 'table' and args.decide.kind then
        local ev = {}
        for k, v in pairs(args.decide.evidence or {}) do ev[k] = v end
        ev.file, ev.text = rel, vim.fn.sha256(args.after)
        plan.hazards[1] = require('cartograph.hazard').new(args.decide.kind, tostring(args.decide.reason or args.decide.kind), nil, ev, 'decision')
    end
    plan.within = slice_of and true or nil
    return txn.protocol(plan, function (p)
        return function (r, before_text)
            if r ~= p.rel then return before_text end
            local t = before_text ~= false and before_text or nil
            if slice_of and t then
                -- re-sliced on the text the stage sees; the function's range is the graph's (a stale range refuses at
                -- apply through the stamp check)
                local s0, e0 = slice_of(t)
                return t:sub(1, s0) .. M.apply_to(t:sub(s0 + 1, e0), p.before_text, p.after_text) .. t:sub(e0 + 1)
            end
            return M.apply_to(t, p.before_text, p.after_text)
        end
    end)
end

return M
