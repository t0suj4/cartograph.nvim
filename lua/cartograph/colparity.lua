-- COLPARITY — the shared comparison core for the columnar faithfulness gates
-- (tools/callparity, tools/nodegate, tools/edgegate). A columnar view must read
-- IDENTICALLY to the raw records; these are the value-equality rules the gates
-- share (previously copied into each — a subtle divergence risk, since a wrong
-- rule silently changes a faithfulness VERDICT):
--   * veq  — scalars by ==, range tables ({start={line,char},end=…}) by deep
--            compare, other tables by REFERENCE (the proxy returns the same
--            residual table a raw read would).
--   * feq  — FLAG fields by TRUTHINESS (a column stores false↔nil as one value,
--            and consumers test `if c.flag`), every other field by veq.
-- Rendering stays per-gate (each prints/collects differently).

local M = {}

-- range-shaped deep compare, else reference/scalar equality
function M.veq(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    local function pt(p, q)
        if p == q then return true end
        if type(p) ~= 'table' or type(q) ~= 'table' then return false end
        return p.line == q.line and p.char == q.char
    end
    if a.start or a['end'] or b.start or b['end'] then
        return pt(a.start, b.start) and pt(a['end'], b['end'])
    end
    return false -- non-range tables must be reference-equal (handled by a==b)
end

-- build a field-aware equality closure given the FLAG field set: a flag compares
-- by truthiness (nil ≡ false), everything else by veq.
function M.mkfeq(flagset)
    return function (field, a, b)
        if flagset[field] then return (not not a) == (not not b) end
        return M.veq(a, b)
    end
end

return M
