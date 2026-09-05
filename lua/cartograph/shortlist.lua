-- shortlist.lua — A RANKED SET OF CANDIDATES THAT STATES ITS OWN COMPLETENESS.
--
-- The third output kind, under an ACTION and a PREMISE (CART-0755). An action
-- says "do this" and is unsound when its direction comes from the code it fixes;
-- a premise says "true if X"; a SHORTLIST says only "the answer is in here,
-- ranked" — a SET, not a value. IT ASSERTS NOTHING ABOUT CORRECTNESS, so a wrong
-- shortlist costs TIME rather than truth, and that is why it generalises where
-- the other two do not.
--
-- ★★ WHY THIS EXISTS AT ALL, MEASURED: 126 tools in tools/, 112 of which PRINT to
-- stdout and 8 of which return a value — while 73 already sort, rank, or carry
-- `candidates`. A majority of the tool surface already does the narrowing work
-- and flattens it to text at the last step. And the flattening is the expensive
-- half: the same day's six behaviour-changing commits added SIXTY-NINE
-- non-comment lines to lua/, so the edit was never the work — the SEARCH was.
--
-- ⚠⚠ `complete` HAS NO DEFAULT AND IS REFUSED IF ABSENT, which is the one rule
-- this module exists to enforce. A NARROWING PRESENTED AS COMPLETE BECOMES A
-- CLAIM, and it fails in the dangerous direction: "the answer is one of these
-- five" makes you STOP LOOKING. So every shortlist must say which it is —
--    'exhaustive'  every member of `scope` was examined; absence is a RESULT
--    'ranked-open' the best N of a larger or unbounded population; absence
--                  means "not ranked highly", never "not there"
-- and `render` puts it in the header where no reader can miss it. This is the
-- ABSENT-vs-UNAVAILABLE distinction from the transport layer, one layer up.
--
-- ⚠ NOT `narrow.lua`, which is branch-sensitive TYPE narrowing and was here
-- first. Same English word, unrelated concept — the name collision hazard in our
-- own namespace (cf. the `attribute` collision, CART-0611).

local M = {}

M.EXHAUSTIVE = 'exhaustive'
M.RANKED_OPEN = 'ranked-open'

local VALID = { [M.EXHAUSTIVE] = true, [M.RANKED_OPEN] = true }

--- Build a shortlist. Refuses rather than guesses.
---@param o table { subject, scope, complete, rows, columns?, skipped? }
---@return table|nil, string|nil  the shortlist, or nil + why it was refused
function M.new(o)
    if type(o) ~= 'table' then return nil, 'shortlist.new needs a table' end
    if type(o.subject) ~= 'string' or o.subject == '' then
        return nil, 'a shortlist must name its SUBJECT — what was searched for'
    end
    if type(o.scope) ~= 'string' or o.scope == '' then
        return nil, 'a shortlist must name its SCOPE — the population searched'
    end
    -- THE REFUSAL THIS MODULE IS FOR. A caller that omits `complete` is a caller
    -- whose reader cannot tell a measured zero from an unranked one.
    if not VALID[o.complete] then
        return nil, ('a shortlist must declare `complete` as %q or %q — an '
            .. 'undeclared one reads as exhaustive and stops the search')
            :format(M.EXHAUSTIVE, M.RANKED_OPEN)
    end
    if type(o.rows) ~= 'table' then return nil, '`rows` must be a list' end
    return setmetatable({
        subject = o.subject, scope = o.scope, complete = o.complete,
        rows = o.rows, columns = o.columns, skipped = o.skipped,
    }, { __index = M })
end

--- What an EMPTY shortlist means — and it is not one thing.
--- ★ This is the whole reason `complete` is mandatory: exhaustive-and-empty is a
--- FINDING ("we looked at all of them and none qualifies"), ranked-open-and-empty
--- is the absence of one.
function M:empty_reason()
    if #self.rows > 0 then return nil end
    if self.complete == M.EXHAUSTIVE then
        return ('none of %s qualifies — every member was examined'):format(self.scope)
    end
    return ('nothing in %s ranked high enough to list; this is NOT a statement '
        .. 'that none exists'):format(self.scope)
end

--- Render to lines. The completeness rides in the header BY CONSTRUCTION, so a
--- tool cannot print a shortlist without printing what it does and does not mean.
---@param fmt function|nil  row -> string; defaults to the `columns` projection
function M:render(fmt)
    local out = {}
    out[#out + 1] = ('%s — %d of %s [%s]')
        :format(self.subject, #self.rows, self.scope, self.complete)
    local why = self:empty_reason()
    if why then out[#out + 1] = '  ' .. why end
    for i, r in ipairs(self.rows) do
        if fmt then out[#out + 1] = '  ' .. fmt(r, i)
        elseif self.columns then
            local parts = {}
            for _, c in ipairs(self.columns) do parts[#parts + 1] = tostring(r[c]) end
            out[#out + 1] = '  ' .. table.concat(parts, '  ')
        else
            out[#out + 1] = '  ' .. tostring(r)
        end
    end
    if self.skipped and #self.skipped > 0 then
        -- ★ SKIPPED IS PART OF THE COMPLETENESS CLAIM, not a footnote. An
        -- "exhaustive" list that quietly skipped members is not exhaustive, so
        -- naming them is what keeps the header honest.
        out[#out + 1] = ('  (%d not examined: %s)')
            :format(#self.skipped, table.concat(self.skipped, ', '))
    end
    return out
end

return M
