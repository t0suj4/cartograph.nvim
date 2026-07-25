-- REORDER: statement-level commutativity for ONE function — the refactor
-- cockpit's safe-reorder view, composed entirely from shipped facts:
-- df statements (direct reads/defs + local dataflow deps), the fn's use
-- edges (which names are module state), and per-call discharged effect
-- summaries ([[cartograph-write-axis]]). Verdicts per statement PAIR:
--   dep       local dataflow: i defines a local j uses — ordered
--   state     both touch the same module var/field, not both set-once
--   world     both write the world (io) — external order observable
-- Statements with unresolvable effects are OPAQUE: listed with the hedge
-- named, certified for nothing — reads through calls are not modeled
-- (the report says so), so 'free' means free w.r.t. what IS modeled.
--
-- analyze/report are READ-ONLY (verdicts; :CartographReorder is the interactive face).
-- plan_move/preview/apply are the WRITE side (:CartographReorderApply) — a single-statement
-- move certified behavior-preserving by the verdict, riding the txn layer.
--   local ro = require 'cartograph.reorder'
--   local res = ro.analyze(store, fn_id)              -- per-pair verdicts + opaque hedges
--   local plan = ro.plan_move(store, fn_id, from, to[, through]) -- or (nil, why)
--   ro.apply(store, plan)                             -- journaled, CAS + parse-clean gated
-- A move handles a single statement or a contiguous block (`through`), and each statement
-- may be MULTI-LINE — its full source span (a continuation, or a control body + `end`) is
-- carried, via block_span's range-to-next-statement extent.

local callrec = require 'cartograph.callrec'
local dfa = require 'cartograph.df'
local effects = require 'cartograph.effects'

local M = {}

