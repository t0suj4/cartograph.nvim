-- cartograph.receipt — WHAT A PLAN DECIDED, INCLUDING WHAT IT DECIDED SILENTLY.
--
-- USER: "maybe we should offer up for review the whole thing, including things
-- that go smoothly so they can be reviewed too".
--
-- ★★★ A HAZARD CARRIES ITS REASON; A SUCCESS CARRIES NOTHING. A plan reports what
-- it will NOT do and leaves what it DID as bare counts — `rewrites = 0` is the
-- whole problem in one field, because it could mean NO CALLERS EXIST or NO
-- CALLERS WERE RESOLVABLE and nothing says which.
--
-- ⇒ SILENCE HAS THREE CAUSES AND THEY RENDER IDENTICALLY: nothing to do, we did
--   it, we could not look. Measured, this project paid for each of them in one
--   day:
--     `hopau` went smoothly, so nobody reviewed it — the next section proved the
--        smoothness was luck
--     `slice` produced ZERO capture hazards because its 26 call sites were
--        unresolved: "could not look" rendered as "nothing to do", and the
--        extracted module loaded clean and died on first use (CART-0919)
--     a mutation did not bite, and "the test does not cover it" looked exactly
--        like "the code does nothing" — the answer was to delete the code
--
-- ★★ SO EVERY ROW CARRIES A WARRANT, and the warrants are the ones the transport
-- layer already draws between ABSENT and UNAVAILABLE:
--
--     did       we performed N of these, and here they are
--     none      we LOOKED and found nothing — and `by` says what looked
--     partial   we looked, and the answer is a LOWER BOUND (say why)
--     blind     this could not be looked at at all (say why)
--
-- ⚠ `none` AND `blind` ARE THE POINT. Collapsing them is exactly the defect this
-- exists to prevent, so `none` REQUIRES a `by` — an instrument that found
-- nothing must name itself, or its silence is indistinguishable from absence.

local M = {}

local Receipt = {}
Receipt.__index = Receipt

--- @return table receipt
function M.new()
    return setmetatable({ rows = {} }, Receipt)
end

--- we did N of these
function Receipt:did(what, n, evidence)
    self.rows[#self.rows + 1] = { what = what, warrant = 'did', n = n or 0,
        evidence = evidence }
    return self
end

--- we looked and found none. ⚠ `by` IS REQUIRED: an instrument that found
--- nothing must name itself, or the row says nothing a blank would not.
function Receipt:none(what, by, evidence)
    if type(by) ~= 'string' or by == '' then
        error('receipt:none(' .. tostring(what) .. ') needs `by` — what looked?', 2)
    end
    self.rows[#self.rows + 1] = { what = what, warrant = 'none', n = 0,
        by = by, evidence = evidence }
    return self
end

--- we looked and the answer is a LOWER BOUND
function Receipt:partial(what, n, why, evidence)
    self.rows[#self.rows + 1] = { what = what, warrant = 'partial', n = n or 0,
        why = why, evidence = evidence }
    return self
end

--- this could not be looked at
function Receipt:blind(what, why, evidence)
    self.rows[#self.rows + 1] = { what = what, warrant = 'blind', n = 0,
        why = why, evidence = evidence }
    return self
end

--- ★ THE REVIEW QUESTION, ANSWERED IN ONE CALL: is anything here unwarranted?
--- A clean run is not `#rows == 0` — it is every row `did` or `none`.
--- @return table rows  the `partial` and `blind` ones, in order
function Receipt:unwarranted() return M.unwarranted(self.rows) end

--- @return table rows
function M.unwarranted(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do
        if r.warrant == 'partial' or r.warrant == 'blind' then out[#out + 1] = r end
    end
    return out
end

--- one line per row, for a report or a spec's message
--- @return table lines
function Receipt:lines() return M.lines(self.rows) end

--- ⚠ THE MODULE FUNCTIONS TAKE PLAIN ROWS, and a plan carries ROWS rather than
--- this object: `journal.begin` SERIALIZES the plan it is given, and a table with
--- a metatable and methods does not survive that. The builder is for building.
--- @return table lines
function M.lines(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do
        if r.warrant == 'did' then
            out[#out + 1] = ('  did       %-28s %d'):format(r.what, r.n)
        elseif r.warrant == 'none' then
            out[#out + 1] = ('  none      %-28s looked: %s'):format(r.what, r.by)
        elseif r.warrant == 'partial' then
            out[#out + 1] = ('  partial   %-28s %d so far — %s'):format(r.what, r.n,
                tostring(r.why))
        else
            out[#out + 1] = ('  ⚠ blind   %-28s %s'):format(r.what, tostring(r.why))
        end
    end
    return out
end

return M
