-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
return function (M, SHARED)
local lcs_alignments, slice, vsym =
    SHARED.lcs_alignments, SHARED.slice, SHARED.vsym

-- ── TERM-GRAPH ANTI-UNIFICATION (Baumgartner, Kutsia, Levy, Villaret, FSCD 2018) ──────
-- Read in full (LIPIcs 108, article 9). A term-graph is a system of recursion equations
-- in canonical form (Def. 4): every equation is  x .= f(χ1..χn)  with the χ recursion
-- variables (term- or hedge-sorted),  x .= y  with y a FREE term variable, or  X .= Y
-- with Y a FREE hedge variable. Cycles are allowed vertically, never horizontally.
-- Equality is BISIMILARITY (Def. 6/7), so sharing is a choice of representative, not
-- information: a graph, its unwinding and its full collapse are one object.
--
-- Representation here:  G = { root = 'x0', eqs = { x0 = {kind='node', sym='f', args={...}},
--                                                  x2 = {kind='tvar', var='y'},
--                                                  X1 = {kind='hvar', var='Y'} } }
-- A recursion variable is hedge-sorted iff its equation is an 'hvar'. Names are opaque.
local function tg_sorted_names(eqs)
    local names = {}
    for n in pairs(eqs) do names[#names + 1] = n end
    table.sort(names)
    return names
end

--- build a term-graph from shorthand: eqs[x] = {'f', 'x1', 'X1'} | {var='y'} | {hvar='Y'}
function M.tg(root, short)
    local eqs = {}
    for n, e in pairs(short) do
        if e.var then eqs[n] = { kind = 'tvar', var = e.var }
        elseif e.hvar then eqs[n] = { kind = 'hvar', var = e.hvar }
        else
            local args = {}
            for i = 2, #e do args[#args + 1] = e[i] end
            eqs[n] = { kind = 'node', sym = e[1], args = args }
        end
    end
    return M.tg_canon({ root = root, eqs = eqs })
end

--- drop equations unreachable from the root (the only canonicalization step the
--- constructors here can violate; instantiate handles the hedge-splicing steps itself)
function M.tg_canon(G)
    local keep, stack = {}, { G.root }
    while #stack > 0 do
        local n = table.remove(stack)
        if not keep[n] then
            local e = G.eqs[n]
            assert(e, 'term-graph: no equation for ' .. tostring(n))
            keep[n] = e
            if e.kind == 'node' then for _, a in ipairs(e.args) do stack[#stack + 1] = a end end
        end
    end
    return { root = G.root, eqs = keep }
end

--- THE COLLAPSE (CART-1344): the graph quotiented by its own MAXIMAL BISIMULATION — the canonical form under the
--- equality this file uses (Def. 6/7: a graph, its unwinding and its full collapse are one object). Not a primitive:
--- derived from the definition of bisimulation by PARTITION REFINEMENT — start from the labels (a node's symbol and
--- arity, a variable's name and sort), split a block while its members' arguments fall in different blocks, stop when
--- nothing splits; then every node is redirected to its block's representative. Gen's Merge pairs NODES by identity
--- (the paper's rule), so it gives the least general generalization only on COLLAPSED inputs — measured: f(l1,l1,l2)
--- with l1 as two nodes generalized to f(u1,u2,u3) against f(m1,m1,m2), and f(g(a),g(a)) unshared to f(g(u1),g(u2))
--- against a shared f(g(b)); collapsed first, both keep their sharing.
--- ⚠ A first-order graph has no binders: a label IS one entity. A producer that encodes SCOPED names must rename them
--- apart before labelling (one label per binder instance), or this merges two entities — the encoder's contract.
function M.tg_collapse(G)
    local names = tg_sorted_names(G.eqs)
    local function label(e)
        if e.kind == 'node' then return 'N' .. e.sym .. '/' .. #e.args end
        return (e.kind == 'hvar' and 'H' or 'T') .. e.var
    end
    -- block[n]: the block id of node n; refined until the count stops growing (at most one split round per node)
    local block, count = {}, 0
    local function renumber(keys)
        local ids, nb = {}, 0
        for _, n in ipairs(names) do
            local k = keys[n]
            if not ids[k] then nb = nb + 1; ids[k] = nb end
            block[n] = ids[k]
        end
        return nb
    end
    local keys = {}
    for _, n in ipairs(names) do keys[n] = label(G.eqs[n]) end
    count = renumber(keys)
    local stable = false
    for _ = 1, #names + 1 do -- (no while / break: mix reads this module)
        if not stable then
            local nk = {}
            for _, n in ipairs(names) do
                local e, parts = G.eqs[n], { tostring(block[n]) }
                if e.kind == 'node' then for i, a in ipairs(e.args) do parts[i + 1] = tostring(block[a]) end end
                nk[n] = table.concat(parts, ',')
            end
            local nc = renumber(nk)
            stable = nc == count
            count = nc
        end
    end
    local rep = {}
    for _, n in ipairs(names) do rep[block[n]] = rep[block[n]] or n end -- (the first name in order represents its block)
    local eqs = {}
    for _, n in ipairs(names) do
        if rep[block[n]] == n then
            local e = G.eqs[n]
            if e.kind == 'node' then
                local args = {}
                for i, a in ipairs(e.args) do args[i] = rep[block[a]] end
                eqs[n] = { kind = 'node', sym = e.sym, args = args }
            else eqs[n] = e end
        end
    end
    return M.tg_canon({ root = rep[block[G.root]], eqs = eqs })
end
function M.tg_nodes(G)
    local n = 0
    for _ in pairs(G.eqs) do n = n + 1 end
    return n
end

--- canonical rendering: DFS from the root, term recursion variables z0.., hedge ones Z1..,
--- free variables u1../U1.. by first occurrence. Two graphs equal modulo renaming of
--- bound AND free variables print the same.
function M.tg_show(G)
    local name, order, nt, nh, nf, nF = {}, {}, -1, 0, 0, 0
    local free = {}
    local function visit(n)
        if name[n] then return end
        local e = G.eqs[n]
        if e.kind == 'hvar' then nh = nh + 1; name[n] = 'Z' .. nh else nt = nt + 1; name[n] = 'z' .. nt end
        order[#order + 1] = n
        if e.kind == 'node' then for _, a in ipairs(e.args) do visit(a) end end
    end
    visit(G.root)
    local out = {}
    for _, n in ipairs(order) do
        local e = G.eqs[n]
        if e.kind == 'node' then
            local as = {}
            for i, a in ipairs(e.args) do as[i] = name[a] end
            out[#out + 1] = name[n] .. '=' .. e.sym .. (#as > 0 and ('(' .. table.concat(as, ',') .. ')') or '')
        else
            if not free[e.var] then
                if e.kind == 'hvar' then nF = nF + 1; free[e.var] = 'U' .. nF else nf = nf + 1; free[e.var] = 'u' .. nf end
            end
            out[#out + 1] = name[n] .. '=' .. free[e.var]
        end
    end
    return table.concat(out, ' ')
end

--- encode a finite term as a term-graph. share=true gives the fully collapsed graph
--- (equal subterms become one node); otherwise one node per position. Holes become free
--- variables: a term hole a free term variable, a rep hole a free hedge variable.
function M.tg_of_term(t, opts)
    opts = opts or {}
    local eqs, memo, n, ids = {}, {}, 0, {}
    local function fresh(hedge) n = n + 1; return (hedge and 'H' or 'n') .. n end
    local function enc(u)
        -- (sharing is the TERM relation: equal subterms by eq, keyed on its hash — CART-1401; show() was the key: O(n^2),
        -- and blind to a presence mark on a literal / a keyed node)
        local k = opts.share and M.content_id(u, ids) or nil
        if k and memo[k] then return memo[k] end
        local id
        if u.k == 'hole' then
            id = fresh(u.rep)
            eqs[id] = { kind = u.rep and 'hvar' or 'tvar', var = u.h }
        else
            id = fresh(false)
            local args = {}
            for _, c in ipairs(u.kids or {}) do args[#args + 1] = enc(c) end
            eqs[id] = { kind = 'node', sym = vsym(u), args = args }
        end
        if k then memo[k] = id end
        return id
    end
    local root = enc(t)
    return { root = root, eqs = eqs }
end

--- Bisimilarity (Def. 6): the closure of the root pair under matched successors is
--- consistent. Free variables are labels of arity zero; with rename=true they only have to
--- correspond by a bijection, sorts agreeing. Returns ok, relation.
function M.tg_bisimilar(G1, G2, opts)
    opts = opts or {}
    local R, work, f12, f21 = {}, { { G1.root, G2.root } }, {}, {}
    while #work > 0 do
        local pr = table.remove(work)
        local a, b = pr[1], pr[2]
        local key = a .. '\1' .. b
        if not R[key] then
            R[key] = pr
            local e1, e2 = G1.eqs[a], G2.eqs[b]
            if e1.kind ~= e2.kind then return false, 'sort' end
            if e1.kind == 'node' then
                if e1.sym ~= e2.sym or #e1.args ~= #e2.args then return false, 'label' end
                for i = 1, #e1.args do work[#work + 1] = { e1.args[i], e2.args[i] } end
            elseif opts.rename then
                if (f12[e1.var] and f12[e1.var] ~= e2.var) or (f21[e2.var] and f21[e2.var] ~= e1.var) then return false, 'variable' end
                f12[e1.var], f21[e2.var] = e2.var, e1.var
            elseif e1.var ~= e2.var then return false, 'variable'
            end
        end
    end
    return true, R
end

--- Substitution application (Sect. 4, Ex. 9): sigma maps a free variable to a list of
--- items; an item is the name of a node in one of `sources` (a term) or, when it is not,
--- a free variable name (hedge-sorted in a hedge slot). The instance is the union of G's
--- equations with the sources', hedges spliced into argument lists, then canonicalized.
--- No subgraph is copied: sharing and cycles in the sources are kept as they are.
function M.tg_instantiate(G, sigma, sources)
    sources = sources or {}
    local eqs = {}
    local function src_of(name)
        for _, S in ipairs(sources) do if S.eqs[name] then return S end end
    end
    -- rename G's bound variables so they cannot collide with the sources'
    local ren = {}
    for n in pairs(G.eqs) do ren[n] = 'g:' .. n end
    local function expand(arg)
        local e = G.eqs[arg]
        local items = sigma[e.var]
        if e.kind == 'node' or not items then return { ren[arg] } end
        if e.kind == 'tvar' then
            assert(#items == 1 and src_of(items[1]), 'a term variable takes exactly one term')
            return { items[1] }
        end
        local out = {}
        for _, it in ipairs(items) do
            if src_of(it) then out[#out + 1] = it
            else
                local hv = 'h:' .. it
                eqs[hv] = { kind = 'hvar', var = it }
                out[#out + 1] = hv
            end
        end
        return out
    end
    for n, e in pairs(G.eqs) do
        if e.kind == 'node' then
            local args = {}
            for _, a in ipairs(e.args) do for _, x in ipairs(expand(a)) do args[#args + 1] = x end end
            eqs[ren[n]] = { kind = 'node', sym = e.sym, args = args }
        elseif not sigma[e.var] then
            eqs[ren[n]] = { kind = e.kind, var = e.var }
        end
    end
    for _, S in ipairs(sources) do for n, e in pairs(S.eqs) do eqs[n] = e end end
    local root = G.eqs[G.root].kind ~= 'node' and sigma[G.eqs[G.root].var] and sigma[G.eqs[G.root].var][1] or ren[G.root]
    return M.tg_canon({ root = root, eqs = eqs })
end

--- Gen(R) (Sect. 5) in recursive form, rigidity = longest common subsequence over the
--- top-symbol strings. Step registers the node pair in the TRAIL before descending, so a
--- pair met again (through sharing or a back edge) is answered by Share with the node
--- already issued: that is what makes the output a dag or a cycle. Dec-S puts the gap
--- slices into the STORE as hedge variables and recurses only on aligned pairs; Solve
--- makes a variable of differing heads; Merge unifies store entries with identical node
--- sequences. Theorem 17's bound (node pairs) is enforced as a step budget.
--- opts.choices: a list of alignment indices consumed at each Dec-S branch point (for
--- enumeration); opts.positional replaces LCS by positional pairing (a mutation hook).
--- Returns { G, store = {var -> {A=, B=, hedge=}}, trail, steps, branches, sigmaL, sigmaR }.
function M.tg_generalize(G1, G2, opts)
    opts = opts or {}
    local eqs, trail, store, n = {}, {}, {}, { rv = 0, fv = 0, steps = 0, branch = 0 }
    local branches, choices = {}, opts.choices or {}
    local budget = M.tg_nodes(G1) * M.tg_nodes(G2) + 1
    local function fresh_rv(hedge) n.rv = n.rv + 1; return (hedge and 'Z' or 'z') .. n.rv end
    local function fresh_fv(hedge) n.fv = n.fv + 1; return (hedge and 'U' or 'u') .. n.fv end
    local function top(G, rv)
        local e = G.eqs[rv]
        return e.kind == 'node' and e.sym or ('$' .. e.var)
    end
    local function solve(A, B, hedge)
        local v, rv = fresh_fv(hedge), fresh_rv(hedge)
        store[v] = { A = A, B = B, hedge = hedge, rv = rv }
        eqs[rv] = { kind = hedge and 'hvar' or 'tvar', var = v }
        return rv
    end
    local gen
    gen = function(y, z)
        local key = y .. '\1' .. z
        if trail[key] then return trail[key] end -- Share
        local e1, e2 = G1.eqs[y], G2.eqs[z]
        if not (e1.kind == 'node' and e2.kind == 'node' and e1.sym == e2.sym) then
            return solve({ y }, { z }, false) -- Solve
        end
        n.steps = n.steps + 1 -- Step
        if n.steps > budget then error('term-graph generalization exceeded its step budget') end
        local u = fresh_rv(false)
        trail[key] = u
        local A, B = {}, {}
        for i, a in ipairs(e1.args) do A[i] = top(G1, a) end
        for j, b in ipairs(e2.args) do B[j] = top(G2, b) end
        local aligns
        if opts.positional then
            local al = {}
            for i = 1, math.min(#A, #B) do if A[i] == B[i] then al[#al + 1] = { i, i } end end
            aligns = { al }
        else
            aligns = lcs_alignments(A, B, opts.cap or 64)
        end
        local al
        if #aligns > 1 then
            n.branch = n.branch + 1
            local c = choices[n.branch] or 1
            branches[n.branch] = #aligns
            al = aligns[c]
        else
            al = aligns[1]
        end
        local args = {}
        local function gap(ga, gb)
            -- KLV's TERM-VARIABLE REFINEMENT (as in M.rigid): an equal-length gap becomes a
            -- sequence of term variables, one per position, instead of one hedge variable.
            -- The printed rules of this paper make every gap a hedge variable, but the
            -- paper's own Example 16 shows the refined answer (z1 .= z, a term variable),
            -- so the refinement is the default; opts.literal follows the printed rules.
            local pointwise = #ga == #gb and not opts.literal
            if pointwise then
                for e = 1, #ga do
                    if G1.eqs[ga[e]].kind == 'hvar' or G2.eqs[gb[e]].kind == 'hvar' then pointwise = false end
                end
            end
            if pointwise then
                for e = 1, #ga do args[#args + 1] = solve({ ga[e] }, { gb[e] }, false) end
            else
                args[#args + 1] = solve(ga, gb, true)
            end
        end
        if #al == 0 then -- Solve on the whole argument hedges (Step's A0, then R = {ε})
            if #e1.args > 0 or #e2.args > 0 then gap(slice(e1.args, 1, #e1.args), slice(e2.args, 1, #e2.args)) end
        else -- Dec-S
            local pi, pj = 0, 0
            for k = 1, #al + 1 do
                local i, j = al[k] and al[k][1] or #e1.args + 1, al[k] and al[k][2] or #e2.args + 1
                if i - pi > 1 or j - pj > 1 then
                    gap(slice(e1.args, pi + 1, i - 1), slice(e2.args, pj + 1, j - 1))
                end
                if al[k] then
                    local a, b = e1.args[i], e2.args[j]
                    if G1.eqs[a].kind == 'node' and G2.eqs[b].kind == 'node' then args[#args + 1] = gen(a, b)
                    else args[#args + 1] = solve({ a }, { b }, G1.eqs[a].kind == 'hvar') end
                end
                pi, pj = i, j
            end
        end
        eqs[u] = { kind = 'node', sym = e1.sym, args = args }
        return u
    end
    local root = gen(G1.root, G2.root)
    -- Merge: store entries with identical node sequences (same sort) become one variable
    if not opts.no_merge then
        local seen, redirect = {}, {}
        for _, v in ipairs(tg_sorted_names(store)) do
            local s = store[v]
            local k = (s.hedge and 'H' or 'T') .. table.concat(s.A, ',') .. '|' .. table.concat(s.B, ',')
            if seen[k] then redirect[s.rv] = seen[k].rv; store[v] = nil; eqs[s.rv] = nil
            else seen[k] = s end
        end
        for _, e in pairs(eqs) do
            if e.kind == 'node' then for i, a in ipairs(e.args) do e.args[i] = redirect[a] or a end end
        end
        root = redirect[root] or root
    end
    local sigmaL, sigmaR = {}, {}
    for v, s in pairs(store) do sigmaL[v], sigmaR[v] = s.A, s.B end
    return { G = M.tg_canon({ root = root, eqs = eqs }), store = store, trail = trail,
        steps = n.steps, branches = branches, sigmaL = sigmaL, sigmaR = sigmaR }
end

--- every R-generalization Gen(R) can reach, by replaying with each choice vector
function M.tg_generalize_all(G1, G2, opts)
    opts = opts or {}
    local out, choices, cap = {}, {}, opts.cap or 32
    while true do
        local r = M.tg_generalize(G1, G2, { choices = choices, positional = opts.positional, no_merge = opts.no_merge, literal = opts.literal })
        out[#out + 1] = r
        if #out >= cap then break end
        -- odometer over the branch points seen in this run
        local k = #r.branches
        while k > 0 do
            choices[k] = (choices[k] or 1) + 1
            if choices[k] <= r.branches[k] then break end
            choices[k] = nil
            k = k - 1
        end
        if k == 0 then break end
        for i = k + 1, #choices do choices[i] = nil end
    end
    return out
end

-- ── CONTENT IDS AS A VIEW (CART-1390, one representation): a term's MERKLE id — the hash of its own label and its
-- kids' ids — computed over the tree as it is stored (no hash-consing at creation; sharing is a view). Two peers agree
-- on an id with no coordination, so a subterm crosses a wire once (CART-1366) and any cache keys on it.
-- ★ THE ORACLE IS `M.eq`: eq(a, b) <=> content_id(a) == content_id(b). So the label carries exactly what eq compares —
-- the kind, a literal's value WITH ITS TYPE ("1" is not 1), a name, a hole's name / rep / ctx, the alignment discipline,
-- the merge key, the presence mark — and a KEYED node's kids enter by KEY order (eq reads them as a set by key), a
-- keyed-ordered or positional node's in their own order. Spans (`at`) and every other field eq ignores stay out.
-- ⚠ NOT tg_of_term's show()-keyed sharing (quadratic). The label is core's M.node_label — ONE label for content ids,
-- the wire's records, term graphs and the edit-distance match (CART-1396); numbers in M.content_num's canonical text.
local num, label = M.content_num, M.node_label
--- the content id of term t (hex sha256). memo: a table shared across calls (keyed by node object) — optional
--- `ordered` = true: the ORDERED relation's hash (a keyed node's kids in written order); its memo must be its own
function M.content_id(t, memo, ordered)
    memo = memo or {}
    local function id(u)
        if memo[u] then return memo[u] end
        local kids = {}
        if u.align == 'keyed' and not ordered then
            for _, e in ipairs(M.keys(u)) do kids[#kids + 1] = id(e.kid) end
        else
            for i, c in ipairs(u.kids or {}) do kids[i] = id(c) end
        end
        local h = vim.fn.sha256(label(u) .. '(' .. table.concat(kids, ',') .. ')')
        memo[u] = h
        return h
    end
    return id(t)
end
--- the MERKLE DAG of t: each DISTINCT subterm once, by id -> { root = id, nodes = { [id] = { label, kids = { id … } } },
--- count = distinct subterms }. The wire form (CART-1366): a peer that holds an id sends nothing under it.
function M.content_dag(t)
    local memo, nodes, count = {}, {}, 0
    local root = M.content_id(t, memo)
    local function walk(u)
        local h = memo[u]
        if nodes[h] then return end
        local kids = {}
        if u.align == 'keyed' then
            for _, e in ipairs(M.keys(u)) do kids[#kids + 1] = memo[e.kid] end
        else
            for i, c in ipairs(u.kids or {}) do kids[i] = memo[c] end
        end
        nodes[h] = { label = label(u), kids = kids }
        count = count + 1
        for _, c in ipairs(u.kids or {}) do walk(c) end
    end
    walk(t)
    return { root = root, nodes = nodes, count = count }
end

-- ── THE TERM WIRE (CART-1366, step 2): a term as a Merkle DAG of NODE RECORDS plus a SIDE MAP. A shared node holds only
-- what eq compares (its id is its content); every other field — a span (`at`), a template's statistics, a grammar tag —
-- is PER-OCCURRENCE and rides in `side`, keyed by the occurrence's path ('' for the root, '2/1' for kid 1 of kid 2),
-- so two occurrences of one subterm can differ there without un-sharing it. The round trip is the oracle:
-- wire_decode(wire_encode(t)) is deep-equal to t (through JSON text too). A field that is no JSON value is REFUSED by
-- name, never dropped.
-- the fields a node RECORD holds — exactly what the id hashes (label above), PER KIND, as eq reads them: a literal is its
-- value alone (eq ignores a presence mark on it), a name its name, a hole its name / rep / ctx plus the node fields, any
-- other node its alignment, merge key and presence mark. Everything else is per-occurrence and rides in `side`.
local RECORD = { lit = { 'v', 'opt' }, name = { 'n', 'opt' }, hole = { 'h', 'rep', 'ctx', 'align', 'key', 'opt', 'g' } }
local NODE_RECORD = { 'align', 'key', 'opt', 'g' }
local function record_fields(u) return RECORD[u.k] or NODE_RECORD end
local function jsonable(x, depth)
    depth = depth or 0
    if depth > 32 then return false end
    local ty = type(x)
    if ty == 'string' or ty == 'boolean' or x == nil then return true end
    if ty == 'number' then return x == x and x ~= math.huge and x ~= -math.huge end
    if ty ~= 'table' or getmetatable(x) ~= nil then return false end
    for k, v in pairs(x) do
        if type(k) ~= 'string' and type(k) ~= 'number' then return false end
        if not jsonable(v, depth + 1) then return false end
    end
    return true
end
--- t -> { v = 1, root, nodes = { [id] = { k, v, vt, n, h, rep, ctx, align, key, opt, kids = { id … } } },
--- side = { [path] = { field = value } } } | nil, why
function M.wire_encode(t)
    local memo, nodes, side = {}, {}, {}
    local okid, root = pcall(M.content_id, t, memo)
    if not okid then return nil, tostring(root) end
    local why
    local function walk(u, path)
        if why then return end
        local h = memo[u]
        local own = {}
        for _, f in ipairs(record_fields(u)) do own[f] = true end
        if not nodes[h] then
            local rec = { k = u.k }
            for f in pairs(own) do rec[f] = u[f] end
            if u.k == 'lit' then
                rec.vt = type(u.v)
                if rec.vt == 'number' then rec.v = num(u.v) end -- (the canonical text: JSON never rounds it)
            end
            if rec.key ~= nil and not jsonable(rec.key) then why = 'a merge key that is no JSON value at ' .. path; return end
            if u.kids then -- (a node with no kids list keeps none: `name`, `lit`)
                local kids = {}
                if u.align == 'keyed' then -- ★ a KEYED node's record holds its kids in KEY order (its id ignores order)
                    for _, e in ipairs(M.keys(u)) do kids[#kids + 1] = memo[e.kid] end
                else
                    for i, c in ipairs(u.kids) do kids[i] = memo[c] end
                end
                rec.kids = kids
            end
            nodes[h] = rec
        end
        local extra
        -- …and each OCCURRENCE's written order is its own: a permutation of the key order, kept only where it differs
        if u.align == 'keyed' and u.kids then
            local perm, moved = {}, false
            for pos, e in ipairs(M.keys(u)) do perm[e.i] = pos; if e.i ~= pos then moved = true end end
            if moved then extra = { ['@order'] = perm } end
        end
        for f, x in pairs(u) do
            if f ~= 'k' and f ~= 'kids' and not own[f] then
                if not jsonable(x) then why = ('the field `%s` at %s is no JSON value'):format(tostring(f), path == '' and 'the root' or path); return end
                extra = extra or {}; extra[f] = x
            end
        end
        if extra then side[path] = extra end
        for i, c in ipairs(u.kids or {}) do walk(c, path == '' and tostring(i) or (path .. '/' .. i)) end
    end
    walk(t, '')
    if why then return nil, why end
    return { v = 1, root = root, nodes = nodes, side = side }
end
--- the wire -> a fresh TREE (no table shared between occurrences: a decoded term may be edited in place) | nil, why
function M.wire_decode(w)
    if type(w) ~= 'table' or w.v ~= 1 or not w.nodes or not w.root then return nil, 'not a term wire (v = 1)' end
    local why
    local function build(id, path)
        if why then return nil end
        local rec = w.nodes[id]
        if not rec then why = 'no node ' .. tostring(id) .. ' at ' .. path; return nil end
        local u = {}
        for f, x in pairs(rec) do if f ~= 'kids' and f ~= 'vt' then u[f] = x end end
        if rec.k == 'lit' then
            if rec.vt == 'number' then u.v = tonumber(rec.v) elseif rec.vt == 'boolean' then u.v = rec.v == true else u.v = rec.v end
        end
        local here = (w.side or {})[path] or {}
        if rec.kids then
            u.kids = {}
            local perm = here['@order'] -- (written position i holds the record's kid perm[i])
            for i = 1, #rec.kids do u.kids[i] = build(rec.kids[perm and perm[i] or i], path == '' and tostring(i) or (path .. '/' .. i)) end
        end
        for f, x in pairs(here) do if f ~= '@order' then u[f] = x end end
        return u
    end
    local t = build(w.root, '')
    if why then return nil, why end
    return t
end
end