--- The model for one fn: { stmts, deps, conflicts, free, opaque }.
function M.analyze(store, fn_id)
    local node = store.node(fn_id)
    if not node then return nil, 'no such node' end
    local sts = dfa.stmts(node)
    if #sts == 0 then return nil, 'no statement-level dataflow' end

    -- module-state vocabulary: name -> var id (~: name-matched, as the
    -- use edges themselves are)
    local varkey, edgeinfo = {}, {}
    for _, u in ipairs(store.topo():var_uses_detail(fn_id)) do
        local vn = store.node(u.to)
        if vn and vn.name then
            varkey[vn.name] = u.to
            edgeinfo[u.to] = u
        end
    end

    local function stmt_of(line0)
        local li, best = line0 + 1, nil
        for i = 1, #sts do
            if sts[i].l <= li then best = i else break end
        end
        return best
    end

    -- per-statement effect rows
    local rows = {}
    for i, st in ipairs(sts) do
        rows[i] = { i = i, l = st.l, writes = {}, reads = {}, hedges = nil }
        for _, d in ipairs(st.def) do
            local v = varkey[d]
            if v then
                local u = edgeinfo[v]
                rows[i].writes[v .. '\31'] = (u and u.gw) or 1
            end
        end
        for _, uname in ipairs(st.use) do
            local v = varkey[uname]
            if v then rows[i].reads[v .. '\31'] = true end
        end
    end
    -- call effects land on the statement containing the call site
    for _, c in ipairs(store.topo():sites(fn_id)) do
        local si = callrec.line(c) and stmt_of(callrec.line(c))
        if si then
            local fx = effects.call_effects(store, c, node.file)
            local row = rows[si]
            for key, tier in pairs(fx.w) do
                local cur = row.writes[key]
                if not cur or tier < cur then row.writes[key] = tier end
            end
            if fx.hedges then
                row.hedges = row.hedges or {}
                for _, h in ipairs(fx.hedges) do
                    if #row.hedges < 3 then row.hedges[#row.hedges + 1] = h end
                end
            end
        end
    end

    -- local dataflow dependencies (df.dep: from-stmt defines, this uses)
    local deps = {}
    for j, st in ipairs(sts) do
        for _, d in ipairs(st.dep or {}) do
            if d.from and d.from ~= j then
                deps[#deps + 1] = { d.from, j, ('local %s'):format(d.var or '?') }
            end
        end
    end

    -- pairwise state/world conflicts (n = statement count: small)
    local IOKEY = effects.IOKEY
    local conflicts = {}
    for i = 1, #rows do
        for j = i + 1, #rows do
            local a, b = rows[i], rows[j]
            local hit, kind
            for key, ta in pairs(a.writes) do
                local tb = b.writes[key]
                if tb and not (ta == 3 and tb == 3) then
                    hit, kind = key, key == IOKEY and 'world' or 'state'
                    break
                end
                if key ~= IOKEY and b.reads[key] then
                    hit, kind = key, 'state'
                    break
                end
            end
            if not hit then
                for key in pairs(a.reads) do
                    if b.writes[key] then hit, kind = key, 'state' break end
                end
            end
            if hit then
                conflicts[#conflicts + 1] = { i, j, kind,
                    kind == 'world' and '(world order)'
                        or (hit:gsub('\31', '.'):gsub('%.$', '')) }
            end
        end
    end

    -- free = constrained by nothing modeled; opaque = hedged
    local bound = {}
    for _, d in ipairs(deps) do bound[d[1]], bound[d[2]] = true, true end
    for _, c in ipairs(conflicts) do bound[c[1]], bound[c[2]] = true, true end
    local free, opaque = {}, {}
    for i, row in ipairs(rows) do
        if row.hedges then
            opaque[#opaque + 1] = i
        elseif not bound[i] then
            free[#free + 1] = i
        end
    end
    return { node = node, stmts = rows, deps = deps, conflicts = conflicts,
        free = free, opaque = opaque }
end

--- Render the model as report lines (the scratch-buffer surface).
function M.report(store, fn_id)
    local m, why = M.analyze(store, fn_id)
    if not m then return { 'reorder: ' .. why } end
    local L = {}
    L[#L + 1] = ('reorder: %s — %d statements (reads through calls not modeled)')
        :format(m.node.name or fn_id, #m.stmts)
    L[#L + 1] = ''
    local IOKEY = effects.IOKEY
    for _, row in ipairs(m.stmts) do
        local fx = {}
        for key, tier in pairs(row.writes) do
            if key == IOKEY then
                fx[#fx + 1] = 'world'
            else
                local name = key:gsub('\31', '.'):gsub('%.$', '')
                local vn = store.node(name) -- key head is the var id
                fx[#fx + 1] = ('w:%s%s'):format(
                    (vn and vn.name) or name, tier == 3 and ' (set-once)' or '')
            end
        end
        table.sort(fx)
        L[#L + 1] = ('  #%-3d L%-5d %s%s'):format(row.i, row.l,
            #fx > 0 and table.concat(fx, '  ') or '·',
            row.hedges and ('  ~ ' .. row.hedges[1]) or '')
    end
    if #m.deps + #m.conflicts > 0 then
        L[#L + 1] = ''
        L[#L + 1] = 'ordering constraints:'
        for _, d in ipairs(m.deps) do
            L[#L + 1] = ('  #%d → #%d   %s'):format(d[1], d[2], d[3])
        end
        for _, c in ipairs(m.conflicts) do
            local name = c[4]
            local vn = store.node(name)
            L[#L + 1] = ('  #%d ⚡ #%d  %s: %s'):format(c[1], c[2], c[3],
                (vn and vn.name) or name)
        end
    end
    if #m.free > 0 then
        L[#L + 1] = ''
        L[#L + 1] = 'freely movable (w.r.t. modeled effects): #'
            .. table.concat(m.free, ', #')
    end
    if #m.opaque > 0 then
        L[#L + 1] = 'opaque (unresolved effects — certify nothing): #'
            .. table.concat(m.opaque, ', #')
    end
    return L
end

-- ── the APPLY side: move ONE statement, verified against the commute verdict ──
-- The reorder analysis says which statement PAIRS commute; the apply is the txn that
-- performs a single-statement move. Moving statement p across a set of statements inverts
-- p's order with each of them, so the move is behavior-preserving iff p has NO modeled
-- relationship (dep or conflict) with any crossed statement, and neither p nor any crossed
-- statement is OPAQUE (unmodeled effects — can't certify). First cut: p must be a single
-- source line (its own), exclusively — multi-line / shared-line statements are refused;
-- block moves are the banked next. Rides the txn contract + parse-clean, like optapply.

local at = require 'cartograph.at'

-- The 0-based source line range a statement/block occupies. A df row's statement runs from
-- its own start line to just before the NEXT statement's start (or the fn body's end for
-- the last) — this captures a MULTI-LINE simple statement's continuation AND a control
-- structure's body + `end` (which the flow model keeps as a single row), tightly enough
-- that only interstitial blank/comment lines are carried along (behavior-preserving). Rows
-- are line-ordered and index-contiguous, so [rows[p].l .. end0(r)] holds exactly the block.
-- end0(i) = the line before the next statement (or before the fn's `end`).
local function block_span(rows, node, p, r)
    if p > 1 and rows[p - 1].l == rows[p].l then return nil, 'the block start shares a line with the previous statement' end
    if r < #rows and rows[r + 1].l == rows[r].l then return nil, 'the block end shares a line with the next statement' end
    local start0 = rows[p].l - 1
    local end0 = rows[r + 1] and (rows[r + 1].l - 2) or (at.el(node.range) - 1)
    if end0 < start0 then return nil, 'empty statement span' end
    return start0, end0
end

--- Plan a reorder: move the statement starting at `from_line` to just before the statement
--- starting at `to_line` (1-based). Returns a txn plan, or (nil, reason) if the move
--- crosses a dependency, a state/world conflict, or an opaque statement — i.e. can't be
--- certified behavior-preserving.
--- `through_line` (optional) makes it a BLOCK move: the contiguous run of statements from
--- `from_line` through `through_line` moves as a unit. The block's internal order is
--- preserved (only the block↔crossed relationships matter), so it is sound iff EVERY block
--- statement commutes with EVERY crossed statement and nothing opaque is crossed or in the
--- block. Each block statement must be single-line (multi-line refused; same first-cut limit).
function M.plan_move(store, fn_id, from_line, to_line, through_line)
    local m, why = M.analyze(store, fn_id)
    if not m then return nil, why end
    local rows = m.stmts
    through_line = through_line or from_line
    local p, r, q
    for i, row in ipairs(rows) do
        if row.l == from_line then p = i end
        if row.l == through_line then r = i end
        if row.l == to_line then q = i end
    end
    if not p then return nil, 'no statement starts at line ' .. from_line end
    if not r then return nil, 'no statement starts at line ' .. through_line end
    if r < p then return nil, 'the block end is before its start' end
    if not q then
        if to_line > rows[#rows].l then q = #rows + 1 else return nil, 'no statement at line ' .. to_line end
    end
    if q >= p and q <= r + 1 then return nil, 'that is already the block\'s position' end

    local inblock = {}
    for i = p, r do inblock[i] = true end
    local opaque = {}
    for _, i in ipairs(m.opaque) do opaque[i] = true end
    for i = p, r do
        if opaque[i] then return nil, ('#%d has unresolved effects (opaque) — cannot certify the move'):format(i) end
    end

    -- the crossed set: statements strictly between the block and the new position
    local passed = {}
    if q > r then for t = r + 1, q - 1 do passed[#passed + 1] = t end
    else for t = q, p - 1 do passed[#passed + 1] = t end end

    -- any modeled relationship between a BLOCK statement and a crossed statement blocks it
    local rel = {}
    local function note(a, b, why2)
        if inblock[a] and not inblock[b] then rel[b] = rel[b] or why2
        elseif inblock[b] and not inblock[a] then rel[a] = rel[a] or why2 end
    end
    for _, d in ipairs(m.deps) do note(d[1], d[2], ('a dataflow dep (%s)'):format(d[3])) end
    for _, c in ipairs(m.conflicts) do note(c[1], c[2], ('a %s conflict (%s)'):format(c[3], c[4])) end
    for _, t in ipairs(passed) do
        if opaque[t] then return nil, ('the move would cross #%d, whose effects are opaque'):format(t) end
        if rel[t] then return nil, ('the move would cross #%d, which has %s with a block statement'):format(t, rel[t]) end
    end

    -- the block's source span (multi-line statements + control `end` handled)
    local src_s0, src_e0, sw = block_span(rows, m.node, p, r)
    if not src_s0 then return nil, sw end
    local dst_line1 = (q <= #rows) and rows[q].l or (at.el(m.node.range)) -- fn `end` line
    local dst0 = dst_line1 - 1
    if dst0 >= src_s0 and dst0 <= src_e0 + 1 then return nil, 'the block cannot move into itself' end

    local root = store.data.root
    local rel_file = m.node.file
    local text = require('cartograph.txn').read_file(root, rel_file)
    if not text then return nil, 'cannot read ' .. rel_file end
    local flines = vim.split(text, '\n', { plain = true })
    local src_lines = {}
    for i = src_s0, src_e0 do src_lines[#src_lines + 1] = flines[i + 1] end

    return {
        verb = 'reorder', generation = store.generation,
        file = rel_file, fn = m.node.name,
        src_s0 = src_s0, src_e0 = src_e0, dst0 = dst0, src_lines = src_lines,
        from_line = from_line, to_line = to_line, through_line = through_line,
        nstmts = r - p + 1,
        ref = store.ref_of(fn_id), fn_id = fn_id,
        touched = { rel_file },
        stamps = { [rel_file] = require('cartograph.txn').disk_stamp(root, rel_file) },
    }
end

--- The edit callback: cut the source line range and re-insert it before the destination.
function M.edits_for(plan)
    return function (rel, before)
        if rel ~= plan.file then return before end
        local lines = vim.split(before, '\n', { plain = true })
        for _ = plan.src_s0, plan.src_e0 do table.remove(lines, plan.src_s0 + 1) end
        -- destination index after the removal: shift down by the block size if it was above
        local removed = plan.src_e0 - plan.src_s0 + 1
        local ins0 = plan.dst0 <= plan.src_s0 and plan.dst0 or plan.dst0 - removed
        for i = #plan.src_lines, 1, -1 do table.insert(lines, ins0 + 1, plan.src_lines[i]) end
        return table.concat(lines, '\n')
    end
end

function M.preview(store, plan)
    return require('cartograph.txn').dryrun(store, plan, M.edits_for(plan))
end

function M.apply(store, plan)
    local txn = require 'cartograph.txn'
    if next(store.moveset or {}) then return nil, 'a move-set is staged — apply or clear it first' end
    local bad = txn.verify(store, plan, { { id = plan.fn_id, name = plan.fn, ref = plan.ref, what = 'function' } })
    if bad then return nil, bad end
    -- the moved lines must still be exactly what we planned (span CAS), and the result must
    -- parse cleanly (a body-changing edit, like optapply)
    local before, after = M.preview(store, plan)
    local bl = before and before[plan.file] and vim.split(before[plan.file], '\n', { plain = true })
    for i, want in ipairs(plan.src_lines) do
        if not bl or bl[plan.src_s0 + i] ~= want then
            return nil, 'the source lines changed since planning — re-plan'
        end
    end
    -- parse-clean on the result (a body-changing edit). Grammar from the file ext; if the
    -- grammar isn't available the sound commute verdict + span-CAS still hold, so skip.
    local text = after and after[plan.file]
    local PARSE = { lua = 'lua', js = 'javascript', jsx = 'javascript' }
    local lang = PARSE[(plan.file:match('%.(%w+)$') or ''):lower()]
    if lang then
        local ok, parser = pcall(vim.treesitter.get_string_parser, text or '', lang)
        if not (ok and parser and not parser:parse()[1]:root():has_error()) then
            return nil, 'the reordered result does not parse — refusing'
        end
    end
    return txn.execute(store, plan, { fn = plan.fn, moved = plan.from_line .. '→' .. plan.to_line },
        M.edits_for(plan))
end

return M
