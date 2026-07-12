-- The df / flow PARITY GATE.
--   nvim --headless -u NONE -l tools/dfgate.lua <corpus>
--
-- The structure gate (tools/gate.lua) diffs a SLIM snapshot that deliberately
-- DROPS df (snapshot.lua), so a def/use drift between flow.du and df's
-- collect_mentions — e.g. a per-language declarator fix landed on ONE side —
-- slips right past it. This gate closes that hole with the df-strangler's own
-- oracle: coarse(flow) must reproduce df's per-statement def/use, MODULO a
-- CATALOGUE of known flow-MORE-correct divergence classes, and flow's CFG
-- (successors/liveness/reaching) must run clean over every function.
--
-- No baseline is stored: coarse(flow)==df is an INVARIANT (both derived from
-- the same extraction), so the only pinned data is a tiny per-corpus RESIDUAL
-- budget (the uncatalogued remainder). Catalogued classes are reported, not
-- gated — a legit def/use improvement lands in one of them and doesn't trip the
-- gate; a real regression lands in the residual (OTHER/disjoint) or as a flow
-- error / partition mismatch, and does.
--
-- Exit 1 on: any flow-invariant error, OR residual over budget. Exit 2 if the
-- corpus is not calibrated / not applicable.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/dfgate%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local flow = require 'cartograph.flow'
local df = require 'cartograph.df'
local store = require 'cartograph.store'
local atr = require 'cartograph.at'

local name = arg and arg[1]
if not name then print('usage: dfgate <corpus>'); os.exit(2) end

-- per-corpus EXPECTED CENSUS: the full labeled divergence-class counts on a
-- known-good rev. The gate diffs actual vs this and fails on ANY delta. Why
-- exact counts, not a residual budget: a one-sided def/use regression (a fix
-- that lands in flow.du but not df, or vice versa) produces the SAME set-shapes
-- as the flow-more-correct classes (a def/use swap; flow⊂df), so it can't be
-- told apart by shape — but it MOVES a class count. The census diff catches
-- that; the labels make the delta interpretable. A deliberate flow/df change
-- recalibrates this table (review the delta first), exactly like the structure
-- gate's --save. A new corpus is uncalibrated (nil) → prints its census for
-- calibration, exits 2.
local EXPECTED = {
    self = { ['binding-as-use'] = 67, ['df-over-collects'] = 404,
        ['flow-over-collects'] = 3, ['OTHER'] = 1 },
    php = { ['df-over-collects'] = 35, ['flow-over-collects'] = 13 },
    cpp = { ['df-over-collects'] = 1, ['receiver'] = 10, ['df-empty-name'] = 1,
        ['partition-mismatch'] = 2, ['line-skew'] = 1 },
    go = {}, -- perfect parity: coarse(flow)==df exactly
    -- rust: all flow-MORE-correct — flow.du captures let/for/if-let bindings df
    -- misses (flow-over-collects), df leaks closure names (df-over-collects),
    -- and bare bindings swap def/use (binding-as-use). 0 flow-invariant errors.
    rust = { ['binding-as-use'] = 363, ['df-over-collects'] = 1980,
        ['flow-over-collects'] = 1988 },
}

local FN = { function_definition = true, method_declaration = true,
    function_declaration = true, method = true, function_item = true,
    method_definition = true, arrow_function = true }

local function toset(t) local s = {} for _, v in ipairs(t) do s[v] = true end return s end
local function eqset(a, b)
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end
local function subset(a, b) for k in pairs(a) do if not b[k] then return false end end return true end
local function empty(a) return next(a) == nil end

-- CATALOGUE: label a per-axis divergence by its flow-vs-df set relationship.
-- The labels annotate the census so a count delta is interpretable; every
-- class is pinned (see EXPECTED), so labels are for humans, not gating.
local function classify_axis(fs, ds)
    if eqset(fs, ds) then return nil end
    local sd = {} -- symmetric difference
    for k in pairs(fs) do if not ds[k] then sd[k] = true end end
    for k in pairs(ds) do if not fs[k] then sd[k] = true end end
    local only_empty, only_recv = true, true
    for k in pairs(sd) do
        if k ~= '' then only_empty = false end
        if k ~= 'this' and k ~= 'self' then only_recv = false end
    end
    if only_empty then return 'df-empty-name' end       -- df emits an empty name
    if only_recv then return 'receiver' end             -- this/self policy
    if subset(fs, ds) then return 'df-over-collects' end -- closure-leak / dedup (flow correct)
    if subset(ds, fs) then return 'flow-over-collects' end -- catch-bind / bare-local (flow correct)
    if not empty(fs) and not empty(ds) then
        for k in pairs(fs) do if ds[k] then return 'OTHER' end end -- some overlap → genuine both-differ
        return 'disjoint'                                -- no overlap → line-collision residue
    end
    return 'OTHER'
end

