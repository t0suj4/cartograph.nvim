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
-- A DECLARATION: { name, lang, wrap?, source = 'spec'|'derived'|'profile', why,
--   select(node, src) -> bool   OPTIONAL: by default DERIVED from the forms — a node is a site when its type is a
--                               form's root type and it carries that form's LITERAL leaves at the same positions
--                               (`attr_accessor` as kid 1, or kid 2 after a receiver; `iq_handler` first in a tuple),
--                               so a site whose arguments refuse is still in the population and refuses by name,
--   context(node, src, file) -> { name = text… } | nil, why      values a site gets from where it sits
--   project = { [kind] = fn(text) -> text }                        how a leaf reads as a name (`:foo` -> `foo`)
--   forms = { { name, site = <SOURCE SNIPPET>, holes = { h = { kind… } }, out = { <OUTPUT>… } }… } }
--
-- ★★ A FORM IS WRITTEN AS SOURCE (CART-1125, the lever the third reader named): `has_many __assoc, __rest__` is
-- parsed with the language's own grammar and read by the same converter as a real site, with each PLACEHOLDER leaf
-- turned into a hole — `__name` a hole, `__name__` a repeated one (both parse as an identifier in ruby and as a
-- variable in erlang). The template is therefore the grammar's own shape and cannot drift from what a site parses
-- to. `wrap` (a format string) gives the snippet a context its grammar needs, for a grammar whose top level does not
-- admit the site's shape (erlang's does: a bare `{…}` parses); the site is the DEEPEST node spanning exactly the
-- snippet, and a snippet that parses only through error recovery refuses. `holes` gives domains: a list of kinds
-- (`{ 'simple_symbol' }`, for a repeated hole each element's); no entry is open. (No least count: an empty argument
-- list converts to a LEAF, so no site ever offers a repeated hole zero elements — a knob no input could reach.)
-- An OUTPUT is a text template, `'$owner#$assoc='` (a `def` whose name is the parts joined), or
-- `{ kind = 'registration', parts = { '$key', '$mod', '$fn' } }`. Options on either: `each` generates once per
-- element of a repeated hole (bound as `as`), `only` keeps elements of those kinds (`delegate :a, to: :x` — the pair
-- is an option, not a method), `ok` filters on the element's projected name, or on hole `check`'s without `each`.
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

-- a placeholder leaf: `__name__` (a repeated hole) or `__name`
local function placeholder(text)
    local r = text:match('^__([%a][%w_]-)__$')
    if r then return r, true end
    local n = text:match('^__([%a][%w_]*)$')
    if n then return n, false end
end

