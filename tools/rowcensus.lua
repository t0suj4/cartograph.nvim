-- ROW CENSUS — the gate for the FINE row model (CART-0389).
--
-- ★★ NOTHING GATED IT. Measured on colobot-base by disabling cpp `for_range_loop`:
-- 2522 rows and 988 opened control structures appeared and disappeared with EVERY EXISTING
-- COLUMN GREEN. That is structural, not accidental:
--   · `struct` gates nodes / edges / calls, and opening a control form repartitions rows
--     WITHIN a function — it mints no node and moves no edge.
--   · `dfpar` gates the COARSE projection, and coarse groups a control row TOGETHER WITH its
--     body under the top-level ancestor, so an opened loop and an unopened one are the SAME
--     coarse statement with the SAME def/use union.
--   · `fold` / `cache` / `par` are round-trips: they check that what we stored comes back,
--     not that what we stored was right.
-- So the fine row model — the entire subject of CART-0363, 0382 and 0386 — was gated only by
-- unit tests on hand-written fixtures. That is why java's switch and ruby's begin/rescue
-- could be 100% opaque for a long time in a repo with 21 gated corpora and 10 invariant
-- columns: not carelessness, but THERE WAS NO NUMBER THAT COULD MOVE.
--
-- ★ THE OPENED/OPAQUE TEST IS STRUCTURAL AND CANNOT DRIFT. "A control row is OPENED iff some
-- OTHER row names it as parent" asks the rows themselves. The obvious alternative — keep a
-- set of control node types and check membership — is the exact defect this repo has now hit
-- four times (flow's CTRL vs cfg.lua's COND, a stale copy inside the probe MEASURING that
-- fix, four disagreeing LOOPISH tables, and a base CATCH the spec seam never reached). An
-- audit tool holding its own copy of the answer audits itself.
--
-- ★ AND WHAT COUNTS AS A CONTROL ROW IS READ OFF flow's OWN OUTPUT, not restated: flow sets
-- `kind = <raw node type>` for a control statement and `kind = 'stmt'` for everything else,
-- plus 'catch'/'case' for clause rows. So `kind ~= 'stmt'` IS flow's answer to "is this row
-- structural", by construction.

local M = {}

--- Census the fine rows of an extracted graph.
--- Returns { rows, fns, cats } where `cats` is the DIFFABLE map, mirroring dfparity:
---   rows / opened / opaque  — the totals
---   <node type>             — opened count for that control form
--- A form that stops opening drives its own key to zero, so the diff names it.
---@param data table  an extracted graph (production; no second walk needed)
function M.check(data)
    local flow = require 'cartograph.flow'
    local cats = { rows = 0, opened = 0, opaque = 0 }
    local fns = 0
    for _, n in ipairs(data.nodes or {}) do
        if flow.present(n) then
            local fl = flow.record(n)
            local stmts = fl and fl.stmts
            if stmts then
                fns = fns + 1
                -- which rows have a child? (the structural OPENED test)
                local haskid = {}
                for _, s in ipairs(stmts) do
                    cats.rows = cats.rows + 1
                    if s.parent and s.parent > 0 then haskid[s.parent] = true end
                end
                for i, s in ipairs(stmts) do
                    local kind = s.kind
                    if kind and kind ~= 'stmt' then
                        -- key by the RAW node type where there is one (control rows), else
                        -- by kind ('catch'/'case' clause rows carry no `t`)
                        local key = s.t or kind
                        if haskid[i] then
                            cats.opened = cats.opened + 1
                            cats[key] = (cats[key] or 0) + 1
                        else
                            cats.opaque = cats.opaque + 1
                            -- ★ AN OPAQUE FORM GETS ITS OWN KEY, not silence. A control row
                            -- with no children is either an empty body (fine) or a form we
                            -- failed to open (the bug). Counting them together under
                            -- `opaque` would hide WHICH form went dark.
                            cats[key .. ':opaque'] = (cats[key .. ':opaque'] or 0) + 1
                        end
                    end
                end
            end
        end
    end
    return { rows = cats.rows, fns = fns, cats = cats }
end

