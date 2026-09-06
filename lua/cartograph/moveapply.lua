-- Move-apply: the founding verb finally writes. The staged move-set
-- (dd cuts, p sets the destination) becomes a transaction: each
-- symbol's text leaves its file and lands in the destination —
-- journal-first, behind the same refusal ladder as clone-merge.
--
-- WHAT IT WRITES, and what it only DISCLOSES. The rule is not "text moves,
-- wiring is the human's": it is that a transaction which GUESSES is a
-- transaction that lies, so anything MECHANICAL in this language is written
-- and everything else rides the plan as a HAZARD with counts and file names.
-- Three things have crossed that line, each behind spec hooks a language opts
-- into (lua has; see spec/contract.lua for who else and why not):
--   * call-site requalification, when the site is exactly <srcAlias>.<name>
--   * the import line that introduces the destination alias (a4e089d)
--   * the destination file's MODULE SCAFFOLD, when the file is CREATED and the
--     idiom is unambiguous (`local M = {}` ... `return M`; CART-0542) — until
--     then an extracted lua module DISCLOSED that it was missing and did not
--     load at all
-- Everything still unwritten — bare-name call sites, an alias the dest file
-- already uses, captures shared with the staying code, the moved body's own
-- requires — is disclosed, not silently guessed at.
--
-- Use headless (agent-drivable — plan → preview → verified apply, no cockpit;
-- [[cartograph-apply-for-agent]]). The :CartographMove/Diff/Apply commands are
-- the interactive face of this same sequence:
--   local mv = require 'cartograph.moveapply'
--   local plan, err = mv.plan_moveset(store, { seed_id }, 'sub/dest.lua')
--   if not plan then return err end          -- refusal names the reason
--   print(mv.preview(store, plan))           -- dry-run diff, no writes
--   local ok, why = mv.apply(store, plan)    -- journalled; graph-PRESERVING witness
--                                            -- (nil,reason if the move-set moved)
-- plan_moveset IS the setup, whole: seed → dependency closure → the closure
-- STAGED in the store → destination → plan. That last rung matters because
-- `apply` confirms the plan against the LIVE move-set, so a plan built the long
-- way (close_moveset + plan_extract_ids, which deliberately do not touch
-- staging) must be staged too or apply refuses. Both refusals used to render
-- identically; they no longer do (CART-0576).

local M = {}
local atr = require 'cartograph.at'
local callrec = require 'cartograph.callrec'

-- where inserted code lands in dest: before a trailing `return M`-ish
-- line (the lua module idiom), else after the last nonblank line.
-- Returns a 0-based insert-before line index.
local function insert_point(lines)
    local last
    for i = #lines, 1, -1 do
        if lines[i]:match('%S') then last = i break end
    end
    if not last then return 0 end
    if lines[last]:match('^%s*return%s+[%w_%.]+%s*$') then
        return last - 1 -- 0-based index OF the return line
    end
    return last -- 0-based slot just after the last nonblank
end

-- a `var` moves only when MODULE-LEVEL: a function-local variable is lexically
-- scoped, and lifting it to another file is meaningless (and unsound). Module-
-- level = the var's range is not CONTAINED in any function/method node's range
-- in the same file. (Enables moving module-level constant tables — the spec-
-- module extraction case, [[cartograph-spec-layering]].)
local function module_level(store, n)
    local ns, ne = atr.sl(n.range), atr.el(n.range)
    for _, f in ipairs(store.data.nodes or {}) do
        if (f.kind == 'function' or f.kind == 'method')
            and f.file == n.file and f.id ~= n.id and f.range
            and atr.sl(f.range) <= ns and atr.el(f.range) >= ne then
            return false
        end
    end
    return true
end

