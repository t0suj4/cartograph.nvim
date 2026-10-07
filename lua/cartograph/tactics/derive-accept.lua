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
-- COVERAGE (CART-1538): each row also carries how much of its RESIDUAL the tapped samples ran — statement lines and
-- branch arms (an arm counts when its first statement ran, recorded by the guard's line hook) — and the claim line says
-- it: measured 2026-10-07, 21.0% of lines and 14.5% of arms, so "agree" is about the paths the suite happens to reach.
-- THE DERIVED CLIENT (fuzz = N [points = 8] [keep = 0.4] [seed = 1538], CART-1538): each operator's case split (the term kinds
-- its code compares against) turned into a peergen model by fnpeer, the generated client driving the derivation
-- interpreted and its residual with N seeded inputs; rows carry `fuzz` = { inputs, ok_same, ok_differ, err_same,
-- err_diffmsg, mixed, budget, decode } and an ok/ok difference, a mixed outcome or a message difference (modulo position
-- and a residual local's name) makes the row DIFFER. Measured 2026-10-07 (120 inputs): arms 14.5% -> 21.5%; on planted
-- RESIDUAL mutants it killed 22 the samples missed out of 160 (match: 15 vs 6); it found CART-1540.
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

-- SYNTHESIZED SAMPLES for an operator the suite never calls (CART-1538): its arguments made from OTHER operators'
-- sampled calls and NATIVE results — one operator's reply is another's request, peergen's premise. Only for operators
-- with no sample; native results only (the derivations are not consulted); a fixed order (D.OPERATORS).
--   diff_regions(a, b, path, out)  pairs of sampled terms        unit(T, h) / admits_template(T, h, T2)  a sampled
--   extract_call(X, V) / extract_call_of(X, t)  native extract's record over extract's samples, its call's term
--   kv_eq(x, y)  pairs of kv_generalize's records                template with one of its own holes
local function synthesize(A, D, samples, cap)
    local made = {}
    local function is_template(v) return type(v) == 'table' and type(v.body) == 'table' and type(v.holes) == 'table' end
    local function is_term(v) return type(v) == 'table' and type(v.k) == 'string' end
    local function add(op, args)
        if #(samples[op] or {}) > 0 and not made[op] then return end -- (a sampled operator keeps its own)
        samples[op] = samples[op] or {}
        if #samples[op] < cap then samples[op][#samples[op] + 1] = args; made[op] = (made[op] or 0) + 1 end
    end
    local templates, terms = {}, {}
    for _, op in ipairs(D.OPERATORS) do
        for _, a in ipairs(samples[op] or {}) do
            for i = 1, a.n or #a do
                local v = a[i]
                if is_template(v) and #templates < 40 then templates[#templates + 1] = v
                elseif is_term(v) and #terms < 40 then terms[#terms + 1] = v end
            end
        end
    end
    local function first_hole(T) local hs = {}; for h in pairs(T.holes) do hs[#hs + 1] = h end; table.sort(hs); return hs[1] end
    for i = 1, #terms - 1 do add('diff_regions', { n = 4, terms[i], terms[i + 1], {}, {} }) end
    for i, T in ipairs(templates) do
        local h = first_hole(T)
        if h then
            add('unit', { n = 2, T, h })
            add('admits_template', { n = 4, T, h, templates[i % #templates + 1] })
        end
    end
    for _, a in ipairs(samples.extract or {}) do
        local okx, X = pcall(A.extract, unpack(vim.deepcopy(a), 1, a.n))
        if okx and type(X) == 'table' and X.params then
            local V = {}
            for _, pr in ipairs(X.params) do V[pr.hole] = A.lit(1) end
            add('extract_call', { n = 3, X, V })
            local okc, r = pcall(A.extract_call, X, V)
            if okc and type(r) == 'table' and r.ok then add('extract_call_of', { n = 3, X, r.term }) end
        end
    end
    for _, a in ipairs(samples.kv_generalize or {}) do
        local recs = a[1]
        if type(recs) == 'table' then
            for i = 1, #recs do add('kv_eq', { n = 2, recs[i], recs[i % #recs + 1] }); add('kv_eq', { n = 2, recs[i], vim.deepcopy(recs[i]) }) end
        end
    end
    return made
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
    local synthesized = synthesize(A, D, samples, tonumber(p.cap or 12))
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
            if not (okd and d) then return false end
            -- (and what the call did to its ARGUMENTS — diff_regions answers into `out`; CART-1538)
            if w.after and g.after then
                local from = math.max(w.from or 1, g.from or 1)
                local okw, dw = pcall(vim.deep_equal, nofn({ unpack(w.after, from, w.after.n) }), nofn({ unpack(g.after, from, g.after.n) }))
                return okw and dw
            end
            return true
        end
        return (not w[1]) and (not g[1])
    end
    local jit_was = jit and jit.status and jit.status()
    if jit then jit.off() end
    local okall, eall = pcall(function ()
        for _, op in ipairs(ops) do
            local key = 'derive.lua::D.' .. op
            local row = { op = op, samples = #(samples[op] or {}), synthesized = synthesized[op] }
            local okp, text, _, lines, knowns, mreport, prims = pcall(MA.program, key, nil, { snapshot = true, through = through or nil, opaque = opaque })
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
                local oks, res, st = pcall(MX.specialize, prog, entry, div, statics, { budget = 5e6, globals = G, prims = prims, reuse = p.reuse,
                    single_prims = mreport and mreport.single_prims })
                if not oks then return nil, 'specialize: ' .. MX.describe(res) end
                local out = MX.print(res, prog.where)
                row.text = out
                row.bytes, row.functions = (row.bytes or 0) + #out, (row.functions or 0) + #res.order
                row.dead_dropped = (row.dead_dropped or 0) + (st.dead_dropped or 0)
                local K = {}
                for k, v in pairs(G) do K[k] = v end
                for k in pairs(opaque or {}) do K[k] = A[k:sub(3)] end
                local okf, f = pcall(function () return assert(load(out, 'residual:' .. op, 't', F.env(res.pool, K, nil, prims)))() end)
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
                row.hit = {}
                local function guarded(f, a, rest, cov)
                    if cov then
                        local src = 'residual:' .. op
                        debug.sethook(function (ev, line)
                            if ev == 'count' then error('GUARD: instruction budget', 0) end
                            if debug.getinfo(2, 'S').source == src then row.hit[line] = true end
                        end, 'l', 5e7)
                    else debug.sethook(function () error('GUARD: instruction budget', 0) end, '', 5e7) end
                    local c = vim.deepcopy(a)
                    local r = { pcall(f, unpack(c, rest and 2 or 1, c.n)) }
                    debug.sethook()
                    r.after, r.from = c, rest and 2 or 1 -- (the arguments AFTER the call: an operator's side effect is a result too)
                    return r
                end
                local agree, w1 = 0, nil
                for i, cs in ipairs(cases) do
                    local w, g = guarded(D[op], cs.a), guarded(cs.f, cs.a, cs.rest, true)
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
                -- ── THE DERIVED CLIENT (fuzz = N, CART-1538): the operator's own case split -> fnpeer's peergen model ->
                -- a generated client, driven over two transports (the derivation interpreted, its residual) with N seeded
                -- inputs: each hole the sampled subterm (keep) or a minimal term of a kind the code compares against ──
                row.hit_base = {}
                for l in pairs(row.hit) do row.hit_base[l] = true end
                local nfuzz = tonumber(p.fuzz or 0)
                if nfuzz > 0 and cases[1] and cases[1].f and not cases[1].rest then
                    local FP, PG = require 'cartograph.fnpeer', require 'cartograph.peergen'
                    local vocab, seen = {}, {}
                    local function walk(x) -- (the KINDS the code compares against, `x.k == 'lit'`, off its lowered IR)
                        if type(x) ~= 'table' or seen[x] then return end
                        seen[x] = true
                        if x.op == 'bin' and (x.o == '==' or x.o == '~=') then
                            for _, pr in ipairs({ { x.l, x.r }, { x.r, x.l } }) do
                                local fe, lit = pr[1], pr[2]
                                if type(fe) == 'table' and fe.op == 'index' and fe.key and fe.key.op == 'str' and fe.key.v == 'k' and lit and lit.op == 'str' then vocab[lit.v] = true end
                            end
                        end
                        for _, c in pairs(x) do walk(c) end
                    end
                    for _, fn in pairs(prog.funcs) do walk(fn.body) end
                    local Lt, Ht, Nt = A.lit, A.hole, A.node
                    local CANDS = { Lt(1), Lt('a'), Lt(true), Ht('x'), Ht('xs', true), A.ctx('C', { Ht('y') }), Nt('f'), Nt('f', Lt(1)),
                        A.seq({}), A.seq({ Lt(2) }), A.name('n'), A.absent(), A.present(), A.cursor(), { k = 'noval' },
                        A.keyed('obj', { Nt('pair', Lt('a'), Lt(1)) }), { k = 'embed', g = 'lua', kids = { Nt('x') } } }
                    local model, meta = FP.model(op, samples[op], { vocab = vocab, points = tonumber(p.points or 8) })
                    local tr = {}
                    local client = assert(load(PG.generate(model), 'fnpeer:' .. op))().new({ exchange = function (req, o)
                        local okd, a = pcall(FP.decode_args, A, meta[o.name], req)
                        if not okd then tr.last = { false, 'decode: ' .. tostring(a) } else tr.last = guarded(tr.fn, a, false, tr.cov) end
                        return { k = 'reply' }
                    end })
                    -- (a message compares modulo its POSITION and a residual local's fresh name: CART-1539)
                    local function norm(m)
                        m = tostring(m)
                        for _ = 1, 4 do m = m:gsub('^%[string "[^"]*"%]:%d+: ', ''):gsub('^[^%s:]*:%d+: ', '') end
                        return (m:gsub("(local '[%w_]-)_%d+'", "%1'"))
                    end
                    local live = {}
                    for _, o in ipairs(model.operations) do if #o.params > 0 then live[#live + 1] = o end end
                    math.randomseed(tonumber(p.seed or 1538) + #rows)
                    local keep = tonumber(p.keep or 0.4)
                    local fz = { inputs = 0, ok_same = 0, ok_differ = 0, err_same = 0, err_diffmsg = 0, mixed = 0, budget = 0, decode = 0 }
                    for k = 1, (#live > 0 and nfuzz or 0) do
                        local o = live[(k - 1) % #live + 1]
                        local args = {}
                        for _, h in ipairs(o.params) do
                            if math.random() < keep then args[h] = meta[o.name].orig[h] else args[h] = FP.encode(CANDS[math.random(#CANDS)]) end
                        end
                        tr.fn, tr.cov = D[op], false
                        client[o.name](args); local w = tr.last
                        tr.fn, tr.cov = cases[1].f, true
                        client[o.name](args); local g = tr.last
                        fz.inputs = fz.inputs + 1
                        local cls
                        local function has(r, pat) return (not r[1]) and tostring(r[2]):find(pat) ~= nil end
                        if has(w, '^decode: ') or has(g, '^decode: ') then cls = 'decode' -- (the adapter failed: no verdict)
                        elseif has(w, 'GUARD') or has(g, 'GUARD') then cls = 'budget'
                        elseif w[1] and g[1] then cls = same_result(w, g) and 'ok_same' or 'ok_differ'
                        elseif (not w[1]) and (not g[1]) then cls = norm(w[2]) == norm(g[2]) and 'err_same' or 'err_diffmsg'
                        else cls = 'mixed' end
                        fz[cls] = fz[cls] + 1
                        if (cls == 'ok_differ' or cls == 'mixed' or cls == 'err_diffmsg') and not fz.first then
                            fz.first = ('%s %s: want %s / got %s'):format(cls, o.name, vim.inspect(nofn(w), { depth = 2 }):sub(1, 100),
                                vim.inspect(nofn(g), { depth = 2 }):sub(1, 100)):gsub('%s+', ' ')
                        end
                    end
                    row.fuzz = fz
                    if fz.ok_differ + fz.mixed + fz.err_diffmsg > 0 then row.class = 'differ'; row.first = row.first or ('fuzz ' .. fz.first) end
                end
            end
            -- COVERAGE of the residual by the tapped samples: statement lines and branch ARMS (if / elseif / else bodies,
            -- loop bodies — an arm is covered when its first statement ran)
            if row.text and row.class ~= 'refused' then
                local tsutil = require 'cartograph.spec.tsutil' -- (indexed child iteration, CART-1453)
                local root = vim.treesitter.get_string_parser(row.text, 'lua'):parse()[1]:root()
                local STMT = { variable_declaration = true, assignment_statement = true, function_call = true, return_statement = true,
                    if_statement = true, for_statement = true, while_statement = true, repeat_statement = true, do_statement = true, break_statement = true }
                local lines, arms = {}, {}
                local function first_stmt(block)
                    for _, c in tsutil.inext, block, -1 do if c:named() and STMT[c:type()] then return c:start() + 1 end end
                end
                local function walk(n, parent_is_stmt)
                    local ty = n:type()
                    if STMT[ty] and not (ty == 'function_call' and parent_is_stmt) then lines[n:start() + 1] = true end
                    if ty == 'block' then
                        local par = n:parent() and n:parent():type()
                        if par == 'if_statement' or par == 'elseif_statement' or par == 'else_statement' or par == 'for_statement'
                            or par == 'while_statement' or par == 'repeat_statement' then
                            local l = first_stmt(n); if l then arms[#arms + 1] = l end
                        end
                    end
                    for _, c in tsutil.inext, n, -1 do if c:named() then walk(c, STMT[ty] or false) end end
                end
                walk(root, false)
                local nl, hl, na, ha = 0, 0, #arms, 0
                for l in pairs(lines) do nl = nl + 1; if row.hit[l] then hl = hl + 1 end end
                for _, l in ipairs(arms) do if row.hit[l] then ha = ha + 1 end end
                local hb = 0
                for _, l in ipairs(arms) do if (row.hit_base or row.hit)[l] then hb = hb + 1 end end
                row.cov = { lines = nl, lines_hit = hl, arms = na, arms_hit = ha, arms_samples = hb }
            end
            row.text, row.hit, row.hit_base = nil, nil, nil
            tally[row.class] = tally[row.class] + 1
            rows[#rows + 1] = row
        end
    end)
    debug.sethook()
    if jit and jit_was then jit.on() end
    if not okall then return { error = tostring(eall), rows = rows } end
    local bytes, fns = 0, 0
    for _, r in ipairs(rows) do bytes, fns = bytes + (r.bytes or 0), fns + (r.functions or 0) end
    return { rows = rows, tally = tally, bytes = bytes, functions = fns, through = through, reuse = p.reuse or 'lazy', control = control, synthesized = synthesized }
end

local E = {
    name = 'derive-accept',
    kind = 'discovery',
    tags = { 'accept', 'algebra' },
    measures = 'CART-1483',
    summary = 'does every algebra derivation, COMPILED by mix (all-dynamic), agree with itself interpreted on the arguments a real suite passes? ops = a,b (default all), through = 1 (follow the basis), opaque = M.x,… (through: kept primitives), reuse = eager, cap = samples per op (12), suite = the spec to tap (default the vendored donor suite), plant = op (a planted difference: the negative control); rows carry residual bytes / functions',
    params = { ops = 'string?', through = 'string?', opaque = 'string?', reuse = 'string?', cap = 'string?', suite = 'string?', plant = 'string?', static = 'string?', groups = 'string?',
        fuzz = 'string?', points = 'string?', keep = 'string?', seed = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local t = v.tally
        local cl, ch, ca, cha, cas, fi = 0, 0, 0, 0, 0, 0
        for _, r in ipairs(v.rows) do
            if r.cov then cl, ch, ca, cha, cas = cl + r.cov.lines, ch + r.cov.lines_hit, ca + r.cov.arms, cha + r.cov.arms_hit, cas + (r.cov.arms_samples or r.cov.arms_hit) end
            if r.fuzz then fi = fi + r.fuzz.inputs end
        end
        local head = ('%d agree, %d differ, %d no sample, %d refused (%s, %s; %d bytes in %d functions; the samples ran %.1f%% of residual lines, %.1f%% of branch arms)'):format(t.agree, t.differ,
            t.nosample, t.refused, v.through and 'through' or 'plain', v.reuse, v.bytes, v.functions, 100 * ch / math.max(1, cl), 100 * cha / math.max(1, ca))
            .. (fi > 0 and ('; the derived client sent %d inputs, arms %.1f%% from the samples alone'):format(fi, 100 * cas / math.max(1, ca)) or '')
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
            -- (and its COVERAGE: the samples ran some of the residual's lines, never more than it has — CART-1538)
            return r.class == 'agree' and r.samples >= 2 and r.agree == r.samples and r.bytes > 0 and r.functions > 0
                and r.cov ~= nil and r.cov.lines_hit > 0 and r.cov.lines_hit <= r.cov.lines and r.cov.arms_hit <= r.cov.arms, vim.inspect(r)
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
        name = 'the DERIVED CLIENT (fuzz = N): the operator\'s case split drives both implementations with N more inputs, and they agree',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'sites', fuzz = '12' }),
        expect = { holds = true, check = function (v)
            local r = v.rows[1]
            return r.class == 'agree' and r.fuzz ~= nil and r.fuzz.inputs == 12 and r.fuzz.ok_differ == 0 and r.fuzz.mixed == 0
                and r.fuzz.decode == 0 and r.cov.arms_samples <= r.cov.arms_hit, vim.inspect(r)
        end },
    },
    {
        name = 'a PLANTED difference is found by the derived client\'s inputs too',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'sites', fuzz = '12', plant = 'sites' }),
        expect = { holds = false, check = function (v)
            local r = v.rows[1]
            return r.class == 'differ' and r.fuzz.ok_differ == r.fuzz.inputs and r.fuzz.inputs > 0, vim.inspect(r)
        end },
    },
    {
        name = 'an operator the suite never calls and no other sample can feed has NO SAMPLE — and a run that compared nothing does not hold',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'kv_eq' }),
        expect = { holds = false, check = function (v) return v.rows[1].class == 'nosample' and v.tally.agree == 0, vim.inspect(v.rows[1]) end },
    },
    {
        name = 'an operator the suite never calls is SYNTHESIZED from other samples (unit: a sampled template and one of its holes)',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'unit' }),
        expect = { holds = true, check = function (v) local r = v.rows[1]; return r.class == 'agree' and (r.synthesized or 0) > 0 and r.agree == r.samples, vim.inspect(r) end },
    },
    {
        name = 'an operator with NO derivation is refused by name before anything runs',
        files = { ['mini_spec.lua'] = MINI }, params = mini({ ops = 'no_such_op' }),
        expect = { holds = false, check = function (v) return (v.error or ''):find('no derivation for `no_such_op`', 1, true) ~= nil, tostring(v.error) end },
    },
}

return E