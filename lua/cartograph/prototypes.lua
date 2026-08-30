-- PROTOTYPE READING — a declarative-data DOMAIN MODEL read out of module-level
-- rows, the way cartograph.fsm reads a state machine out of literal data.
--
-- The shape it reads (measured on ~/git/Von-Neumann, a Factorio 1.1 mod):
--
--     local chest = table.deepcopy(data.raw["container"]["wooden-chest"])
--     chest.name = "vn-chest"
--     chest.inventory_size = 8000
--     chest.minable.result = "vn-chest"
--     pathReplaceRecursively(chest)          -- an OPAQUE call
--     data:extend{chest}
--
-- so a prototype is NOT a table literal. It is a BASE REFERENCE plus an ORDERED
-- SEQUENCE OF FIELD OVERRIDES plus a registration — which is why reading it needs
-- the module-level statement harvest (expr.of_module) and could not exist before
-- it: 249 of that mod's 344 field-shaping assignments, 72%, are module top level.
--
-- WHY A SEPARATE MODULE AND NOT A `pack`. M.packs is a RESOLUTION overlay
-- (stdlib_names / synth_defs / ctor_finders) consumed by extraction. This is an
-- ANALYSIS, so it follows fsm.lua instead: generic machinery over a DECLARED
-- adapter, with the domain semantics as data. The Factorio adapter is three
-- fields, and it activates off the L2 profile identity rather than a hardcoded
-- language check, so a Rails initializer or a webpack config is the same reading
-- with a different adapter.
--
-- THREE HONESTY RULES, because a prototype read is a LOWER BOUND by nature:
--   1. An OPAQUE CALL (any call taking the prototype var that is not the
--      registrar) may rewrite anything, so it lands as a FRONTIER and the record
--      reports complete=false. Deliberately not called a "mutator": lua passes
--      tables by reference, so the honest claim is that a rewrite cannot be RULED
--      OUT, not that one happened — `log(x)` is hedged too, and a reader who sees
--      the callee can discount it. A purity-proven callee could be exempted via
--      the write axis; guessing from the NAME could not.
--      The case that makes this mandatory: Von-Neumann's pathReplaceRecursively
--      walks the whole object rewriting every nested string, so no static reading
--      survives it and claiming completeness would be exactly the fabrication
--      this codebase keeps paying for ([[cartograph-concern-layering]]).
--   2. An override whose value is not a literal keeps its PATH and records WHY
--      the value is unknown (call / name / expr), never a guess.
--   3. Registration is read from the row's dataflow USE set, not by parsing the
--      table constructor: the expression IR models `{...}` as an opaque
--      allocation ({k='table'}, no contents), so `data:extend{chest}` does not
--      say `chest` anywhere in the IR. du's read census does. A registration
--      whose use set holds no tracked var is an ANONYMOUS registration — recorded
--      as such rather than dropped.

local expr = require 'cartograph.expr'

local atr = require 'cartograph.at'

local M = {}

--- The Factorio data-stage adapter: the domain semantics a generic analysis
--- cannot infer. `registrar` = the call that registers (data:extend harvests as a
--- field call, so the dotted form is `data.extend`); `base_root` = the dotted
--- table a base prototype is copied out of, indexed [type][name]; `copy_tail` =
--- copy verbs matched on the LAST path segment, so both `table.deepcopy` and
--- `util.table.deepcopy` land.
M.FACTORIO = {
    name      = 'factorio-data',
    registrar = { ['data.extend'] = true },
    base_root = 'data.raw',
    -- the property whose VALUE is the prototype's typename. A copied prototype takes
    -- its type from `data.raw[<type>][<name>]`; a literal one declares it as a
    -- property, and it is equally exact either way — `local x = {}` followed by
    -- `x.type = "sound"` is the same fact as `{ type = "sound" }`, one line later.
    type_key = 'type',
    copy_tail = { deepcopy = true },
    -- APPEND verbs, matched on the last path segment like `copy_tail` so both
    -- `table.insert` and `util.table.insert` land (CART-0640). A prototype list is
    -- often built empty and filled — `local t = {}` … `table.insert(t, {…})` …
    -- `data:extend(t)` — and the literal handed to the append IS the prototype.
    append_tail = { insert = true },
}

--- The adapter for a store, or nil. Activates off the L2 profile identity
--- ([[cartograph-stdlib-profile]]) — the same signal that already decides the
--- factorio vocabulary — never off the file extension: a plain Lua project must
--- not be read as a prototype tree.
function M.adapter(store)
    local prof = store.data and store.data.profile
    if prof == 'lua-factorio' then return M.FACTORIO end
    return nil
end

-- ── reading the pieces out of one harvested expression ──────────────────────