-- ★★ THE SAME RULE, FOR EVERYTHING ELSE THAT MOVES (CART-0770). `module_level`
-- above states the principle and applies it only to `var`; a FUNCTION or METHOD
-- got no such check, so its text was lifted out of whatever it sat inside and
-- appended to the destination at top level. MEASURED: 369 broken plans over three
-- corpora, in two surface forms with ONE cause —
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
-- (allow) rather than refusing: this guard is ADDITIVE, everything it cannot
-- speak about was already allowed, and refusing on absence of evidence would
-- take the verb away wherever a parser is missing.
---@return string|nil  the enclosing chain, innermost first, or nil at module level
local function enclosing_syntax(store, n, text)
    if not text then return nil end
    local okp, ts = pcall(require, 'cartograph.providers.treesitter')
    if not okp then return nil end
    local lang = ts.parse_lang(n.file)
    if not lang then return nil end
    local okr, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not okr or not parser then return nil end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return nil end
    local root = tree:root()
    local okd, d = pcall(root.named_descendant_for_range, root,
        atr.sl(n.range), atr.sc(n.range), atr.el(n.range), atr.ec(n.range))
    if not okd or not d then return nil end
    local fnt = ts.fn_types(lang) or {}
    while d and d ~= root and not fnt[d:type()] do d = d:parent() end
    if not d or d == root then return nil end
    local chain, p = {}, d:parent()
    while p and p ~= root do chain[#chain + 1] = p:type(); p = p:parent() end
    if #chain == 0 then return nil end
    return table.concat(chain, ' < ')
end

-- THE MODULE SCAFFOLD (CART-0542). A file this verb CREATES used to get the
-- language header plus the moved text and nothing else -- so an extracted lua
-- module opened with `function M.scan` and no `local M = {}`. That COMPILES (M
-- is a global at compile time) and dies on first require: "attempt to index
-- global 'M' (a nil value)". The verb DISCLOSED it as a capture hazard, so the
-- contract held; but a disclosure that must be honoured before the tree loads
-- at all is not advisory polish, it is completion work the verb can do.
--
-- Written on exactly the terms import wiring is (a4e089d): only when the idiom
-- is MECHANICAL, which here means all of --
--   * the destination's spec declares one (ts.module_scaffold; lua only)
--   * every source file whose moved text mentions a module table names the SAME
--     one, read from that file's own `local M = {}` ... `return M`
--   * the moved lines genuinely mention it
--   * the declaration is not itself travelling in the move-set (then the text
--     already carries a `local M = {}` and a second one would shadow it)
-- Any of those unmet: nothing is written and every hazard stands unchanged.
--
-- WHAT IT DOES NOT PROMISE. The new table is a NEW EMPTY table, so a moved
-- reference to a member that STAYED behind resolves to nil -- a load-clean file
-- with a runtime hole. So the residual is enumerated (`M.foo` not defined by
-- the move-set; a bare `M` handed somewhere as a value) and disclosed, and the
-- capture hazard is retired ONLY when that residual is empty, i.e. only when
-- the write really is complete. Retiring it matters: its instruction ("require
-- it, or copy it into the extracted module") aliases the OLD module's table,
-- which after the scaffold is the wrong table to reach for.
local function module_scaffold(plan, dest, ts, file_lines)
    local moved = {}
    for _, m in ipairs(plan.moves) do moved[m.name] = true end
    local name, disagree
    for _, m in ipairs(plan.moves) do
        local ls = file_lines(m.file)
        local n = ls and ts.module_table(m.file, ls) or nil
        if n and not moved[n] then
            local seen = false
            for i = m.lines.s + 1, m.lines.e + 1 do
                if (ls[i] or ''):find('%f[%w_]' .. n .. '%f[^%w_]') then
                    seen = true; break
                end
            end
            if seen then
                if name and name ~= n then disagree = true end
                name = name or n
            end
        end
    end
    if not name or disagree then return end
    local pre, post = ts.module_scaffold(dest, name)
    if not (pre and post) then return end
    plan.scaffold = { name = name, pre = pre, post = post }
    -- every mention of the name the fresh table does NOT satisfy
    local left, order = {}, {}
    for _, m in ipairs(plan.moves) do
        local ls = file_lines(m.file) or {}
        for i = m.lines.s + 1, m.lines.e + 1 do
            local l, pos = ls[i] or '', 1
            while true do
                local a, b = l:find('%f[%w_]' .. name .. '%f[^%w_]', pos)
                if not a then break end
                local member = l:match('^%.([%a_][%w_]*)', b + 1)
                local spell = member and (name .. '.' .. member) or name
                if not moved[spell] and not left[spell] then
                    left[spell] = true; order[#order + 1] = spell
                end
                pos = b + 1
            end
        end
    end
    local kept = {}
    for _, h in ipairs(plan.hazards) do
        if not h:find('^capture: ' .. name .. '%f[%W]') then
            kept[#kept + 1] = h
        end
    end
    plan.hazards = kept
    if #order > 0 then
        table.sort(order)
        plan.hazards[#plan.hazards + 1] = ('%s is created FRESH in %s (its'
            .. ' `local %s = {}` and `return %s` are written) — but the moved'
            .. ' code still reaches %s, which the new table does not hold:'
            .. ' wire those by hand'):format(name, dest, name, name,
            table.concat(order, ', '))
    end
end

-- the shared plan core: collect the staged symbols (kind gate, comment
-- adhesion, cbarg disclosure), fold in the ImpactEngine's findings as
-- disclosure hazards, stamp the touched set. Both verbs (move,
-- extract-module) build on it.
local function collect(store, ids, dest, plan)
    local txn = require 'cartograph.txn'
    local root = store.data.root
    local okp, ts = pcall(require, 'cartograph.providers.treesitter')
    local lines_cache, text_cache = {}, {}
    local function file_text(rel)
        if text_cache[rel] == nil then text_cache[rel] = txn.read_file(root, rel) or false end
        return text_cache[rel] or nil
    end
    local function file_lines(rel)
        if lines_cache[rel] == nil then
            local t = file_text(rel)
            lines_cache[rel] = t and vim.split(t, '\n', { plain = true }) or false
        end
        return lines_cache[rel]
    end
    local touched = { [dest] = true }
    for _, id in ipairs(ids) do
        local n = store.node(id)
        if not n then return nil, 'staged symbol vanished: ' .. tostring(id) end
        if n.kind == 'var' then
            -- module-level constants move (full-declaration range, incl multi-
            -- line tables); function-local vars do not. References ride the
            -- ImpactEngine like any symbol (disclosed, not silently rewritten).
            if not module_level(store, n) then
                return nil, ('%s is a function-local variable — only module-'
                    .. 'level constants move'):format(n.name)
            end
        elseif n.kind ~= 'function' and n.kind ~= 'method' then
            return nil, ('%s is a %s — only functions, methods, and module-'
                .. 'level variables move'):format(n.name, n.kind)
        else
            -- ★★ THE SAME RULE AS THE `var` BRANCH ABOVE, WHICH IS WHY IT SITS
            -- BESIDE IT (CART-0770). The text is lifted and appended at the
            -- destination's TOP LEVEL, so a definition that is not at top level
            -- HERE cannot survive the trip: a php method lands after its class's
            -- closing brace, a lua table field lands with its trailing comma.
            -- The refusal NAMES the enclosing chain, because "it is inside
            -- something" is not actionable and "inside a class_declaration" is.
            local encl = enclosing_syntax(store, n, file_text(n.file))
            if encl then
                return nil, ('%s is not at module level — it is inside %s, and a '
                    .. 'move lifts only the definition, not its container. The '
                    .. 'container would have to move with it, or %s has to become '
                    .. 'a top-level definition first')
                    :format(n.name, encl, n.name)
            end
        end
        if n.file == dest then
            return nil, n.name .. ' already lives in ' .. dest
        end
        -- comment adhesion: the doc lines directly above travel too —
        -- unless the block touches the top of the file (a license /
        -- file header belongs to the FILE; disclosed, left behind)
        local s, header = atr.sl(n.range), false
        local ls = file_lines(n.file)
        if ls then
            s, header = txn.attach_above(ls, s,
                okp and ts.attach_pats(n.file) or {})
        end
        plan.moves[#plan.moves + 1] = { id = id, name = n.name, file = n.file,
            lines = { s = s, e = atr.el(n.range) },
            ref = store.ref_of(id),
            mode = (plan.copy and plan.copy[id]) and 'copy' or 'move' }
        touched[n.file] = true
        if header then
            plan.hazards[#plan.hazards + 1] = ('the comment block above %s'
                .. ' touches the top of %s (file header) — left behind')
                :format(n.name, n.file)
        end
        -- "referenced from data" is the `reg` EDGE's claim, so ask the edge.
        -- This used to read n.cbarg, which conflates three classes — a
        -- table-field def and a callback argument are neither of them a
        -- registry reference, so the hazard fired on defs it did not describe.
        if store.topo():n_registrants(id) > 0 then
            plan.hazards[#plan.hazards + 1] = ('%s is referenced from data'
                .. ' (dispatch table / registry) — those references are NOT'
                .. ' rewritten'):format(n.name)
        end
    end
    -- ORDERED review + valid dest layout: lay the move-set out in SOURCE order
    -- (which compiles — deps precede dependents there), so the extracted module
    -- is load-valid and the review reads top-to-bottom like the original.
    table.sort(plan.moves, function (a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lines.s < b.lines.s
    end)
    -- COPY entries duplicate a symbol into dest while leaving the original —
    -- disclose it (the two copies drift independently).
    for _, m in ipairs(plan.moves) do
        if m.mode == 'copy' then
            plan.hazards[#plan.hazards + 1] = ('%s is COPIED (the original stays'
                .. ' in %s) — the two copies must be kept in sync by hand')
                :format(m.name, m.file)
        end
    end

    -- the ImpactEngine's analysis: WRITE what is provably complete,
    -- disclose the rest. A caller site rewrites only when its token is
    -- exactly <srcAlias>.<name> (the alias its import BINDS) and a dest
    -- alias exists or a new import line can introduce one — the pair is
    -- written together or not at all. Bare names, exotic forms and
    -- shadowed aliases stay hazards; the moved code's own body is never
    -- rewritten (dest_requires stays spoken).
    local imp = require('cartograph.impact').compute(store, ids, dest)
    for _, h in ipairs(imp.hazards) do
        if h.kind ~= 'noop' then
            plan.hazards[#plan.hazards + 1] = h.kind .. ': ' .. h.msg
        end
    end
    plan.rewrites, plan.imports_add = {}, {}
    local in_move = {}
    for _, id in ipairs(ids) do in_move[id] = true end
    local binds = {} -- file -> { target file -> local alias }
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'import' and e.bind then
            binds[e.from] = binds[e.from] or {}
            binds[e.from][e.to] = e.bind
        end
    end
    local function import_at(ls, pats)
        local last = -1
        for i, l in ipairs(ls) do
            for _, p in ipairs(pats or {}) do
                if l:match(p) then last = i - 1 break end
            end
        end
        return last
    end
    local imports, rw_left = {}, {} -- per-file: planned import / leftovers
    for _, m in ipairs(plan.moves) do
        local tailname = m.name:match('([%w_]+)$')
        -- a COPY leaves the original in place, so its callers must NOT be
        -- requalified — they keep resolving to the still-present source symbol.
        for _, c in ipairs((m.mode ~= 'copy') and store.calls_to[m.id] or {}) do
            local F = callrec.file(c)
            if F ~= dest and not (callrec.fn(c) and in_move[callrec.fn(c)]) then
                local ls = file_lines(F)
                local at = c.at
                local token = at and ls and atr.oneline(at)
                    and (ls[atr.sl(at) + 1] or '')
                        :sub(atr.sc(at) + 1, atr.ec(at))
                local srcAlias = binds[F] and binds[F][m.file]
                local ok_site = srcAlias and token
                    and token == (srcAlias .. '.' .. tailname)
                local destAlias = ok_site and binds[F] and binds[F][dest]
                if ok_site and not destAlias then
                    local imp2 = imports[F]
                    if imp2 == nil and okp and ls then
                        local line, alias = ts.import_line(F, dest)
                        -- decline an alias the file already uses
                        if line and alias and not table.concat(ls, '\n')
                            :find('%f[%w_]' .. alias .. '%f[^%w_]') then
                            imp2 = { text = line, alias = alias,
                                after = import_at(ls, ts.import_pats(F)) }
                        else
                            imp2 = false
                        end
                        imports[F] = imp2
                    end
                    destAlias = imp2 and imp2.alias or nil
                end
                if ok_site and destAlias then
                    plan.rewrites[#plan.rewrites + 1] = { file = F, at = at,
                        to = destAlias .. '.' .. tailname }
                    touched[F] = true
                else
                    rw_left[F] = (rw_left[F] or 0) + 1
                end
            end
        end
    end
    for F, imp2 in pairs(imports) do
        if imp2 then
            plan.imports_add[#plan.imports_add + 1] = { file = F,
                after = imp2.after, text = imp2.text }
            touched[F] = true
        end
    end
    table.sort(plan.imports_add, function (a, b) return a.file < b.file end)
    for _, F in ipairs((function ()
        local out = {}
        for f in pairs(rw_left) do out[#out + 1] = f end
        table.sort(out)
        return out
    end)()) do
        plan.hazards[#plan.hazards + 1] = ('%d call site(s) in %s still'
            .. ' reference the old home — requalify them yourself')
            :format(rw_left[F], F)
    end
    for _, f in ipairs(imp.requires_add) do
        if not (imports[f] and imports[f] ~= false) then
            plan.hazards[#plan.hazards + 1] = f .. ' should import ' .. dest
        end
    end
    for _, f in ipairs(imp.dest_requires) do
        plan.hazards[#plan.hazards + 1] = dest .. ' should import ' .. f
    end
    -- a file being CREATED may need the language's module scaffold to LOAD;
    -- a MOVE into an existing file inherits that file's own (CART-0542)
    if okp and plan.creates and plan.creates[dest] then
        module_scaffold(plan, dest, ts, file_lines)
    end
    for f in pairs(touched) do
        plan.touched[#plan.touched + 1] = f
        plan.stamps[f] = txn.disk_stamp(root, f)
    end
    table.sort(plan.touched)
    return txn.protocol(plan, M.edits_for)
end

--- Build the MOVE plan from the staged move-set + destination.
--- Everything the apply verifies rides along: refs, stamps, the
--- generation, the insertion point (pinned by the dest stamp).
function M.plan(store)
    local ids = store.staged_ids()
    if #ids == 0 then
        return nil, 'nothing staged — dd cuts a function into the move-set'
    end
    if not store.dest then
        return nil, 'no destination — p on a file row sets it'
    end
    return M.plan_ids(store, ids, store.dest)
end

--- plan a MOVE from an EXPLICIT id set and destination, the way plan_extract_ids
--- does for extract. Factored out of M.plan (CART-0583) so a caller that must not
--- touch the live move-set can still build a plan: STAGING IS ARMING, and a host
--- that can never apply should not arm. M.preview/txn.dryrun reads the plan and
--- never the staged set, so an unarmed plan still previews.
--- @param ids string[]  the move-set, explicitly
--- @param dest string   an EXISTING file (that is what makes it a move)
function M.plan_ids(store, ids, dest)
    if not ids or #ids == 0 then return nil, 'no functions to move' end
    local txn = require 'cartograph.txn'
    -- ★ THE CHECK THIS BRANCH NEVER HAD (CART-0577). plan_extract_ids has always
    -- refused an escaping path; MOVE did not, so a dest of `../x.lua` planned and
    -- applied outside the project. Interactively `dest` came from pressing `p` on a
    -- FILE ROW and could only be inside the tree — the guarantee was the UI's, and
    -- making the verb agent-drivable removed it without replacing it.
    local okc, whyc = txn.contained(dest)
    if not okc then return nil, whyc end
    local dtext = txn.read_file(store.data.root, dest)
    if not dtext then return nil, 'cannot read ' .. dest end
    local plan = {
        verb = 'move', generation = store.generation, dest = dest,
        guards = { 'parses' }, -- CART-0769: every text-editing verb owes rung 0
        moves = {}, hazards = {}, stamps = {}, touched = {},
        dest_at = insert_point(vim.split(dtext, '\n', { plain = true })),
    }
    return collect(store, ids, dest, plan)
end

--- Build the EXTRACT-MODULE plan: the staged move-set leaves for a
--- file that does not exist yet. The destination is created from a
--- language header plus the moved text; its undo is deletion.
function M.plan_extract(store, relpath, opts)
    local ids = store.staged_ids()
    if #ids == 0 then
        return nil, 'nothing staged — dd cuts a function into the move-set'
    end
    return M.plan_extract_ids(store, ids, relpath, opts)
end

--- Close a move-set: seed ids → the full self-contained cluster (seed + every
--- PRIVATE same-file capture, transitively — the fixpoint of the capture
--- analysis). A "private" capture is referenced only from within the move;
--- SHARED captures (used by staying code too) are LEFT OUT — they are a
--- require/copy decision, not something to silently swallow. The result is
--- ordered by (file, source line) so the extracted module lays out deps before
--- dependents (the source already compiles in that order). "Move X and
--- everything it needs" as one call; the residual SHARED captures ride the
--- eventual plan as hazards for the human to require-or-copy.
function M.close_moveset(store, seed, dest)
    local impact = require 'cartograph.impact'
    local set, inset = {}, {}
    for _, id in ipairs(seed or {}) do
        if not inset[id] then inset[id] = true; set[#set + 1] = id end
    end
    for _ = 1, 200 do -- bounded fixpoint; the private-capture set only grows
        local added = false
        for _, c in ipairs(impact.compute(store, set, dest).captures or {}) do
            if c.private and not inset[c.id] then
                inset[c.id] = true; set[#set + 1] = c.id; added = true
            end
        end
        if not added then break end
    end
    table.sort(set, function (a, b)
        local na, nb = store.node(a), store.node(b)
        if not (na and nb and na.range and nb.range) then
            return tostring(a) < tostring(b)
        end
        if na.file ~= nb.file then return na.file < nb.file end
        return atr.sl(na.range) < atr.sl(nb.range)
    end)
    return set
end

--- THE WHOLE SETUP AS ONE CALL (CART-0576). Seed ids + a destination → a plan
--- `apply` will accept: close the move-set over its private captures, STAGE that
--- closure in the store (the state apply's last rung compares the plan against),
--- set the destination, plan. Those four steps have no decision between them, so
--- no caller should be able to get them half-right — omitting the staging pair
--- built a plan that could only ever refuse, which is what sent the recipe into a
--- kb note instead of the code.
---
--- The VERB is decided by the destination, on the same predicate
--- plan_extract_ids refuses with, so dispatch and refusal cannot disagree: an
--- existing file is a MOVE, a path that does not exist yet is an
--- EXTRACT-MODULE. `plan.verb` records which one ran. Returns the plan, or
--- (nil, reason) with the staging cleared again — a refusal leaves no
--- half-built move-set behind.
function M.plan_moveset(store, seed, dest, opts)
    dest = (dest or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if dest == '' then
        return nil, 'no destination — plan_moveset(store, seed_ids, dest)'
    end
    if not seed or #seed == 0 then
        return nil, 'no seed symbols — plan_moveset(store, seed_ids, dest)'
    end
    -- ★ CONTAINMENT FIRST, ahead of disk_stamp and ahead of clear_stage. Ahead of
    -- disk_stamp because that composes root .. '/' .. dest and its answer ROUTES us
    -- (move vs extract); ahead of clear_stage because a refusal must not cost the
    -- caller their staged set. This is the agent-facing entry point, so `dest` is an
    -- arbitrary string here where the cockpit could only ever supply a file row.
    do
        local ok, why = require('cartograph.txn').contained(dest)
        if not ok then return nil, why end
    end
    local exists = require('cartograph.txn').disk_stamp(store.data.root, dest)
    -- `copy` is an extract-module option (M.plan builds no copy set): say so
    -- rather than accept it and silently move what the caller asked to duplicate
    if exists and opts and opts.copy and next(opts.copy) then
        return nil, ('copy is an extract-module option, and %s already exists'
            .. ' — that destination is a MOVE'):format(dest)
    end
    local set = M.close_moveset(store, seed, dest)

    -- ★ STAGING IS ARMING, NOT PLANNING (CART-0583). M.apply's verb-specific rung
    -- requires store.staged_ids() to still equal plan.moves, so staging is how a
    -- plan is ARMED — it cannot be skipped and still yield an applyable plan. But
    -- M.preview/txn.dryrun reads the PLAN and never the staged set, so a caller
    -- that can never apply (a read-only agent host) can plan and diff with ZERO
    -- session mutation. `opts.arm = false` asks for exactly that.
    -- Default true: every existing caller wants an applyable plan.
    local arm = not (opts and opts.arm == false)

    -- ★ A REFUSAL MUST NOT COST THE CALLER THEIR MOVE-SET (CART-0576 note 3).
    -- This used to `store.clear_stage()` on failure, which CLEARS rather than
    -- RESTORES — so a cockpit user who had symbols staged lost them because an
    -- agent asked for a plan that refused. Save both halves and put them back.
    local prior_ids, prior_dest
    if arm then
        prior_ids, prior_dest = store.staged_ids(), store.dest
        store.clear_stage()
        for _, id in ipairs(set) do store.stage(id) end
        store.set_dest(dest)
    end

    local plan, why
    if exists then
        -- ★ EXPLICIT if/else, NOT `arm and M.plan(store) or M.plan_ids(...)`:
        -- M.plan returns nil on a refusal, so the `or` arm would fire and run the
        -- OTHER planner. That is the `f.absent and false or f.before` bug found in
        -- this same repo on 2026-08-27, one line long and invisible in review.
        if arm then
            plan, why = M.plan(store)
        else
            plan, why = M.plan_ids(store, set, dest)
        end
    else
        plan, why = M.plan_extract_ids(store, set, dest, opts)
    end

    if not plan and arm then
        store.clear_stage()
        for _, id in ipairs(prior_ids or {}) do store.stage(id) end
        store.set_dest(prior_dest) -- nil is a legal dest: set_dest just assigns
    end
    return plan, why
end

--- plan_extract from an EXPLICIT id set (not the staged move-set) — the seam the
--- inter-untangle handoff uses to plan a function CLUSTER into a new module
--- without touching the live staging. Read-only (builds a plan; apply mutates).
function M.plan_extract_ids(store, ids, relpath, opts)
    if not ids or #ids == 0 then return nil, 'no functions to extract' end
    relpath = (relpath or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if relpath == '' then
        return nil, 'usage: :CartographExtractModule <new-file-path>'
    end
    local txn = require 'cartograph.txn'
    -- was an inline `^/` / `%.%.` test here; it is txn.contained now so both entry
    -- points share ONE rule. The old spelling rejected the SUBSTRING `..`, which
    -- also refused a legal filename like `a..b.lua` — a refusal with no premise.
    local okc, whyc = txn.contained(relpath)
    if not okc then return nil, whyc end
    if txn.disk_stamp(store.data.root, relpath) then
        return nil, relpath .. ' already exists — that is a MOVE (:CartographMove)'
    end
    local okp, ts = pcall(require, 'cartograph.providers.treesitter')
    if okp and not ts.lang_of(relpath) then
        return nil, ('no language spec for %s — the graph could never'
            .. ' see the new file'):format(relpath)
    end
    local plan = {
        verb = 'extract-module', generation = store.generation,
        guards = { 'parses' }, -- CART-0769: every text-editing verb owes rung 0
        dest = relpath, creates = { [relpath] = true }, dest_at = 0,
        header = okp and ts.file_header(relpath) or {},
        moves = {}, hazards = {}, stamps = {}, touched = {},
        copy = (opts and opts.copy) or {}, -- id set: leave the original, don't rewrite
    }
    if okp and ts.lang_of(relpath) == 'go' then
        plan.hazards[#plan.hazards + 1] = relpath
            .. ' will need its package clause — cartograph wrote none'
    end
    return collect(store, ids, relpath, plan)
end

-- at most three names, then a count — a refusal that lists forty symbols is a
-- wall again
local function some(names)
    local shown = {}
    for i = 1, math.min(#names, 3) do shown[i] = names[i] end
    if #names > 3 then shown[#shown + 1] = ('+%d more'):format(#names - 3) end
    return table.concat(shown, ', ')
end

-- THE TWO WAYS THE STAGED-SET RUNG FAILS, which used to render as one string
-- (CART-0576). An EMPTY stage means the plan was never mirrored into the store:
-- a call-sequence error, whose repair is one call and whose risk is zero. A
-- DIFFERENT stage means the move-set really moved under the plan: the world
-- changed, and the only safe answer is to re-plan. Opposite instructions, so the
-- refusal has to say WHICH premise failed — a reader who cannot see the calling
-- code (an agent) cannot guess it back.
local function stage_mismatch(store, ids, plan)
    if #ids == 0 then
        return ('nothing is staged, so the plan\'s %d move(s) cannot be'
            .. ' confirmed against the live move-set — stage them first'
            .. ' (headless: moveapply.plan_moveset plans AND stages in one call;'
            .. ' in the cockpit: dd the symbols, p the destination)')
            :format(#plan.moves)
    end
    local want, have, extra, missing = {}, {}, {}, {}
    for _, m in ipairs(plan.moves) do want[m.id] = true end
    for _, id in ipairs(ids) do have[id] = true end
    for _, id in ipairs(ids) do
        if not want[id] then
            local n = store.node(id)
            extra[#extra + 1] = (n and n.name) or tostring(id)
        end
    end
    for _, m in ipairs(plan.moves) do
        if not have[m.id] then missing[#missing + 1] = m.name end
    end
    local detail = ''
    if #extra > 0 then detail = detail .. '; staged but not planned: ' .. some(extra) end
    if #missing > 0 then detail = detail .. '; planned but not staged: ' .. some(missing) end
    return ('the move-set changed since planning (staged %d, plan %d%s)'
        .. ' — re-plan (:CartographMove, or moveapply.plan_moveset headless)')
        :format(#ids, #plan.moves, detail)
end

--- Apply: the shared ladder plus one verb-specific rung — the LIVE
--- move-set must still be exactly the plan's moves. On success the
--- move-set is consumed (cleared before the splice, which a staged
--- set would freeze).
function M.apply(store, plan)
    local ids = store.staged_ids()
    local want = {}
    for _, m in ipairs(plan.moves) do want[m.id] = true end
    local same = #ids == #plan.moves
    if same then
        for _, id in ipairs(ids) do
            if not want[id] then same = false end
        end
    end
    if not same then
        return nil, stage_mismatch(store, ids, plan)
    end
    local txn = require 'cartograph.txn'
    -- every move-set entry's span is READ (to paste into dest), so all are
    -- verified; but only MOVE entries DEPART the graph — a COPY leaves its
    -- original in place, so it is not in the executed move set.
    local refspecs, departed = {}, {}
    for _, m in ipairs(plan.moves) do
        refspecs[#refspecs + 1] = { id = m.id, name = m.name,
            ref = m.ref, what = 'move' }
        if m.mode ~= 'copy' then departed[#departed + 1] = m.ref end
    end
    local bad = txn.verify(store, plan, refspecs)
    if bad then return nil, bad end
    -- consumed: the splice after the writes must not see a frozen graph
    store.clear_stage()
    return txn.execute(store, plan, {
        moves = departed,
        dest = plan.dest,
    })
end

--- What :CartographApply would write, nothing written: the dry-run
--- feeding the pre-apply diff.
function M.preview(store, plan)
    local txn = require 'cartograph.txn'
    return txn.dryrun(store, plan)
end

--- The verb's edit callback — shared verbatim by apply and preview.
function M.edits_for(plan)
    return function (rel, before, all)
        if plan.creates and plan.creates[rel] then
            -- a NEW file: language header + the module scaffold's prologue +
            -- the moved text + the scaffold's epilogue, from the same
            -- before-bytes the journal holds
            local out = {}
            vim.list_extend(out, plan.header or {})
            vim.list_extend(out, plan.scaffold and plan.scaffold.pre or {})
            for mi, m in ipairs(plan.moves) do
                if mi > 1 then out[#out + 1] = '' end
                local src = vim.split(all[m.file], '\n', { plain = true })
                for i = m.lines.s + 1, m.lines.e + 1 do
                    out[#out + 1] = src[i]
                end
            end
            if plan.scaffold then
                out[#out + 1] = ''
                vim.list_extend(out, plan.scaffold.post)
            end
            out[#out + 1] = ''
            return table.concat(out, '\n')
        end
        local lines = vim.split(before, '\n', { plain = true })
        if rel == plan.dest then
            -- the moved blocks, lifted from each source's BEFORE content
            -- (the same bytes the journal holds)
            local ins = {}
            local at = plan.dest_at
            if at > 0 and (lines[at] or ''):match('%S') then
                ins[#ins + 1] = ''
            end
            for mi, m in ipairs(plan.moves) do
                if mi > 1 then ins[#ins + 1] = '' end
                local src = vim.split(all[m.file], '\n', { plain = true })
                for i = m.lines.s + 1, m.lines.e + 1 do
                    ins[#ins + 1] = src[i]
                end
            end
            if (lines[at + 1] or ''):match('%S') then
                ins[#ins + 1] = ''
            end
            for i = #ins, 1, -1 do
                table.insert(lines, at + 1, ins[i])
            end
        else
            -- a source/caller file: departures, requalified call
            -- sites and new import lines — one pass, bottom-up,
            -- through the shared editor
            local dels, reps, ins = {}, {}, {}
            for _, m in ipairs(plan.moves) do
                -- a COPY does not cut the original; only MOVE entries depart
                if m.file == rel and m.mode ~= 'copy' then dels[#dels + 1] = m.lines end
            end
            for _, r in ipairs(plan.rewrites or {}) do
                if r.file == rel then reps[#reps + 1] = r end
            end
            for _, i in ipairs(plan.imports_add or {}) do
                if i.file == rel then
                    ins[#ins + 1] = { after = i.after, lines = { i.text } }
                end
            end
            return require('cartograph.txn').edit_file(before, dels, reps, ins)
        end
        return table.concat(lines, '\n')
    end
end

return M