-- corpus identity (mirror gate.lua): a moved/dirty pinned checkout makes the
-- oracle meaningless
local corpus = bench.corpus(name)
if not corpus then print('unknown corpus: ' .. name); os.exit(2) end
local now = corpus.git and corpus.git.rev
if corpus.rev and not bench.same_rev(corpus.rev, now) then
    print(('DFGATE NOT APPLICABLE: %s pinned @ %s but checkout @ %s')
        :format(name, corpus.rev, now or '?'))
    os.exit(2)
end

local data = bench.extract(name)
local lang = corpus.lang
local spec = ts.spec[lang] or {}

local byfile = {}
for _, n in ipairs(data.nodes) do
    if (n.kind == 'function' or n.kind == 'method') and n.file and df.present(n) then
        byfile[n.file] = byfile[n.file] or {}
        table.insert(byfile[n.file], n)
    end
end

local cats, ferr, nfn, nstmt = {}, 0, 0, 0
local function tally(c) if c then cats[c] = (cats[c] or 0) + 1 end end

for file, nodes in pairs(byfile) do
    local ok_read, lines = pcall(vim.fn.readfile, store.abs_in(data, file))
    if ok_read then
        local src = table.concat(lines, '\n')
        local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
        if okp then
            local root = parser:parse()[1]:root()
            local byline = {}
            local function rec(nd)
                if FN[nd:type()] then local sl = select(1, nd:range()); byline[sl] = byline[sl] or nd end
                for c in nd:iter_children() do if c:named() then rec(c) end end
            end
            rec(root)
            for _, n in ipairs(nodes) do
                local af = byline[atr.sl(n.range)]
                if af then
                    local cfg = { pfield = spec.params_field, df_ids = spec.df_ids,
                        regime = flow.REGIME[lang],
                        method = spec.is_method and spec.is_method(n.name or '', af) or false }
                    local okb, fl = pcall(flow.build, af, src, cfg)
                    if okb then
                        nfn = nfn + 1
                        if not pcall(function () flow.successors(fl); flow.liveness(fl); flow.reaching(fl) end) then
                            ferr = ferr + 1
                        end
                        local co = flow.coarse(fl)
                        local dfs = df.get(n).stmts
                        if #co ~= #dfs then
                            tally('partition-mismatch')
                        else
                            for i, cs in ipairs(co) do
                                local ds = dfs[i]
                                if cs.l ~= ds.l then
                                    tally('line-skew')
                                else
                                    nstmt = nstmt + 1
                                    local fd, fu = toset(cs.def), toset(cs.use)
                                    local dd, du = toset(ds.def), toset(ds.use)
                                    if eqset(fd, dd) and eqset(fu, du) then
                                        -- agree
                                    elseif eqset(fd, du) and eqset(fu, dd)
                                        and (not empty(fd) or not empty(fu)) then
                                        tally('binding-as-use') -- def/use swap (flow defs a bare binding)
                                    else
                                        tally(classify_axis(fd, dd))
                                        tally(classify_axis(fu, du))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- census (stable order; KNOWN classes first, residual/structural last)
local order = { 'binding-as-use', 'df-over-collects', 'flow-over-collects',
    'receiver', 'df-empty-name', 'OTHER', 'disjoint', 'partition-mismatch', 'line-skew' }
local seen, parts = {}, {}
for _, k in ipairs(order) do
    if cats[k] then parts[#parts + 1] = k .. '=' .. cats[k]; seen[k] = true end
end
for k, v in pairs(cats) do if not seen[k] then parts[#parts + 1] = k .. '=' .. v end end
print(('dfgate %-6s fns=%d stmts=%d  flow-invariant-errors=%d')
    :format(name, nfn, nstmt, ferr))
print('  divergences: ' .. (#parts > 0 and table.concat(parts, ' ') or 'NONE'))

local failed = false
if ferr > 0 then
    print(('FAIL: %d flow-invariant errors (successors/liveness/reaching threw)'):format(ferr))
    failed = true
end

local expected = EXPECTED[name]
if expected == nil then
    print('NOT CALIBRATED: add EXPECTED[' .. name .. '] to tools/dfgate.lua after reviewing the census above')
    os.exit(failed and 1 or 2)
end
-- census diff: any class whose count moved is a def/use asymmetry to review
local allk = {}
for k in pairs(cats) do allk[k] = true end
for k in pairs(expected) do allk[k] = true end
local diffs = {}
for k in pairs(allk) do
    local a, e = cats[k] or 0, expected[k] or 0
    if a ~= e then diffs[#diffs + 1] = ('%s %d→%d'):format(k, e, a) end
end
if #diffs > 0 then
    table.sort(diffs)
    print('FAIL: coarse(flow)==df census moved (flow.du vs df drift — review, then recalibrate EXPECTED):')
    for _, d in ipairs(diffs) do print('    ' .. d) end
    failed = true
end
print('DFGATE: ' .. (failed and 'FAIL' or 'PASS'))
os.exit(failed and 1 or 0)