--- a SOURCE SNIPPET as a template: parsed with `lang` (inside `wrap`, when given), the deepest node spanning exactly
--- the snippet read by M.term, placeholder leaves turned into holes with the declared domains.
function M.snippet(A, lang, snippet, holes, wrap)
    local text = wrap and wrap:format(snippet) or snippet
    local off = wrap and (text:find(snippet, 1, true) - 1) or 0
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    local root = ok and parser and parser:parse()[1]:root()
    if not root then return nil, 'no ' .. lang .. ' parser' end
    -- a snippet its grammar only RECOVERS from (an erlang tuple with no function around it) is not a shape the
    -- grammar gives a site: refuse rather than template the error recovery
    if root:has_error() then return nil, ('`%s` does not parse as %s%s'):format(snippet, lang, wrap and '' or ' (a wrap?)') end
    local best
    local function find(n)
        local _, _, sb, _, _, eb = n:range(true)
        if sb == off and eb == off + #snippet and n:named() then best = n end
        for c in n:iter_children() do find(c) end
    end
    find(root)
    if not best then return nil, 'no node spans the snippet `' .. snippet .. '`' end
    local reps = {}
    local function holify(t)
        if t.k ~= 'lit' and #(t.kids or {}) == 1 and t.kids[1].k == 'lit' then
            local name, rep = placeholder(tostring(t.kids[1].v))
            if name then reps[name] = rep; return A.hole(name, rep or nil) end
        end
        if not t.kids then return t end
        local kids = {}
        for i, k in ipairs(t.kids) do kids[i] = holify(k) end
        return A.node(t.k, unpack(kids))
    end
    local body = holify(M.term(A, best, text))
    -- the GRAMMAR FIELD of each direct kid: the term keeps positions, not fields, and a selector needs both —
    -- `delegate :a` has `delegate` as its METHOD, `delegate.respond_to?(:x)` as its RECEIVER, both at kid 1
    local fields = {}
    local is_comment = require('cartograph.spec.tsutil').is_comment
    for c, fld in best:iter_children() do
        if c:named() and not is_comment(c) then fields[#fields + 1] = fld or false end
    end
    local domains = {}
    for name, rep in pairs(reps) do
        local d = holes and holes[name]
        local kinds = d and #d > 0 and A.kinds(d) or nil
        domains[name] = rep and A.rep(kinds or A.open(), 0) or kinds
    end
    local T = A.template(body, domains)
    T.kid_fields = fields
    return T
end

--- an OUTPUT text template (`'$owner#$assoc='`) as the kids it instantiates to: holes and literal runs
local function out_kids(A, text)
    local kids, i = {}, 1
    while i <= #text do
        local s, e, name = text:find('%$([%a_][%w_]*)', i)
        if not s then kids[#kids + 1] = A.lit(text:sub(i)); break end
        if s > i then kids[#kids + 1] = A.lit(text:sub(i, s - 1)) end
        kids[#kids + 1] = A.hole(name)
        i = e + 1
    end
    return kids
end

-- a declaration's forms compiled once: sites and outputs as algebra templates
local function compile(A, gen)
    local fs = {}
    for _, f in ipairs(gen.forms) do
        local T, why = M.snippet(A, gen.lang, f.site, f.holes, gen.wrap)
        if not T then error(('generator %s form %s: %s'):format(gen.name, f.name or f.site, why), 0) end
        local out = {}
        for _, o in ipairs(f.out) do
            local body
            if type(o[1]) == 'string' then
                body = A.node(o.kind or 'def', unpack(out_kids(A, o[1])))
            else
                local parts = {}
                for i, p in ipairs(o.parts) do
                    local k = out_kids(A, p)
                    parts[i] = #k == 1 and k[1] or A.node('part', unpack(k))
                end
                body = A.node(o.kind, unpack(parts))
            end
            out[#out + 1] = { T = A.template(body), each = o.each, as = o.as, only = o.only, ok = o.ok, check = o.check }
        end
        fs[#fs + 1] = { name = f.name or f.site, T = T, out = out }
    end
    return fs
end

-- the selector a declaration's forms imply: per form, its root type and its direct literal leaves by position
local function derived_select(forms)
    local keys = {}
    for _, f in ipairs(forms) do
        local lits = {}
        for i, k in ipairs(f.T.body.kids or {}) do
            if k.k ~= 'hole' and #(k.kids or {}) == 1 and k.kids[1].k == 'lit' then
                lits[#lits + 1] = { i = i, k = k.k, v = tostring(k.kids[1].v), f = f.T.kid_fields and f.T.kid_fields[i] }
            end
        end
        keys[#keys + 1] = { root = f.T.body.k, lits = lits }
    end
    local is_comment = require('cartograph.spec.tsutil').is_comment
    return function (node, src)
        local t = node:type()
        local kids, flds
        for _, key in ipairs(keys) do
            if key.root == t then
                if not kids then
                    kids, flds = {}, {}
                    for c, fld in node:iter_children() do
                        if c:named() and not is_comment(c) then kids[#kids + 1] = c; flds[#kids] = fld or false end
                    end
                end
                local all = true
                for _, l in ipairs(key.lits) do
                    local c = kids[l.i]
                    if not (c and c:type() == l.k and c:named_child_count() == 0 and (l.f == nil or flds[l.i] == l.f)
                            and vim.treesitter.get_node_text(c, src) == l.v) then all = false; break end
                end
                if all then return true end
            end
        end
        return false
    end
end

local function top_rep(T)
    for _, k in ipairs(T.body.kids or {}) do if k.k == 'hole' and k.rep then return true end end
    return false
end

--- read one generator over one tree. Returns facts, refusals ({ site, reason, why, file }), selected (count).
function M.read(gen, troot, src, file)
    local A, err = algebra()
    if not A then return nil, err end
    gen._forms = gen._forms or compile(A, gen)
    gen._select = gen._select or gen.select or derived_select(gen._forms)
    local facts, refusals, selected = {}, {}, 0
    local function visit(node)
        if gen._select(node, src) then
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
        -- one form per declared arity, written as the tuple itself: `{iq_handler, __p2, __key, __fn}`
        local forms, arities = {}, {}
        for n in pairs(c.arities) do arities[#arities + 1] = n end
        table.sort(arities)
        for _, n in ipairs(arities) do
            local map, role = c.arities[n], {}
            for r, i in pairs(map) do if type(i) == 'number' then role[i] = r end end
            local els = { c.tag }
            for i = 2, n do els[i] = '__' .. (role[i] or ('p' .. i)) end
            -- the POSITIVE kind requirement (erlreg's `element` note): a registration supplies a namespace macro and a
            -- function atom; a pattern supplies vars, a type supplies type applications
            forms[#forms + 1] = { name = 'arity' .. n, site = '{' .. table.concat(els, ', ') .. '}',
                holes = { key = { 'macro_call_expr' }, fn = { 'atom' } },
                out = { { kind = 'registration', parts = { '$key', map.mod == 'context' and '$cmod' or '$mod', '$fn' } } } }
        end
        out[#out + 1] = {
            name = 'erlang.' .. c.tag, lang = 'erlang', source = 'derived', why = c.why,
            context = function (_, _, file) return { cmod = (file or ''):match('([^/]+)%.erl$') or '' } end,
            forms = forms,
        }
    end
    return out
end

return M
