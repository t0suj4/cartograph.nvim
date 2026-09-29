-- cartograph.grammargen — A GRAMMAR DERIVED FROM A CORPUS, AND EVERY TREE UP TO A SIZE (CART-1206).
--
-- WHY FROM A CORPUS: tree-sitter ships its parse tables, not its grammar — `language.inspect` gives symbols, fields
-- and supertypes, no productions, and no grammar.json is on disk. So the productions are READ OFF real trees: every
-- node of every file, as the lossless reader's term modulo layout (cartograph.algebraread), becomes its SKELETON —
-- the node's kind and its children in order, an anonymous token kept as its text, a named child as a SLOT. The slot
-- admits every kind seen in that position of that skeleton. A named LEAF seen with one text only (`break`, `nil`,
-- `...`) gets that text as a zero-slot production; a leaf with many texts (identifiers, numbers) has no production — a FRAGMENT supplies atoms.
--
-- ⚠ THE POPULATION IS THE CLAIM'S SCOPE: "every tree to size N" means over THESE productions ∩ the fragment's kinds,
-- with its atom pools — never "every Lua program". A shape no corpus file writes is not generated; a slot union can
-- admit a combination no file wrote (the language's own reader and Lua's `load` are the validity oracles downstream).
--
-- SIZE = the number of NAMED nodes (an atom or a constant is 1). Counting comes first (`count`), so a bound is chosen
-- from a budget, not discovered by running out of memory.
local M = {}

--- a term is LAYOUT when it is a whitespace gap or a comment (the lossless reader keeps both as kids)
local function layout(t) return (t.k == 'lit' and type(t.v) == 'string' and t.v:match('^%s*$')) or t.k == 'comment' end
local function named_leaf(t) return t.kids and #t.kids == 1 and t.kids[1].k == 'lit' end

