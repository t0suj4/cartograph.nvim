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
    cpp = { rows = 78202, opened = 18827, opaque = 253, case_statement = 1704,
        ['case_statement:opaque'] = 238, ['cond:opaque'] = 12, do_statement = 12,
        for_statement = 2119, if_statement = 14513, ['if_statement:opaque'] = 3,
        switch_statement = 313, while_statement = 166 },
    cppmodern = { rows = 63362, opened = 12990, opaque = 364, case_statement = 651,
        ['case_statement:opaque'] = 355, catch = 42, ['cond:opaque'] = 5, do_statement = 5,
        for_range_loop = 259, for_statement = 623, if_statement = 11192,
        ['if_statement:opaque'] = 4, switch_statement = 86, try_statement = 41,
        while_statement = 91 },
    -- go / mootools / synjs recalib @ CART-0390: js/ts SWITCH BODIES now open (they were
    -- one opaque `switch_body` row). switch_case/switch_default are NEW keys; if_statement
    -- also rises, which is control NESTED INSIDE the bodies that were folded. go moves
    -- because its corpus carries js files too.
    go = { rows = 59034, opened = 12758, opaque = 52, catch = 18, ['catch:opaque'] = 6,
        default_case = 260, ['default_case:opaque'] = 8, expression_case = 970,
        ['expression_case:opaque'] = 33, expression_switch_statement = 320,
        for_in_statement = 7, for_statement = 2146, if_statement = 8816,
        ['if_statement:opaque'] = 1, select_statement = 11, switch_case = 23,
        ['switch_case:opaque'] = 4, switch_default = 4, switch_statement = 8,
        try_statement = 29, type_switch_statement = 130, while_statement = 16 },
    grocy = { rows = 8844, opened = 1872, opaque = 3, case_statement = 15, catch = 83,
        ['catch:opaque'] = 2, else_if_clause = 39, ['else_if_clause:opaque'] = 1,
        for_statement = 5, foreach_statement = 73, if_statement = 1572, switch_statement = 3,
        try_statement = 82 },
    haskell = { rows = 30, opened = 8, opaque = 0, if_statement = 6, while_statement = 2 },
    jquery = { rows = 3441, opened = 869, opaque = 6, catch = 9, ['catch:opaque'] = 5,
        for_in_statement = 31, for_statement = 56, if_statement = 713, try_statement = 14,
        while_statement = 46, ['while_statement:opaque'] = 1 },
    -- recalib @ CART-0406: +4680 rows / +151 opened = A JAVA LAMBDA NOW HAS A NODE, so its body
    -- has rows at all. Every form rose and none fell — the shape of the delta IS the review
    -- question's answer. `opaque` UNMOVED at 102, which is the sharper signal: 1579 new function
    -- bodies arrived and not one of them opened a control form it then failed to region.
    libs = { rows = 55149, opened = 7544, opaque = 102, catch = 446, ['catch:opaque'] = 49,
        ['cond:opaque'] = 21, do_statement = 21, enhanced_for_statement = 441,
        for_statement = 1476, if_expression = 2, if_statement = 3480, match_block = 2,
        match_expression = 2, switch_block_statement_group = 88,
        ['switch_block_statement_group:opaque'] = 10, switch_expression = 50,
        switch_rule = 162, synchronized_statement = 1, try_statement = 490,
        try_with_resources_statement = 649, ['try_with_resources_statement:opaque'] = 21,
        while_statement = 234, ['while_statement:opaque'] = 1 },
    mootools = { rows = 2100, opened = 513, opaque = 4, catch = 6, ['catch:opaque'] = 3,
        for_in_statement = 30, for_statement = 43, if_statement = 370, switch_case = 31,
        ['switch_case:opaque'] = 1, switch_default = 5, switch_statement = 11,
        try_statement = 9, while_statement = 8 },
    nio = { rows = 924, opened = 201, opaque = 0, elseif_statement = 19, for_statement = 38,
        if_statement = 141, while_statement = 3 },
    php = { rows = 22372, opened = 5016, opaque = 282, case_statement = 434,
        ['case_statement:opaque'] = 276, catch = 13, ['cond:opaque'] = 4,
        default_statement = 78, ['default_statement:opaque'] = 1, do_statement = 4,
        else_if_clause = 38, for_statement = 47, foreach_statement = 538,
        if_statement = 3617, ['if_statement:opaque'] = 1, switch_statement = 123,
        try_statement = 13, while_statement = 111 },
    python = { rows = 10754, opened = 2090, opaque = 0, catch = 158, elif_clause = 61,
        for_in_statement = 1, for_statement = 279, if_statement = 1441, try_statement = 144,
        while_statement = 6 },
    -- ── recalib @ CART-0363 part B, all THREE ruby corpora ──────────────────────────────
    -- ATTACHED BLOCKS (`do…end` / `{…}`) open, and CART-0397 restored the tail of every
    -- NESTED elsif chain. Both are ROWS THAT DID NOT EXIST BEFORE, so every number here
    -- rises and none falls — the review question ("did a form's opened count go DOWN, or a
    -- `<form>:opaque` count go UP?") is answered by the shape of the delta itself.
    -- rails: rows 10257->13852 (+35%), opened 2135->3609. `do_block`+`block` = 970 new
    -- control rows; the other ~500 newly opened are control statements that live INSIDE a
    -- block and so had no rows at all (if 797->977, if_modifier 952->1172, elsif 50->75).
    -- `elsif:opaque` 0->1 is the review question firing, and CHECKED: cached_counting.rb:78
    -- is a genuinely EMPTY arm (`elsif PG::ReadOnlySqlTransaction === ex` whose body is a
    -- comment), not a form that went dark.
    -- recalib @ CART-0387: a case SUBJECT and a when PATTERN are not rows (10324 -> 10257)
    rails = { rows = 13816, opened = 3592, opaque = 22, begin = 35, block = 447, case = 17,
        catch = 65, ['catch:opaque'] = 21, do_block = 506, elsif = 75, ['elsif:opaque'] = 1,
        ['if'] = 977, if_modifier = 1172, unless = 54, unless_modifier = 190, when = 47,
        ['while'] = 7 },
    -- ★ rspec IS THE BLOCK-DENSEST CORPUS WE OWN, and it shows what the gap actually was:
    -- an RSpec suite is `describe … do` / `it … do` all the way down, and it opened SIX
    -- control structures across 123 functions. Now 33, of which 25 are the blocks.
    rspec = { rows = 328, opened = 33, opaque = 0, block = 16, do_block = 9, ['if'] = 1,
        if_modifier = 7 },
    -- recalib @ CART-0387: rows 5893->5672. A ruby `case` SUBJECT and a `when` PATTERN are
    -- not statements that execute, so they stopped being rows. `when:opaque` 0->3 is the
    -- review question firing and CHECKED: all three are genuinely EMPTY arms
    -- (`when Integer` / `when nil` with no body, a deliberate ruby no-op), not a regression.
    -- …then @ part B: rows 5672->7745 (+37%), opened 1112->2027. `block:opaque` 0->1 is
    -- CHECKED the same way — group.rb:112 is `Dir::Tmpname.create([…]) { }`, a literally
    -- empty brace block, which is exactly what an honest opaque count is FOR.
    ruby = { rows = 7734, opened = 2022, opaque = 11, begin = 40, block = 311,
        ['block:opaque'] = 1, case = 70, catch = 65, ['catch:opaque'] = 7, do_block = 309,
        elsif = 78, ['if'] = 465, if_modifier = 298, unless = 67, unless_modifier = 138,
        ['until'] = 4, when = 163, ['when:opaque'] = 3, ['while'] = 14 },
    rust = { rows = 10986, opened = 1263, opaque = 1, case_statement = 9, for_expression = 146,
        if_expression = 685, if_statement = 1, loop_expression = 9, match_block = 190,
        match_expression = 190, while_expression = 33, ['while_expression:opaque'] = 1 },
    synjava = { rows = 312, opened = 58, opaque = 1, catch = 2, ['cond:opaque'] = 1,
        do_statement = 1, enhanced_for_statement = 3, for_statement = 9, if_statement = 31,
        switch_block_statement_group = 3, switch_expression = 2, switch_rule = 3,
        synchronized_statement = 1, try_statement = 1, try_with_resources_statement = 1,
        while_statement = 1 },
    synjs = { rows = 677, opened = 42, opaque = 1, catch = 1, ['cond:opaque'] = 1,
        do_statement = 1, for_in_statement = 3, for_statement = 11, if_statement = 20,
        switch_case = 2, switch_default = 1, switch_statement = 1, try_statement = 1,
        while_statement = 1 },
    synlua = { rows = 554, opened = 101, opaque = 19, ['cond:opaque'] = 19, do_statement = 20,
        elseif_statement = 10, for_statement = 14, if_statement = 23, repeat_statement = 19,
        while_statement = 15 },
}

return M
