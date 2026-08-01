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
    copy_tail = { deepcopy = true },
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
---   overrides  ordered { path, value, ty, why, line }
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
    local function fresh(var, line, basis)
        order = order + 1
        local p = { var = var, line = line, basis = basis, overrides = {},
            frontiers = {}, complete = true, ord = order }
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
                    -- a literal prototype: its FIELDS are invisible to the IR
                    -- ({k='table'} is an opaque allocation), so the basis is
                    -- honest about being unread rather than reporting none
                    fresh(lhs1.n, line, 'literal')
                end
            end

            -- 2. a FIELD OVERRIDE on a tracked var, or a direct PATCH of a base
            for _, l in ipairs(e.lhs or {}) do
                local root, path = target_path(l)
                local p = root and by_var[root]
                if p and path then
                    local v, why = literal((e.rhs or {})[1])
                    p.overrides[#p.overrides + 1] = { path = path, value = v,
                        ty = (e.rhs or {})[1] and (e.rhs or {})[1].ty or nil,
                        why = why, line = line }
                    if path == 'name' and v then p.name = v end
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
                    if #touched == 0 then
                        -- registered something we never tracked (an inline
                        -- literal): recorded, not dropped
                        local p = fresh(nil, line, 'literal')
                        p.registered = { line = line }
                        p.anonymous = true
                    end
                    for _, p in ipairs(touched) do p.registered = { line = line } end
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
