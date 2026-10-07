-- DERIVE-ACCEPT (discovery, CART-1483): does every algebra DERIVATION, compiled by mix, agree with itself interpreted?
-- The arguments are the ones a real suite passes: the suite (default the vendored donor suite, the one the derivations
-- were judged by) runs under a permissive busted shim with the derivations bound into the algebra, and each operator's
-- first `cap` distinct argument lists are TAPPED. Per operator: its closure assembled (mixalg.program; `through = 1`
-- follows the basis into the algebra, with `opaque` kept primitives — default admits / admits_slice / match / entails),
-- lowered, specialized ALL-DYNAMIC (`reuse = eager` for the eager policy, CART-1507), and the residual run on every
-- sample against the interpreted derivation. Each row also carries the residual's SIZE (bytes, functions) — the code-size
-- side of the reuse choice. Closures in results compare as placeholders (identity differs by construction); a call past
-- 5e7 VM instructions is aborted (a LOOPING residual is a finding, not a hang).
-- ⚠ It binds the derivations into the shared algebra table and turns the JIT off for the instruction guard while it
-- runs; both are restored, on error too.
-- CLAIM: no operator differs, none is refused, at least one was compared — and the CONTROL held: two of a derivation's
-- own results that differ compared as different (a dead comparison would call every residual right).
local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local OPAQUE = { 'M.admits', 'M.admits_slice', 'M.match', 'M.entails' }

-- (a closure in a result compares by identity — the residual's and the original's are different objects)
local function nofn(v, seen)
    seen = seen or {}
    if type(v) == 'function' then return '<fn>' end
    if type(v) ~= 'table' then return v end
    if seen[v] then return seen[v] end
    local o = {}; seen[v] = o
    for k, x in pairs(v) do o[k] = nofn(x, seen) end
    return o
end

