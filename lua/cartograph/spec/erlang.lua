-- The ERLANG language spec (L0 grammar binding + L1 name model)
-- ([[cartograph-spec-layering]]). Added for the ejabberd half of the brotardcast
-- corpus (CART-0793), which is a POLYGLOT pair — an Erlang XMPP server beside its
-- own JS/TS client — and so the roster's missing polyglot tier.

-- @langs erlang — a spec IS one grammar's mapping, so every node type here is
-- erlang's by construction.

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
