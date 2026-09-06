-- declare — add a member to a declared container. CART-0766 step D, and the
-- consumer the template arc was waiting for.
--
-- ★★ WHY THIS VERB AND NOT ANOTHER REFACTORING. CART-0763 measured a day's real
-- work against the write surface: 15 commits, 17 touching lua/, ZERO file moves,
-- diffs shaped +158/-0, +130/-1, +105/-0, median ~ +60/-3. The work was ADD A
-- TABLE ENTRY, ADD A COMMENT BLOCK, ADD A TEST. The shipped verbs model moving
-- symbols and hoisting loop-invariants, so NONE of the day's commits could have
-- gone through the write ladder however reliable it became. The binding
-- constraint is edit-vocabulary coverage, not reliability — and "add an entry to
-- a declared table" is the most common edit AND the most tractable, because it is
-- structured data the expression IR already reads with `.at` ranges.
--
-- ★★ TWO INPUTS, WHICH IS THE USER'S OWN FRAMING ("a structural insert but also
-- a textual insert"):
--   member = '<source text>'   TEXTUAL   — you write it, cartograph checks it fits
--   subs   = { [hole] = text } STRUCTURAL — cartograph writes it from the donor
-- They converge immediately: both produce candidate TEXT, which is spliced into
-- the container, reparsed, and matched against the container's element template.
-- Construction differs; verification does not.
--
-- ★★ AND THE SURFACE IS SLICED, NEVER GUESSED — the same rule step C established
-- for the member, applied to the SEPARATOR. See `gap_of`.

local M = {}

local atr = require 'cartograph.at'
local expr = require 'cartograph.expr'
local clones = require 'cartograph.clones'
local txn = require 'cartograph.txn'