--- Census one-liner (stable order: totals first, then forms by descending count).
function M.census(cats)
    local parts = { ('rows=%d opened=%d opaque=%d'):format(
        cats.rows or 0, cats.opened or 0, cats.opaque or 0) }
    local ord = {}
    for k, v in pairs(cats) do
        if k ~= 'rows' and k ~= 'opened' and k ~= 'opaque' then
            ord[#ord + 1] = { k = k, v = v }
        end
    end
    table.sort(ord, function (a, b)
        if a.v ~= b.v then return a.v > b.v end
        return a.k < b.k
    end)
    for _, e in ipairs(ord) do parts[#parts + 1] = e.k .. '=' .. e.v end
    return table.concat(parts, ' ')
end

--- Diff against a pinned census; returns report lines (empty = agree). Mirrors dfparity.diff
--- so a caller can treat the two columns identically.
function M.diff(cats, expected)
    local out, seen = {}, {}
    for k, v in pairs(cats) do
        seen[k] = true
        local e = expected[k]
        if e ~= v then out[#out + 1] = ('    %s %s→%d'):format(k, e == nil and '(new)' or e, v) end
    end
    for k, e in pairs(expected) do
        if not seen[k] then out[#out + 1] = ('    %s %d→0 (GONE)'):format(k, e) end
    end
    table.sort(out)
    return out
end

--- PINNED per-corpus census. Same discipline as dfparity.EXPECTED: only a corpus with a
--- pinned `rev` can hold one, because a LIVING corpus moves it every cut for free.
--- A deliberate flow change recalibrates the affected entry AFTER reviewing the delta —
--- and here the review question is always the same: did a form's opened count go DOWN?
M.EXPECTED = {
    -- Calibrated 2026-08-11 on arrival of this column, over the --quick tier. Every entry is
    -- a corpus with a pinned rev or a deterministic synthetic identity; the LIVING corpora
    -- (self, bnw, wow, desynced, factorio, se) deliberately have none, the same rule
    -- dfparity.EXPECTED follows -- a corpus that changes under the pin moves the number for
    -- free, so a delta there would never mean a regression.
    --
    -- ★ THE REVIEW QUESTION FOR ANY DELTA IS ALWAYS THE SAME: did a form's OPENED count go
    -- DOWN, or did a `<form>:opaque` count go UP? Either means a construct stopped opening,
    -- which is the class of bug this column exists for. Rows/opened rising is what a new
    -- language form looks like.
    --
    -- ★ AND THE ENTRIES BELOW ARE THE WEEK'S WORK MADE VISIBLE, which is the point: libs
    -- carries try_with_resources_statement=642 / enhanced_for_statement=431 / switch_rule=157
    -- / switch_expression=48 (CART-0363), ruby carries begin=26 (CART-0386), cppmodern
    -- for_range_loop=257 (CART-0363 + CART-0385), and synjava/synjs carry the control
    -- bestiary (CART-0377). Before this column, every one of those could have gone to zero
    -- with the whole matrix green.
    bash = { rows = 9439, opened = 1430, opaque = 0, case_statement = 82, catch = 1,
        elif_clause = 273, for_statement = 66, if_statement = 977, try_statement = 1,
        while_statement = 30 },
    cpp = { rows = 78003, opened = 18816, opaque = 253, case_statement = 1704,
        ['case_statement:opaque'] = 238, ['cond:opaque'] = 12, do_statement = 12,
        for_statement = 2117, if_statement = 14504, ['if_statement:opaque'] = 3,
        switch_statement = 313, while_statement = 166 },
    cppmodern = { rows = 63151, opened = 12959, opaque = 363, case_statement = 651,
        ['case_statement:opaque'] = 355, catch = 38, ['cond:opaque'] = 4, do_statement = 4,
        for_range_loop = 257, for_statement = 620, if_statement = 11177,
        ['if_statement:opaque'] = 4, switch_statement = 86, try_statement = 37,
        while_statement = 89 },
    go = { rows = 58960, opened = 12726, opaque = 48, catch = 18, ['catch:opaque'] = 6,
        default_case = 260, ['default_case:opaque'] = 8, expression_case = 970,
        ['expression_case:opaque'] = 33, expression_switch_statement = 320,
        for_in_statement = 7, for_statement = 2145, if_statement = 8812,
        ['if_statement:opaque'] = 1, select_statement = 11, switch_statement = 8,
        try_statement = 29, type_switch_statement = 130, while_statement = 16 },
    grocy = { rows = 8844, opened = 1872, opaque = 3, case_statement = 15, catch = 83,
        ['catch:opaque'] = 2, else_if_clause = 39, ['else_if_clause:opaque'] = 1,
        for_statement = 5, foreach_statement = 73, if_statement = 1572, switch_statement = 3,
        try_statement = 82 },
    haskell = { rows = 30, opened = 8, opaque = 0, if_statement = 6, while_statement = 2 },
    jquery = { rows = 3441, opened = 869, opaque = 6, catch = 9, ['catch:opaque'] = 5,
        for_in_statement = 31, for_statement = 56, if_statement = 713, try_statement = 14,
        while_statement = 46, ['while_statement:opaque'] = 1 },
    libs = { rows = 50403, opened = 7383, opaque = 102, catch = 425, ['catch:opaque'] = 49,
        ['cond:opaque'] = 21, do_statement = 21, enhanced_for_statement = 431,
        for_statement = 1448, if_expression = 2, if_statement = 3409, match_block = 2,
        match_expression = 2, switch_block_statement_group = 88,
        ['switch_block_statement_group:opaque'] = 10, switch_expression = 48, switch_rule = 157,
        synchronized_statement = 1, try_statement = 474, try_with_resources_statement = 642,
        ['try_with_resources_statement:opaque'] = 21, while_statement = 233,
        ['while_statement:opaque'] = 1 },
    mootools = { rows = 2000, opened = 476, opaque = 3, catch = 6, ['catch:opaque'] = 3,
        for_in_statement = 30, for_statement = 43, if_statement = 369, switch_statement = 11,
        try_statement = 9, while_statement = 8 },
    nio = { rows = 924, opened = 201, opaque = 0, elseif_statement = 19, for_statement = 38,
        if_statement = 141, while_statement = 3 },
    php = { rows = 22372, opened = 5016, opaque = 282, case_statement = 434,
        ['case_statement:opaque'] = 276, catch = 13, ['cond:opaque'] = 4,
        default_statement = 78, ['default_statement:opaque'] = 1, do_statement = 4,
        else_if_clause = 38, for_statement = 47, foreach_statement = 538, if_statement = 3617,
        ['if_statement:opaque'] = 1, switch_statement = 123, try_statement = 13,
        while_statement = 111 },
    python = { rows = 10754, opened = 2090, opaque = 0, catch = 158, elif_clause = 61,
        for_in_statement = 1, for_statement = 279, if_statement = 1441, try_statement = 144,
        while_statement = 6 },
    -- recalib @ CART-0387: a case SUBJECT and a when PATTERN are not rows (10324 -> 10257)
    rails = { rows = 10257, opened = 2135, opaque = 14, begin = 27, case = 15, catch = 48,
        ['catch:opaque'] = 14, elsif = 50, ['if'] = 797, if_modifier = 952, unless = 41,
        unless_modifier = 157, when = 42, ['while'] = 6 },
    rspec = { rows = 262, opened = 6, opaque = 0, ['if'] = 1, if_modifier = 5 },
    -- recalib @ CART-0387: rows 5893->5672. A ruby `case` SUBJECT and a `when` PATTERN are
    -- not statements that execute, so they stopped being rows. `when:opaque` 0->3 is the
    -- review question firing and CHECKED: all three are genuinely EMPTY arms
    -- (`when Integer` / `when nil` with no body, a deliberate ruby no-op), not a regression.
    ruby = { rows = 5672, opened = 1112, opaque = 7, ['when:opaque'] = 3, begin = 26, case = 60, catch = 48,
        ['catch:opaque'] = 4, elsif = 56, ['if'] = 390, if_modifier = 224, unless = 50,
        unless_modifier = 105, ['until'] = 2, when = 140, ['while'] = 11 },
    rust = { rows = 10986, opened = 1263, opaque = 1, case_statement = 9, for_expression = 146,
        if_expression = 685, if_statement = 1, loop_expression = 9, match_block = 190,
        match_expression = 190, while_expression = 33, ['while_expression:opaque'] = 1 },
    synjava = { rows = 312, opened = 58, opaque = 1, catch = 2, ['cond:opaque'] = 1,
        do_statement = 1, enhanced_for_statement = 3, for_statement = 9, if_statement = 31,
        switch_block_statement_group = 3, switch_expression = 2, switch_rule = 3,
        synchronized_statement = 1, try_statement = 1, try_with_resources_statement = 1,
        while_statement = 1 },
    synjs = { rows = 670, opened = 39, opaque = 1, catch = 1, ['cond:opaque'] = 1,
        do_statement = 1, for_in_statement = 3, for_statement = 11, if_statement = 20,
        switch_statement = 1, try_statement = 1, while_statement = 1 },
    synlua = { rows = 554, opened = 101, opaque = 19, ['cond:opaque'] = 19, do_statement = 20,
        elseif_statement = 10, for_statement = 14, if_statement = 23, repeat_statement = 19,
        while_statement = 15 },
}

return M
