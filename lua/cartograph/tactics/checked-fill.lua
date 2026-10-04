-- CHECKED FILL (discovery, CART-1342): may template VALUE fill hole HOLE of TEMPLATE, and what is the composite?
-- The PREMISE is the algebra's own generality order — VALUE must be an instance of the hole's UNIT, the single-hole
-- template carrying its domain (A.admits_template: instance_of checks a ground part by admits and a hole by entails,
-- domain inclusion) — and the STEP is A.fill. A.fill itself stays the raw composition: MEASURED 2026-10-03, filling a
-- hole pinned to 2 with the template 3 is accepted. Staging is the same step with the hole's own unit as the value
-- (the unit law: the composite is the template, domains included).
-- CLAIM: the value is admitted (the value carries the composite then); refused, `why` names the hole and its domain.
local function A() return require('cartograph.algebra').load() end

-- a template from a term or a template (a ground term is a template with no holes)
local function tpl(t) if t.body then return t end return A().template(t) end

local E = {
    name = 'checked-fill',
    kind = 'discovery',
    tags = { 'gate', 'algebra' },
    measures = 'CART-1342',
    summary = 'fill hole `hole` of `template` with `value` only if every instance of value lies in the hole\'s domain (value is an instance of the hole\'s unit); the value carries the composite',
    params = { template = 'term', hole = 'string', value = 'term' },
    measure = function (_, p)
        local a = A()
        local T, V = tpl(p.template), tpl(p.value)
        local ok, why = a.admits_template(T, p.hole, V)
        local v = { admitted = ok and true or false, why = why }
        if ok then v.composite = a.fill(T, p.hole, V) end
        return v
    end,
    claim = function (v)
        if v.admitted then return true, 'admitted' end
        return false, v.why
    end,
}

-- the fixture: f(?a, ?b) with a OPEN and b PINNED to 2
local function fixture()
    local a = A()
    local T = a.template(a.node('f', a.hole('a'), a.hole('b')))
    T.holes.b.domain = a.closed(a.lit(2))
    return T
end
local function row(hole, value)
    return function () return { template = fixture(), hole = hole, value = value() } end
end
local function holes(T) local n = vim.tbl_keys(T.holes); table.sort(n); return table.concat(n, ',') end

E.examples = {
    {
        name = 'a ground value inside the pin is ADMITTED, and the composite keeps the other hole',
        files = {}, params = row('b', function () return A().lit(2) end),
        expect = { holds = true, check = function (v) return v.composite and holes(v.composite) == 'a', 'holes ' .. (v.composite and holes(v.composite) or '-') end },
    },
    {
        name = 'a ground value outside the pin is REFUSED by name — the raw fill would accept it',
        files = {}, params = row('b', function () return A().lit(3) end),
        expect = { holds = false, check = function (v)
            return v.composite == nil and (v.why or ''):find('hole b', 1, true) ~= nil and A().fill(fixture(), 'b', A().template(A().lit(3))) ~= nil,
                tostring(v.why)
        end },
    },
    {
        name = 'the hole\'s own UNIT is admitted and the composite IS the template (the unit law: staging)',
        files = {}, params = function () local T = fixture(); return { template = T, hole = 'b', value = A().unit(T, 'b') } end,
        expect = { holds = true, check = function (v)
            local T = fixture()
            return vim.deep_equal(v.composite.body, T.body) and vim.deep_equal(v.composite.holes, T.holes), 'composite differs from the template'
        end },
    },
    {
        name = 'an OPEN hole cannot fill a pinned one — not every instance of it lies in the pin',
        files = {}, params = row('b', function () return A().template(A().hole('x')) end),
        expect = { holds = false },
    },
    {
        name = 'a hole under ANOTHER name with the same pin is admitted, and carries its domain into the composite',
        files = {}, params = row('b', function ()
            local a = A()
            local X = a.template(a.hole('x'))
            X.holes.x.domain = a.closed(a.lit(2))
            return X
        end),
        expect = { holds = true, check = function (v)
            return holes(v.composite) == 'a,x' and v.composite.holes.x.domain.kind == 'closed', 'holes ' .. holes(v.composite)
        end },
    },
    {
        name = 'anything fills an OPEN hole',
        files = {}, params = row('a', function () return A().template(A().node('g', A().hole('y'))) end),
        expect = { holds = true, check = function (v) return holes(v.composite) == 'b,y', 'holes ' .. holes(v.composite) end },
    },
    {
        name = 'a hole the template does not have is refused by name',
        files = {}, params = row('zz', function () return A().lit(1) end),
        expect = { holds = false, check = function (v) return (v.why or ''):find('no hole zz', 1, true) ~= nil, tostring(v.why) end },
    },
}

return E
