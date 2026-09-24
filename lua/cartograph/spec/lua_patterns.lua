-- lua_patterns.lua — HOW FAR A LUA PATTERN CAN BACKTRACK: an UPPER bound on a search's growth in
-- the subject's length, for loopcost's call pricing (CART-1057). `spec.lua.pattern_degree`.
--
-- USER (2026-09-24): "Do we price string search patterns?" — no, only the subject's length was.
-- Measured on the trim idiom `s:match('^%s*(.-)%s*$')`: 0.17 s at 2,000 characters, 0.77 s at
-- 4,000, 2.75 s at 8,000 — quadratic in ONE call, priced linear.
--
-- ── THE BOUND ────────────────────────────────────────────────────────────────────
-- Lua's matcher (lstrlib.c) retries an unanchored pattern from every start position, and a
-- quantified item (`*`, `+`, `-`, and `%b` which scans to a balance) retries each length against
-- the rest of the pattern. So the worst case — a match that FAILS late — grows as n ^ degree:
--   degree = (unanchored ? 1 : 0) + the longest CHAIN of unbounded items that can trade characters
-- (the scan's 1 is dropped when the first item is bounded and disjoint from an unbounded item right
-- after it: no start inside that run can proceed — see degree())
-- A chain continues while each unbounded item's class OVERLAPS the next one's (`.-` then `%s*`),
-- and across a bounded item the previous class also matches (`.*,.*`: `.` swallows the comma);
-- it breaks where the classes are disjoint (`%d+%.%d+`: a digit run stops at the dot exactly).
-- Class overlap is decided by LUA'S OWN MATCHER over the 256 byte values, not by a table of
-- class names. The result is at least 1 (the scan itself).
-- ⚠ AN UPPER BOUND, and it overshoots where a greedy prefix cannot backtrack into what follows
-- (the trim idiom is degree 3 here and measures 2). loopcost carries it as a HOLE (`backtrack`),
-- never as certified depth: backtracking needs adversarial input, which the lens cannot see.
-- Acceptance: tools/patternjoin.lua times every sample pattern on backtracking-prone inputs and
-- checks the measured exponent never exceeds the degree.
-- ⚠ The pattern is the literal's SOURCE text (argv's `v`): a Lua escape (`"\n"`) is not decoded.

local M = {}

local members_memo = {}
local function members(cls)
    local m = members_memo[cls]
    if m then return m end
    m = {}
    if cls == '.' then
        for b = 0, 255 do m[b] = true end
    else
        local ok = pcall(function()
            for b = 0, 255 do
                if string.find(string.char(b), '^' .. cls .. '$') then m[b] = true end
            end
        end)
        if not ok then for b = 0, 255 do m[b] = true end end -- unparseable: assume it overlaps
    end
    members_memo[cls] = m
    return m
end

local function overlaps(a, b)
    local ma, mb = members(a), members(b)
    for x = 0, 255 do if ma[x] and mb[x] then return true end end
    return false
end
M._overlaps = overlaps

--- the pattern's single-character ITEMS: { cls, unb } (captures, anchors and frontiers dropped)
function M.items(pat, no_anchor)
    local i, n = 1, #pat
    local anchored = false
    if pat:sub(1, 1) == '^' and not no_anchor then anchored = true; i = 2 end
    local items = {}
    while i <= n do
        local ch = pat:sub(i, i)
        local cls
        if ch == '(' or ch == ')' then
            i = i + 1
        elseif ch == '$' and i == n then
            i = i + 1
        elseif ch == '%' and pat:sub(i + 1, i + 1) == 'b' then
            items[#items + 1] = { cls = '.', unb = true } -- %bxy scans to the balance: unbounded
            i = i + 4
        elseif ch == '%' and pat:sub(i + 1, i + 1) == 'f' then
            i = (pat:find(']', i + 3, true) or n) + 1 -- a frontier is zero width
        else
            if ch == '%' then
                local nx = pat:sub(i + 1, i + 1)
                cls = nx:match('%d') and '.' or ('%' .. nx) -- a back-reference: linear, any
                i = i + 2
            elseif ch == '[' then
                local j = i + 1
                if pat:sub(j, j) == '^' then j = j + 1 end
                if pat:sub(j, j) == ']' then j = j + 1 end
                while j <= n and pat:sub(j, j) ~= ']' do
                    if pat:sub(j, j) == '%' then j = j + 1 end
                    j = j + 1
                end
                cls = pat:sub(i, j); i = j + 1
            elseif ch == '.' then
                cls = '.'; i = i + 1
            else
                cls = ch:match('%p') and ('%' .. ch) or ch; i = i + 1
            end
            local q = pat:sub(i, i)
            local unb = q == '*' or q == '+' or q == '-'
            if unb or q == '?' then i = i + 1 end
            items[#items + 1] = { cls = cls, unb = unb }
        end
    end
    return items, anchored
end

--- @param pat string        the pattern's text
--- @param no_anchor boolean  a leading `^` is a LITERAL, not an anchor (5.1/LuaJIT gmatch)
--- @return integer degree  (>= 1)
--- @return integer chain   the longest overlapping unbounded chain
function M.degree(pat, no_anchor)
    local items, anchored = M.items(pat, no_anchor)
    local run, best, last = 0, 0, nil
    for _, it in ipairs(items) do
        if it.unb then
            if run > 0 and last and overlaps(last, it.cls) then run = run + 1 else run = 1 end
            last = it.cls
        elseif run > 0 and not (last and overlaps(last, it.cls)) then
            run, last = 0, nil
        end
        if run > best then best = run end
    end
    -- the unanchored SCAN multiplies a chain only if a start INSIDE the chain's region can proceed:
    -- when the first item is bounded and DISJOINT from an unbounded item right after it
    -- (`%.([%w]+)$`: a start inside a word fails at the dot at once), every start that reaches the
    -- run is outside it, and the scan adds nothing (measured 0.95 where the naive bound said 2)
    local scan = anchored and 0 or 1
    if scan == 1 and items[1] and not items[1].unb and items[2] and items[2].unb
        and not overlaps(items[1].cls, items[2].cls) then scan = 0 end
    return math.max(1, scan + best), best
end

return M
