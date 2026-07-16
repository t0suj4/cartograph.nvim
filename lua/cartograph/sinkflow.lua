-- SINKFLOW — taint rung 0 ([[cartograph-taint-analysis]]): a DIVERGENT
-- SQL-injection smell — one function string-concatenates a param into a
-- query-shaped SINK WITHOUT sanitizing it, while a SIBLING concatenates the
-- same shape into the same sink and DOES ("you defended the peer, not this
-- one"). The honest first rung — no inter-proc fixpoint, no ORM/sink-table.
--
-- The PEER IS REQUIRED, not decorative: it IS the evidence. Measured across
-- the PHP corpora, "unsanitized param -> sink" ALONE over-fires (a param is
-- not a source; untyped legacy code reads as uniformly unsanitized) — mantis
-- 37 FP, sylius 4 FP. Requiring the divergent peer took both to 0 while
-- keeping grocy's real vuln (a param is only suspicious when a peer proves the
-- author knew to defend it). Lone offenders are reachability's job (rung 2).
--
-- Two sanitizer classes: COERCION (scalar type hint / `(int)$x` cast) and
-- PARAMETERIZATION/ESCAPING (param()/db_param/bindValue/escapes — the dominant
-- safe channel; a bound param is not raw). The SINK is a `~` HYPOTHESIS (method
-- name / dangling-operator content / DB receiver), never confirmed — so every
-- finding says so.
--
-- Re-parses PHP on demand (the atlas.M.fields precedent): PHP param type hints
-- and the build-a-string-then-pass flow are not in the closed schema. PHP-only
-- in v1 (sanitizer notions are typed-/framework-specific; Lua would be noise).
--
-- RUNG 1 (M.source_findings, `sink-source` rule): a REQUEST SOURCE
-- ($_GET/$_POST/$_REQUEST/$_COOKIE/$_SERVER/$_FILES) reaching a SQL sink,
-- unsanitized — the classic vulnerable-script shape rung 0 can't see
-- (top-level, source not param, interpolation not just concat). NO peer
-- needed: a superglobal is definitionally tainted. Scope-aware forward taint
-- (fixpoint over each scope's assignments; top-level scripts + each function),
-- carrying whether taint has been EMBEDDED in SQL-carrying string text — only
-- string-embedded taint at a sink is injection (a bare tainted value passed
-- standalone is a bound parameter, e.g. LessQL `where('col', $v)`; that
-- distinction is what keeps it quiet on grocy/mantis/sylius). Sanitizers as
-- rung 0 + scalar casts. Validated on DVWA: the sqli low/impossible gradient
-- (low fires, impossible silent); grocy/mantis/sylius 0.
--
-- RUNG 1.5: FRAMEWORK request sources (a controller action — a *Request*-typed
-- param — treats its Request + array/route-arg params as external input) +
-- GUARD sanitizers via CFG-phase-1 DOMINANCE ([[cartograph-cfg-scope]]): a
-- value is sanitized only when a validator on it (IsIsoDate/filter_var/
-- is_numeric/…) guards it on a DOMINATING path — positive nesting
-- (`if(valid($x)){…sink…}`) OR an early-exit guard-clause
-- (`if(!valid($x)){return}` then …sink…), with conjunct/negation soundness
-- (no `||` for positive, negated validator for early-exit). Flow-sensitive,
-- unlike the old scope-wide "validated anywhere" set: a branch-split (validate
-- in A, use raw in B) correctly FIRES, and a guard-clause correctly SUPPRESSES.
-- grocy Spendings validates the model both ways in one method (IsIsoDate-guarded
-- date suppressed; unguarded product_group fires).
--
-- RUNG 2 (inter-procedural cross-function taint) is NOT here: a standalone
-- re-parse prototype worked (confirmed grocy's keystone: route arg ->
-- GetProductStockLocations -> sink) but re-derived the resolved call graph,
-- types, and SCC fixpoint the graph-VM + effects.summaries already own — to be
-- re-founded on that substrate (resolved c.to + scc.lua + VM types; embedding
-- shape as EXTRACTED facts). See [[cartograph-taint-analysis]].
--
-- The sink hypothesis (sink_reason) is EXACT (SQL_METHODS + *query suffix + DB
-- receiver): substring matching mismatches non-SQL names (print_date_selection_set,
-- shell_exec) — measured on mantis (1887 fns).

local M = {}

local cfg = require 'cartograph.cfg'

local function txt(n, src) return vim.treesitter.get_node_text(n, src) end

-- all descendant nodes of the given types (named only)
local function collect(node, types)
    local want, acc = {}, {}
    for _, t in ipairs(types) do want[t] = true end
    local function rec(n)
        if want[n:type()] then acc[#acc + 1] = n end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(node)
    return acc
end

-- COERCION SANITIZER = a per-LANGUAGE fact ([[cartograph-taint-analysis]],
-- "TYPE DECIDES THE REGIME"). The question is NOT "is this a primitive type?"
-- but "does a primitive TYPE ANNOTATION rewrite the value at runtime, so it
-- CLEARS taint?" — and that is true only in languages that COERCE:
--   • PHP scalar hints coerce: `int $x` turns "5 OR 1=1" into the int 5 (or
--     TypeErrors in strict mode) — no SQL metacharacter survives. So a
--     scalar-typed param is a genuine sanitizer. Casts `(int)$x` coerce too.
--   • TypeScript / Flow annotations are ERASED at runtime — `x: number` is a
--     compile-time promise the runtime does NOT enforce (any / `as` casts /
--     untyped JS callers / JSON.parse all defeat it). A type there sanitizes
--     NOTHING; it is at most a `~` hint. So JS/TS is intentionally ABSENT below.
-- DEFAULT for an unconfigured language = {} (no coercive types) → a type can
-- never drop taint → SOUND (a missing entry causes false positives at worst,
-- never a false negative). A future JS/TS rung inherits the correct behaviour
-- for free; adding a language means declaring whether/what it coerces.
local COERCION = {
    php = { int = true, float = true, bool = true }, -- the valid scalar hints;
    -- cast_ancestor also accepts the (integer)/(boolean) cast spellings
    -- javascript = {} / typescript = {}  -- erased annotations, no coercion
}
-- sinkflow is PHP-only in v1; the PHP coercive-type set (type hints + casts)
local SCALAR = COERCION.php

-- parameterization / escaping wrappers: a param passed to one of these is
-- bound or escaped, NOT concatenated raw — the dominant sanitizer in
-- well-written code (mantis's db_param / $query->param, PDO bindValue, the
-- escape family). A reference enclosed by one of these is not a taint source.
local PARAMETERIZE = { param = true, db_param = true, bindvalue = true,
    bindparam = true, quote = true, escape = true, addslashes = true,
    real_escape_string = true, mysqli_real_escape_string = true,
    intval = true, floatval = true }

local function callee_name(call, src)
    local nf = call:field('name')[1] or call:field('function')[1]
    return nf and txt(nf, src):lower() or nil
end

-- is this variable_name occurrence enclosed (up to `root`) by a
-- parameterizing/escaping call?
local function protected_ref(v, root, src)
    local p = v:parent()
    while p do
        local t = p:type()
        if t == 'member_call_expression' or t == 'function_call_expression'
            or t == 'scoped_call_expression' then
            local cn = callee_name(p, src)
            if cn and PARAMETERIZE[cn] then return true end
        end
        if p == root then break end
        p = p:parent()
    end
    return false
end

-- params of a fn node: name -> { scalar = bool } (scalar type hint = the
-- coercion sanitizer). Text-based on each parameter node: robust across the
-- grammar's `type`/no-field shapes.
local function param_info(fnnode, src)
    local info = {}
    local fp
    for c in fnnode:iter_children() do
        if c:type() == 'formal_parameters' then fp = c break end
    end
    if not fp then return info end
    for p in fp:iter_children() do
        local t = p:type()
        if p:named() and (t == 'simple_parameter'
            or t == 'property_promotion_parameter' or t == 'variadic_parameter') then
            local pt = txt(p, src)
            local ty, nm = pt:match('^%s*%??%s*([%a_\\]+)%s+%$([%w_]+)')
            if not nm then nm = pt:match('%$([%w_]+)') end
            if nm then info[nm] = { scalar = ty ~= nil and SCALAR[ty] or false } end
        end
    end
    return info
end

-- first string-literal text inside a node (the concat "prefix")
local function prefix_of(node, src)
    for _, s in ipairs(collect(node, { 'string', 'encapsed_string', 'string_content' })) do
        local t = txt(s, src):gsub('^["\']', ''):gsub('["\']$', '')
        if t ~= '' then return t end
    end
    return nil
end

-- an inline scalar CAST applied to $name (calls like intval() are handled
-- by PARAMETERIZE/protected_ref; this is the `(int)$x` cast syntax)
local function cast_sanitized(text, name)
    local e = '%$' .. name:gsub('(%W)', '%%%1')
    return text:find('%(%s*int[eger]*%s*%)%s*' .. e) ~= nil
        or text:find('%(%s*float%s*%)%s*' .. e) ~= nil
        or text:find('%(%s*bool[ean]*%s*%)%s*' .. e) ~= nil
end

-- Does `node` (a call argument) carry a taint source — a PARAM, or a LOCAL
-- built from a param-concat (one hop) — reaching it through string concat?
-- Returns { param, prefix, sanitized } or nil. `locals` maps name->that hit.
local function taint_in(node, src, params, locals)
    -- a bare local that is itself a param-concat
    if node:type() == 'variable_name' then
        return locals[txt(node, src):gsub('^%$', '')]
    end
    -- otherwise: must be a concat referencing a param directly or a taint-local
    local bins = node:type() == 'binary_expression' and { node }
        or collect(node, { 'binary_expression' })
    if #bins == 0 then return nil end
    local has_concat = false
    for _, b in ipairs(bins) do if txt(b, src):find('%.') then has_concat = true end end
    if not has_concat then return nil end
    for _, v in ipairs(collect(node, { 'variable_name' })) do
        local nm = txt(v, src):gsub('^%$', '')
        -- a reference bound/escaped by a parameterizing wrapper is not raw
        if (params[nm] or locals[nm]) and not protected_ref(v, node, src) then
            if params[nm] then
                local text = txt(node, src)
                return { param = nm, prefix = prefix_of(node, src),
                    sanitized = params[nm].scalar or cast_sanitized(text, nm) }
            else
                return locals[nm]
            end
        end
    end
    return nil
end

local function process_fn(fnnode, src, file, fname, out)
    local params = param_info(fnnode, src)
    if next(params) == nil then return end

    -- local -> its param-concat hit (one hop), from `=` and `.=`
    local locals = {}
    for _, a in ipairs(collect(fnnode,
        { 'assignment_expression', 'augmented_assignment_expression' })) do
        local lhs, rhs = a:field('left')[1], a:field('right')[1]
        if lhs and rhs and lhs:type() == 'variable_name' then
            local hit = taint_in(rhs, src, params, locals)
            if hit then locals[txt(lhs, src):gsub('^%$', '')] = hit end
        end
    end

    for _, call in ipairs(collect(fnnode,
        { 'member_call_expression', 'function_call_expression', 'scoped_call_expression' })) do
        local namef = call:field('name')[1] or call:field('function')[1]
        local callee = namef and txt(namef, src) or '?'
        local objf = call:field('object')[1]
        local receiver = objf and txt(objf, src) or nil
        local argsn = call:field('arguments')[1]
        for arg in (argsn and argsn:iter_children() or function () end) do
            if arg:named() and arg:type() == 'argument' then
                local av = arg:named_child(0) or arg
                local hit = taint_in(av, src, params, locals)
                if hit then
                    out[#out + 1] = { file = file, fn = fname, callee = callee,
                        receiver = receiver, prefix = hit.prefix,
                        param = hit.param, sanitized = hit.sanitized or false,
                        line = select(1, call:range()) + 1 }
                end
            end
        end
    end
end

--- Every candidate egress across the PHP corpus (sanitized + not).
function M.candidates(store)
    local out = {}
    for _, file in ipairs(store.files or {}) do
        if file:match('%.php$') then
            local path = store.abs(file)
            local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path)
            if lines then
                local src = table.concat(lines, '\n')
                local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'php')
                if ok and parser then
                    local root = parser:parse()[1]:root()
                    for _, fn in ipairs(collect(root,
                        { 'function_definition', 'method_declaration' })) do
                        local nf = fn:field('name')[1]
                        process_fn(fn, src, file, nf and txt(nf, src) or '?', out)
                    end
                end
            end
        end
    end
    return out
