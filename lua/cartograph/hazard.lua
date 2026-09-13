-- cartograph.hazard — A HAZARD IS A ROW, AND IT SAYS HOW TO DISCHARGE IT (CART-0920).
--
-- USER: "the way to resolve them with the tools should be discoverable, but this
-- looks like this needs an interactive composition of tool invocations".
--
-- ★★★ A HAZARD WAS A SENTENCE ADDRESSED TO A HUMAN. `impact.lua` emitted
--     "%s (file-local in %s, shared with staying code) is referenced — require
--      it, or copy it into the extracted module"
-- and a caller — cockpit row, agent verb, or a person driving one — could not ask
-- WHICH INVOCATION DISCHARGES THIS, because there was nothing to ask. Measured
-- over three sections of the algebra split: 13, 22 and 15 hazards, every one of
-- them resolved by reading prose and typing an edit the tool already knew.
-- ⇒ [[cartograph-interactive-reports]]'s lesson landing on hazards: the enabler
--   is ROWS, NOT STRINGS. And [[cartograph-explaining-a-finding]] already names
--   the shape — A HEDGE IS A DOOR.
--
-- ★★ AND THE TREE ALREADY HELD TWO REPRESENTATIONS. `optimize`/`optapply` read
-- `h.reason` off a row while `moveapply`/`impact` pushed strings, so "a hazard"
-- meant two different things depending on which verb built the plan. This is the
-- convergence, not a third: the row's field is `reason`, the name the existing
-- rows already use.
--
-- ★★★ IT QUACKS LIKE ITS OWN SENTENCE, ON PURPOSE. Consumers do `h:find('capture',
-- 1, true)` and `('%s'):format(h)` and `'x ' .. h` in a dozen places, including
-- specs. A row carrying `__tostring`, `__concat` and a `find` that delegates to
-- `reason` is ONE representation with a rendering — NOT the two-representations
-- drift CART-0698 warns about, which is two SOURCES OF TRUTH. There is one source
-- here; the string is a view of it.
--
-- ⚠ `fix` IS A PROPOSAL, NEVER AN ACTION. It names a verb and the arguments that
-- would discharge the hazard; nothing here runs it, and a caller is free to
-- decide the hazard is acceptable. A handle that executed itself would move the
-- operator's decision into the reporter.

local M = {}

local mt = {}
mt.__index = {
    --- delegate the string API consumers actually use, so a row reads as its own
    --- sentence wherever one was expected
    find = function (self, pat, init, plain) return self.reason:find(pat, init, plain) end,
    match = function (self, pat, init) return self.reason:match(pat, init) end,
    gsub = function (self, pat, rep, n) return self.reason:gsub(pat, rep, n) end,
    sub = function (self, i, j) return self.reason:sub(i, j) end,
    lower = function (self) return self.reason:lower() end,
    len = function (self) return #self.reason end,
}
mt.__tostring = function (self) return self.reason end
mt.__concat = function (a, b)
    if type(a) == 'table' then a = a.reason end
    if type(b) == 'table' then b = b.reason end
    return a .. b
end
mt.__len = function (self) return #self.reason end
mt.__eq = function (a, b) return tostring(a) == tostring(b) end

--- @param kind string   a stable slug: 'capture' | 'surface' | 'scaffold' | …
--- @param reason string the sentence, unchanged from what it was
--- @param fix table|nil { verb = string, args = table, why = string }
--- @param evidence table|nil machine-readable specifics
--- @return table hazard
function M.new(kind, reason, fix, evidence)
    return setmetatable({ kind = kind, reason = reason, fix = fix,
        evidence = evidence }, mt)
end

--- is this value one of our rows (as opposed to a bare string a producer has not
--- been converted yet)? ⚠ The answer must not be "it is a table": `optimize`
--- already builds plain `{ reason = … }` rows and those are hazards too.
function M.is(v) return type(v) == 'table' and v.reason ~= nil end

--- the row form of whatever a producer emitted — so a consumer can read `.kind`
--- and `.fix` without caring whether that producer has been converted
--- @return table
function M.row(v)
    if M.is(v) then return v end
    return M.new('unclassified', tostring(v))
end

--- ⚠ `table.concat` HONOURS NEITHER `__tostring` NOR `__concat` — it demands
--- real strings and raises "invalid value (table) at index N". That is the ONE
--- place the row does not quack like its sentence, and it is why this exists:
--- join through here rather than reaching for `table.concat` on a hazard list.
--- @return string
function M.text(list, sep)
    local out = {}
    for i, h in ipairs(list or {}) do out[i] = tostring(h) end
    return table.concat(out, sep or ' | ')
end

--- every fix a plan's hazards propose, in order, deduplicated by (verb, hazard
--- kind). ★ THIS IS THE DISCOVERABILITY SURFACE: given a plan, what could be run
--- next. It returns PROPOSALS; running them is the caller's business.
--- @param plan table
--- @return table fixes { { kind, verb, args, why, reason } }
function M.fixes(plan)
    local out, seen = {}, {}
    for _, h in ipairs((plan or {}).hazards or {}) do
        local r = M.row(h)
        if r.fix and r.fix.verb then
            local key = r.fix.verb .. '\0' .. tostring(r.kind)
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = { kind = r.kind, verb = r.fix.verb,
                    args = r.fix.args, why = r.fix.why, reason = r.reason }
            end
        end
    end
    return out
end

return M
