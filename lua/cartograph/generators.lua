-- generators — METAPROGRAMMING AS ONE RELATION (CART-1125, first step): a GENERATOR is a site selector, the
-- shapes (forms) a site may take as algebra templates, and what each form GENERATES as output templates. Reading
-- one is the algebra's own pair: `match(form, site) -> V`, then `instantiate(output, V)` — with every generated
-- fact carrying its site.
-- @langs any
-- (the engine names no grammar's node types; a generator DECLARATION does, and lives with its language)
--
-- ★★ USER, 2026-09-27: "I think if we do it right a lot of work collapses." The hand-rolled declaration readers —
-- ruby's attr_* emitter, erlreg's tuple carrier, the behaviour obligations, record declarations, macros — each
-- re-implement "a site of this shape generates these facts". This is the shared engine, and the first step is a
-- MEASUREMENT: two existing readers of different languages are re-expressed as declarations and joined row for
-- row against the originals (tools/generatorjoin.lua). Nothing reads this at extraction yet.
--
-- ★ SELECTING A SITE IS NOT MATCHING ONE. `select` is the cheap discriminator (a tuple whose first element is the
-- tag; a call whose method is attr_*) and defines the POPULATION; a selected site that fits no form is a REFUSAL
-- with a reason, never silence. Without the split, every tuple in a tree would be either a refusal or nothing.
--   reason 'shape'   no form has the site's arity (forms without a repeated hole are compared by kid count, since
--                    `match` itself reports the first hole that refuses, not the count)
--   reason 'hole'    a form fits the shape and one of its holes refuses (`match`'s own words: erlreg's
--                    "not a value" — a `var` where a registration supplies a macro — is exactly this)
--   reason 'context' the generator needs an enclosing context (a class, a module) and there is none
--
-- A DECLARATION: { name, source = 'spec'|'derived'|'profile', why,
--   select(node, src) -> bool,
--   context(node, src, file) -> { name = text… } | nil, why      values a site gets from where it sits
--   project = { [kind] = fn(text) -> text }                        how a leaf reads as a name (`:foo` -> `foo`)
--   forms(A) -> { { name, T = template, out = { { T = template, each = hole, as = hole, only = { kind… },
--                                                  ok = lua pattern, check = hole }… } }… } }
--     `each` generates once per element of a repeated hole (bound as `as`), `only` keeps elements of those kinds
--     (`delegate :a, :b, to: :x` — the pair is an option, not a method), `ok` filters on the element's projected
--     name, or on hole `check`'s when there is no `each`.
-- `forms` takes the algebra so a spec can declare generators without loading it.
--
-- A FACT: { gen, form, kind (the output node's type), parts = { text… } (its kids, projected), name (parts joined),
--           site = { sl, sc, el, ec } (the site), at = { … } (the repeated element's node, when `each`), file }
local M = {}

local A_, A_err
local function algebra()
    if A_ or A_err then return A_, A_err end
    A_, A_err = require('cartograph.algebra').load()
    return A_, A_err
end

--- a tree-sitter node as an algebra term: a named node with named children is (type kids…), a named leaf is
--- (type "text"); comments are skipped (a comment inside an argument list would make a repeated hole refuse a site
--- the original reader accepts). Each term keeps its node's range in `at` — spans ride through the algebra's
--- arrows untouched (`eq` compares only k, v, n and kids).
function M.term(A, node, src)
    local kids = {}
    for c in node:iter_children() do
        if c:named() and not require('cartograph.spec.tsutil').is_comment(c) then kids[#kids + 1] = M.term(A, c, src) end
    end
    local t = #kids > 0 and A.node(node:type(), unpack(kids))
        or A.node(node:type(), A.lit(vim.treesitter.get_node_text(node, src)))
    t.at = { node:range() }
    return t
end

-- the text of a term, projected per kind: a leaf's literal, else its kids' texts joined
local function text(t, project)
    if t.k == 'lit' then return tostring(t.v) end
    local s = {}
    for _, k in ipairs(t.kids or {}) do s[#s + 1] = text(k, project) end
    local out = table.concat(s)
    local p = project and project[t.k]
    return p and p(out) or out
end
M.text = text

local function holes_of(A, T)
    local out = {}
    for h in pairs(A.sites(T)) do out[h] = true end
    return out
end

local function top_rep(T)
    for _, k in ipairs(T.body.kids or {}) do if k.k == 'hole' and k.rep then return true end end
    return false
end

--- read one generator over one tree. Returns facts, refusals ({ site, reason, why, file }), selected (count).
function M.read(gen, troot, src, file)
    local A, err = algebra()
    if not A then return nil, err end
    gen._forms = gen._forms or gen.forms(A)
    local facts, refusals, selected = {}, {}, 0
    local function visit(node)
        if gen.select(node, src) then
            selected = selected + 1
            local I = M.term(A, node, src)
            local site = I.at
            local ctx, cwhy
            if gen.context then ctx, cwhy = gen.context(node, src, file) end
            if gen.context and not ctx then
                refusals[#refusals + 1] = { site = site, reason = 'context', why = cwhy, file = file }
            else
                local hit, fitwhy, depth
                for _, f in ipairs(gen._forms) do
                    local fits = top_rep(f.T) or #(I.kids or {}) == #(f.T.body.kids or {})
                    if fits then
                        local m = A.match(f.T, I)
                        if m.ok then hit = { form = f, V = m.values }; break end
                        -- the refusal worth reporting is the one from the form that matched FURTHEST (the longest
                        -- refusal path): `attr_accessor period` should say its argument refused, not that it is
                        -- not the verb `attr`
                        -- (paths compare lexicographically as number lists: `2/1` is further than `1/1`)
                        local d = {}
                        for n in tostring(m.refusal and m.refusal.at or ''):gmatch('%d+') do d[#d + 1] = tonumber(n) end
                        local further = not depth
                        if depth then
                            for i = 1, math.max(#d, #depth) do
                                local x, y = d[i] or -1, depth[i] or -1
                                if x ~= y then further = x > y; break end
                            end
                        end
                        if further then depth, fitwhy = d, (m.refusal and m.refusal.why or 'no match') end
                    end
                end
                if not hit then
                    refusals[#refusals + 1] = { site = site, reason = fitwhy and 'hole' or 'shape',
                        why = fitwhy or ('no form of ' .. #(I.kids or {}) .. ' kid(s)'), file = file }
                else
                    local V = {}
                    for h, v in pairs(hit.V) do V[h] = v end
                    for h, s in pairs(ctx or {}) do V[h] = A.lit(s) end
                    for _, o in ipairs(hit.form.out) do
                        local need = holes_of(A, o.T)
                        local function emit(Vx, at)
                            local W = {}
                            for h in pairs(need) do W[h] = Vx[h] end
                            local r = A.instantiate(o.T, W)
                            if r.ok then
                                local parts = {}
                                for i, k in ipairs(r.term.kids or {}) do parts[i] = text(k, gen.project) end
                                facts[#facts + 1] = { gen = gen.name, form = hit.form.name, kind = r.term.k,
                                    parts = parts, name = table.concat(parts), site = site, at = at, file = file }
                            else
                                refusals[#refusals + 1] = { site = site, reason = 'output', file = file,
                                    why = table.concat(r.unfilled or {}, ',') .. table.concat(r.rejected or {}, ',') }
                            end
                        end
                        local only = nil
                        if o.only then only = {}; for _, k in ipairs(o.only) do only[k] = true end end
                        if o.each then
                            for _, e in ipairs((V[o.each] and V[o.each].kids) or {}) do
                                local ename = text(e, gen.project)
                                if (not only or only[e.k]) and (not o.ok or ename:match(o.ok)) then
                                    local Vx = {}
                                    for h, v in pairs(V) do Vx[h] = v end
                                    Vx[o.as] = e
                                    emit(Vx, e.at)
                                end
                            end
                        elseif not (o.ok and o.check) or text(V[o.check], gen.project):match(o.ok) then
                            emit(V, o.check and V[o.check].at or nil)
                        end
                    end
                end
            end
        end
        for c in node:iter_children() do if c:named() then visit(c) end end
    end
    visit(troot)
    return facts, refusals, selected
end

--- the erlreg carriers (erlreg.CARRIERS: a tag and a position map per arity) as generator declarations — the SAME
--- declaration the hand-rolled reader walks, so a join between the two tests the reading, not the positions.
--- Output: (registration key mod fn); `mod = 'context'` is the enclosing module, the file's own basename.
function M.from_erlreg(carriers)
    local out = {}
    for _, c in ipairs(carriers) do
        out[#out + 1] = {
            name = 'erlang.' .. c.tag, source = 'derived', why = c.why,
            select = function (node, src)
                if node:type() ~= 'tuple' then return false end
                local first = node:named_child(0)
                return first ~= nil and first:type() == 'atom' and vim.treesitter.get_node_text(first, src) == c.tag
            end,
            context = function (_, _, file)
                return { cmod = (file or ''):match('([^/]+)%.erl$') or '' }
            end,
            forms = function (A)
                local fs = {}
                local arities = {}
                for n in pairs(c.arities) do arities[#arities + 1] = n end
                table.sort(arities)
                for _, n in ipairs(arities) do
                    local map = c.arities[n]
                    local role = {}
                    for r, i in pairs(map) do if type(i) == 'number' then role[i] = r end end
                    local kids = { A.node('atom', A.lit(c.tag)) }
                    for i = 2, n do kids[i] = A.hole(role[i] or ('p' .. i)) end
                    -- the POSITIVE kind requirement (erlreg's `element` note): a registration supplies a namespace
                    -- macro and a function atom; a pattern supplies vars, a type supplies type applications
                    local T = A.template(A.node('tuple', unpack(kids)),
                        { key = A.kinds({ 'macro_call_expr' }), fn = A.kinds({ 'atom' }) })
                    local mod = map.mod == 'context' and A.hole('cmod') or A.hole('mod')
                    fs[#fs + 1] = { name = 'arity' .. n, T = T,
                        out = { { T = A.template(A.node('registration', A.hole('key'), mod, A.hole('fn'))) } } }
                end
                return fs
            end,
        }
    end
    return out
end

return M