end

-- SQL sink callees, EXACT (lowercased). Substring matching ('select'/'where'
-- as fragments) matches UI/helper names (print_date_selection_set) — measured
-- FP source on mantis (1887 fns). Exact also excludes shell_exec/system
-- cleanly (command injection ≠ SQL).
-- Suffix `*query` catches the wrapper family (ExecuteDbQuery, rawQuery).
local SQL_METHODS = {
    query = true, exec = true, execute = true, prepare = true,
    where = true, having = true, orwhere = true, andwhere = true,
    wherein = true, whereraw = true, executestatement = true,
    executedbstatement = true, mysqli_query = true, mysql_query = true,
    pg_query = true, sqlite_query = true, db_query = true,
}

-- a raw-SQL METHOD name (the strong sink signal): a query verb or a *query
-- wrapper suffix. Deliberately NOT the DB-receiver catch-all — an ORM
-- insert/update on a DB object (LessQL createRow, `->users()`) is
-- PARAMETERIZED, and a receiver-only hypothesis mislabels it a raw sink (the
-- grocy TrackChore FP). rung 2 keys sinks on this alone.
local function is_sql_method(callee)
    local cl = callee:lower()
    return SQL_METHODS[cl] or cl:find('query$') ~= nil or cl:find('_query$') ~= nil
