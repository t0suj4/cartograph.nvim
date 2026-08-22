-- ACCESS BY STRING KEY — a variable named as DATA, and the reads that name it.
--
-- THE HOLE (CART-0504, measured on ~/git/mantisbt). After file-scope mentions
-- gained an owner (CART-0479) mantis still had 605 vars with no use edge of any
-- kind, and 450 of them were not detector holes at all: `$g_db_type` occurs
-- exactly TWICE in the whole repository -- a docblock and its definition -- while
-- `config_get_global( 'db_type' )` reads it from 457 call sites. The codebase
-- reaches its configuration through a string-keyed API, so there is no identifier
-- mention for a mention pass to find. CART-0490 is the same gap from the other
-- end (`define('X', v)` DEFINES by call); together they are one thing: A NAME
-- THAT LIVES IN A STRING ARGUMENT.
--
-- ★★ THE TRANSFORM IS DERIVED, NOT DECLARED, and that is the whole design. The
-- obvious build is a per-application rule -- "config_get('x') means $g_x" -- and
-- the ticket proposed exactly that, profile-supplied. It is the wrong shape: the
-- convention is an authored guess, and a wrong one FABRICATES reads corpus-wide,
-- which is the direction this codebase keeps paying for. But the convention is
-- not hidden. It is two lines of the accessor's own body:
--
--     function config_get_global( $p_option, $p_default = null ) {
--         $t_var_name = 'g_' . $p_option;
--         if( isset( $GLOBALS[$t_var_name] ) ) {
--
-- an index into the GLOBAL TABLE whose key is a literal prefix concatenated with
-- a PARAMETER. So the accessor tells you its own signature: (parameter 1, prefix
-- 'g_', no suffix), and nothing is guessed. [[cartograph-optimizer-oracle]]'s
-- convergence rule holds -- external knowledge is an oracle or declared data,
-- never authored code -- because this is neither: it is the subject code read.
--
-- ★ AND THE DIRECTION FALLS OUT FREE, which is the argument for deriving rather
-- than declaring stated as a testable claim: the global-table index's POSITION
-- says read or write. `config_set_global` assigns `$GLOBALS[...]` and is a
-- WRITER; `config_set` writes the database and never touches the global table, so
-- it is not an accessor at all. A declared table of "config accessors" would have
-- had to get that right by hand, and the name gives no clue.
--
-- WHAT IS REFUSED, because a derivation that guesses is worse than none:
--   · a key chain that is not single-assignment, or mixes two parameters, or
--     runs through a call -- the function is recorded OPAQUE with a reason, never
--     given a transform;
--   · a call site whose key argument is not a literal (`config_get( $t_name )`)
--     -- counted as a DYNAMIC site, which is an honest frontier and the thing a
--     reader needs to know the roster is a lower bound;
--   · a derived name matching more than one var node -- AMBIGUOUS, resolved to
--     nothing. Picking the first would repeat CART-0505 exactly.
--
-- This module only ANSWERS; it mints nothing. Whether a derived read becomes a
-- real use edge is a separate decision with its own cost (an extraction change)
-- and its own open question (a use edge carries no provenance field today, so a
-- derived read would be indistinguishable from a syntactic one).

local expr = require 'cartograph.expr'
local argv = require 'cartograph.argv'
local callrec = require 'cartograph.callrec'
local ts = require 'cartograph.providers.treesitter'

local M = {}

local MAXDEPTH = 8      -- key-chain recursion; a real chain is 1-2 deep
local MAXROUNDS = 4     -- forwarder fixpoint; mantis's is one hop

local function spec_of(file)
    local lang = ts.lang_of(file)
    local s = lang and ts.spec[lang]
    if s and s.global_table and s.concat_op then return s, lang end
end

--- The literal STRING value of an expression, or nil. expr.eval owns the
--- quote-stripping convention (the harvest carries source quotes).
local function litstr(e)
    if not e or e.k ~= 'lit' then return nil end
    local ok, v = expr.eval(e)
    if ok and type(v) == 'string' then return v end
end

-- ── stage A: a function whose body indexes the global table by a parameter ──

--- Every `index` whose base names the global table, split by whether it was
--- found on the left of an assignment (a WRITE) or anywhere else (a READ).
local function global_indexes(rows, gt)
    local out = {}
    local function scan(e, iswrite)
        if not e then return end
        expr.walk(e, function (x)
            if x.k == 'index' and x.b and x.b.k == 'name' and gt[x.b.n] then
                out[#out + 1] = { key = x.i, write = iswrite }
            end
        end)
    end
    for _, st in ipairs(rows) do
        -- the harvested expression hangs off the ROW as `.expr` ({lhs,rhs,cond});
        -- the row itself carries flow bookkeeping
        local x = st.expr
        if x then
            for _, e in ipairs(x.lhs or {}) do scan(e, true) end
            for _, e in ipairs(x.rhs or {}) do scan(e, false) end
            scan(x.cond, false)
        end
    end
    return out
end

--- name -> { n = times assigned, rhs = the single rhs } over a function's rows.
--- SINGLE ASSIGNMENT is the admission test, not a convenience: a key local that
--- is written twice has no one value to read, and following either would be a
--- guess dressed as a derivation.
local function assigns(rows)
    local a = {}
    for _, st in ipairs(rows) do
        local x = st.expr or {}
        local lhs, rhs = x.lhs or {}, x.rhs or {}
        if #lhs == 1 and lhs[1].k == 'name' then
            local e = a[lhs[1].n] or { n = 0 }
            e.n = e.n + 1
            e.rhs = (#rhs == 1) and rhs[1] or nil
            a[lhs[1].n] = e
        else
            for _, l in ipairs(lhs) do -- a destructuring/multi target: unusable
                if l.k == 'name' then
                    local e = a[l.n] or { n = 0 }
                    e.n, e.rhs = e.n + 1, nil
                    a[l.n] = e
                end
            end
        end
    end
    return a
end

--- Reduce a key expression to (param name, prefix, suffix), or nil + a reason.
--- The only shapes admitted are a bare parameter, a single-assignment local that
--- reduces to one, and a concatenation of exactly one such with string literals.
local function reduce(e, ctx, depth)
    if not e then return nil, 'missing' end
    if depth > MAXDEPTH then return nil, 'too-deep' end
    if e.k == 'lit' then return nil, 'literal-key' end
    if e.k == 'name' then
        if ctx.params[e.n] then
            if (ctx.asg[e.n] or { n = 0 }).n > 0 then return nil, 'param-reassigned' end
            return { param = e.n, prefix = '', suffix = '' }
        end
        local a = ctx.asg[e.n]
        if not a then return nil, 'free-name' end
        if a.n ~= 1 or not a.rhs then return nil, 'multi-assigned' end
        return reduce(a.rhs, ctx, depth + 1)
    end
    if e.k == 'bin' and e.op == ctx.concat then
        local ls, rs = litstr(e.l), litstr(e.r)
        if ls and rs then return nil, 'literal-key' end
        if rs then
            local got, why = reduce(e.l, ctx, depth + 1)
            if not got then return nil, why end
            return { param = got.param, prefix = got.prefix, suffix = got.suffix .. rs }
        end
        if ls then
            local got, why = reduce(e.r, ctx, depth + 1)
            if not got then return nil, why end
            return { param = got.param, prefix = ls .. got.prefix, suffix = got.suffix }
        end
        return nil, 'concat-of-two-unknowns'
    end
    return nil, e.k
end

--- Is `fn_id` a DIRECT accessor? Returns a signature or nil + reason.
--- @return table? { param=<1-based index>, pname, prefix, suffix, rw, via='direct' }
function M.direct(store, fn_id)
    local node = store.node(fn_id)
    if not node or not node.file then return nil, 'no-node' end
    local s = spec_of(node.file)
    if not s then return nil, 'no-global-table' end
    local r = expr.of(store, fn_id)
    if not r then return nil, 'no-ir' end
    local rows = r.fl.stmts or {}
    local hits = global_indexes(rows, s.global_table)
    if #hits == 0 then return nil, 'no-global-index' end
    local params, idx = {}, {}
    for i, p in ipairs(r.fl.params or {}) do params[p] = true; idx[p] = i end
    local ctx = { params = params, asg = assigns(rows), concat = s.concat_op }
    -- EVERY global index must agree on one signature. A function that indexes the
    -- global table two different ways is not one accessor, and calling it one
    -- would make its call sites resolve to whichever shape we happened to see
    -- first -- the same first-candidate-wins defect as CART-0505.
    local sig, rw, why
    for _, h in ipairs(hits) do
        local got, w = reduce(h.key, ctx, 1)
        if not got then why = why or w
        elseif not sig then
            sig = got; rw = h.write and 'w' or 'r'
        elseif got.param ~= sig.param or got.prefix ~= sig.prefix
            or got.suffix ~= sig.suffix then
            return nil, 'disagreeing-signatures'
        else
            if h.write and rw == 'r' then rw = 'rw'
            elseif not h.write and rw == 'w' then rw = 'rw' end
        end
    end
    if not sig then return nil, why or 'unreduced' end
    return { param = idx[sig.param], pname = sig.param, prefix = sig.prefix,
        suffix = sig.suffix, rw = rw, via = 'direct' }
end

-- ── stage B: a function that FORWARDS its parameter to an accessor ──────────

--- The functions worth trying stage A on: a global-table name has to appear in
--- the file's text. `expr.of` re-parses per function, and a corpus has thousands
--- of them; this keeps the scan to the handful of files that could possibly
--- qualify. A prefilter, never a decision -- everything it admits is still
--- reduced from the IR.
local function candidates(store)
    local per, out = {}, {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.kind == 'function' or n.kind == 'method' then
            local hit = per[n.file]
            if hit == nil then
                hit = false
                local s = spec_of(n.file)
                if s then
                    local fd = io.open(store.abs(n.file), 'r')
                    if fd then
                        local src = fd:read('*a') or ''
                        fd:close()
                        for name in pairs(s.global_table) do
                            if src:find(name, 1, true) then hit = true break end
                        end
                    end
                end
                per[n.file] = hit
            end
            if hit then out[#out + 1] = n.id end
        end
    end
    return out
end

--- Every accessor in the graph: the direct ones, then the transitive closure
--- over forwarding. `opaque` records the functions that touch the global table
--- and could NOT be reduced, with the reason -- the roster's own frontier.
--- @return table accs  fn_id -> signature
--- @return table opaque  fn_id -> reason
function M.accessors(store)
    local accs, opaque = {}, {}
    for _, id in ipairs(candidates(store)) do
        local sig, why = M.direct(store, id)
        if sig then accs[id] = sig
        elseif why ~= 'no-global-index' and why ~= 'no-ir'
            and why ~= 'no-global-table' then opaque[id] = why end
    end
    -- FORWARDERS. `config_get` is 1371 of mantis's call sites and touches no
    -- global table at all: it ends in `return config_get_global( $p_option,
    -- $p_default )`. So an accessor's parameter position is inherited by any
    -- function that passes its OWN parameter there, bare. Resolved calls only
    -- (callrec.to), never name matching -- a name-matched forwarder would invent
    -- an accessor out of an unrelated same-named function.
    local params_of = {}
    local function params(fn_id)
        local p = params_of[fn_id]
        if p == nil then
            local r = expr.of(store, fn_id)
            p = false
            if r then
                p = {}
                for i, nm in ipairs(r.fl.params or {}) do p[nm] = i end
            end
            params_of[fn_id] = p
        end
        return p or nil
    end
    for _ = 1, MAXROUNDS do
        local added = 0
        for _, c in ipairs(store.data.calls or {}) do
            local to, from = callrec.to(c), callrec.fn(c)
            local sig = to and accs[to]
            if sig and from and not accs[from] then
                local a = argv.at(c, sig.param)
                if a and a.k == 'local' and a.name then
                    local p = params(from)
                    local i = p and p[a.name]
                    if i then
                        accs[from] = { param = i, pname = a.name,
                            prefix = sig.prefix, suffix = sig.suffix,
                            rw = sig.rw, via = 'forward', from = to }
                        added = added + 1
                    end
                end
            end
        end
        if added == 0 then break end
    end
    return accs, opaque
end

-- ── stage C: the call sites, and the names they name ───────────────────────

--- var name -> array of var node ids, corpus-wide. Resolution is by the WHOLE
--- corpus deliberately: taking the first same-file candidate is exactly the
--- defect CART-0505 records, so a name with several bearers resolves to nothing
--- rather than to the nearest one.
--- ★ AND ONLY IN A LANGUAGE THAT GUARANTEES A FILE-SCOPE VAR IS IN THAT TABLE.
--- This is the second refusal and it was bought with a fabrication: measured on
--- ~/work/wow_addons, `_G["OnTooltipSetItem"]` in four separate addons resolved
--- to Panda/GemTooltip.lua's `local OnTooltipSetItem` -- a LOCAL, not reachable
--- through _G at all -- because "the only var node with that name in the corpus"
--- is not the same claim as "the variable that name reaches". php has no such
--- gap (`$x = 1` at file scope IS `$GLOBALS['x']`), lua's is one keyword, and a
--- var node records neither: `exported` is set by handle_fn only, so every var
--- carries nil, which the tree's own comment says means "never asked".
--- So the admission is per-language and declared (spec.global_scope_vars), and
--- lua's absence costs a genuinely-correct hit (!swatter's bare `SetItemRef =`)
--- to avoid four wrong ones. CART-0500 turns this per-node.
local function vars_by_name(store)
    local by, ok_lang = {}, {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.kind == 'var' and not n.sql and not n.ctype then
            local admit = ok_lang[n.file]
            if admit == nil then
                local lang = ts.lang_of(n.file)
                local sp = lang and ts.spec[lang]
                admit = (sp and sp.global_scope_vars) == true
                ok_lang[n.file] = admit
            end
            if admit then
                by[n.name] = by[n.name] or {}
                table.insert(by[n.name], n.id)
            end
        end
    end
    return by
end

--- Does this accessor's own language admit resolution at all? A site in a
--- language without the guarantee is counted as BLOCKED, never as "no node":
--- the difference between "the name names nothing" and "this language cannot
--- say" is the whole point of an honest frontier.
local function lang_admits(store, fn_id)
    local n = store.node(fn_id)
    local lang = n and n.file and ts.lang_of(n.file)
    local sp = lang and ts.spec[lang]
    return (sp and sp.global_scope_vars) == true
end

--- Every call to an accessor, classified.
--- @return table sites  { { call, acc, name, var, rw, fn, file, line } … } for
---   the sites whose key is a literal AND whose derived name has exactly one
---   bearer -- the only ones an edge could be minted from
--- @return table stats  the four buckets plus the dynamic frontier
function M.sites(store, accs)
    accs = accs or (M.accessors(store))
    local by = vars_by_name(store)
    local sites = {}
    local stats = { calls = 0, dynamic = 0, unique = 0, ambiguous = 0,
        nonode = 0, blocked = 0, had_edges = 0, names = {},
        ambiguous_names = {}, nonode_names = {} }
    local band = store.topo and store.topo() or nil
    for _, c in ipairs(store.data.calls or {}) do
        local sig = accs[callrec.to(c) or '']
        if sig then
            stats.calls = stats.calls + 1
            local a = argv.at(c, sig.param)
            local key = a and a.k == 'lit' and a.v or nil
            if not key or key == '' then
                stats.dynamic = stats.dynamic + 1
            elseif not lang_admits(store, callrec.to(c)) then
                stats.blocked = stats.blocked + 1
            else
                local name = sig.prefix .. key .. sig.suffix
                local hit = by[name]
                if not hit then
                    stats.nonode = stats.nonode + 1
                    stats.nonode_names[name] = (stats.nonode_names[name] or 0) + 1
                elseif #hit > 1 then
                    stats.ambiguous = stats.ambiguous + 1
                    stats.ambiguous_names[name] = #hit
                else
                    stats.unique = stats.unique + 1
                    stats.names[name] = (stats.names[name] or 0) + 1
                    if band and #band:var_used_by_detail(hit[1]) > 0 then
                        stats.had_edges = stats.had_edges + 1
                    end
                    sites[#sites + 1] = { call = c, acc = callrec.to(c),
                        name = name, var = hit[1], rw = sig.rw,
                        fn = callrec.fn(c), file = callrec.file(c),
                        line = callrec.line(c) }
                end
            end
        end
    end
    return sites, stats
end

-- ── the read index: var -> the sites that name it ───────────────────────────
-- Derivation costs ~525 ms on mantis (accessors 407, sites 117) because deriving
-- an accessor re-parses its file through expr.of. That is once per graph and far
-- too much per render, so the index is MEMOIZED ON GRAPH IDENTITY (store.data's
-- own table) exactly like the axis cone memo: a re-ingest hands out a new table,
-- so the memo cannot outlive the graph it describes and no stamp is needed --
-- the key IS the thing that would have to change.
local index = setmetatable({}, { __mode = 'k' })

--- var id -> array of sites naming it, built once per graph. Lazy: nothing pays
--- for this until a consumer asks.
function M.read_index(store)
    local g = store.data
    if not g then return {} end
    local per = index[g]
    if not per then
        per = {}
        for _, s in ipairs((M.sites(store))) do
            local l = per[s.var]
            if l then l[#l + 1] = s else per[s.var] = { s } end
        end
        index[g] = per
    end
    return per
end

--- The string-keyed reads of one var: `{ name, acc, fn, file, line, rw }`.
--- `name` is the DERIVED variable name, `acc` the accessor the site called --
--- which is what a row has to show, because "read as 'db_type' via
--- config_get_global" is the whole fact and the bare line number is not.
function M.reads_of(store, var_id)
    return M.read_index(store)[var_id] or {}
end

return M