--- the source text a span covers (0-based lines/cols, end-exclusive — the
--- convention derived in CART-0766 step C, not assumed)
local function slice(lines, a)
    if not a then return nil end
    local sl, sc, el, ec = atr.sl(a), atr.sc(a), atr.el(a), atr.ec(a)
    if not lines[sl + 1] or not lines[el + 1] then return nil end
    if sl == el then return lines[sl + 1]:sub(sc + 1, ec) end
    local out = {}
    for ln = sl, el do
        local l = lines[ln + 1]
        if ln == sl then out[#out + 1] = l:sub(sc + 1)
        elseif ln == el then out[#out + 1] = l:sub(1, ec)
        else out[#out + 1] = l end
    end
    return table.concat(out, '\n')
end

--- ★★ THE SEPARATOR IS SLICED FROM BETWEEN THE FIRST TWO MEMBERS, and this is
--- the whole placement strategy. It replaces the obvious idea — copy the donor's
--- whole LINE — which MEASUREMENT KILLED:
---
---                      one member per line   two members share a line
---     lua (our tree)      87 of 714  (12%)     627 of 714  (88%)
---     php (grocy)        219 of 252  (87%)      33 of 252  (13%)
---     js  (jquery)        28 of  85  (33%)      57 of  85  (67%)
---
--- Whole-line copying is right for php and wrong for 88% of lua. Rather than
--- CLASSIFY the layout — which would be a rule per language per style, and wrong
--- the first time someone formats differently — take the text that already sits
--- between two real members. A compact table yields `, `; a one-per-line table
--- yields `,\n    ` with its indentation attached. ONE RULE, NO LAYOUT
--- VOCABULARY, and it is the step-C lesson one level up: the donor supplies the
--- surface, because it IS the surrounding style rather than an imitation of it.
local function gap_of(lines, ms)
    if #ms < 2 or not ms[1].at or not ms[2].at then return nil end
    local a, b = ms[1].at, ms[2].at
    return slice(lines, { start = { line = atr.el(a), char = atr.ec(a) },
        ['end'] = { line = atr.sl(b), char = atr.sc(b) } })
end

local function parse_root(text, lang)
    local okp, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not okp or not parser then return nil, 'cannot parse ' .. tostring(lang) end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return nil, 'cannot parse ' .. tostring(lang) end
    return tree:root()
end

--- ★★ NO PER-LANGUAGE CONTAINER-TYPE TABLE. The first cut declared
--- `{lua='table_constructor', php='array_creation_expression', javascript='object'}`
--- and searched by TYPE — a list that is wrong the moment a grammar spells a
--- literal differently, and the corpus oracle said so immediately: 49 php and 15
--- js containers came back "no container literal found". The IR ALREADY KNOWS
--- WHAT A CONTAINER IS (`k == 'table'`); asking tree-sitter to re-declare it in
--- three dialects was inventing a second vocabulary for a fact one layer down.
---
--- ★★ AND THE SEARCH IS BY EXACT START POSITION, NOT BY LINE, which is what the
--- oracle actually caught. Containers NEST and a line can begin two of them —
--- `local shim = { data = data,` is one line starting an outer table whose first
--- member starts another. Searching by line returned the OUTERMOST, so the check
--- judged a different container than the one that was edited, and reported three
--- unrelated-looking failure classes with one cause. The START position survives
--- an insertion (which happens after it) while the END does not, so the start is
--- the durable half of a span across this edit.
---@return table|nil ir, string|nil why
local function container_at(text, lang, sl, sc)
    local root, why = parse_root(text, lang)
    if not root then return nil, why end
    local okd, d = pcall(root.named_descendant_for_range, root, sl, sc, sl, sc)
    if not okd or not d then return nil, 'nothing at that position' end
    -- walk UP while the start still matches, taking the outermost node at that
    -- exact position which the IR reads as a container
    local best
    while d do
        local dsr, dsc = d:range()
        if dsr ~= sl or dsc ~= sc then break end
        local ok, ir = pcall(expr.build, d, text, lang)
        if ok and ir and ir.k == 'table' then best = ir end
        d = d:parent()
    end
    if not best then return nil, 'no container literal starts at that position' end
    return best, nil
end

--- ⚠ `k == 'table'` IS LOOSER THAN "CONTAINER LITERAL", MEASURED. A php
--- `new \HTMLPurifier($cfg)` builds to `k == 'table'` with the class name and
--- the argument as its "members" (CART-0774, found as the insert oracle's ONE
--- failure in 1021 — and the failure was this verb correctly REFUSING the
--- resulting nonsense). Nothing unsound is written, because the template match
--- rejects it; the cost is that such a symbol is offered as editable and then
--- refused for a reason that reads oddly.
---
--- The first container literal inside a declared symbol's range — how `plan`
--- turns "add to SOLE_WRAP" into a position. `verify` never uses this: once the
--- plan exists the container is addressed EXACTLY, because by then we know which
--- one was chosen and a nested one must not be able to answer instead.
---@return table|nil ir, string|nil why
function M.container_of(text, lang, range)
    local root, why = parse_root(text, lang)
    if not root then return nil, why end
    local found
    local function walk(nd)
        if found then return end
        local sr, _, er = nd:range()
        if range and (er < atr.sl(range) or sr > atr.el(range)) then return end
        local ok, ir = pcall(expr.build, nd, text, lang)
        if ok and ir and ir.k == 'table' then found = ir; return end
        for c in nd:iter_children() do if c:named() then walk(c) end end
    end
    walk(root)
    if not found then return nil, 'no container literal found in that range' end
    return found, nil
end

--- ★★ THE LAW, AT PLAN TIME AND AT EXECUTE TIME BY THE SAME CODE: a write
--- authorised by a derived fact must RE-DERIVE that fact after the write. The
--- authorising fact here is "this payload matches the container's element
--- template", so the check is: splice, reparse, rebuild the template, match.
---
--- ★ AND IT IS DELIBERATELY NOT `render`'s snippet check. Step C verifies that a
--- MEMBER parses and fits; that says nothing about whether the FILE still parses
--- with the member in it, and a valid member with the wrong separator or on the
--- wrong side of a delimiter is exactly the failure this had to avoid. Both are
--- needed and they are different assertions.
---@return boolean ok, string|nil why
--- ★★ THE TEMPLATE IS BUILT FROM THE MEMBERS *EXCEPT THE NEW ONE*, AND THE FIRST
--- CUT GOT THIS WRONG IN A WAY THAT MADE THE DIAGNOSIS CIRCULAR. Rebuilding it
--- from the whole post-insert container lets the bad member poison the template
--- it is being judged against, so a payload of the wrong shape came back as "the
--- members no longer share a shape" — true, and useless: yes, because of the one
--- you just added. Excluding the last member reconstructs the AUTHORISING
--- template exactly, needs nothing carried on the plan, and lets the refusal name
--- the divergence with step B's ranked vocabulary.
function M.verify(text, lang, sl, sc)
    local ir, why = container_at(text, lang, sl, sc)
    if not ir then return false, why end
    local ms = ir.kids or {}
    if #ms < 2 then return false, 'the container lost its members' end
    local prior = {}
    for i = 1, #ms - 1 do prior[i] = ms[i] end
    local t = clones.element_template({ k = 'table', kids = prior, at = ir.at })
    if not t.alignable then
        return false, 'the container\'s own members no longer share a shape'
    end
    local m = clones.match(t, ms[#ms], { lang = lang })
    if m.ok then return true end
    local names = {}
    for _, r in ipairs(m.refusal.features and m.refusal.features.rows or {}) do
        names[#names + 1] = r.feature
    end
    return false, ('the new member does not fit the ones already there (%s)')
        :format(#names > 0 and table.concat(names, ', ') or m.refusal.why)
end

--- Build the plan.
---@param store table
---@param opts table {
---   node = <id>            the declared symbol whose value is the container
---   member = '<text>'      TEXTUAL: the member you wrote
---   subs = { key = text }  STRUCTURAL: fill the template's holes instead
--- }
---@return table|nil plan, string|nil why
function M.plan(store, opts)
    opts = opts or {}
    local n = opts.node and store.node(opts.node)
    if not n then return nil, 'no declared symbol to add to' end
    if not n.file then return nil, n.name .. ' has no file' end
    local ts = require 'cartograph.providers.treesitter'
    local lang = ts.parse_lang(n.file)
    if not lang then return nil, 'no parser for ' .. n.file end
    local root = store.data.root
    local text = txn.read_file(root, n.file)
    if not text then return nil, 'cannot read ' .. n.file end
    local lines = vim.split(text, '\n', { plain = true })

    local ir, why = M.container_of(text, lang, n.range)
    if not ir then return nil, ('%s: %s'):format(n.name, why) end
    local ms = ir.kids or {}
    local t = clones.element_template(ir)

    -- ⚠ THE DOMINANT ANSWER, so its message matters most: 70.5% of containers
    -- with two or more members on our own lua tree share NO shape. "What should a
    -- new member look like" genuinely has no answer there, and inventing one from
    -- an arbitrary first member would answer a question nobody asked.
    if not t.alignable then
        return nil, ('%s\'s members do not share a shape (%d members), so there '
            .. 'is no template to check a new one against — supply the member '
            .. 'text and edit the file directly'):format(n.name, t.n or 0)
    end
    if (t.n or 0) < 2 then
        -- one member is a shape, not a template, AND there is no second member to
        -- read a separator from — both halves of this verb need the pair
        return nil, ('%s has %d member(s): a single member is a shape, not a '
            .. 'template, and there is no gap between two members to take the '
            .. 'separator from'):format(n.name, t.n or 0)
    end

    local gap = gap_of(lines, ms)
    if not gap then return nil, 'cannot read the separator between two members' end

    -- CONSTRUCT: textual (you wrote it) or structural (rendered from the donor)
    local member = opts.member
    if not member then
        if not opts.subs then
            return nil, 'supply `member` (the text) or `subs` (the template holes)'
        end
        local out, rwhy = clones.render(t, opts.subs, text, { unverified = true })
        if not out then return nil, 'render: ' .. tostring(rwhy) end
        member = out
    end
    member = (member:gsub('^%s+', ''):gsub('%s+$', ''))
    if member == '' then return nil, 'the member is empty' end

    -- PLACE: after the LAST member, so the closing delimiter is untouched. (The
    -- delete side had the opposite problem — CART-0773's witness is a last member
    -- that OWNS the closing brace — but an insertion writes BEFORE that brace and
    -- never disturbs it.)
    local last = ms[#ms]
    if not last.at then return nil, 'the last member has no source span' end
    if atr.el(last.at) ~= atr.sl(last.at) then
        -- ⚠ REFUSED BY NAME, v1: `txn.edit_file` applies a replacement's END
        -- COLUMN to its START LINE, so a multi-line rep is silently corrupted
        -- (CART-0767). This verb declines rather than inheriting that.
        return nil, ('%s\'s last member spans several lines, and a multi-line '
            .. 'replacement is not safe through this transaction layer yet '
            .. '(CART-0767)'):format(n.name)
    end
    local ins_at = { start = { line = atr.el(last.at), char = atr.ec(last.at) },
        ['end'] = { line = atr.el(last.at), char = atr.ec(last.at) } }

    -- ★ RE-DERIVE BEFORE PROMISING. The same check the guard runs at execute,
    -- run now so the refusal is early and specific instead of late and generic —
    -- the shape CART-0773 arrived at for the delete side.
    local edited = vim.deepcopy(lines)
    do
        local li = atr.el(last.at) + 1
        local l = edited[li]
        edited[li] = l:sub(1, atr.ec(last.at)) .. gap .. member .. l:sub(atr.ec(last.at) + 1)
    end
    local simulated = table.concat(edited, '\n')
    local ok, vwhy = M.verify(simulated, lang, atr.sl(ir.at), atr.sc(ir.at))
    if not ok then
        return nil, ('%s: %s'):format(n.name, vwhy)
    end

    local plan = {
        verb = 'declare',
        guards = { 'parses', 'shape-preserved' },
        generation = store.generation,
        touched = { n.file },
        stamps = { [n.file] = txn.disk_stamp(root, n.file) },
        hazards = {},
        -- the AUTHORISATION the guard re-derives (CART-0769's law): which
        -- container, in which file, at which line
        -- the AUTHORISATION the guard re-derives (CART-0769's law): WHICH
        -- container, addressed by the half of its span an insertion cannot move
        shape = { file = n.file, lang = lang,
            container_sl = atr.sl(ir.at), container_sc = atr.sc(ir.at) },
        target = { name = n.name, file = n.file, ref = store.ref_of(n.id) },
        member = member,
        reps = { { at = ins_at, to = gap .. member } },
    }
    return txn.protocol(plan, M.edits_for)
end

--- The verb's edit callback — shared verbatim by apply and preview.
function M.edits_for(plan)
    return function (rel, before)
        if rel ~= plan.shape.file then return before end
        return txn.edit_file(before, nil, plan.reps, nil)
    end
end

function M.preview(store, plan) return txn.dryrun(store, plan) end

function M.apply(store, plan)
    local bad = txn.verify(store, plan, { { ref = plan.target.ref,
        name = plan.target.name, what = 'symbol' } })
    if bad then return nil, bad end
    return txn.execute(store, plan, 'declare: add a member to ' .. plan.target.name)
end

return M