end

-- the `~`-tier sink hypothesis: returns the reason string, or nil
local function sink_reason(c)
    if is_sql_method(c.callee) then
        return ("method '%s'"):format(c.callee)
    end
    local r = c.receiver and c.receiver:lower()
    if r and (r:find('database') or r:find('->db') or r:find('pdo')) then
        return 'DB receiver'
    end
    return nil
end

--- Lint findings: unsanitized candidates that pass the sink hypothesis,
--- with an opportunistic peer-divergence annotation.
function M.findings(store)
    local cands = M.candidates(store)
    -- peer index: (callee, first prefix token) -> a SANITIZED peer fn
    local sanpeer = {}
    for _, c in ipairs(cands) do
        if c.sanitized and c.prefix then
            local tok = c.prefix:match('([%w_]+)')
            if tok then sanpeer[c.callee .. '\31' .. tok] = c.fn end
        end
    end
    local out = {}
    for _, c in ipairs(cands) do
        -- rung 0 REQUIRES a sanitizing peer: the divergence IS the evidence.
        -- "unsanitized param → sink" alone over-fires (a param is not a
        -- source; untyped legacy code reads as uniformly unsanitized) — that
        -- is rung 2's (reachability) job. The peer is what makes this `~`
        -- honest without inter-proc analysis.
        local why = not c.sanitized and sink_reason(c)
        local tok = why and c.prefix and c.prefix:match('([%w_]+)')
        local peer = tok and sanpeer[c.callee .. '\31' .. tok]
        if why and peer and peer ~= c.fn then
            out[#out + 1] = { file = store.abs(c.file), line = c.line,
                message = ('possible SQL injection (~, sink unconfirmed): '
                    .. 'unsanitized param $%s concatenated into %s [%s] — peer '
                    .. '%s() sanitizes the same shape (defended the peer, not this one)')
                    :format(c.param, c.callee ~= '?'
                        and ('sink %s()'):format(c.callee) or 'a query', why, peer) }
        end
    end
    return out
