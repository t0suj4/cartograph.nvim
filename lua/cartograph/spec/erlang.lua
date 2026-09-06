-- The ERLANG language spec (L0 grammar binding + L1 name model)
-- ([[cartograph-spec-layering]]). Added for the ejabberd half of the brotardcast
-- corpus (CART-0793), which is a POLYGLOT pair — an Erlang XMPP server beside its
-- own JS/TS client — and so the roster's missing polyglot tier.

-- @langs erlang — a spec IS one grammar's mapping, so every node type here is
-- erlang's by construction.

-- one definition of "how many arguments", used by the def name key, the alt key
-- and both call paths. Three copies of this counter is how they drift apart.
local function arity_of(n)
    local args = n and n:field('args')[1]
    if not args then return 0 end
    local k = 0
    for c in args:iter_children() do if c:named() then k = k + 1 end end
    return k
end

return {
    -- the callee sits in `expr`, which is either an `atom` (local call) or a
    -- `remote` (module-qualified). tree-sitter-erlang gives BOTH the same parent.
    call_positions = {
        call = 'expr',
    },
    -- .hrl is a HEADER, included textually by `-include`. It holds records,
    -- macros and occasionally functions, and it is a real file in the graph —
    -- ejabberd has 37 of them against 353 .erl.
    exts = { 'erl', 'hrl', 'escript' },

    -- ★★ A FUNCTION IS ITS CLAUSES. `handle_call(a, _, S) -> …; handle_call(b, _, S)
    -- -> …` is ONE function with two heads, so the DEF captured here is the
    -- `function_clause` and `merge_equations` folds the heads together — exactly
    -- haskell's case, and the same flag serves it. Capturing the enclosing
    -- `fun_decl` instead would put name/args/body one level down and buy nothing.
    functions = [=[ (function_clause name: (atom) @name) @def ]=],
    fn_types = { function_clause = true },
    merge_equations = true,
    -- ★★★ ARITY-KEYING IS LANGUAGE SPECIFIC, and erlang is the only one of the 17
    -- specs that needs it (user, 2026-09-06). Java's overloads are selected by
    -- TYPES, of which arity is a partial and varargs-breakable filter; erlang's
    -- `store_room/4` and `store_room/5` are simply DIFFERENT FUNCTIONS with no
    -- relationship. So this is a per-language identity rule, not a resolver-wide
    -- change — CART-0676 is a different mechanism on a neighbouring question.
    -- Without it, `merge_equations` folds the two into one node: 802 of 9650
    -- functions on ejabberd (8.3%), worst case `join` with FOUR arities.
    merge_key = function (defn) return arity_of(defn) end,

    -- ⚠⚠ AND THE ARITY GOES IN AN **ALT KEY**, NEVER IN THE NAME. Putting it in
    -- the name (`store_room/4`) was tried and MEASURED: resolution 81.6% -> 35.6%,
    -- extract 8.5s -> 61.7s, minting 560 -> 0 nodes. EIGHT sites read a name's last
    -- `[%w_]+` run as its unqualified tail, so `store_room/4` indexed under the
    -- tail `4` and every erlang function landed in a handful of giant arity
    -- buckets. `alt_keys` is the mechanism for exactly this and says so in its own
    -- comment: "exact-only (no tail) — an alias key must not become a promiscuous
    -- tail target." The NAME stays a source identifier; the KEY carries the arity.
    alt_keys = function (name, defn)
        return { name .. '/' .. arity_of(defn) }
    end,
    params_field = 'args',
    body_field = 'body',
    -- erlang has no nested named functions; a `fun` is anonymous. So every named
    -- definition is top level, and this keeps clause-local `fun`s out of the index.
    toplevel_only = true,

    -- LOCAL and REMOTE calls, and the name captured is the FUNCTION in both. The
    -- module of a remote call is deliberately not part of @name: the resolver's
    -- name index is keyed by function name across the corpus, and folding the
    -- module in here would make every remote call miss.
    calls = [=[
        (call expr: (atom) @name) @call
        (call expr: (remote fun: (atom) @name)) @call
    ]=],
    -- ⚠⚠ A `-spec` IS NOT CODE, AND THE GRAMMAR CANNOT TELL YOU THAT. `-spec
    -- f(non_neg_integer()) -> boolean().` parses its type applications as `call`
    -- nodes, identical in shape to a real call. MEASURED on ejabberd: 12811 of
    -- 54335 call nodes — 23.6% — sit inside a type context, and the top
    -- "unresolved callees" in the first cut were `boolean`, `non_neg_integer`,
    -- `state`, `jid` and `opts`: type names, every one.
    -- ★ AND THE HARM IS NOT NOISE, IT IS FABRICATION. A `-spec` mentioning `jid()`
    -- name-matches a real `jid/0` in the corpus and mints an edge that no call
    -- site justifies. Dropping them removes an inflated denominator AND a class of
    -- invented reference.
    -- WHY A PREDICATE AND NOT `call_skip_within`: that hook walks THREE parents,
    -- and 1621 of the 12811 (12.7%) sit deeper — a type nests arbitrarily
    -- (`[{atom(), [binary()]}]`). Measured, not assumed. So the rule is stated as
    -- what it actually is: a call in erlang is code only if a function clause
    -- encloses it.
    skip_call = function (calln)
        local a = calln:parent()
        while a do
            local t = a:type()
            -- reached the code that encloses it: this is a real call
            if t == 'clause_body' or t == 'function_clause' or t == 'fun_decl' then
                return false
            end
            -- a type/attribute context: not code
            if t == 'type_sig' or t == 'field_type' or t == 'type_alias'
                or t == 'ann_type' or t == 'fun_type_sig' or t == 'wild_attribute'
                or t == 'spec_attribute' or t == 'callback_attribute' then
                return true
            end
            a = a:parent()
        end
        -- never found a clause body: a top-level attribute, not a call
        return true
    end,

    -- ★★ THE MODULE OF A REMOTE CALL WAS BEING THROWN AWAY. `lists:foldl(F, A, L)`
    -- recorded `callee = foldl` and nothing else — measured: 111 of 55474 erlang
    -- calls carried a `full`, and all 111 were the JS files in the corpus. So the
    -- single most informative token in an erlang call site was absent, and `foldl`
    -- (342 sites) was matched by bare name against the whole corpus.
    -- ⚠⚠ AND IT MUST BE A DOT, NOT THE SOURCE'S COLON. The provider computes
    -- `method = full:find(':')` BEFORE this hook runs — that is php's `Class::m`
    -- test — and a method shifts the implicit-self argument, so emitting
    -- `lists:map` would silently renumber every OTP call's arguments. A dot also
    -- makes the L2 profile's namespace path reachable, which keys on the root
    -- before a DOT (`prof_ext`). The source text is unchanged; only the
    -- RESOLUTION KEY is normalised, exactly as php rewrites `$this->m` to
    -- `Class::m`.
    qualify_call = function (calln, name, src)
        if calln:type() ~= 'call' then return nil end
        local e = calln:field('expr')[1]
        -- ★ A LOCAL CALL KEYS BY name/arity, meeting the alt key above, so a call
        -- with four arguments reaches `store_room/4` and not its five-argument
        -- sibling. The argument count is at the site and needs no type
        -- information — which is why this works spec-locally while the general
        -- overload question (CART-0676) needs the resolver to see the call.
        -- ⚠⚠ A REMOTE CALL KEEPS `mod.name` WITH NO ARITY, AND THAT IS MEASURED,
        -- NOT ASSUMED. Adding the arity there is the obvious symmetry and it made
        -- things WORSE: REMOTE 59.7% -> 55.1%. The module-to-file bind resolves
        -- `mod:f` by looking the member up BY BARE NAME inside the bound file, and
        -- it does not consult alt keys — so `f/2` matches nothing and the call is
        -- refused outright instead of merely being ambiguous.
        -- ★ SO THE RESIDUAL IS PRECISE: a remote call into a module that defines
        -- the same name at two arities cannot be disambiguated from the spec side.
        -- The evidence is at the site and the alias path cannot see it — the same
        -- shape as CART-0676, one layer down.
        if not e or e:type() ~= 'remote' then
            return name .. '/' .. arity_of(calln)
        end
        local m = e:field('module')[1]
        if not m then return nil end
        -- `remote_module` wraps the atom; a VARIABLE module (`Mod:f()`) is a
        -- dynamic dispatch this cannot name, and is left alone rather than guessed
        local ma = m:named_child(0)
        if not ma or ma:type() ~= 'atom' then return nil end
        local mod = vim.treesitter.get_node_text(ma, src)
        if not mod or mod == '' or mod:find('[^%w_]') then return nil end
        return mod .. '.' .. name
    end,

    -- an `atom` is erlang's identifier AND its string-ish literal, so mentioning
    -- every one of them would index the language's punctuation. Measured on
    -- ELDAPv3.erl: 2114 atoms against 880 calls. Mentions stay off until there is
    -- a measurement that says which atoms are references.
    mention_types = nil,
    vars = nil,
    is_method = function () return false end,
    -- OTP entry points: `start/2` and `start_link/2` are how a supervisor reaches
    -- a module, and `init/1` is the callback the behaviour then calls. `main` is
    -- escript's.
    entry_names = { main = true, start = true, start_link = true, init = true },

    -- ★★★ A MODULE NAME IS A FILE NAME, AND THE COMPILER ENFORCES IT. erlang has
    -- no import statement: `ejabberd_hooks:run(...)` names its module inline, and
    -- the module `ejabberd_hooks` MUST live in `ejabberd_hooks.erl` or the
    -- compiler refuses the file. So the binding is not a convention this is
    -- guessing at — it is a language rule, and it is the same shape zig's
    -- `@import` binding already feeds: {alias, path} per file, then
    -- `resolve_import` maps the path to a corpus file.
    -- SIZED BEFORE BUILDING, on 14849 unresolved remote calls:
    --     module IS a corpus file    4001   26.9%   <- this
    --     module is an OTP module   10175   68.5%   <- an L2 profile, not built
    --     neither (deps, missing)     673    4.5%
    -- This half yields REAL EDGES to real definitions; the OTP half can only
    -- yield an honest `external`, which is why this one is worth more per call.
    -- ⚠ SORTED, and that is not housekeeping: the caller appends one import edge
    -- per entry, so an unsorted set makes the edge ORDER depend on LuaJIT's
    -- per-process hash seed — which is precisely the bug CART-0790 found in
    -- zig_imports, in this exact position, four hours ago.
    scan_imports = function (tsroot, src)
        local seen = {}
        local function walk(n)
            if n:type() == 'remote' then
                local m = n:field('module')[1]
                local ma = m and m:named_child(0)
                if ma and ma:type() == 'atom' then
                    local mod = vim.treesitter.get_node_text(ma, src)
                    -- a quoted atom may hold anything; only a bare module name is
                    -- a file name
                    if mod and mod ~= '' and not mod:find('[^%w_]') then
                        seen[mod] = true
                    end
                end
            end
            for c in n:iter_children() do if c:named() then walk(c) end end
        end
        walk(tsroot)
        local out = {}
        for mod in pairs(seen) do out[#out + 1] = { alias = mod, path = mod .. '.erl' } end
        table.sort(out, function (a, b) return a.alias < b.alias end)
        return out
    end,

    -- `-include("x.hrl")` and `-include_lib("app/include/x.hrl")` are the file
    -- dependency edge. include_lib resolves through the application path, which
    -- this cannot see, so it is left to resolve_import to refuse.
    import_query = [=[
        (pp_include (string) @path)
        (pp_include_lib (string) @path)
    ]=],
    resolve_import = function (path, files)
        local p = path:gsub('^"', ''):gsub('"$', '')
        if p == '' then return nil end
        -- an exact hit first, then a unique suffix match: ejabberd's headers sit
        -- in include/ while the -include names them bare, and include_lib names
        -- them app-qualified. Unique-or-refuse, never a first-wins guess.
        if files[p] then return p end
        local base = p:match('([^/]+)$') or p
        local hit
        for f in pairs(files) do
            if f == base or f:sub(-#base - 1) == '/' .. base then
                if hit then return nil end -- ambiguous: refuse
                hit = f
            end
        end
        return hit
    end,

    -- ⚠⚠ ARITY IS PART OF AN ERLANG FUNCTION'S IDENTITY AND THIS SPEC CANNOT SAY SO.
    -- `store_room/4` and `store_room/5` are DIFFERENT functions; mod_muc.erl
    -- exports both. The graph keys definitions by NAME, so they merge into one
    -- node here — and `merge_equations`, which correctly folds the several heads
    -- of one function, folds these two functions together as well. It cannot
    -- distinguish them, because the distinction is not expressible.
    -- ★ MEASURED ON ejabberd RATHER THAN ASSERTED, 353 files, 15112 clauses:
    --     distinct (file, name, arity)   9650
    --     distinct (file, name)          8848
    --     names carrying >1 arity         733 of 8848   8.3%
    --     functions merged away           802 of 9650   8.3%
    -- Worst single case: `join` in muc_tests.erl, FOUR distinct arities in one
    -- node. So the cost is real, bounded, and not a reason to withhold the spec —
    -- 91.7% of the language is unaffected and the graph is useful today.
    -- ★ THIS IS NOT AN ERLANG WORKAROUND, IT IS CART-0676 ARRIVING. Arity is
    -- already unconsulted in resolution for every language; erlang is simply the
    -- first where ignoring it is WRONG rather than imprecise.
    -- Encoding the arity into the name (`store_room/5`) was considered and NOT
    -- done: it would make erlang the one language whose node names are not source
    -- identifiers, and every cross-language name match would miss.
    -- ★ AND AN `arity_in_identity = true` MARKER WAS WRITTEN HERE AND REMOVED: the
    -- spec contract is CLOSED and the suite failed on it within a minute
    -- ("unregistered spec fields (closed-contract violation)"). Nothing read the
    -- field, so registering it would have invented a surface to carry a fact this
    -- comment already states. The contract was right.
}
