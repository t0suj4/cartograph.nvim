-- df / flow PARITY CHECK — the shared core behind tools/dfgate.lua (the
-- per-corpus CLI gate) and tools/guards.lua (the dogfood run, which checks the
-- SELF corpus inline on its already-extracted data). Pure: operates on an
-- already-extracted `data` table, no extraction or exit of its own.
--
-- The oracle: coarse(flow) must reproduce df's per-statement def/use (the
-- df-strangler parity contract), MODULO known flow-MORE-correct classes, and
-- flow's CFG (successors/liveness/reaching) must run clean over every function.
-- The structure gate (tools/gate.lua) can't see this — its snapshot DROPS df.
--
-- Every divergence class is LABELLED and the full per-corpus census is PINNED
-- (M.EXPECTED); the gate fails on ANY class-count delta. Exact counts, not a
-- residual budget: a one-sided regression (a fix in flow.du but not df, or vice
-- versa) has the SAME set-shape as a flow-more-correct class, so only the COUNT
-- moving is a reliable signal.

local ts = require 'cartograph.providers.treesitter'
local flow = require 'cartograph.flow'
local df = require 'cartograph.df'
local store = require 'cartograph.store'
local atr = require 'cartograph.at'

local M = {}

-- per-corpus EXPECTED census (calibrated on a known-good rev). A deliberate
-- flow/df change recalibrates the affected entry (review the delta first),
-- exactly like the structure gate's --save. Uncalibrated corpus → nil.
-- (calibrated with PER-FILE language detection: each file checked under its own
-- grammar, matching extraction. This removed mis-parse artifacts that a single
-- corpus-lang produced — e.g. cpp's .sh files and libs' native .rs/.cpp.)
-- RECALIBRATED 2026-07-12 when flow moved to the STORED source (df-strangler
-- step 4): the census now compares the ACTUAL extracted+folded flow vs df, with
-- NO re-parse node-resolution. This DISSOLVED a class of harness artifacts —
-- `partition-mismatch`/`disjoint` and re-parse-induced flow-over-collects/OTHER
-- collapsed to ~0 (they were the walk mis-picking minified/nested-JS fns sharing
-- a start position, + the .ts-under-JS boundary), and `df-over-collects` (the
-- REAL closure-leak divergences) rose as leaks got attributed to the right node.
-- Net: cleaner, truer censuses. (self churns with cartograph's own code.)
M.EXPECTED = {
    -- self includes its multi-language tests/fixtures (php/js/…), not just lua.
    self = { ['binding-as-use'] = 73, ['df-over-collects'] = 457,
        ['flow-over-collects'] = 2, ['OTHER'] = 1 }, -- +1/+11 @ v50 const-fold
        -- (self analyzes its own new source: constfold.lua + the handle_var /
        -- post-pass edits add loop/binding patterns the catalogue counts; the
        -- fold is df-INERT — php/libs/grocy dfpar unchanged — so this is pure
        -- new-source churn, not a df-behavior change)
    php = { ['df-over-collects'] = 35, ['flow-over-collects'] = 13 },
    -- cpp/go line-skew = the control-transfer LABEL unwrap (v33): a labeled loop /
    -- C label target now heads its own coarse row at the LOOP's line rather than
    -- the label's line — a 1-line cosmetic label difference, def/use unchanged.
    cpp = { ['line-skew'] = 11 },
    go = { ['df-over-collects'] = 27, ['line-skew'] = 17 }, -- +line-skew (labels);
    -- df-over-collects=27 closure-leaks; partition-mismatch=21 was the re-parse
    -- artifact (minified vendored JS), gone with stored flow.
    -- rust: all flow-MORE-correct — flow.du captures let/for/if-let bindings df
    -- misses (flow-over-collects), df leaks closure names (df-over-collects),
    -- and bare bindings swap def/use (binding-as-use). 0 flow-invariant errors.
    rust = { ['binding-as-use'] = 363, ['df-over-collects'] = 1980,
        ['flow-over-collects'] = 1988 },
    python = { ['df-over-collects'] = 3 }, -- closure-leak/dedup only
    ruby = {}, -- perfect parity
    -- ghost = the JS scale corpus; df-over-collects (closure-leak) dominates. The
    -- old partition/disjoint/flow-over-collects residual was the re-parse .ts-
    -- under-JS + node-resolution artifact — gone with stored flow (OTHER=3 left).
    ghost = { ['df-over-collects'] = 1746, ['OTHER'] = 3 },
    jquery = { ['df-over-collects'] = 2 }, -- closure-leak (was masked by re-parse)
    mootools = {}, -- perfect parity (js archaeology tier)
    -- libs = elasticsearch: java + native rust/cpp, each checked under its own
    -- grammar. All flow-more-correct (closure-leak + bindings df misses).
    libs = { ['df-over-collects'] = 1588, ['flow-over-collects'] = 4 },
    -- synthetic corpora (tools/gen.lua): deterministic content, so these
    -- censuses are exact for (GEN_VERSION, seed) — recalibrate on gen bumps
    synlua = { ['df-over-collects'] = 47 }, -- closure-leak, flow-correct
    synjava = {}, -- perfect parity
    synjs = { ['df-over-collects'] = 294 }, -- closure-leak (arrows), flow-correct
}

M.ORDER = { 'binding-as-use', 'df-over-collects', 'flow-over-collects',
    'receiver', 'df-empty-name', 'OTHER', 'disjoint', 'partition-mismatch', 'line-skew' }

local FN = { function_definition = true, method_declaration = true,
    function_declaration = true, method = true, function_item = true,
    method_definition = true, arrow_function = true }

local function toset(t) local s = {} for _, v in ipairs(t) do s[v] = true end return s end
local function sortset(s) local o = {} for k in pairs(s) do o[#o + 1] = k end table.sort(o) return table.concat(o, ',') end
local function eqset(a, b)
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end
local function subset(a, b) for k in pairs(a) do if not b[k] then return false end end return true end
local function empty(a) return next(a) == nil end

-- label a per-axis divergence by its flow-vs-df set relationship (for humans;
-- gating is on the pinned census, not the label)
local function classify_axis(fs, ds)
    if eqset(fs, ds) then return nil end
    local sd = {}
    for k in pairs(fs) do if not ds[k] then sd[k] = true end end
    for k in pairs(ds) do if not fs[k] then sd[k] = true end end
    local only_empty, only_recv = true, true
    for k in pairs(sd) do
        if k ~= '' then only_empty = false end
        if k ~= 'this' and k ~= 'self' then only_recv = false end
    end
    if only_empty then return 'df-empty-name' end        -- df emits an empty name
    if only_recv then return 'receiver' end              -- this/self policy
    if subset(fs, ds) then return 'df-over-collects' end -- closure-leak / dedup (flow correct)
    if subset(ds, fs) then return 'flow-over-collects' end -- catch-bind / bare-local (flow correct)
    if not empty(fs) and not empty(ds) then
        for k in pairs(fs) do if ds[k] then return 'OTHER' end end
        return 'disjoint'
    end
    return 'OTHER'
end

--- Run the parity check over already-extracted `data`. Language is detected
--- PER FILE (ts.lang_of) — the same way extraction does — so a mixed-language
--- corpus (e.g. elasticsearch/libs = java + native rust/cpp) is each checked
--- under its own grammar, not a single nominal corpus lang.
--- Returns { cats = {class -> count}, ferr, nfn, nstmt, instances }. When
--- `collect` (a set {class=true}) is given, `instances[class]` gathers the
--- divergence instances (file/line/axis/flow/df/src) — the fix-side explorer
--- behind `dfgate --show <class>`.
function M.check(data, collect)
    local byfile = {}
    for _, n in ipairs(data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file and df.present(n) then
            byfile[n.file] = byfile[n.file] or {}
            table.insert(byfile[n.file], n)
        end
    end
    local cats, ferr, nfn, nstmt, instances = {}, 0, 0, 0, {}
    local function record(c, info)
        if not c then return end
        cats[c] = (cats[c] or 0) + 1
        if collect and collect[c] then
            local l = instances[c]; if not l then l = {}; instances[c] = l end
            l[#l + 1] = info
        end
    end
    for file, nodes in pairs(byfile) do
        local lang = ts.lang_of(file)
        local spec = lang and ts.spec[lang]
        local ok_read, lines = false, nil
        if spec then ok_read, lines = pcall(vim.fn.readfile, store.abs_in(data, file)) end
        if ok_read and spec then
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
                    -- SOURCE flow from the STORED graph (df-strangler step 4): the
                    -- eager-extracted + folded flow IS the shipped artifact, and
                    -- flow.record(n) is unambiguously node n's flow — no re-parse
                    -- node-resolution guesswork (which mis-picked minified/nested-JS
                    -- fns sharing a start position → false divergences). This makes
                    -- the census validate the ACTUAL stored flow vs df (the fusion
                    -- gate is now the census itself). Fall back to a fresh build only
                    -- for df fns WITHOUT stored flow (haskell's custom-df model).
                    local fl
                    if flow.present(n) then fl = flow.record(n)
                    elseif af then fl = select(2, pcall(flow.build, af, src, {
                        pfield = spec.params_field, df_ids = spec.df_ids, regime = spec.regime,
                        method = spec.is_method and spec.is_method(n.name or '', af) or false })) end
                    if fl then
                        do
                            nfn = nfn + 1
                            if not pcall(function () flow.successors(fl); flow.liveness(fl); flow.reaching_cfg(fl) end) then
                                ferr = ferr + 1
                            end
                            local co = flow.coarse(fl)
                            local dfs = df.get(n).stmts
                            if #co ~= #dfs then
                                record('partition-mismatch', { file = file, l = atr.sl(n.range) + 1,
                                    note = ('%s: flow %d stmts vs df %d'):format(n.name or '?', #co, #dfs) })
                            else
                                for i, cs in ipairs(co) do
                                    local ds = dfs[i]
                                    if cs.l ~= ds.l then
                                        record('line-skew', { file = file, l = cs.l,
                                            note = ('flow L%d vs df L%d'):format(cs.l, ds.l) })
                                    else
                                        nstmt = nstmt + 1
                                        local fd, fu = toset(cs.def), toset(cs.use)
                                        local dd, du = toset(ds.def), toset(ds.use)
                                        local srcline = lines[cs.l]
                                        if eqset(fd, dd) and eqset(fu, du) then
                                            -- agree
                                        elseif eqset(fd, du) and eqset(fu, dd)
                                            and (not empty(fd) or not empty(fu)) then
                                            record('binding-as-use', { file = file, l = cs.l, src = srcline,
                                                axis = 'def/use swap', flow = sortset(fd) .. ' / ' .. sortset(fu),
                                                df = sortset(dd) .. ' / ' .. sortset(du) })
                                        else
                                            record(classify_axis(fd, dd), { file = file, l = cs.l, src = srcline,
                                                axis = 'def', flow = sortset(fd), df = sortset(dd) })
                                            record(classify_axis(fu, du), { file = file, l = cs.l, src = srcline,
                                                axis = 'use', flow = sortset(fu), df = sortset(du) })
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
    return { cats = cats, ferr = ferr, nfn = nfn, nstmt = nstmt, instances = instances }
end

--- Render collected instances of a class as report lines (the `--show` output).
function M.show_instances(list, class, cap)
    cap = cap or 40
    local n = list and #list or 0
    local L = { ('%s: %d instance(s)%s'):format(class, n, n > cap and (' (showing first ' .. cap .. ')') or ''), '' }
    for i = 1, math.min(n, cap) do
        local it = list[i]
        L[#L + 1] = ('%s:%d'):format(it.file, it.l)
        if it.note then L[#L + 1] = '    ' .. it.note end
        if it.src then L[#L + 1] = '    | ' .. it.src:gsub('^%s+', ''):sub(1, 76) end
        if it.flow or it.df then
            L[#L + 1] = ('    [%s]  flow={%s}  df={%s}'):format(it.axis or '', it.flow or '', it.df or '')
        end
    end
    return L
end

--- Census one-liner (the labelled divergence counts, stable order).
function M.census(cats)
    local seen, parts = {}, {}
    for _, k in ipairs(M.ORDER) do
        if cats[k] then parts[#parts + 1] = k .. '=' .. cats[k]; seen[k] = true end
    end
    for k, v in pairs(cats) do if not seen[k] then parts[#parts + 1] = k .. '=' .. v end end
    return #parts > 0 and table.concat(parts, ' ') or 'NONE'
end

--- Diff actual `cats` vs `expected` census → sorted list of "class e→a" strings
--- for every class whose count moved (empty = in parity).
function M.diff(cats, expected)
    local allk, diffs = {}, {}
    for k in pairs(cats) do allk[k] = true end
    for k in pairs(expected) do allk[k] = true end
    for k in pairs(allk) do
        local a, e = cats[k] or 0, expected[k] or 0
        if a ~= e then diffs[#diffs + 1] = ('%s %d→%d'):format(k, e, a) end
    end
    table.sort(diffs)
    return diffs
end

return M