--- The literal value of an expr, or nil + a reason code. A string literal's `v`
--- carries its SOURCE QUOTES, so they are stripped here — the one place that
--- knows the harvest's convention.
local function literal(e)
    if not e then return nil, 'missing' end
    if e.k ~= 'lit' then return nil, e.k end
    local v = e.v
    if e.ty == 'str' and type(v) == 'string' then
        v = v:gsub('^([\'"])(.*)%1$', '%2')
        -- a LONG BRACKET is a string literal too, and its delimiters are part of
        -- the source text the IR carries: Von-Neumann's story text is
        -- `[[…]]`, and leaving the brackets on made the value read as if the
        -- content started with a bracket. Any level: [[…]], [=[…]=], …
        local _, body = v:match('^%[(=*)%[(.*)%]%1%]$')
        if body then v = body:gsub('^\n', '') end   -- a leading newline is skipped
    end
    return v, nil
end

--- `data.raw[<type>][<name>]` → type, name. Returns nil unless BOTH indices are
--- string literals and the chain is rooted at the adapter's base_root: a computed
--- index names a prototype we cannot identify, and a hedged guess is worse than
--- an honest nil.
local function base_ref(e, ad)
    if not e or e.k ~= 'index' then return nil end
    local nm = literal(e.i)
    local outer = e.b
    if not (nm and outer) then return nil end
    -- the TYPE segment is written either way in real mods, and both forms appear
    -- in one file: data.raw["logistic-container"][n] and data.raw.item[n]. Reading
    -- only the bracket form left 12 of Von-Neumann's prototypes basis='unknown'.
    local ty
    if outer.k == 'index' then ty = literal(outer.i)
    elseif outer.k == 'field' then ty = outer.n end
    if not (ty and expr.dotted(outer.b) == ad.base_root) then return nil end
    return ty, nm
end

--- What a copy call is copying FROM, as a descriptor — or nil when the call is
--- not a copy at all. THREE shapes, all real in one 2000-line mod:
---   { base = {type,name} }  data.raw[t][n] / data.raw.t[n] / data.raw.t.n
---   { from_var = 'x' }      a copy of a LOCAL — either another prototype we are
---                           tracking (a derivation) or an alias we never
---                           resolved (an honest frontier that NAMES the local,
---                           so it is actionable rather than a shrug)
---   { opaque = true }       a copy of something else entirely
local function copy_of(e, ad)
    if not (e and e.k == 'call') then return nil end
    local d = expr.dotted(e.f)
    local tail = d and d:match('([%w_]+)$')
    if not (tail and ad.copy_tail[tail]) then return nil end
    local arg = (e.a or {})[1]
    local ty, nm = base_ref(arg, ad)
    if ty then return { base = { type = ty, name = nm } } end
    -- `data.raw.accumulator.accumulator` — BOTH segments as fields, no bracket
    -- anywhere. Reading only the bracketed name segment misclassified 6 of
    -- Von-Neumann's prototypes as basis='unknown'.
    if arg and arg.k == 'field' then
        local ty2, nm2 = base_ref({ k = 'index', b = arg.b,
            i = { k = 'lit', ty = 'str', v = arg.n } }, ad)
        if ty2 then return { base = { type = ty2, name = nm2 } } end
    end
    -- anything else rooted at a local: name the ROOT so the frontier is
    -- actionable. `deepcopy(gui_style_default.frame)` is not a data.raw base, but
    -- "copied out of local gui_style_default at .frame" is a fact a reader can
    -- follow, where basis='unknown' is a shrug.
    local root = expr.rootname(arg)
    if root then return { from_var = root, from_path = expr.dotted(arg) } end
    return { opaque = true }
end

--- A dotted assignment target rooted at a NAME: `chest.minable.result` →
--- 'chest', 'minable.result'. nil for anything else (an index target, a bare name).
local function target_path(e)
    local d = e and expr.dotted(e)
    if not d then return nil end
    local root, rest = d:match('^([%w_]+)%.(.+)$')
    return root, rest
end

