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

--- THE COMPLETENESS LADDER — highest coverage first, in ONE place, deliberately
--- shaped like `tier.lua`'s. A new rung (a sampled census? a timed-out scan?)
--- inserts as ONE ROW here rather than as N edits across N comparisons, which is
--- the lesson tier.lua's own header records: its if-chain was hand-copied into
--- census, ladder, graphdiff and fold, "four spellings that had already drifted".
---
--- ⚠ AND IT IS DELIBERATELY *NOT* A ROW IN tier.lua. Same SHAPE — a ladder, a
--- rank, a meet — but a different SUBJECT: `tier` ranks one EDGE's trust from its
--- boolean flags, this ranks a SET's coverage. Merging them would make one ladder
--- mean two things, which is the invariant tier.lua says it does not currently
--- satisfy (ladder.lua orders its bottom two rungs the other way; CART-0545).
--- Adopt the pattern, not the table.
M.LADDER = {
    { name = M.EXHAUSTIVE,  why = 'every member of the scope was examined' },
    { name = M.RANKED_OPEN, why = 'the best N of a larger or unbounded population' },
}

local RANK = {}
for i, r in ipairs(M.LADDER) do RANK[r.name] = i end
local VALID = RANK

--- Rank of a completeness claim: LOWER is more complete.
function M.rank(c) return RANK[c] end

--- The MEET of two claims — the weaker (higher-ranked) of the two. Composition
--- can only lose coverage, never restore it, so this is `max(rank)` and the
--- absorbing element falls out of the ladder rather than being special-cased.
function M.meet(a, b)
    local ra, rb = RANK[a], RANK[b]
    if not ra or not rb then return nil end
    return M.LADDER[math.max(ra, rb)].name
end

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
    -- ★★ THE DERIVATION CHAIN. This is PROVENANCE (user) — the same question
    -- `c.prov` answers per CALL and `tier.lua` answers per EDGE, asked of a SET —
    -- so it records EVERY step, not only the lossy ones. An all-exhaustive chain
    -- that stored nothing would have no provenance at all, which is what a
    -- lossy-events-only ledger gave. [[cartograph-provenance-surfacing]] banked
    -- exactly this shape ("NODE provenance + derivation chains"); this is a
    -- per-set instance of it.
    return setmetatable({
        subject = o.subject, scope = o.scope, complete = o.complete,
        rows = o.rows, columns = o.columns, skipped = o.skipped,
        derivation = { { subject = o.subject, scope = o.scope, complete = o.complete } },
    }, { __index = M })
end

--- The step where coverage was first lost, or nil if it never was — DERIVED from
--- the chain rather than stored beside it, so the two cannot disagree.
--- ⚠ IT IS THE FIRST WEAKENING STEP, NOT THE IMMEDIATE PARENT, and the
--- difference was a measured bug: on a 4-step chain (A exhaustive, B
--- ranked-open, C and D exhaustive) the parent-naming version left B — the step
--- that actually truncated — blameless, and accused C, which examined everything
--- and spent nothing.
function M:lost_at()
    for _, step in ipairs(self.derivation) do
        if step.complete ~= M.EXHAUSTIVE then return step end
    end
    return nil
end

--- Every step that weakened coverage. `#weakenings()` is HOW MANY times the
--- population was cut, which is what decides whether a small surviving set is
--- worth acting on: one truncation of 1274 is a different object from three.
function M:weakenings()
    local out = {}
    for _, step in ipairs(self.derivation) do
        if step.complete ~= M.EXHAUSTIVE then out[#out + 1] = step end
    end
    return out
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

--- Compose: a shortlist built by running something over THIS one's rows.
---
--- ★★ THE COMPLETENESS IS THE MEET, COMPUTED AND NEVER ASSERTED, and this is the
--- whole reason `derive` exists rather than callers writing `new` again. Once a
--- population has been TRUNCATED, nothing downstream can restore exhaustiveness:
--- an exhaustive check over the top 15 of a `ranked-open` list has examined every
--- member OF THE FIFTEEN and says nothing about the other 1259. A caller passing
--- `complete = 'exhaustive'` there is making a FALSE CLAIM about the original
--- population, and it is the exact failure this module was built to stop, one
--- composition later. `ranked-open` is ABSORBING.
---
--- ⚠ AND THE MEET IS NOT A CEILING ON HONESTY. A derived list may be MORE
--- restricted than its parent (a ranked-open step over an exhaustive parent
--- yields ranked-open), never less.
function M:derive(o)
    if type(o) ~= 'table' then return nil, 'derive needs a table' end
    local child_claim = o.complete
    if not VALID[child_claim] then
        return nil, ('a derived shortlist must declare its own `complete` too — '
            .. 'inheriting it silently is how a truncated population is reported '
            .. 'as exhaustive')
    end
    local eff = M.meet(self.complete, child_claim)
    local out, why = M.new{
        subject = o.subject, columns = o.columns, rows = o.rows,
        skipped = o.skipped, complete = eff,
        scope = o.scope or ('%d rows of "%s"'):format(#self.rows, self.subject),
    }
    if not out then return nil, why end
    out.from = self
    -- ★ THE CHAIN IS THE PARENT'S PLUS THIS STEP'S OWN CLAIM — the claim it MADE,
    -- not the meet it ended up with. A step that examined everything it was given
    -- says `exhaustive` forever; the meet lives on the LIST, and mixing the two
    -- would blame an honest step for an upstream cut. That distinction is the
    -- whole reason `lost_at` can name the right one.
    local chain = {}
    for _, e in ipairs(self.derivation) do chain[#chain + 1] = e end
    chain[#chain + 1] = { subject = o.subject, scope = out.scope, complete = child_claim }
    out.derivation = chain
    return out
end

--- The durable REFS a downstream tool can address, for rows that carry one.
--- `store.ref_of(id)` is the contract — "what pins, plans and journals hold
--- instead of a raw id" — so a shortlist row is addressable across a re-extract
--- without this module knowing anything about node ids.
function M:refs()
    local out = {}
    for _, r in ipairs(self.rows) do if r.ref then out[#out + 1] = r.ref end end
    return out
end

--- Render to lines. The completeness rides in the header BY CONSTRUCTION, so a
--- tool cannot print a shortlist without printing what it does and does not mean.
---@param fmt function|nil  row -> string; defaults to the `columns` projection
function M:render(fmt)
    local out = {}
    out[#out + 1] = ('%s — %d of %s [%s]')
        :format(self.subject, #self.rows, self.scope, self.complete)
    -- ★ THE PROVENANCE, when it is not already obvious. For a ROOT ranked-open
    -- list the only weakening IS this list, and the header already says "15 of
    -- 1274 [ranked-open]" — repeating it as "lost at <itself>" is noise that
    -- trains a reader to skip the line that matters on a COMPOSED one.
    local weak = self:weakenings()
    local self_only = #weak == 1 and weak[1].subject == self.subject
    if #weak > 0 and not self_only then
        out[#out + 1] = ('  narrowed %d time(s) over %d step(s); coverage lost at "%s" (%s)')
            :format(#weak, #self.derivation, weak[1].subject, weak[1].scope)
        for i = 2, #weak do
            out[#out + 1] = ('    …and again at "%s" (%s)'):format(weak[i].subject, weak[i].scope)
        end
    end
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
