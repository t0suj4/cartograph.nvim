-- THE CONTRADICTORY-PATH CEILING PROBE (CART-0256) — "would a boolean path
-- solver earn its keep?", measured BEFORE building one. Sibling of
-- tools/ifaceceil.lua and tools/levers.lua: dry-run the proposed rung's logic
-- over real corpora and report what it WOULD find, plus what it would get wrong.
--
--   nvim --headless -u NONE -l tools/pathsat.lua <corpus|path> [--show N]
--   nvim --headless -u NONE -l tools/pathsat.lua --selftest
--
-- THE PROPOSED RUNG. cartograph can STATE a path condition and cannot SOLVE one:
-- cfg.guards_over gives the conjunction dominating a statement, while expr.eval is
-- closed-world literal folding that returns ⊤ at the first name or call. But you do
-- not need a theory solver to find a CONTRADICTION — treat each atomic guard as an
-- OPAQUE boolean variable and a conjunction holding both `C` and `¬C` proves the
-- statement unreachable, whatever C means. That is a soundness-POSITIVE claim in the
-- authoritative tier's style (provably dead, not suspected dead), and a sibling of
-- dead-confined. Prior art for the machinery IF it is ever funded: clpb.pl in
-- ~/git/swipl-devel ([[swipl-reference]]); clpfd/simplex are the NEXT rung, needed
-- only to SYNTHESIZE a witness rather than decide satisfiability.
--
-- WHY A PROBE AND NOT A LINT. The naive version of this is a NAME MATCH — two
-- textually equal conditions assumed to have equal value — and this repo has measured
-- name-match precision at ~10% wrong ([[cartograph-linker]]). So the probe reports a
-- LADDER of tiers, and the DROP between them is the finding, not a footnote:
--
--   RAW      same canonical key under both polarities. No filters. The naive number.
--   PURE     + the condition contains no call/table/closure/vararg (expr.is_pure)
--            AND does not read a container (expr.reads_content). `if f() then …
--            if not f() then` is NOT a contradiction: two calls may return
--            different values — and `if t[k] then … load() … if t[k] then` is not
--            one either, for the same reason. The container half was added when
--            CART-0257 made an admissible false positive visible (AtlasLoot); the
--            name-keyed tiers below it CANNOT see a mutation through an index.
--   NOREASSIGN + no name in the condition is REASSIGNED anywhere in the function.
--            Mirrors narrow.lua's shipped `mutated_of` (assignment_statement defs),
--            whose header names this exact hazard: guards_over "can't see that
--            `if x then … x = f() … use(x)`" restales the guard.
--   STRICT   + no name in the condition is DEFINED anywhere in the function at all.
--            Strictly stronger than NOREASSIGN because it also catches SHADOWING: a
--            fresh `local x` between the guards makes the inner `x` a DIFFERENT
--            binding, which a reassignment-only filter cannot see. Conservative by
--            construction — a condition over parameters / upvalues / module-level
--            names only. This is the tier to trust and the tier to hand-sample.
--
-- STRICT is deliberately over-conservative: it kills legitimate cases (a local
-- assigned once before both guards). That is the right direction for a probe whose
-- question is "does ANY survivor exist" — a nonzero STRICT is a floor on the real
-- answer, and a zero STRICT with a large RAW is itself the result.
--
-- SELFTEST IS NOT OPTIONAL. A probe reporting zero is uninterpretable unless it has
-- been shown capable of reporting nonzero — the zero could equally mean "no
-- contradictions in this corpus" or "the normalizer never matches anything". So
-- --selftest runs a fixture with KNOWN positives and KNOWN near-misses and asserts
-- both directions; it runs automatically before any corpus and aborts on failure.
--
-- SCOPE: Lua only, matching narrow.lua's INC 1. guards_over itself is per-language,
-- but the flow-def filters are read through Lua's spec, and an unvalidated
-- cross-language claim is worth less than an honest single-language one.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local cfg = require 'cartograph.cfg'
local expr = require 'cartograph.expr'
local at = require 'cartograph.at'

