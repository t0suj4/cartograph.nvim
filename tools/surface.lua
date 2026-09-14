-- surface — WHAT A VENDORED ARTIFACT REACHES FOR, AND WHETHER ANYTHING SUPPLIES IT.
--
-- ★★★ WRITTEN BECAUSE I HAND-ROLLED THE SAME CHECK TWICE IN ONE DAY. Absorbing
-- the algebra produced two hand-written seams, and each needed the identical
-- question asked of it:
--
--     the PARTS protocol   a part reads `SHARED.vsym`; does core's PARTS table
--                          supply it, and does core still define the local?
--     the harness shim     the donor spec reads `assert.are_not.equal`; does the
--                          shim supply it?
--
-- Both are `reads ⊆ supplied`, one interface apart, and both were a dozen lines
-- of `gmatch` in a spec. ⇒ THE SECOND HAND-ROLLED WALKER IS THE ONE THAT SAYS
-- BUILD THE TOOL ([[cartograph-capabilities]]: never hand-roll a walker).
--
-- ★★ AND IT ANSWERS THE HALF OF "CAN THE TOOL CREATE A SHIM" THAT IT CAN.
-- It derives the OBLIGATION — which names must be mapped — and fences TOTALITY.
-- It cannot invent SEMANTICS: that busted's `equals` is `==` while `same` is
-- DEEP is a fact about the donor's harness, and getting it wrong is silent
-- (mapping `equals` onto a deep comparison makes the borrowed oracle WEAKER,
-- which is the flattering direction). Semantics come from a human or a declared
-- profile; totality comes from here.
--
-- ⚠⚠ THE FLOOR IS PART OF THE ANSWER, NOT AN EXTRA. A scan whose pattern matches
-- nothing reports ZERO MISSING — indistinguishable from a shim that supplies
-- everything. Both hand-rolled versions carried a floor assertion for that
-- reason and both would have been wrong without it, so `gap` REFUSES rather than
-- returning an empty list when it saw no uses at all.

local M = {}

--- Names an artifact reaches for.
---
--- @param src string     the artifact's text
--- @param spec table     { receivers = {'SHARED','assert'}, bares = {'describe','it'} }
---   receivers: a name read as `<recv>.member` (and `<recv>.a.b`, kept whole —
---              `assert.are_not.equal` is ONE name, not two)
---   bares:     a plain global that must exist, matched only where CALLED
--- @return table used  set of names -> true
function M.uses(src, spec)
    local used = {}
    for _, recv in ipairs((spec or {}).receivers or {}) do
        -- ⚠ THE RECEIVER IS MATCHED ON A FRONTIER. Without it, `SHARED` would
        -- also match inside `NOT_SHARED`, and a one-letter receiver would match
        -- any local of that name — which is exactly how the first hand-rolled
        -- version reported `termgraph reads S.eqs` (its own term-graph store).
        for name in src:gmatch('%f[%w_]' .. recv .. '%.([%w_.]+)') do
            used[recv .. '.' .. name] = true
        end
    end
    for _, bare in ipairs((spec or {}).bares or {}) do
        if src:find('%f[%w_]' .. bare .. '%s*%(') then used[bare] = true end
    end
    return used
end

--- What is used and not supplied.
---
--- ⚠ REFUSES on an empty `used` set: see the header. A caller that legitimately
--- expects nothing passes `opts.allow_empty`.
--- @return table|nil missing (sorted), string|nil why
function M.gap(used, supplied, opts)
    local n = 0
    for _ in pairs(used) do n = n + 1 end
    if n == 0 and not (opts and opts.allow_empty) then
        return nil, 'the scan found NO uses at all — a pattern that matches'
            .. ' nothing reports zero missing, which is the same answer as a'
            .. ' complete shim. Check the receivers before believing the gap'
    end
    local have = {}
    if supplied[1] ~= nil then                 -- a list of names
        for _, s in ipairs(supplied) do have[s] = true end
    else                                       -- or a set
        for s in pairs(supplied) do have[s] = true end
    end
    local missing = {}
    for name in pairs(used) do
        if not have[name] then missing[#missing + 1] = name end
    end
    table.sort(missing)
    return missing
end

--- one-line report, for a spec's failure message
--- @return string
function M.report(missing, what)
    if #missing == 0 then return ('%s: total'):format(what or 'surface') end
    return ('%s: %d unsupplied — %s'):format(what or 'surface', #missing,
        table.concat(missing, ', '))
end

return M