--- derive the grammar from source texts. -> G = { kinds = { [k] = { prods = { {items, slots, seen} }, texts = {..} } },
--- files, refused = { {name, why} } }. `sources` = { {name, text} }
function M.derive(sources, lang)
    local R = require 'cartograph.algebraread'
    local G = { kinds = {}, files = 0, refused = {}, lang = lang }
    local function kind(k)
        G.kinds[k] = G.kinds[k] or { prods = {}, by_sig = {}, texts = {}, ntexts = 0 }
        return G.kinds[k]
    end
    local function walk(t)
        if t.k == 'lit' or not t.kids then return end
        local K = kind(t.k)
        if named_leaf(t) then
            local s = t.kids[1].v
            if not K.texts[s] then K.texts[s] = true; K.ntexts = K.ntexts + 1 end
            return
        end
        local items, slotk, sig = {}, {}, {}
        for _, c in ipairs(t.kids) do
            if not layout(c) then
                if c.k == 'lit' then items[#items + 1] = { tok = c.v }; sig[#sig + 1] = 'T' .. c.v
                else items[#items + 1] = { slot = #slotk + 1 }; slotk[#slotk + 1] = c.k; sig[#sig + 1] = '_' end
            end
        end
        local key = table.concat(sig, '\31')
        local p = K.by_sig[key]
        if not p then
            p = { items = items, slots = {}, seen = 0 }
            for i = 1, #slotk do p.slots[i] = {} end
            K.by_sig[key] = p
            K.prods[#K.prods + 1] = p
        end
        p.seen = p.seen + 1
        for i, k in ipairs(slotk) do p.slots[i][k] = true end
        for _, c in ipairs(t.kids) do if not layout(c) then walk(c) end end
    end
    for _, s in ipairs(sources) do
        local t, why = R.read(s[2], lang)
        if t then G.files = G.files + 1; walk(t) else G.refused[#G.refused + 1] = { s[1], why } end
    end
    -- ★ REPETITION: a slot RUN that repeats admits every kind seen anywhere in it. Positional typing alone was measured
    -- too narrow: a block's i-th slot admitted only what corpus blocks of that exact length held at i, so `goto` (always
    -- the LAST statement — `goto continue`) could never precede a label, and every generated goto failed to load
    for _, K in pairs(G.kinds) do M.widen_runs(K) end
    -- a kind seen with ONE text as a leaf gets that text as a zero-slot production (bare `return` beside
    -- `return <list>`, `break`, `nil`): measured, a constant kept apart from the productions lost bare `return`
    for _, K in pairs(G.kinds) do
        if K.ntexts == 1 then K.prods[#K.prods + 1] = { items = { { tok = (next(K.texts)) } }, slots = {}, seen = 0 } end
        K.by_sig = nil
    end
    return G
end

--- widen a kind's slot sets over its REPEATED runs. A run is a maximal `S (t S)*` whose separator t is '' (slots
--- side by side) or a token that occurs at least twice between slots in SOME production of the kind (evidence it
--- repeats: `,` in a list — `=` or `then`, once per production, never qualify). Productions whose runs collapse to the
--- same signature form a family; a run whose LENGTH varies across the family is a repetition, and each of its slots
--- admits the union of the run's kinds. A run of fixed length (an `if` condition, a `for` variable) stays positional.
--- The productions themselves are unchanged: only lengths the corpus wrote are generated.
function M.widen_runs(K)
    local sep = { [''] = true }
    for _, p in ipairs(K.prods) do
        local between = {}
        for j = 2, #p.items - 1 do
            local it = p.items[j]
            if it.tok and p.items[j - 1].slot and p.items[j + 1].slot then between[it.tok] = (between[it.tok] or 0) + 1 end
        end
        for t, n in pairs(between) do if n >= 2 then sep[t] = true end end
    end
    local fams = {}
    for _, p in ipairs(K.prods) do
        local runs, sig, j = {}, {}, 1
        while j <= #p.items do
            local it = p.items[j]
            if it.tok then sig[#sig + 1] = 'T' .. it.tok; j = j + 1
            else
                local run, t = { it.slot }, nil
                j = j + 1
                while j <= #p.items do
                    local a, b = p.items[j], p.items[j + 1]
                    if a.slot and (t == nil or t == '') then run[#run + 1] = a.slot; t = ''; j = j + 1
                    elseif a.tok and sep[a.tok] and b and b.slot and (t == nil or t == a.tok) then
                        run[#run + 1] = b.slot; t = a.tok; j = j + 2
                    else break end
                end
                runs[#runs + 1] = run
                -- the key omits the separator: a ONE-element run has none, and it is the same list as the long one
                -- (measured: `return x` and `return 1, y, z` formed two families and lent nothing)
                sig[#sig + 1] = 'R'
            end
        end
        local key = table.concat(sig, '\31')
        fams[key] = fams[key] or {}
        table.insert(fams[key], { p = p, runs = runs })
    end
    -- ALTERNATION: productions with the same items but ONE token (`S + S` / `S < S`, `not S` / `- S`) are alternatives
    -- of one shape, so each slot admits what any of them admitted there. Measured: without it, `S % S` only ever took
    -- identifiers (as the corpus wrote it) and 10 operators were unreachable over literal atoms
    local alts = {}
    for _, p in ipairs(K.prods) do
        for j, it in ipairs(p.items) do
            if it.tok then
                local sig = {}
                for jj, x in ipairs(p.items) do sig[jj] = jj == j and '?' or (x.tok and ('T' .. x.tok) or '_') end
                local key = table.concat(sig, '\31')
                alts[key] = alts[key] or {}
                table.insert(alts[key], p)
            end
        end
    end
    for _, group in pairs(alts) do
        if #group > 1 then
            for i = 1, #group[1].slots do
                local union = {}
                for _, p in ipairs(group) do for k in pairs(p.slots[i]) do union[k] = true end end
                for _, p in ipairs(group) do for k in pairs(union) do p.slots[i][k] = true end end
            end
        end
    end
    for _, fam in pairs(fams) do
        for r = 1, #fam[1].runs do
            local lens, union = {}, {}
            for _, m in ipairs(fam) do
                lens[#m.runs[r]] = true
                for _, si in ipairs(m.runs[r]) do for k in pairs(m.p.slots[si]) do union[k] = true end end
            end
            if vim.tbl_count(lens) > 1 then
                for _, m in ipairs(fam) do
                    for _, si in ipairs(m.runs[r]) do for k in pairs(union) do m.p.slots[si][k] = true end end
                end
            end
        end
    end
end

--- a FRAGMENT: `kinds` (set) the kinds a tree may use; `atoms` { kind -> { text, … } } — a kind with atoms is a leaf of
--- size 1 whatever its productions. -> a closure table over G: count(kind, n), each(kind, n, fn(text)), why_empty
function M.fragment(G, frag)
    local allowed, atoms = frag.kinds, frag.atoms or {}
    local memo, smemo, popts = {}, {}, {} -- per FRAGMENT: a production's admissible slot kinds depend on `allowed`
    local count
    local function options(p, i)
        local out = {}
        for k in pairs(p.slots[i]) do if allowed[k] or atoms[k] then out[#out + 1] = k end end
        table.sort(out)
        return out
    end
    -- the number of ways to fill slots i..#slots of p with total size m (each slot at least 1)
    local function slots_ways(p, i, m)
        if i > #p.slots then return m == 0 and 1 or 0 end
        popts[p] = popts[p] or {}
        popts[p][i] = popts[p][i] or options(p, i)
        local key = i .. ':' .. m
        smemo[p] = smemo[p] or {}
        if smemo[p][key] then return smemo[p][key] end
        local total = 0
        for first = 1, m - (#p.slots - i) do
            local here = 0
            for _, k in ipairs(popts[p][i]) do here = here + count(k, first) end
            if here > 0 then total = total + here * slots_ways(p, i + 1, m - first) end
        end
        smemo[p][key] = total
        return total
    end
    function count(k, n)
        if n < 1 then return 0 end
        if atoms[k] then return n == 1 and #atoms[k] or 0 end
        if not allowed[k] then return 0 end
        local K = G.kinds[k]
        if not K then return 0 end
        memo[k] = memo[k] or {}
        if memo[k][n] then return memo[k][n] end
        memo[k][n] = 0 -- a cycle through size n cannot contribute (every production of size n splits n-1 below it)
        local total = 0
        for _, p in ipairs(K.prods) do total = total + slots_ways(p, 1, n - 1) end
        memo[k][n] = total
        return total
    end
    -- enumerate: every tree of kind k and size n, as its token list, to fn(tokens) (the list is reused: copy to keep)
    local buf = {}
    local gen
    -- every tree of kind k and size n, its tokens pushed on `buf` in order, then kont()
    function gen(k, n, kont)
        if atoms[k] then
            if n ~= 1 then return end
            -- an atom is pushed MARKED ({ atom = text }): only an atom's `#` is a placeholder — a grammar token `#` (Lua's
            -- length operator) is not (measured: numbering every token printed `# "10"` as `1 "10"`)
            for _, a in ipairs(atoms[k]) do buf[#buf + 1] = { atom = a }; kont(); buf[#buf] = nil end
            return
        end
        for _, p in ipairs(G.kinds[k].prods) do
            if slots_ways(p, 1, n - 1) > 0 then
                -- walk the items: a token is pushed, a slot is generated in place (so tokens interleave correctly)
                local function items_from(j, i, m)
                    local it = p.items[j]
                    if not it then if m == 0 then kont() end return end
                    if it.tok then
                        buf[#buf + 1] = it.tok
                        items_from(j + 1, i, m)
                        buf[#buf] = nil
                        return
                    end
                    for first = 1, m - (#p.slots - i) do
                        if slots_ways(p, i + 1, m - first) > 0 then
                            for _, sk in ipairs(popts[p][i]) do
                                if count(sk, first) > 0 then
                                    gen(sk, first, function () items_from(j + 1, i + 1, m - first) end)
                                end
                            end
                        end
                    end
                end
                items_from(1, 1, n - 1)
            end
        end
    end
    local F = {}
    F.count = count
    --- every tree of kind k and size exactly n: fn(tokens) (a reused list)
    function F.each(k, n, fn)
        gen(k, n, function () fn(buf) end)
    end
    --- the selected kinds that can build NOTHING here (no production, no constant, no atoms) — a fragment that selects
    --- one is refused by its caller: a kind with zero productions makes "exhaustive over it" a vacuous claim
    function F.dead()
        local out = {}
        for k in pairs(allowed) do
            local K = G.kinds[k]
            if not atoms[k] and not (K and #K.prods > 0) then out[#out + 1] = k end
        end
        table.sort(out)
        return out
    end
    return F
end

--- print a token list as source text (tokens joined by one space: no two tokens can fuse — `- -1` stays two
--- operators, never a `--` comment). An ATOM (a marked entry) has its `#` replaced by its occurrence number (distinct
--- print sites); a grammar token is printed as it is
function M.print(tokens)
    local n = 0
    local out = {}
    for i, t in ipairs(tokens) do
        if type(t) == 'table' then
            out[i] = (t.atom:gsub('#', function () n = n + 1; return tostring(n) end))
        else
            out[i] = t
        end
    end
    return table.concat(out, ' ')
end

return M