--- A table literal's OWN top-level entries, as prototype overrides (CART-0220).
--- Returns (overrides, declared_type, own_name, unreadable_keys) or nil when `e` is
--- not a table.
---
--- THIS IS WHERE 82% OF THE ECOSYSTEM LIVES. Measured across 195 installed mods:
--- 3280 `data:extend` sites hand over an INLINE TABLE LITERAL against 594 that pass a
--- variable, so the base-copy-plus-overrides shape this module was built for — the one
--- Von-Neumann uses — is the minority everywhere else. Those keys used to be
--- unreadable ({k='table'} was an opaque allocation); the expression IR now models a
--- constructor entry as {k='pair', key, val}, so they are ordinary reads.
---
--- A LITERAL PROTOTYPE CARRIES ITS OWN DISCRIMINATOR in `type=`, exactly as a copied
--- one carries it in `data.raw[<type>][<name>]` — so the property check stays exact for
--- both shapes and needs no inference either way.
---
--- A COMPUTED KEY is counted, never guessed: `key.k == 'lit'` means the property name
--- is known, and anything else (`{[x] = 1}`) is reported as unreadable so the record
--- stays an honest lower bound instead of silently dropping an entry.
-- THE NESTED WALK (CART-0633). Factorio's data stage is deeply nested — a prototype
-- holds `working_sound = {…}` (a WorkingSound), `animation = {layers = {{hr_version =
-- …}}}` (an Animation) — and every property inside those was invisible, because this
-- reader stopped at depth 1. 2.0 removed `hr_version` from all seven sprite/animation
-- types and the data-stage diff was silent on 24 sites in one mod.
--
-- ★ ARRAYS ARE TRANSPARENT, deliberately. `layers` is an `Animation[]`, so every
-- element has the ELEMENT type and adds no name to the path: `animation.layers.
-- hr_version`, not `animation.layers.1.hr_version`. The consumer resolves the path
-- down the declared type chain, where the array step is already transparent
-- (prototypedistill's `prop_type` unwraps it), and an index segment would only have
-- to be stripped again. Each element still yields its OWN entry with its own line, so
-- three sibling sprites give three rows a reader can open.
--
-- ⚠ EMITTED AS A SEPARATE LIST, not folded into `fields`. Several consumers count
-- `fields` (the symbols pane, the prototype report) and silently tripling those
-- counts to serve one new question is how a number stops meaning what its readers
-- think. `nested` is depth >= 2 only; `fields` keeps its depth-1 contract exactly.
local NEST_DEPTH, NEST_CAP = 6, 400

local function nested_walk(e, prefix, depth, out, line)
    if depth > NEST_DEPTH or #out >= NEST_CAP then return end
    for _, kid in ipairs(e.kids or {}) do
        if #out >= NEST_CAP then return end
        -- 0-BASED IN THE IR, 1-BASED FOR A READER (expr.lua:419). Getting this wrong
        -- sends someone to the line above the one that is wrong, which reads as the
        -- tool being confused rather than as an off-by-one.
        -- ⚠ THROUGH THE ACCESSOR. This first read `kid.at.start` and `.line` in two
        -- steps, which slipped past the seam-guard's `%.start%.line` pattern by
        -- accident — a raw read of a foldable representation is a violation however it
        -- is spelled, and splitting the expression only hid it.
        local kline = (kid.at and (atr.sl(kid.at) + 1)) or line
        if kid.k == 'pair' then
            local key = kid.key
            if key and key.k == 'lit' and type(key.v) == 'string' then
                local path = prefix .. key.v
                local v, why = literal(kid.val)
                out[#out + 1] = { path = path, value = v, why = why, line = kline,
                    ty = kid.val and kid.val.ty or nil }
                if kid.val and kid.val.k == 'table' then
                    nested_walk(kid.val, path .. '.', depth + 1, out, kline)
                end
            end
        elseif kid.k == 'table' then
            -- an ARRAY ELEMENT: same prefix, one level deeper
            nested_walk(kid, prefix, depth + 1, out, kline)
        end
    end
end

local function literal_fields(e, line)
    if not (e and e.k == 'table') then return nil end
    local ovs, ty, own, unreadable = {}, nil, nil, 0
    local nested = {}
    for _, kid in ipairs(e.kids or {}) do
        if kid.k == 'pair' then
            local key = kid.key
            if key and key.k == 'lit' and type(key.v) == 'string' then
                local prop = key.v
                local v, why = literal(kid.val)
                ovs[#ovs + 1] = { path = prop, value = v, why = why, line = line,
                    ty = kid.val and kid.val.ty or nil }
                if prop == 'type' and v then ty = v end
                if prop == 'name' and v then own = v end
                if kid.val and kid.val.k == 'table' then
                    nested_walk(kid.val, prop .. '.', 2, nested, line)
                end
            else
                unreadable = unreadable + 1
            end
        end
    end
    return ovs, ty, own, unreadable, nested
end

-- ── the reading ─────────────────────────────────────────────────────────────

--- Prototypes declared in one module. Returns a list, source-ordered, or nil when
--- the adapter does not apply / the module cannot be harvested.
---
--- Each entry:
---   var        the local the prototype is built in (nil for a direct patch)
---   line       where it starts
---   base       { type, name } it was copied from, or nil (a literal / unknown)
---   basis      'copy' | 'literal' | 'patch' | 'unknown'
---   patch      { type, name } when this OVERRIDES an existing prototype in place
---   overrides  ordered { path, value, ty, why, line } — MUTATIONS after construction
---   fields     a LITERAL's own constructor entries, same shape (CART-0220). Kept
---              separate from `overrides` because they are construction, not mutation
---   declared_type  the literal's own `type=` — its discriminator, as `base.type` is
---              for a copied one
---   unreadable_keys  how many entries had a COMPUTED key, so the record stays an
---              honest lower bound
---   name       the prototype's own name, when a literal override supplied it
---   registered { line } | nil
---   frontiers  { { kind='mutator', callee, line } }
---   complete   false when a frontier means the overrides are a lower bound
function M.of_module(store, mod_id)
    local ad = M.adapter(store)
    if not ad then return nil end
    local eo = expr.of_module(store, mod_id)
    if not eo then return nil end

    local protos, by_var, order = {}, {}, 0
    -- local -> { proto, path } for a local bound INTO a prototype (CART-0642)
    local aliases = {}
    local function fresh(var, line, basis)
        order = order + 1
        local p = { var = var, line = line, basis = basis, overrides = {},
            nested = {}, elements = {}, frontiers = {}, complete = true, ord = order }
        protos[#protos + 1] = p
        if var then by_var[var] = p end
        return p
    end

    for _, st in ipairs(eo.fl.stmts or {}) do
        local e, line = st.expr, st.l
        if e then
            -- 1. a DECLARATION that starts a prototype
            local lhs1 = (e.lhs or {})[1]
            local rhs1 = (e.rhs or {})[1]
            if lhs1 and lhs1.k == 'name' and rhs1 then
                local cp = copy_of(rhs1, ad)
                if cp and cp.base then
                    fresh(lhs1.n, line, 'copy').base = cp.base
                elseif cp and cp.from_var then
                    -- a copy of a LOCAL. If we are tracking it, this is a
                    -- DERIVATION and inherits its base transitively; if not, the
                    -- basis NAMES the local so the frontier is actionable (the
                    -- gui-style pattern: `local d = data.raw['gui-style'].default`
                    -- then copies out of `d`, registered by assigning back INTO
                    -- it rather than via the registrar — a second registration
                    -- model, deliberately not read here).
                    local src = by_var[cp.from_var]
                    local p = fresh(lhs1.n, line, src and 'derived' or 'copy-unresolved')
                    p.from_var, p.from_path = cp.from_var, cp.from_path
                    if src then p.base = src.base end
                elseif cp then
                    fresh(lhs1.n, line, 'unknown') -- a copy of something else
                elseif rhs1.k == 'table' then
                    -- a LITERAL prototype. Its fields used to be invisible ({k='table'}
                    -- was an opaque allocation); the IR now models constructor entries,
                    -- so they are read here and the basis says so.
                    local ovs, ty, own, bad, nst = literal_fields(rhs1, line)
                    local p = fresh(lhs1.n, line, 'literal')
                    -- `fields` NOT `overrides`: this module's model is a base plus an
                    -- ORDERED SEQUENCE OF OVERRIDES, and a literal's own keys are its
                    -- CONSTRUCTION, not a later mutation. Merging them would silently
                    -- redefine `overrides` for every existing consumer — measured: it
                    -- shifted overrides[1] and broke four specs that index it.
                    p.fields = ovs or {}
                    p.nested = nst or {}
                    p.declared_type, p.name = ty, own
                    -- keep the literal so a later `data:extend(thatLocal)` can descend
                    -- into an ARRAY of prototypes (CART-0637 step 2)
                    p._lit = rhs1
                    p.unreadable_keys = bad
                elseif rhs1 and (rhs1.k == 'field' or rhs1.k == 'index') then
                    -- ── AN ALIAS INTO A PROTOTYPE'S INTERIOR (CART-0642) ─────────
                    -- `local layers = assembling_machine.animation.layers`. The
                    -- prototype is tracked; `layers` is not, so every later write
                    -- THROUGH it — `layer1.hr_version.filename = …` — had a target
                    -- root of an ordinary local and nothing tied it back. Five sites
                    -- in Von-Neumann, THREE OF THEM LOAD-FATAL: they index a table
                    -- 2.0 removed, which errors on load rather than going nowhere
                    -- silently like a missed write.
                    --
                    -- ★ ONE HOP, AND DELIBERATELY NOT ALIAS ANALYSIS. The root must
                    -- be a tracked prototype and the path must be readable as dotted
                    -- text; anything else is left alone rather than guessed at.
                    local d = expr.dotted(rhs1)
                    local aroot = d and d:match('^([%w_]+)%.')
                    local ap = d and d:match('^[%w_]+%.(.+)$')
                    if aroot and ap and by_var[aroot] then
                        local tgt = by_var[aroot]
                        aliases[lhs1.n] = { proto = tgt, path = ap, line = line }
                        -- ★ AND THE PATH ITSELF IS A FACT ABOUT THE PROTOTYPE
                        -- (CART-0643). Reaching into `<proto>.animation.layers` READS
                        -- every hop on the way; if the target removed one, the read
                        -- indexes nil and STOPS THE LOAD. That is worse than the
                        -- writes this module was built to check, which fail silently.
                        -- Recorded on the prototype rather than returned separately,
                        -- because `of_module` returns a flat list and every consumer
                        -- indexes it.
                        tgt.reached = tgt.reached or {}
                        tgt.reached[#tgt.reached + 1] = { path = ap, line = line,
                            var = lhs1.n }
                    end
                end
            end

            -- 2. a FIELD OVERRIDE on a tracked var, or a direct PATCH of a base
            for _, l in ipairs(e.lhs or {}) do
                local root, path = target_path(l)
                local p = root and by_var[root]
                if not p and root and aliases[root] and path then
                    -- resolved through the alias: the write is on the PROTOTYPE, at
                    -- the alias's path joined to this one
                    local a = aliases[root]
                    p, path = a.proto, a.path .. '.' .. path
                end
                if p and path then
                    local v, why = literal((e.rhs or {})[1])
                    p.overrides[#p.overrides + 1] = { path = path, value = v,
                        ty = (e.rhs or {})[1] and (e.rhs or {})[1].ty or nil,
                        why = why, line = line }
                    if path == 'name' and v then p.name = v end
                elseif l.k == 'index' and l.b and l.b.k == 'name' and by_var[l.b.n]
                    and (e.rhs or {})[1] and (e.rhs or {})[1].k == 'table' then
                    -- ── ACCUMULATE-THEN-REGISTER (CART-0640) ────────────────────
                    -- `local t = {}` … `t[#t+1] = { type = "item", … }` …
                    -- `data:extend(t)`. The table is EMPTY at its declaration, so it
                    -- recorded one entry-less literal and the registration made it a
                    -- single untyped prototype — while the elements sat in the file
                    -- as ordinary literals. Collected here as ELEMENTS, minted at the
                    -- registration site (where `data:extend` proves they are
                    -- prototypes rather than a list of anything else).
                    --
                    -- ⚠ DISTINGUISHED FROM `data.raw[t][n].f = v` BY THE BASE: that
                    -- one's base is a field/index CHAIN, this one's is a tracked
                    -- local. Same node kind, different fact.
                    local pp = by_var[l.b.n]
                    pp.elements[#pp.elements + 1] = { expr = (e.rhs or {})[1],
                        line = line }
                elseif l.k == 'field' or l.k == 'index' then
                    -- `data.raw[t][n].field = v` — an in-place patch of an
                    -- EXISTING prototype, no local involved. Walk out to the
                    -- data.raw[t][n] part and record the rest as the path.
                    local seg, cur = {}, l
                    while cur and (cur.k == 'field' or cur.k == 'index') do
                        local ty, nm = base_ref(cur, ad)
                        if ty then
                            local pp = fresh(nil, line, 'patch')
                            pp.patch = { type = ty, name = nm }
                            local v, why = literal((e.rhs or {})[1])
                            -- reverse in place (the walk collected outermost
                            -- first). math.floor, not `//`: luajit is 5.1.
                            for i = 1, math.floor(#seg / 2) do
                                seg[i], seg[#seg - i + 1] = seg[#seg - i + 1], seg[i]
                            end
                            -- `ty` too, so a PATCH override has the same record
                            -- shape as a tracked-var one. Without it a consumer
                            -- cannot tell `x.p = nil` (a deletion) from an
                            -- unreadable value on a patch while it can on every
                            -- other basis — the asymmetry that makes a downstream
                            -- check silently wrong on exactly one branch.
                            pp.overrides[1] = { path = table.concat(seg, '.'),
                                value = v, why = why, line = line,
                                ty = (e.rhs or {})[1] and (e.rhs or {})[1].ty or nil }
                            break
                        end
                        seg[#seg + 1] = cur.n or '[]'
                        cur = cur.b
                    end
                end
            end

            -- 3. a CALL: the registrar, or an opaque mutator. Which vars it
            -- touches comes from du's read census, because the IR models the
            -- table constructor as an opaque allocation.
            if rhs1 and rhs1.k == 'call' and not (e.lhs or {})[1] then
                local d = expr.dotted(rhs1.f)
                local touched = {}
                for _, u in ipairs(st.use or {}) do
                    if by_var[u] then touched[#touched + 1] = by_var[u] end
                end
                if d and ad.registrar[d] then
                    -- ── WHAT IS REGISTERED vs WHAT IS MENTIONED (CART-0639) ──────
                    -- `touched` is every tracked local appearing ANYWHERE in the
                    -- statement, and this branch used to treat it as "the things
                    -- being registered". It is not. In
                    --     data:extend({{ type="gun", …, sound = heavygunshotsounds }})
                    -- the helper is merely REFERENCED by a prototype, and the old
                    -- reading did two wrong things with it at once: marked the helper
                    -- `registered`, and — because `#touched == 0` was then false —
                    -- SKIPPED THE INLINE EXPANSION ENTIRELY, so every real prototype
                    -- in the call went unrecorded. Aircraft-space-age's items.lua has
                    -- 27 `type=` declarations and produced 0 typed records; its only
                    -- output was the four sound helpers that caused the loss.
                    --
                    -- ★ THE ARGUMENT IS THE ANSWER. Read the registrar's first
                    -- argument and nothing else: a table literal is the group, a name
                    -- is the record it resolves to. Every other local in the statement
                    -- is a reference and gets no registration.
                    local arg = (rhs1.a or {})[1]
                    local made = 0
                    if arg and arg.k == 'table' then
                        -- ⚠ AN ELEMENT IS A LITERAL **OR** A NAME, and both are being
                        -- registered. `data:extend{a, b}` — two locals built earlier
                        -- and handed over together — is the shape `touched` was
                        -- originally written for, and dispatching only on `table`
                        -- kids silently dropped it. That is what the spec caught:
                        -- narrowing from "every local in the statement" to "the
                        -- argument" is right, but the argument's ELEMENTS still name
                        -- records, and they are registered exactly as much as an
                        -- inline literal is.
                        for _, kid in ipairs(arg.kids or {}) do
                            if kid.k == 'table' then
                                local kl = (kid.at and (atr.sl(kid.at) + 1)) or line
                                local ovs, ty, own, bad, nst = literal_fields(kid, kl)
                                local pr = fresh(nil, kl, 'literal')
                                pr.fields, pr.declared_type, pr.name = ovs or {}, ty, own
                                pr.nested, pr.unreadable_keys = nst or {}, bad
                                pr.registered = { line = line }
                                made = made + 1
                            elseif kid.k == 'name' and by_var[kid.n] then
                                by_var[kid.n].registered = { line = line }
                                made = made + 1
                            end
                        end
                    elseif arg and arg.k == 'name' and by_var[arg.n] then
                        -- registered BY NAME. If it is an array of typed prototypes,
                        -- its elements are the prototypes (CART-0637); otherwise the
                        -- record itself is what was registered.
                        local p = by_var[arg.n]
                        local kids = (not p.declared_type) and p._lit
                            and p._lit.k == 'table' and p._lit.kids or nil
                        local expanded = 0
                        -- ELEMENTS ACCUMULATED INTO THE LOCAL (CART-0640) are minted
                        -- HERE, not where they were assigned: `data:extend(t)` is what
                        -- proves the list holds prototypes. A table filled the same way
                        -- and never registered stays what it is — a list.
                        for _, el in ipairs(p.elements or {}) do
                            local ovs, ty, own, bad, nst = literal_fields(el.expr, el.line)
                            if ty then
                                local c = fresh(nil, el.line, 'literal')
                                c.fields, c.declared_type, c.name = ovs or {}, ty, own
                                c.nested, c.unreadable_keys = nst or {}, bad
                                c.registered = { line = line }
                                expanded = expanded + 1
                            end
                        end
                        for _, kid in ipairs(kids or {}) do
                            if kid.k == 'table' then
                                local kl = (kid.at and (atr.sl(kid.at) + 1)) or p.line
                                local ovs, ty, own, bad, nst = literal_fields(kid, kl)
                                -- ⚠ ONLY IF THE ELEMENT DECLARES A TYPE. Descending
                                -- into a helper would mint prototypes out of sound
                                -- variations and sprite layers.
                                if ty then
                                    local c = fresh(nil, kl, 'literal')
                                    c.fields, c.declared_type, c.name = ovs or {}, ty, own
                                    c.nested, c.unreadable_keys = nst or {}, bad
                                    c.registered = { line = line }
                                    expanded = expanded + 1
                                end
                            end
                        end
                        if expanded > 0 then p.container = expanded end
                        p.registered = { line = line }
                        made = expanded + 1
                    end
                    if made == 0 then
                        -- registered something we could not read at all (a call, a
                        -- name we never tracked): recorded, not dropped
                        local pr = fresh(nil, line, 'literal')
                        pr.registered = { line = line }
                        pr.anonymous = true
                    end
                elseif d and (ad.append_tail or {})[d:match('([%w_]+)$') or ''] then
                    -- `table.insert(t, {…})` — the append half of accumulate-then-
                    -- register. The literal handed over IS the element, so this is a
                    -- read, not a frontier: an append verb whose second argument we
                    -- can see does not make the list opaque.
                    -- ⚠ AND IT IS ONLY THIS SHAPE. `table.insert(t, factory(x))` still
                    -- falls through to the opaque-call branch below, because the
                    -- element's content is in another function — measured, that is
                    -- roughly half of this bucket and it does not move.
                    local tgt = (rhs1.a or {})[1]
                    local val = (rhs1.a or {})[2]
                    if tgt and tgt.k == 'name' and by_var[tgt.n]
                        and val and val.k == 'table' then
                        local pp = by_var[tgt.n]
                        pp.elements[#pp.elements + 1] = { expr = val, line = line }
                    else
                        for _, p in ipairs(touched) do
                            p.frontiers[#p.frontiers + 1] =
                                { kind = 'opaque-call', callee = d, line = line }
                            p.complete = false
                        end
                    end
                elseif d then
                    for _, p in ipairs(touched) do
                        -- 'opaque-call', not 'mutator': we do NOT know it
                        -- mutates (`log(x)` almost certainly does not). The
                        -- claim is only that lua passes tables by reference so
                        -- we cannot RULE OUT a rewrite. Naming it a mutator
                        -- would assert more than the reading knows.
                        p.frontiers[#p.frontiers + 1] =
                            { kind = 'opaque-call', callee = d, line = line }
                        p.complete = false
                    end
                end
            end
        end
    end
    -- THE DISCRIMINATOR CAN ARRIVE LATE. Von-Neumann writes `local cage_sound = {}`
    -- and then `cage_sound.type = "sound"`, so the typename is an OVERRIDE rather than
    -- a constructor entry — same fact, one line later. Read it from either, since
    -- without it a record has no property set to be checked against.
    if ad.type_key then
        for _, p in ipairs(protos) do
            if not p.declared_type then
                for _, list in ipairs({ p.fields or {}, p.overrides or {} }) do
                    for _, ov in ipairs(list) do
                        if ov.path == ad.type_key and type(ov.value) == 'string' then
                            p.declared_type = ov.value
                            break
                        end
                    end
                    if p.declared_type then break end
                end
            end
        end
    end
    return protos
end

--- Every prototype in the graph, grouped by module. { {file, protos}, ... },
--- file-ordered. nil when the adapter does not apply.
function M.all(store)
    if not M.adapter(store) then return nil end
    local out = {}
    for _, n in ipairs((store.data or {}).nodes or {}) do
        if n.kind == 'module' then
            local ps = M.of_module(store, n.id)
            if ps and #ps > 0 then out[#out + 1] = { file = n.file, protos = ps } end
        end
    end
    table.sort(out, function (a, b) return (a.file or '') < (b.file or '') end)
    return out
end

-- ── the browser's view of the reading (the COMPARTMENT pilot) ────────────────
-- The reading was a report first: `M.report` formats these same records into
-- strings. A browser altitude is a SECOND consumer of the records, not a second
-- reading ([[cartograph-interactive-reports]]) — which is why the only thing
-- needed here is an addressable KEY per prototype.

local KEYSEP = '\31'

--- A stable key for one prototype: its module plus its position in that module's
--- ordered list. Invertible by construction, because an altitude's key IS its own
--- inverse ([[cartograph-navigation-model]]).
function M.key(file, idx) return ('%s%s%d'):format(file, KEYSEP, idx) end

--- key -> (record, file, idx). nil when the key no longer names a prototype (the
--- file changed under us) — the caller must SAY that rather than render an empty
--- prototype, which would read as "this one has no fields".
function M.at(store, key)
    local file, idx = (key or ''):match('^(.-)' .. KEYSEP .. '(%d+)$')
    if not file then return nil end
    local ps = M.of_module(store, file)
    if not ps then return nil end
    return ps[tonumber(idx)], file, tonumber(idx)
end

--- The UNCOMPUTED half of the typed empty: why the data stage may have no answer
--- here at all. nil when the reading applies, so a caller can write
--- `unavailable(store) or '(no prototypes declared)'` and never conflate the two.
function M.unavailable(store)
    if not M.adapter(store) then
        return 'no data stage here — the prototype reading activates on an env'
            .. ' profile that has one (today: lua-factorio)'
    end
end

--- Census over M.all: how much of the data stage is READ vs hedged.
function M.census(store)
    local all = M.all(store)
    if not all then return nil end
    local c = { modules = #all, total = 0, registered = 0, hedged = 0,
        anonymous = 0, overrides = 0, nonliteral = 0, named = 0, basis = {} }
    for _, m in ipairs(all) do
        for _, p in ipairs(m.protos) do
            c.total = c.total + 1
            c.basis[p.basis] = (c.basis[p.basis] or 0) + 1
            if p.registered then c.registered = c.registered + 1 end
            if not p.complete then c.hedged = c.hedged + 1 end
            if p.anonymous then c.anonymous = c.anonymous + 1 end
            if p.name then c.named = c.named + 1 end
            c.overrides = c.overrides + #p.overrides
            for _, o in ipairs(p.overrides) do
                if o.value == nil then c.nonliteral = c.nonliteral + 1 end
            end
        end
    end
    return c
end

-- Rendering an override VALUE into a report line. A prototype field legitimately
-- holds a MULTI-LINE `[[…]]` string (Von-Neumann's storyText1 is four paragraphs),
-- and nvim_buf_set_lines REJECTS an embedded newline outright — so one story blob
-- killed the whole command. Fold to one line, and while here, say more than
-- tostring did: quoted, so the string "8000" is distinguishable from the number
-- 8000 that the reading DOES tell apart; ↵ for a fold, … for a truncation, so
-- neither is silent; and an explicit nil named as the DELETE it is.
local VALUE_WIDTH = 60
--- Truncate to `n` BYTES without splitting a UTF-8 sequence (this module stays
--- vim-free, and LuaJIT has no utf8 library): back off over continuation bytes.
local function cut(s, n)
    if #s <= n then return s end
    local i = n
    while i > 0 do
        local b = s:byte(i + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end   -- not a continuation
        i = i - 1
    end
    return s:sub(1, i)
end
local function render_value(o)
    if o.value == nil then return '<' .. tostring(o.why) .. '>' end
    if o.value == expr.NIL then return 'nil  (DELETE)' end
    if type(o.value) ~= 'string' then return tostring(o.value) end
    local s = o.value:gsub('[\r\n]+', '↵')
    if #s > VALUE_WIDTH then s = cut(s, VALUE_WIDTH - 3) .. '…' end
    return ('"%s"'):format(s)
end

--- The report: every prototype the data stage declares, grouped by file, with the
--- hedges inline. Lines, for the scratch buffer. `nil` when the adapter does not
--- apply — the caller reports THAT rather than an empty list, since "this is not
--- a Factorio project" and "this project declares no prototypes" are different
--- facts ([[cartograph-concern-layering]], typed empty).
function M.report(store)
    local all = M.all(store)
    if not all then return nil end
    local c = M.census(store)
    local out = { ('PROTOTYPES — %d in %d module(s), %d override(s)')
        :format(c.total, c.modules, c.overrides) }
    local bases = {}
    for b, n in pairs(c.basis) do bases[#bases + 1] = ('%s %d'):format(b, n) end
    table.sort(bases)
    out[#out + 1] = '  basis: ' .. table.concat(bases, ' · ')
    out[#out + 1] = ('  registered %d/%d · named %d · HEDGED %d · non-literal values %d')
        :format(c.registered, c.total, c.named, c.hedged, c.nonliteral)
    if c.hedged > 0 then
        out[#out + 1] = '  ~ HEDGED = an opaque call received the prototype, so its'
            .. ' overrides are a LOWER BOUND'
    end
    for _, m in ipairs(all) do
        out[#out + 1] = ''
        out[#out + 1] = m.file
        for _, p in ipairs(m.protos) do
            local what = p.var or (p.patch and ('%s/%s (in place)'):format(
                p.patch.type, p.patch.name)) or '(anonymous)'
            local line = ('  %-4d %-28s [%s]'):format(p.line, what, p.basis)
            if p.base then
                line = line .. (' <- %s/%s'):format(p.base.type, p.base.name)
            elseif p.from_path then
                line = line .. (' <- %s (unresolved)'):format(p.from_path)
            end
            if p.name then line = line .. ('  = %q'):format(p.name) end
            line = line .. (p.registered
                and ('  registered@%d'):format(p.registered.line)
                or '  NOT registered here')
            if not p.complete then line = line .. '  ~' end
            out[#out + 1] = line
            -- Overrides and frontiers INTERLEAVED by line. Printing all
            -- overrides then all frontiers put a hedge at line 48 below an
            -- override at line 51, which reads as if the hedge came after — and
            -- the whole point of the sequence is that position matters. Stable:
            -- overrides keep their relative order (later wins), a frontier sorts
            -- to the first override that follows it.
            local fi = 1
            local function frontiers_before(n)
                while fi <= #p.frontiers and (n == nil
                        or p.frontiers[fi].line <= n) do
                    local f = p.frontiers[fi]
                    out[#out + 1] = ('       %-4d ~ %s: %s — may have rewritten any'
                        .. ' field, so values below it are what the source ASSIGNS,'
                        .. ' not necessarily the final ones')
                        :format(f.line, f.kind, f.callee)
                    fi = fi + 1
                end
            end
            for _, o in ipairs(p.overrides) do
                frontiers_before(o.line)
                out[#out + 1] = ('       %-4d %-34s = %s')
                    :format(o.line, o.path, render_value(o))
            end
            frontiers_before(nil)
        end
    end
    return out
end

return M
