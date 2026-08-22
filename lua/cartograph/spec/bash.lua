-- The BASH language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs bash — a spec IS one grammar's mapping, so every node type here is
-- bash's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local inext = tsutil.inext
local refusal = tsutil.refusal

return {
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        command_name = 0, -- ★ NOT `command`: `command`'s `name` field holds a
        -- command_name NODE, and the identifier sits one level further down as
        -- its child 0. The ticket named `command` and would have matched nothing
    },
        exts = { 'sh', 'bash' },
        functions = [=[
            (function_definition name: (word) @name) @def
        ]=],
        -- every command is application; builtins/coreutils opt out via
        -- stdlib_names. `local`/`declare`/`export` are declaration_command
        -- in the grammar, so they never reach here.
        calls = [=[
            (command name: (command_name (word) @name)) @call
        ]=],
        -- top-level assignments (bash vars are PROCESS-GLOBAL by default —
        -- which is also why this spec has NO scopes table: name matching
        -- across files is the semantically honest default, and `local` is
        -- DYNAMIC scoping our lexical model must not fake; banked design)
        vars = [=[
            (program (variable_assignment name: (variable_name) @vname value: (_) @value) @vdef)
            (program (declaration_command (variable_assignment name: (variable_name) @vname value: (_) @value) @vdef))
        ]=],
        litdata_types = { string = true, raw_string = true, array = true,
            word = true, number = true },
        body_field = 'body',
        fn_types = { function_definition = true },
        -- $x expansions carry variable_name; a bare word in argument
        -- position can NAME a function (trap cleanup EXIT) — both mention
        -- kinds feed the id pass
        mention_types = { word = true, variable_name = true },
        df_ids = { variable_name = true },
        -- typed-string SINK: eval's arg IS code — the literal head names
        -- the real callee (the aperture-analyzer side of the eval story)
        string_sinks = { eval = { arg = 1, ty = 'code' } },
        -- bash has NO qualification syntax: a command names its function
        -- literally (slashed ble/* names are exact identifiers) — never
        -- tail-match, never tail-vocab
        literal_names = true,
        -- APERTURE emission (scope-model memo: emit from day one, zero
        -- analyzers — the refusal IS the contract): eval conjures
        -- functions and vars no static pass can enumerate. Witness sites
        -- ride the module node; resolution turns "namespaced name with
        -- no def" into refusal-with-witness instead of presuming an
        -- external command. Capture name = the aperture rule.
        aperture_query = [=[
            ((command name: (command_name (word) @_kw)) @eval
                (#eq? @_kw "eval"))
            ((command name: (command_name (word) @_b)
                . argument: (word) @_arg) @eval
                (#eq? @_b "builtin") (#eq? @_arg "eval"))
        ]=],
        -- a bash function_definition is self-contained (no class context
        -- to escape), and tree-sitter-bash chokes locally on exotic
        -- parameter expansions (`${1//&/&amp;}` tears testssl.sh at line
        -- 580 of 26k): tear only defs whose OWN subtree holds the error
        torn_by_node = true,
        is_method = function () return false end,
        -- source/. splice a file in at RUN time: resolve like C includes —
        -- relative to the sourcing file, then the root, then a unique
        -- basename (ambiguity refuses, as everywhere). Runtime cwd is the
        -- honest unknowable; this is the conventional layout.
        -- THE SECOND LANGUAGE WHERE THE SITE DISCRIMINATES, and it is the
        -- honest end of the axis: `source` / `.` have no memoization at all, so
        -- sourcing a file in a loop re-executes it every pass. The `@path`'s
        -- enclosing node here is the `command` itself (see the bounded ancestor
        -- walk in the provider) -- one entry covers both spellings, because the
        -- query's #any-of? predicate already decided which commands match.
        import_kinds = { command = { once = false } },
        import_query = [=[
            ((command name: (command_name (word) @_kw) argument: (word) @path)
                (#any-of? @_kw "source" "."))
        ]=],
        resolve_import = function (path, files, from)
            local dir = from:match('^(.*)/[^/]*$')
            for _, cand in ipairs({ dir and (dir .. '/' .. path) or path,
                (path:gsub('^%./', '')) }) do
                if files[cand] then return cand end
            end
            local base, hit = path:match('([^/]+)$'), nil
            for f in pairs(files) do
                if f:match('([^/]+)$') == base then
                    if hit then return nil end
                    hit = f
                end
            end
            return hit
        end,
        -- a script IS its top level: any statement that isn't a function
        -- def / comment runs on load (a top-level assignment writes a
        -- process-global, which is an effect too)
        module_effects = function (root)
            for _, c in inext, root, -1 do
                local t = c:type()
                if c:named() and t ~= 'function_definition' and t ~= 'comment' then
                    return true
                end
            end
            return false
        end,
        stdlib_names = (function ()
            local t = {}
            for _, n in ipairs({
                -- builtins
                'echo', 'printf', 'read', 'cd', 'pwd', 'export', 'unset',
                'shift', 'exit', 'return', 'source', 'eval', 'exec', 'trap',
                'set', 'test', 'true', 'false', 'wait', 'kill', 'ulimit',
                'umask', 'getopts', 'command', 'type', 'hash', 'alias',
                'break', 'continue', 'let', 'readonly', 'caller', 'shopt',
                'complete', 'compgen', 'bind', 'builtin', 'enable', 'mapfile',
                'readarray', 'suspend', 'times', 'disown', 'bg', 'fg', 'jobs',
                -- ubiquitous externals
                'ls', 'cat', 'grep', 'egrep', 'fgrep', 'sed', 'awk', 'cut',
                'tr', 'sort', 'uniq', 'head', 'tail', 'wc', 'find', 'xargs',
                'rm', 'mv', 'cp', 'mkdir', 'rmdir', 'touch', 'chmod', 'chown',
                'ln', 'basename', 'dirname', 'date', 'sleep', 'curl', 'wget',
                'tar', 'gzip', 'git', 'which', 'env', 'id', 'whoami', 'uname',
                'hostname', 'tee', 'stat', 'du', 'df', 'ps', 'mktemp', 'seq',
                'expr', 'dig', 'openssl', 'sudo', 'apt', 'yum', 'dnf',
            }) do t[n] = true end
            return t
        end)(),
}