end

-- ── taint rung 1: a REQUEST SOURCE reaching a SQL sink ──────────────────
-- Unlike rung 0, a superglobal is DEFINITIONALLY tainted, so no peer is
-- needed — the source IS the evidence. Interpolation (`"…'$id'"`) and
-- concatenation are both covered for free: a taint carrier is any tainted
-- `variable_name` descendant of the arg, whatever the embedding. Scope-aware
-- forward propagation ($id = $_GET[…]; $q = "… $id"; query($q)); handles the
-- top-level (function-less) scripts that are the classic injection shape and
-- that rung 0 cannot see.

local SOURCES = { _GET = true, _POST = true, _REQUEST = true,
    _COOKIE = true, _SERVER = true, _FILES = true }

local BODY_STOP = { function_definition = true, method_declaration = true,
    anonymous_function = true, arrow_function = true }

-- descendants of `node` of the given types, NOT descending into nested
-- function scopes (a scope sees only its own statements)
local function collect_scoped(node, types)
    local want, acc = {}, {}
    for _, t in ipairs(types) do want[t] = true end
    local function rec(n, top)
        if not top and BODY_STOP[n:type()] then return end
        if want[n:type()] then acc[#acc + 1] = n end
        for c in n:iter_children() do if c:named() then rec(c, false) end end
    end
    rec(node, true)
    return acc
end

-- a scalar cast (int/float/bool) enclosing `v` up to `root` — sanitizes
local function cast_ancestor(v, root, src)
    local p = v:parent()
    while p do
        if p:type() == 'cast_expression' then
            local ty = txt(p, src):match('^%(%s*(%a+)')
            if ty and (SCALAR[ty:lower()] or ty:lower() == 'integer'
                or ty:lower() == 'boolean') then return true end
        end
        if p == root then break end
        p = p:parent()
    end
    return false
end

-- is this variable_name occurrence embedded (up to `root`) in a STRING that
-- carries SQL text — an interpolation, or a concat with a string literal?
-- That embedding IS the injection; a bare value passed standalone (a bound
-- parameter, e.g. LessQL `where('col', $v)`) is not.
local function embedded_at(v, root)
    local p = v:parent()
    while p do
        local t = p:type()
        if t == 'encapsed_string' then return true end
        if t == 'binary_expression' and #collect(p, { 'string', 'encapsed_string' }) > 0 then
            return true
        end
        if p == root then break end
        p = p:parent()
    end
    return false
end

local CALLTYPES = { 'member_call_expression', 'function_call_expression',
    'scoped_call_expression' }

-- ── rung 1.5: framework request sources + guard sanitizers ──────────────────

-- ENTRY-POINT sources: a controller-action method (one param typed *Request*)
-- treats its Request param + any array params (Slim/PSR route args, e.g.
-- $args['id']) as external input — the portable framework-source shape.
local function entry_sources(fnnode, src)
    local fp
    for c in fnnode:iter_children() do
        if c:type() == 'formal_parameters' then fp = c break end
    end
    if not fp then return nil end
    local ps, hasreq = {}, false
    for p in fp:iter_children() do
        if p:named() and p:type() == 'simple_parameter' then
            local ty, nm = txt(p, src):match('^%s*%??%s*([%w_\\]+)%s+%$([%w_]+)')
            if nm then
                ps[#ps + 1] = { name = nm, ty = ty }
                if ty and ty:lower():find('request') then hasreq = true end
            end
        end
    end
    if not hasreq then return nil end
    local seed = {}
    for _, p in ipairs(ps) do
        if p.ty and (p.ty:lower():find('request') or p.ty:lower() == 'array') then
            seed[p.name] = { origin = '$' .. p.name .. ' (request)', embedded = false }
        end
    end
    return next(seed) and seed or nil
end

-- GUARD sanitizers: functions whose argument is thereby validated (grocy's
-- Spendings uses IsIsoDate / filter_var). A carrier is sanitized when such a
-- call on its access-expression appears in a DOMINATING guard condition (see
-- guard_validates + cfg.guards_over) — structural, not scope-wide.
local VALIDATORS = { isisodate = true, isisodatetime = true, filter_var = true,
    is_numeric = true, is_int = true, ctype_digit = true, ctype_alnum = true,
    preg_match = true, in_array = true, intval = true }

local function normtext(node, src) return (txt(node, src):gsub('%s+', '')) end

-- outermost access expression (subscript / member chain) around `v`
local function access_expr(v)
    local top, p = v, v:parent()
    while p and (p:type() == 'subscript_expression'
        or p:type() == 'member_access_expression'
        or p:type() == 'member_call_expression'
        or p:type() == 'scoped_call_expression') do
        top = p; p = p:parent()
    end
    return top
end

-- is `inner` under a `!`/`not` negation somewhere up to `outer`?
local function neg_over(inner, outer, src)
    local p = inner:parent()
    while p do
        if p:type():find('unary') then
            local s = txt(p, src)
            if s:match('^%s*!') or s:match('^%s*not%f[^%w_]') then return true end
        end
        if p == outer then break end
        p = p:parent()
    end
    return false
end

-- GUARD-DOMINANCE sanitizer (CFG phase 1, [[cartograph-cfg-scope]]): a carrier
-- `v` is sanitized iff a validator on v's access-expression guards it along a
-- DOMINATING path (cfg.guards_over gives positive-nesting AND early-exit
-- guard-clauses). Flow-sensitive (branch-split use is NOT suppressed) with
-- conjunct/negation soundness: positive nesting needs a NON-negated validator
-- and no `||` (it must be a conjunct); an early-exit `if(!valid)exit` needs a
-- NEGATED validator and no `&&`.
local function guard_validates(v, src)
    local guards = cfg.guards_over(v, src)
    if #guards == 0 then return false end
    local target = normtext(access_expr(v), src)
    for _, g in ipairs(guards) do
        local cond = g.cond
        local ct = txt(cond, src)
        local has_or = ct:find('||', 1, true) or ct:match('%f[%w]or%f[%W]')
        local has_and = ct:find('&&', 1, true) or ct:match('%f[%w]and%f[%W]')
        for _, call in ipairs(collect(cond, CALLTYPES)) do
            local namef = call:field('name')[1] or call:field('function')[1]
            local cn = namef and txt(namef, src):lower()
            if cn and VALIDATORS[cn] then
                local argsn = call:field('arguments')[1]
                local hit = false
                if argsn then
                    for arg in argsn:iter_children() do
                        if arg:named() and arg:type() == 'argument'
                            and normtext(arg:named_child(0) or arg, src) == target then
                            hit = true; break
                        end
                    end
                end
                if hit then
                    local negd = neg_over(call, cond, src)
                    if not g.neg and not negd and not has_or then return true end
                    if g.neg and negd and not has_and then return true end
                end
            end
        end
    end
    return false
end

-- unsanitized taint carried into `node`: { origin, embedded } or nil.
-- `origin` is a request-source string ('$_GET') OR, when seeded from params,
-- a param INDEX number. `embedded` = the taint reaches `node` inside
-- SQL-carrying string text (here, or inherited). A ref bound/escaped by a
-- parameterizer, scalar cast, or a DOMINATING guard is not raw.
local function embed_witness(node, src, tainted)
    local best
    for _, v in ipairs(collect(node, { 'variable_name' })) do
        if not protected_ref(v, node, src) and not cast_ancestor(v, node, src)
            and not guard_validates(v, src) then
            local nm = txt(v, src):gsub('^%$', '')
            local base = SOURCES[nm] and { origin = '$' .. nm, embedded = false }
                or tainted[nm]
            if base then
                local emb = base.embedded or embedded_at(v, node)
                if emb then return { origin = base.origin, embedded = true } end
                best = best or { origin = base.origin, embedded = false }
            end
        end
    end
    return best
end

-- forward taint over one scope's own assignments (fixpoint). `seed` pre-taints
-- names (entry_sources seeds a controller action's request/route params).
local function scope_taint(scope, src, seed)
    local tainted = {}
    if seed then for k, v in pairs(seed) do tainted[k] = v end end
    local assigns = collect_scoped(scope,
        { 'assignment_expression', 'augmented_assignment_expression' })
    local changed = true
    while changed do
        changed = false
        for _, a in ipairs(assigns) do
            local lhs, rhs = a:field('left')[1], a:field('right')[1]
            if lhs and rhs and lhs:type() == 'variable_name' then
                local nm = txt(lhs, src):gsub('^%$', '')
                local w = embed_witness(rhs, src, tainted)
                local cur = tainted[nm]
                if w and (not cur or (w.embedded and not cur.embedded)) then
                    tainted[nm] = w; changed = true
                end
            end
        end
    end
    return tainted
end

local function scope_findings(scope, src, file, out, seed)
    local tainted = scope_taint(scope, src, seed)
    for _, call in ipairs(collect_scoped(scope, CALLTYPES)) do
        local namef = call:field('name')[1] or call:field('function')[1]
        local callee = namef and txt(namef, src) or '?'
        local objf = call:field('object')[1]
        local argsn = call:field('arguments')[1]
        if callee ~= '?' and argsn and sink_reason({ callee = callee,
            receiver = objf and txt(objf, src) or nil }) then
            for arg in argsn:iter_children() do
                if arg:named() and arg:type() == 'argument' then
                    local w = embed_witness(arg:named_child(0) or arg, src, tainted)
                    -- only STRING-EMBEDDED taint is injection; a bare tainted
                    -- value passed standalone is a bound parameter
                    if w and w.embedded and type(w.origin) == 'string' then
                        out[#out + 1] = { file = file, line = select(1, call:range()) + 1,
                            source = w.origin, callee = callee }
                        break -- one finding per sink call
                    end
                end
            end
        end
    end
end

local function each_php(store, fn)
    for _, file in ipairs(store.files or {}) do
        if file:match('%.php$') then
            local path = store.abs(file)
            local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path)
            if lines then
                local s = table.concat(lines, '\n')
                local ok, parser = pcall(vim.treesitter.get_string_parser, s, 'php')
                if ok and parser then fn(file, s, parser) end
            end
        end
    end
end

--- Lint findings: a request source reaches a SQL sink, unsanitized (rung 1).
function M.source_findings(store)
    local out = {}
    each_php(store, function (file, s, parser)
        local root = parser:parse()[1]:root()
        scope_findings(root, s, file, out) -- top-level: superglobals only
        for _, fn in ipairs(collect(root,
            { 'function_definition', 'method_declaration' })) do
            -- controller-action params (Request / route args) as sources too
            scope_findings(fn, s, file, out, entry_sources(fn, s))
        end
    end)
    local fs = {}
    for _, c in ipairs(out) do
        fs[#fs + 1] = { file = store.abs(c.file), line = c.line,
            message = ('possible SQL injection (~, sink unconfirmed): request '
                .. 'input %s reaches SQL sink %s() with no sanitizer on the path')
                :format(c.source, c.callee) }
    end
    return fs
end

-- ── taint rung 2: INTER-PROCEDURAL source → sink reachability ───────────────
-- Rides the RESOLVED call graph (store.calls_by_fn / c.to) + scc.lua — NOT the
-- name-matching the stripped prototype used ([[cartograph-taint-analysis]]
-- architecture finding). Two-pass ASSEMBLY of shipped parts:
--   PASS 1 (re-parse PHP, like rungs 0/1): per fn, a scope taint seeded with
--     BOTH its request/route sources (entry_sources) AND its non-scalar params
--     (by INDEX). From it derive (a) sink_params = which param INDEX reaches an
--     EMBEDDED SQL sink inside this fn, and (b) per outgoing-call arg: does it
--     carry a source (string origin) or a caller param (number origin)?
--   PASS 2 (scc.condense over the resolved call graph, callees-first — the SAME
--     scaffolding as effects.summaries): propagate sink-reachability BACKWARD.
--     A caller passing its own param to a callee's sink-param INHERITS it
--     (grows its sink_params); a caller passing a SOURCE to a callee sink-param
--     emits a finding. Fixpoint within each SCC (recursion).
-- COERCION sanitizer = TYPE DECIDES THE REGIME: a scalar-typed param is never
-- seeded (value rewritten at the boundary) so it can't be a sink_param — the
-- grocy keystone exactly (untyped GetProductStockLocations vuln fires, the
-- `int $productId` sibling stays silent). GUARD sanitizers ride embed_witness
-- (cfg dominance) intra-proc. Sound under-claim: an arg embed_witness can't
-- attribute (opaque local / aggregate) simply doesn't propagate — never
-- fabricated. Sink stays a `~` hypothesis (sink_reason), like rungs 0/1.

-- ordered params (1-based, matching argv/effects.arg_target) with scalar flag
local function ordered_params(fnnode, src)
    local out = {}
    local fp
    for c in fnnode:iter_children() do
        if c:type() == 'formal_parameters' then fp = c break end
    end
    if not fp then return out end
    for p in fp:iter_children() do
        local t = p:type()
        if p:named() and (t == 'simple_parameter'
            or t == 'property_promotion_parameter' or t == 'variadic_parameter') then
            local pt = txt(p, src)
            local ty, nm = pt:match('^%s*%??%s*([%a_\\]+)%s+%$([%w_]+)')
            if not nm then nm = pt:match('%$([%w_]+)') end
            if nm then out[#out + 1] = { name = nm,
                scalar = ty ~= nil and SCALAR[ty] or false } end
        end
    end
    return out
end

--- Lint findings (rung 2): a request/route source flows, across ≥1 resolved
--- call hop, into a callee param that reaches a SQL sink unsanitized.
function M.reach_findings(store)
    local atr = require 'cartograph.at'
    -- bridge: (file, 0-based start line) -> store fn-node id
    local fid_at = {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            fid_at[n.file .. ':' .. atr.sl(n.range)] = n.id
        end
    end

    -- PASS 1: intra-proc analysis per fn, keyed by store node id
    local info = {} -- fid -> { sinkparams = {idx=true}, argclass = {line -> {callee_lower -> {argidx -> origin}}} }
    each_php(store, function (file, s, parser)
        local root = parser:parse()[1]:root()
        for _, fn in ipairs(collect(root,
            { 'function_definition', 'method_declaration' })) do
            local fid = fid_at[file .. ':' .. select(1, fn:range())]
            if fid then
                local params = ordered_params(fn, s)
                local seed = {}
                for i, p in ipairs(params) do
                    if not p.scalar then seed[p.name] = { origin = i, embedded = false } end
                end
                local srcseed = entry_sources(fn, s)
                if srcseed then for k, v in pairs(srcseed) do seed[k] = v end end
                local tainted = scope_taint(fn, s, seed)
                local rec = { sinkparams = {}, argclass = {} }
                for _, call in ipairs(collect_scoped(fn, CALLTYPES)) do
                    local namef = call:field('name')[1] or call:field('function')[1]
                    local callee = namef and txt(namef, s) or '?'
                    local argsn = call:field('arguments')[1]
                    -- 0-based, to match the store's c.line in pass 2
                    local line = select(1, call:range())
                    -- classify each positional arg (source / caller-param / nil)
                    local byidx, ai = {}, 0
                    for arg in (argsn and argsn:iter_children() or function () end) do
                        if arg:named() and arg:type() == 'argument' then
                            ai = ai + 1
                            local w = embed_witness(arg:named_child(0) or arg, s, tainted)
                            if w then byidx[ai] = w.origin end
                        end
                    end
                    if next(byidx) then
                        rec.argclass[line] = rec.argclass[line] or {}
                        rec.argclass[line][callee:lower()] = byidx
                    end
                    -- intra sink_params: a param INDEX embedded at a raw SQL
                    -- sink here (method-name signal; ORM inserts are excluded —
                    -- is_sql_method, not the DB-receiver catch-all, so a
                    -- parameterized createRow does not read as a sink)
                    if callee ~= '?' and argsn and is_sql_method(callee) then
                        for arg in argsn:iter_children() do
                            if arg:named() and arg:type() == 'argument' then
                                local w = embed_witness(arg:named_child(0) or arg, s, tainted)
                                if w and w.embedded and type(w.origin) == 'number' then
                                    rec.sinkparams[w.origin] = true
                                end
                            end
                        end
                    end
                end
                info[fid] = rec
            end
        end
    end)

    -- PASS 2: backward propagation over the resolved call graph, callees-first
    local scc = require 'cartograph.scc'
    local ids, calladj = {}, {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            ids[#ids + 1] = n.id
            local adj = {}
            for _, c in ipairs(store.calls_by_fn[n.id] or {}) do
                if c.to then adj[#adj + 1] = c.to end
            end
            calladj[n.id] = adj
        end
    end
    table.sort(ids)
    local con = scc.condense(calladj, ids)
    local sp = {} -- fid -> {idx=true}, seeded from intra, GROWS during propagation
    for fid, rec in pairs(info) do
        sp[fid] = {}
        for i in pairs(rec.sinkparams) do sp[fid][i] = true end
    end
    local findings, seen = {}, {}
    for ci = 1, con.n do
        local changed = true
        while changed do -- fixpoint within the SCC (recursion)
            changed = false
            for _, fid in ipairs(con.members[ci]) do
                local rec = info[fid]
                for _, c in ipairs(rec and store.calls_by_fn[fid] or {}) do
                    local gsp = c.to and sp[c.to]
                    if gsp and next(gsp) then
                        local ac = rec.argclass[c.line]
                            and rec.argclass[c.line][(c.callee or ''):lower()]
                        if ac then
                            for i in pairs(gsp) do
                                local o = ac[i]
                                if type(o) == 'string' then
                                    local key = fid .. '\31' .. c.line .. '\31' .. i
                                    if not seen[key] then
                                        seen[key] = true
                                        findings[#findings + 1] = { file = c.file,
                                            line = c.line, source = o, callee = c.callee }
                                    end
                                elseif type(o) == 'number' and not sp[fid][o] then
                                    sp[fid][o] = true; changed = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local fs = {}
    for _, f in ipairs(findings) do
        fs[#fs + 1] = { file = store.abs(f.file), line = f.line,
            message = ('possible SQL injection (~, inter-procedural, sink '
                .. 'unconfirmed): request input %s is passed to %s(), whose '
                .. 'parameter reaches a SQL sink unsanitized (no scalar type '
                .. 'hint or guard on the cross-function path)')
                :format(f.source, f.callee) }
    end
    return fs
end

return M