local function txt(n, src) return n and vim.treesitter.get_node_text(n, src) or '' end
local function squash(s) return (s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')) end

-- The KEY text: whitespace squashed everywhere EXCEPT inside a string literal,
-- built by rejoining the node's children rather than rewriting its source text.
-- A flat `gsub('%s+', ' ')` collapsed `char == "  "` (two spaces) and
-- `char == " "` (one) into one key, and Skada/Modules/Nickname.lua:301/305 tests
-- exactly those two in one elseif chain — so the CART-0257 negations turned a
-- latent normalizer bug into a reported STRICT survivor. Whitespace is
-- insignificant BETWEEN tokens and significant INSIDE one; a normalizer that
-- does not know the difference manufactures contradictions.
local function keytext(n, src)
    if not n then return '' end
    if n:type() == 'string' then return txt(n, src) end
    local parts, any = {}, false
    for c in n:iter_children() do
        any = true
        parts[#parts + 1] = keytext(c, src)
    end
    if not any then return squash(txt(n, src)) end
    return table.concat(parts, ' ')
end

-- ── guard NORMALIZATION: a TS condition node → (key, polarity) ───────────────
-- Only value-preserving rewrites, each individually sound:
--   (E)        → E
--   not E / !E → E with the polarity flipped
--   a ~= b     → key of `a == b` with the polarity flipped
-- Anything else is opaque and keys on its squashed source text. Textual equality
-- is what makes this a NAME MATCH, which is what the filter tiers exist to price.
-- The OPERATOR of a unary/binary expression. In tree-sitter-lua it is an
-- ANONYMOUS, FIELD-LESS child of both — `field('operator')` returns nothing, which
-- is what made the first version of this probe silently detect nothing but the
-- `==` cases. The selftest is what caught it; without a fixture of known positives
-- the corpus numbers would have read as a clean NO-GO.
local function op_text(n, src)
    for c, f in n:iter_children() do
        if not f and not c:named() then return txt(c, src) end
    end
end

local function normalize(n, src)
    local pol = true
    local guard = 0
    while n and guard < 32 do
        guard = guard + 1
        local t = n:type()
        if t == 'parenthesized_expression' then
            local inner
            for c in n:iter_children() do if c:named() then inner = c; break end end
            if not inner then break end
            n = inner
        elseif t == 'unary_expression' then
            local ot = op_text(n, src)
            if ot ~= 'not' and ot ~= '!' then break end
            local operand = n:field('operand')[1] or n:field('argument')[1]
            if not operand then
                for c in n:iter_children() do if c:named() then operand = c end end
            end
            if not operand then break end
            n, pol = operand, not pol
        elseif t == 'binary_expression' then
            local ot = op_text(n, src)
            if ot ~= '~=' and ot ~= '!=' then break end
            local l, r = n:field('left')[1], n:field('right')[1]
            if not (l and r) then break end
            return keytext(l, src) .. ' == ' .. keytext(r, src), not pol, n
        else break end
    end
    if not n then return nil end
    return keytext(n, src), pol, n
end

-- ── the two filter inputs, per function ─────────────────────────────────────
-- Computed over the function's AST SUBTREE, deliberately NOT over its flow record.
-- The first version of this probe used `flow.record(node)` and reported 12 STRICT
-- survivors on `self`, EVERY ONE a false positive of one shape: the guards sat
-- inside a nested `cmd(…, function() … end)` callback, so the `local store = live()`
-- and `store = whole_graph(store)` that invalidate them belong to the CALLBACK's
-- flow rows, not the enclosing function's. The filter saw no def for the name and
-- read that absence as "never defined" — the absence-as-falseness defect class, in
-- the probe built to price exactly that risk. An AST subtree walk crosses closure
-- boundaries and so cannot be fooled the same way.
--
--   defined    = every identifier bound anywhere in the subtree: an assignment
--                target (local decl OR reassignment), a for-clause variable, or a
--                NESTED function's parameter (which shadows). Over-approximates on
--                purpose — `t[i] = 1` marks both `t` and `i`.
--   reassigned = the same, minus `local` declarations (an assignment_statement whose
--                parent is a variable_declaration IS a fresh binding). This is the
--                tier comparable to narrow.lua's shipped `mutated_of`.
local FOR_CLAUSE = { for_numeric_clause = true, for_generic_clause = true }
local function idents_into(n, set)
    if not n then return end
    if n:type() == 'identifier' then set[n] = true; return end
    for c in n:iter_children() do if c:named() then idents_into(c, set) end end
end
local function def_sets(fn, src)
    local reassigned, defined = {}, {}
    local function add(node, into)
        local acc = {}
        idents_into(node, acc)
        for id in pairs(acc) do into[txt(id, src)] = true end
    end
    -- `top` = we are directly inside the function under analysis, so its OWN
    -- `parameters` child must NOT count as a def: a parameter is bound once and is
    -- stable across the body unless something assigns it (which the assignment arm
    -- catches). A NESTED function's parameters DO count — they shadow.
    local function walk(n, top)
        for c in n:iter_children() do
            if c:named() then
                local t = c:type()
                if t == 'assignment_statement' then
                    -- the targets hang off a `variable_list` CHILD, not off the
                    -- assignment's own `name` field (which does not exist) — reading
                    -- them straight off the assignment silently collects nothing,
                    -- and the selftest's kill cases are what caught that.
                    local islocal = c:parent() and c:parent():type() == 'variable_declaration'
                    for vl in c:iter_children() do
                        if vl:named() and vl:type() == 'variable_list' then
                            add(vl, defined)
                            if not islocal then add(vl, reassigned) end
                        end
                    end
                elseif FOR_CLAUSE[t] then
                    for target, f in c:iter_children() do
                        if f == 'name' then add(target, defined) end
                    end
                elseif t == 'parameters' and not top then
                    add(c, defined)
                end
                walk(c, false)
            end
        end
    end
    walk(fn, true)
    return reassigned, defined
end

local FN_TYPES = { function_declaration = true, function_definition = true }
-- takes the file's ALREADY-PARSED root: one parse per FILE, not per function.
-- Re-parsing per function was both slow and part of why the first wow run was
-- OOM-killed (exit 137) — the sweep-memory lesson that a per-corpus tool must
-- stream ([[cartograph-sweep-memory]]).
local function fn_node(root, node)
    local d = root:named_descendant_for_range(at.sl(node.range), at.sc(node.range),
        at.el(node.range), at.ec(node.range))
    while d do
        if FN_TYPES[d:type()] then return d end
        d = d:parent()
    end
    return nil
end

-- the condition's expr IR, for purity + the names it reads.
-- PURE = is_pure AND NOT reads_content. The container-read half was added after
-- the CART-0257 else/elseif negations made a false positive VISIBLE that the
-- tier had always been able to admit: AtlasLoot.lua:1224 tests
-- `AtlasLoot_Data[dataID]`, its else branch calls LoadAddOn(moduleName) — whose
-- entire job is to POPULATE that table — and re-tests the same index at 1240.
-- No name is reassigned and none is defined in the function, so NOREASSIGN and
-- STRICT (both name-keyed) are structurally blind to it; only purity can refuse
-- it, and a container read is the same hazard as a call for the same reason —
-- two evaluations may differ. `expr.reads_content` already existed and says so
-- in its own docstring ("values a mutation elsewhere can change").
local function cond_facts(cnode, src)
    local okr, row = pcall(expr.harvest_row, cnode, src, 'cond', 'lua')
    if not (okr and row and row.cond) then return nil end
    local okp, pure = pcall(expr.is_pure, row.cond)
    local okc, reads = pcall(expr.reads_content, row.cond)
    local okn, names = pcall(expr.names, row)
    if not (okp and okc and okn) then return nil end
    return { pure = pure and not reads, names = names }
end

--- Contradictions in ONE function. Returns a list of findings, each a distinct
--- PAIR of guard nodes (not one per dominated statement — an outer contradiction
--- dominates every statement inside it, and counting those would inflate the
--- number by nesting depth).
local function scan_fn(root, store_node, src)
    local fn = fn_node(root, store_node)
    if not fn then return {} end
    local reassigned, defined = def_sets(fn, src)
    local out, seenpair = {}, {}
    local function visit(n)
        for c in n:iter_children() do
            if c:named() then
                if c:type() == 'block' then
                    for stmt in c:iter_children() do
                        if stmt:named() and stmt:type() ~= 'comment' then
                            -- key → { [true] = gnode, [false] = gnode }
                            local seen = {}
                            for _, g in ipairs(cfg.guards_over(stmt, src)) do
                                -- guards_over's `neg` means ¬cond holds here, so the
                                -- polarity asserted at this point is (not g.neg)
                                local key, pol, cnode = normalize(g.cond, src)
                                if key then
                                    local asserted = (not g.neg) == pol
                                    seen[key] = seen[key] or {}
                                    seen[key][asserted] = cnode
                                    local other = seen[key][not asserted]
                                    if other then
                                        local a, b = cnode:id(), other:id()
                                        if a > b then a, b = b, a end
                                        local pid = a .. '|' .. b
                                        if not seenpair[pid] then
                                            seenpair[pid] = true
                                            local f = cond_facts(cnode, src)
                                            local names = (f and f.names) or {}
                                            local anyre, anydef = false, false
                                            for _, nm in ipairs(names) do
                                                if reassigned[nm] then anyre = true end
                                                if defined[nm] then anydef = true end
                                            end
                                            out[#out + 1] = {
                                                key = key,
                                                line = stmt:start() + 1,
                                                gline = cnode:start() + 1,
                                                oline = other:start() + 1,
                                                pure = f and f.pure or false,
                                                known = f ~= nil,
                                                nnames = #names,
                                                reassigned = anyre,
                                                defined = anydef,
                                            }
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                visit(c)
            end
        end
    end
    visit(fn)
    return out
end

--- Sweep every Lua function in the open store, STREAMING BY FILE: group the nodes,
--- then hold exactly one file's source + parse tree at a time. The first version
--- cached every file's source and re-parsed per function, and wow (2.27M lines) was
--- OOM-KILLED at exit 137 — a corpus tool must stream ([[cartograph-sweep-memory]]:
--- a sweep can sit inside the extract budget and still die).
local function sweep()
    local res, nfn = {}, 0
    -- GLOBAL dedup: a nested closure's statements are inside the subtree of every
    -- enclosing function node, so the same guard pair is reachable from several
    -- store nodes. Keyed by the site itself (file + key + the two guard lines), not
    -- by node id, because the ids differ per parse.
    local seen = {}
    local files, order = {}, {}
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file
            and n.file:match('%.lua$') and n.range then
            if not files[n.file] then files[n.file] = {}; order[#order + 1] = n.file end
            local l = files[n.file]
            l[#l + 1] = n
            nfn = nfn + 1
        end
    end
    for _, rel in ipairs(order) do
        local nodes = files[rel]
        local src = table.concat(store.content(nodes[1]) or {}, '\n')
        if src ~= '' then
            local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
            local root = okp and parser and parser:parse()[1]:root()
            if root then
                for _, n in ipairs(nodes) do
                    local oks, fs = pcall(scan_fn, root, n, src)
                    if oks then
                        for _, f in ipairs(fs) do
                            local sid = ('%s|%s|%d|%d'):format(rel, f.key,
                                math.min(f.gline, f.oline), math.max(f.gline, f.oline))
                            if not seen[sid] then
                                seen[sid] = true
                                f.file, f.fn = rel, n.name or '?'
                                res[#res + 1] = f
                            end
                        end
                    end
                end
            end
        end
        files[rel] = nil -- drop the node list with the source and the tree
    end
    return res, nfn
end

local function tally(res)
    local t = { raw = 0, pure = 0, noreassign = 0, strict = 0 }
    for _, f in ipairs(res) do
        t.raw = t.raw + 1
        if f.pure then
            t.pure = t.pure + 1
            if not f.reassigned then
                t.noreassign = t.noreassign + 1
                if not f.defined then t.strict = t.strict + 1 end
            end
        end
    end
    return t
end

local function survivors(res)
    local out = {}
    for _, f in ipairs(res) do
        if f.pure and not f.reassigned and not f.defined then out[#out + 1] = f end
    end
    return out
end

-- ── SELFTEST: known positives AND known near-misses ─────────────────────────
local FIXTURE = table.concat({
    'local M = {}',
    '',
    -- POSITIVE 1: nested `if x` / `if not x`, x is a param, never assigned
    'local function p1(x)',
    '    if x then',
    '        if not x then',
    '            M.dead1 = 1',
    '        end',
    '    end',
    'end',
    '',
    -- POSITIVE 2: early-exit guard clause then the same condition
    'local function p2(y)',
    '    if y == 3 then return end',
    '    if y == 3 then',
    '        M.dead2 = 1',
    '    end',
    'end',
    '',
    -- POSITIVE 3: ~= normalizes to the == form with flipped polarity
    'local function p3(z)',
    '    if z ~= 4 then',
    '        if z == 4 then',
    '            M.dead3 = 1',
    '        end',
    '    end',
    'end',
    '',
    -- NEAR-MISS A: impure condition — two calls may differ. RAW yes, PURE no.
    'local function m1(t)',
    '    if t:ok() then',
    '        if not t:ok() then',
    '            M.live1 = 1',
    '        end',
    '    end',
    'end',
    '',
    -- NEAR-MISS B: reassigned between the guards. RAW+PURE yes, NOREASSIGN no.
    'local function m2(w, f)',
    '    if w then',
    '        w = f',
    '        if not w then',
    '            M.live2 = 1',
    '        end',
    '    end',
    'end',
    '',
    -- NEAR-MISS C: SHADOWED by a fresh local — the inner `v` is a NEW binding.
    -- RAW+PURE+NOREASSIGN all yes (no assignment_statement!), STRICT no.
    'local function m3(v, g)',
    '    if v then',
    '        local v = g',
    '        if not v then',
    '            M.live3 = 1',
    '        end',
    '    end',
    'end',
    '',
    -- NEAR-MISS D: THE REGRESSION CASE. The guards live inside a NESTED closure,
    -- and so does the `local s` / `s = h(s)` that invalidates them. A def-set read
    -- from the OUTER function's flow record cannot see either, which is exactly how
    -- the first version of this probe produced 12 false positives on `self` (the
    -- `local store = live() … store = whole_graph(store)` command-callback idiom).
    -- Must be detected RAW and killed by NOREASSIGN.
    'local function m4(h)',
    '    reg("v", function ()',
    '        local s = h()',
    '        if not s then return end',
    '        s = h(s)',
    '        if not s then return end',
    '        M.live4 = s',
    '    end)',
    'end',
    '',
    -- NEAR-MISS E: a CONTAINER READ re-tested across a call that populates it —
    -- the AtlasLoot shape. No name is reassigned and none is defined, so the
    -- name-keyed tiers pass it; PURE must be the one to kill it.
    'local function m5(t, k)',
    '    if t[k] then',
    '        M.hit = 1',
    '    else',
    '        populate(t, k)',
    '        if t[k] then',
    '            M.live5 = 1',
    '        end',
    '    end',
    'end',
    '',
    -- CONTROL 2: two DIFFERENT string literals that a whitespace-squashing
    -- normalizer collapses into one key — the Skada shape. Must be SILENT: it is
    -- not a near-miss to be caught by a later tier, it is not a contradiction at
    -- all, and reporting it is the normalizer manufacturing one.
    'local function ok2(char)',
    '    if char == "  " then',
    '        M.two = 1',
    '    elseif char == " " then',
    '        M.one = 1',
    '    end',
    'end',
    '',
    -- CONTROL: no contradiction at all
    'local function ok1(a, b)',
    '    if a then',
    '        if b then',
    '            M.fine = 1',
    '        end',
    '    end',
    'end',
    '',
    -- POSITIVE 4: THE ELSE PATH (CART-0257). ¬x holds in the else, so `if x`
    -- inside it is unreachable. This shape yielded RAW 0 before guards_over
    -- emitted else/elseif negations — the probe was blind to the most idiomatic
    -- branch shape there is, which is why CART-0256's yield was banked as a
    -- LOWER BOUND rather than an answer. Kept here so the fix cannot silently
    -- regress: a zero from this probe is only meaningful if it can still fire.
    'local function p4(x)',
    '    if x then',
    '        M.a = 1',
    '    else',
    '        if x then',
    '            M.dead4 = 1',
    '        end',
    '    end',
    'end',
    '',
    -- POSITIVE 5: THE ELSEIF CHAIN — a repeated condition, i.e. the copy-paste
    -- defect this probe exists to find, and the place the ticket argued it is
    -- MOST likely to occur. ¬y from standing on the chain ∧ y from the clause.
    'local function p5(y)',
    '    if y then',
    '        M.b = 1',
    '    elseif y then',
    '        M.dead5 = 1',
    '    end',
    'end',
    '',
    'M.p1, M.p2, M.p3, M.p4, M.p5 = p1, p2, p3, p4, p5',
    'M.m1, M.m2, M.m3, M.m4, M.m5 = m1, m2, m3, m4, m5',
    'M.ok1, M.ok2 = ok1, ok2',
    'return M',
}, '\n') .. '\n'

local function selftest()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/fx.lua', 'w')); fd:write(FIXTURE); fd:close()
    store.ingest(ts.extract(root))
    local res = sweep()
    local byfn = {}
    for _, f in ipairs(res) do
        byfn[f.fn] = byfn[f.fn] or {}
        table.insert(byfn[f.fn], f)
    end
    local fails = {}
    local function chk(cond, msg) if not cond then fails[#fails + 1] = msg end end
    local function one(fn)
        local l = byfn[fn]
        if not l or #l ~= 1 then return nil end
        return l[1]
    end
    -- positives must reach STRICT
    for _, fn in ipairs { 'p1', 'p2', 'p3', 'p4', 'p5' } do
        local f = one(fn)
        chk(f, fn .. ': expected exactly one contradiction, got '
            .. tostring(byfn[fn] and #byfn[fn] or 0))
        if f then
            chk(f.pure, fn .. ': should be PURE')
            chk(not f.reassigned, fn .. ': should not be reassigned')
            chk(not f.defined, fn .. ': should not be defined in-fn (key=' .. f.key .. ')')
        end
    end
    -- near-misses must be DETECTED raw but KILLED at the right tier
    local a = one('m1')
    chk(a, 'm1: expected a RAW detection (impure)')
    chk(a and not a.pure, 'm1: must be killed by PURE')
    local b = one('m2')
    chk(b, 'm2: expected a RAW detection (reassigned)')
    chk(b and b.pure, 'm2: is pure')
    chk(b and b.reassigned, 'm2: must be killed by NOREASSIGN')
    local c = one('m3')
    chk(c, 'm3: expected a RAW detection (shadowed)')
    chk(c and c.pure and not c.reassigned,
        'm3: passes PURE and NOREASSIGN (the point — a fresh local is no assignment)')
    chk(c and c.defined, 'm3: must be killed by STRICT (shadowing)')
    -- THE REGRESSION: guards + their invalidation both inside a nested closure.
    -- Found as 12 false positives on `self`; the def-set must cross the boundary.
    local d = byfn['m4'] and byfn['m4'][1]
    chk(d, 'm4: expected a RAW detection inside the nested closure')
    chk(d and d.reassigned,
        'm4: must be killed by NOREASSIGN — the def-set must cross the CLOSURE boundary'
        .. ' (this is the 12-false-positive regression)')
    -- THE CONTAINER READ: only PURE can refuse it, and it must.
    local e = one('m5')
    chk(e, 'm5: expected a RAW detection (container read re-tested across a call)')
    chk(e and not e.pure,
        'm5: must be killed by PURE — `t[k]` is mutable through a call, and the'
        .. ' name-keyed tiers cannot see it (the AtlasLoot false positive)')
    chk(e and not e.reassigned and not e.defined,
        'm5: and NOREASSIGN/STRICT must NOT save us here — the point is that they'
        .. ' pass it, so purity is load-bearing')
    -- controls must be silent
    chk(byfn['ok1'] == nil, 'ok1: must report nothing')
    chk(byfn['ok2'] == nil,
        'ok2: `char == "  "` and `char == " "` are DIFFERENT conditions — a'
        .. ' whitespace-squashing normalizer manufactures a contradiction here'
        .. ' (the Skada false positive)')
    vim.fn.delete(root, 'rf')
    return fails
end

-- ── main ────────────────────────────────────────────────────────────────────
local target = arg[1]
local show = 8
for i = 1, #(arg or {}) do if arg[i] == '--show' then show = tonumber(arg[i + 1]) or 8 end end

print('pathsat SELFTEST (a zero is meaningless from a probe that cannot fire)')
local fails = selftest()
for _, m in ipairs(fails) do print('  FAIL ' .. m) end
if #fails > 0 then
    print(('pathsat: SELFTEST FAILED (%d) — refusing to report corpus numbers'):format(#fails))
    os.exit(1)
end
print('  ok — 5 positives reach STRICT (incl. the else + elseif shapes CART-0257'
    .. ' made visible); 4 near-misses detected RAW and killed at'
    .. ' PURE / NOREASSIGN / STRICT / PURE respectively; 2 controls silent')

if not target or target == '--selftest' then
    print('pathsat: selftest only (pass a corpus|path to sweep)')
    os.exit(0)
end

local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) == 0 then
    print('pathsat: not a directory: ' .. root)
    os.exit(2)
end

print('')
print(('pathsat %s — %s'):format(target, root))
store.ingest(ts.extract(root))
local res, nfn = sweep()
local t = tally(res)
print(('  %d lua function(s) scanned'):format(nfn))
print(('  RAW        %5d   same key under both polarities, no filters (the NAME MATCH)')
    :format(t.raw))
print(('  PURE       %5d   + condition has no call/table/closure/vararg'):format(t.pure))
print(('  NOREASSIGN %5d   + no condition name reassigned in the fn (narrow.lua\'s filter)')
    :format(t.noreassign))
print(('  STRICT     %5d   + no condition name DEFINED in the fn (catches shadowing)')
    :format(t.strict))
if t.raw > 0 then
    print(('  → the filters remove %d of %d (%.0f%%) of the naive signal')
        :format(t.raw - t.strict, t.raw, 100 * (t.raw - t.strict) / t.raw))
end

local sv = survivors(res)
if #sv > 0 then
    print('')
    print(('STRICT survivors (%d) — HAND-READ THESE; the probe claims each is unreachable:')
        :format(#sv))
    table.sort(sv, function (x, y)
        if x.file ~= y.file then return x.file < y.file end
        return x.line < y.line
    end)
    for i = 1, math.min(#sv, show) do
        local f = sv[i]
        print(('  %s:%d  in %s  — `%s` asserted both ways (guards L%d / L%d)')
            :format(f.file, f.line, f.fn, f.key, math.min(f.gline, f.oline),
                math.max(f.gline, f.oline)))
    end
    if #sv > show then print(('  … %d more (--show N)'):format(#sv - show)) end
end