-- the suite's arguments per operator, with the derivations bound into A -> { [op] = { args… } } | nil, why
local function tap(A, D, suite, cap)
    local orig = {}
    for _, op in ipairs(D.OPERATORS) do orig[op] = A[op] end
    local samples, seen = {}, {}
    local ok, err = pcall(function ()
        D.apply_to(A, 'all')
        for _, op in ipairs(D.OPERATORS) do
            samples[op], seen[op] = {}, {}
            local f = A[op]
            A[op] = function (...)
                local n = select('#', ...)
                if #samples[op] < cap then
                    local okc, args = pcall(vim.deepcopy, { n = n, ... })
                    local okk, key = pcall(vim.inspect, args, { depth = 6 })
                    if okc and okk and not seen[op][key] then seen[op][key] = true; samples[op][#samples[op] + 1] = args end
                end
                return f(...)
            end
        end
        local any = setmetatable({}, { __index = function (t) return t end, __call = function () end })
        local env = setmetatable({ assert = any, pending = function () error('pending', 0) end,
            describe = function (_, fn) fn() end, before_each = function () end, after_each = function () end,
            it = function (_, fn) pcall(fn) end }, { __index = _G })
        package.preload['algebra'] = function () return A end
        local chunk = assert(loadfile(suite))
        setfenv(chunk, env)
        pcall(chunk)
    end)
    package.preload['algebra'] = nil
    for _, op in ipairs(D.OPERATORS) do A[op] = orig[op] end
    if not ok then return nil, 'tapping ' .. suite .. ': ' .. tostring(err) end
    return samples
end

local function measure(_, p)
    local MA, MX, F = require 'cartograph.mixalg', require 'cartograph.mix', require 'cartograph.mixfn'
    local R = require 'cartograph.algebraread'
    local A = require('cartograph.algebra').load()
    local D = require 'cartograph.algebra.derive'
    local ops = p.ops and vim.split(p.ops, ',', { trimempty = true }) or D.OPERATORS
    for _, op in ipairs(ops) do
        if not D[op] then return { error = ('no derivation for `%s` in cartograph.algebra.derive (its OPERATORS: %s)'):format(op, table.concat(D.OPERATORS, ', ')) } end
    end
    local suite = p.suite or (repo_of_toolbelt() .. '/tests/vendor/algebra_spec.lua')
    local samples, why = tap(A, D, suite, tonumber(p.cap or 12))
    if not samples then return { error = why } end
    local through = p.through == '1' or p.through == 'true'
    local opaque
    if through then
        opaque = {}
        for _, k in ipairs(p.opaque and vim.split(p.opaque, ',', { trimempty = true }) or OPAQUE) do opaque[k] = true end
    end
    local rows, tally = {}, { agree = 0, differ = 0, nosample = 0, refused = 0 }
    local control
    local function same_result(w, g)
        if w[1] and g[1] then
            local okd, d = pcall(vim.deep_equal, nofn({ unpack(w, 2, 4) }), nofn({ unpack(g, 2, 4) }))
            return okd and d
        end
        return (not w[1]) and (not g[1])
    end
    local jit_was = jit and jit.status and jit.status()
    if jit then jit.off() end
    local okall, eall = pcall(function ()
        for _, op in ipairs(ops) do
            local key = 'derive.lua::D.' .. op
            local row = { op = op, samples = #(samples[op] or {}) }
            local okp, text, _, lines, knowns, _, prims = pcall(MA.program, key, nil, { snapshot = true, through = through or nil, opaque = opaque })
            local prog, entry, G
            if not okp then row.refused = 'assemble: ' .. tostring(text)
            else
                local okl, pr = pcall(MX.lower, R.read(text, 'lua'), { lines = lines })
                if not okl then row.refused = 'lower: ' .. MX.describe(pr)
                else
                    prog, entry = pr, MA.mangle(key)
                    G = { ['M.grammars'] = A.grammars }
                    for k, v in pairs(knowns or {}) do G[k] = v end
                end
            end
            -- one residual for a division and its statics -> the residual function | nil, why
            local function build(div, statics)
                local oks, res, st = pcall(MX.specialize, prog, entry, div, statics, { budget = 5e6, globals = G, prims = prims, reuse = p.reuse })
                if not oks then return nil, 'specialize: ' .. MX.describe(res) end
                local out = MX.print(res, prog.where)
                row.bytes, row.functions = (row.bytes or 0) + #out, (row.functions or 0) + #res.order
                row.dead_dropped = (row.dead_dropped or 0) + (st.dead_dropped or 0)
                local K = {}
                for k, v in pairs(G) do K[k] = v end
                for k in pairs(opaque or {}) do K[k] = A[k:sub(3)] end
                local okf, f = pcall(function () return assert(load(out, 'residual', 't', F.env(res.pool, K, nil, prims)))() end)
                if not okf then return nil, 'load: ' .. tostring(f) end
                -- (a PLANTED difference — the tool's own negative control: this operator's compiled result gets one
                -- field more, so a run that still calls it right has a dead comparison or a dead tally)
                if p.plant == op then
                    local r0 = f
                    f = function (...)
                        local r = { r0(...) }
                        if type(r[1]) == 'table' then r[1] = vim.deepcopy(r[1]); r[1].__planted = true else r[1] = { planted = r[1] } end
                        return unpack(r, 1, table.maxn(r))
                    end
                end
                return f
            end
            -- the CASES: every sample against one all-dynamic residual, or (static = first) the samples grouped by their
            -- FIRST argument, a residual specialized to each — the compiled form a template-first verb is used in
            local cases = {}
            if prog and row.samples > 0 then
                local np = #prog.funcs[entry].params
                if p.static == 'first' then
                    local groups, order = {}, {}
                    for _, a in ipairs(samples[op]) do
                        local okk, gk = pcall(vim.inspect, a[1], { depth = 12 })
                        gk = okk and gk or tostring(a[1])
                        if not groups[gk] and #order < tonumber(p.groups or 4) then groups[gk] = { first = a[1], list = {} }; order[#order + 1] = gk end
                        if groups[gk] then table.insert(groups[gk].list, a) end
                    end
                    for _, gk in ipairs(order) do
                        local div = { 'S' }
                        for i = 2, np do div[i] = 'D' end
                        local f, why = build(div, { groups[gk].first })
                        if not f then row.refused = why; break end
                        for _, a in ipairs(groups[gk].list) do cases[#cases + 1] = { a = a, f = f, rest = true } end
                    end
                    row.samples = #cases
                else
                    local div = {}
                    for i = 1, np do div[i] = 'D' end
                    local f, why = build(div, {})
                    if not f then row.refused = why
                    else for _, a in ipairs(samples[op]) do cases[#cases + 1] = { a = a, f = f } end end
                end
            end
            if row.refused then row.class = 'refused'
            elseif row.samples == 0 then row.class = 'nosample'
            else
                local function guarded(f, a, rest)
                    debug.sethook(function () error('GUARD: instruction budget', 0) end, '', 5e7)
                    local c = vim.deepcopy(a)
                    local r = { pcall(f, unpack(c, rest and 2 or 1, c.n)) }
                    debug.sethook()
                    return r
                end
                local agree, w1 = 0, nil
                for i, cs in ipairs(cases) do
                    local w, g = guarded(D[op], cs.a), guarded(cs.f, cs.a, cs.rest)
                    local same = same_result(w, g)
                    -- (the CONTROL: two of the derivation's own results that differ must compare as different — a dead
                    -- comparison would call every residual right)
                    if not w1 then w1 = w elseif not control and w[1] and w1[1] and not same_result(w1, w) then control = op end
                    if same then agree = agree + 1
                    elseif not row.first then
                        row.first = ('sample %d: want %s / got %s'):format(i, vim.inspect(w[2], { depth = 2 }):sub(1, 120),
                            vim.inspect(g[2], { depth = 2 }):sub(1, 120)):gsub('%s+', ' ')
                    end
                end
                row.agree = agree
                row.class = agree == row.samples and 'agree' or 'differ'
            end
            tally[row.class] = tally[row.class] + 1
            rows[#rows + 1] = row
        end
    end)
    debug.sethook()
    if jit and jit_was then jit.on() end
    if not okall then return { error = tostring(eall), rows = rows } end
    local bytes, fns = 0, 0
    for _, r in ipairs(rows) do bytes, fns = bytes + (r.bytes or 0), fns + (r.functions or 0) end
    return { rows = rows, tally = tally, bytes = bytes, functions = fns, through = through, reuse = p.reuse or 'lazy', control = control }
end

local E = {
    name = 'derive-accept',
    kind = 'discovery',
    tags = { 'accept', 'algebra' },
    measures = 'CART-1483',
    summary = 'does every algebra derivation, COMPILED by mix (all-dynamic), agree with itself interpreted on the arguments a real suite passes? ops = a,b (default all), through = 1 (follow the basis), opaque = M.x,… (through: kept primitives), reuse = eager, cap = samples per op (12), suite = the spec to tap (default the vendored donor suite), plant = op (a planted difference: the negative control); rows carry residual bytes / functions',
    params = { ops = 'string?', through = 'string?', opaque = 'string?', reuse = 'string?', cap = 'string?', suite = 'string?', plant = 'string?', static = 'string?', groups = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local t = v.tally
        local head = ('%d agree, %d differ, %d no sample, %d refused (%s, %s; %d bytes in %d functions)'):format(t.agree, t.differ,
            t.nosample, t.refused, v.through and 'through' or 'plain', v.reuse, v.bytes, v.functions)
        if t.differ > 0 or t.refused > 0 then
            for _, r in ipairs(v.rows) do
                if r.class == 'differ' then return false, head .. ' — first: ' .. r.op .. ' ' .. tostring(r.first) end
                if r.class == 'refused' then return false, head .. ' — first: ' .. r.op .. ' ' .. tostring(r.refused) end
            end
        end
        if t.agree == 0 then return false, head .. ' — nothing compared' end
        if not v.control then return false, head .. ' — the CONTROL failed: no two of a derivation\'s own different results compared as different (a dead comparison, or every sample alike)' end
        return true, head .. '; control: ' .. v.control
    end,
}

-- the examples tap a SMALL suite, not the 8,270-line donor one: two calls of `sites`, nothing of `unit`
local MINI = table.concat({
    'local A = require "algebra"',
    'describe("mini", function ()',
    '  it("sites", function ()',
    '    A.sites(A.template(A.node("f", A.hole("x"), A.node("g", A.hole("y")))))',
    '    A.sites(A.template(A.node("h", A.hole("z"))))',
    '  end)',
    'end)', '' }, '\n')
local function mini(extra) return function (store)
    local t = { suite = store.data.root .. '/mini_spec.lua' }
    for k, v in pairs(extra) do t[k] = v end
    return t
end end

E.examples = {
    {
        name = 'a derivation the suite calls AGREES compiled and interpreted, on every tapped sample, with its residual size',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'sites' }),
        expect = { holds = true, check = function (v)
            local r = v.rows[1]
            -- (at least the two direct calls: `sites` is reached through other operators the suite calls too)
            return r.class == 'agree' and r.samples >= 2 and r.agree == r.samples and r.bytes > 0 and r.functions > 0, vim.inspect(r)
        end },
    },
    {
        name = 'THROUGH the basis too',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'sites', through = '1' }),
        expect = { holds = true, check = function (v) return v.through and v.rows[1].class == 'agree', vim.inspect(v.rows[1]) end },
    },
    {
        name = 'a PLANTED difference (the negative control) is reported as DIFFER, with the first differing sample',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'sites', plant = 'sites' }),
        expect = { holds = false, check = function (v)
            local r = v.rows[1]
            return r.class == 'differ' and r.agree == 0 and v.tally.differ == 1 and (r.first or ''):find('__planted', 1, true) ~= nil, vim.inspect(r)
        end },
    },
    {
        name = 'an operator the suite never calls has NO SAMPLE — and a run that compared nothing does not hold',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'unit' }),
        expect = { holds = false, check = function (v) return v.rows[1].class == 'nosample' and v.tally.agree == 0, vim.inspect(v.rows[1]) end },
    },
    {
        name = 'an operator with NO derivation is refused by name before anything runs',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'no_such_op' }),
        expect = { holds = false, check = function (v) return (v.error or ''):find('no derivation for `no_such_op`', 1, true) ~= nil, tostring(v.error) end },
    },
}

return E