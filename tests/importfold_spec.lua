-- A COMPUTED IMPORT PATH BUILT FROM SET-ONCE STRINGS IS STILL A PATH (CART-0944).
--
-- `local path = "prototypes/phase-3/compatibility/krastorio2/entity/"` at the top
-- of a file, then `require(path .. "power")` further down, is 93 of se's 661
-- requires — 14.1% of the factorio reference corpus — and produced NO IMPORT EDGE
-- AT ALL. The argument reader's concat arm is guarded on the LEFT being a string
-- (php's `'prefix_' . x` prefix family), so an identifier-left concat fell through
-- to `{ k = 'expr' }` with an EMPTY `args` slot, and the import branch reads an
-- empty slot as "nothing to resolve".
--
-- ★ THE GATE IS CONSTFOLD'S, NOT A NEW ONE. Every leaf must be a plain string
-- literal or a name the same-file const index calls a string; the index poisons a
-- name on ANY rebind or non-string binding. The negative tests below pin that the
-- poison actually reaches the import branch — a fold that silently ignored the
-- poison would pass the positive test alone.
--
-- ⚠ THE OPERATOR IS READ, NOT ASSUMED. `x - "3"` is a `binary_expression` too, so
-- a concat fold that trusts the node type folds subtraction into a path. The
-- operator is compared against `spec.concat_op`, which lua and php already declare.

local ts = require 'cartograph.providers.treesitter'

local function has_parser(lang)
    return pcall(vim.treesitter.language.add, lang)
end

--- extract a throwaway tree; `tree` maps relative path -> source text
local function extract(tree)
    local root = vim.fn.tempname()
    for rel, src in pairs(tree) do
        local dir = rel:match('^(.*)/[^/]*$')
        vim.fn.mkdir(root .. (dir and ('/' .. dir) or ''), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(src); fd:close()
    end
    return ts.extract(root)
end

--- the import targets of `from`, sorted
local function imports_of(data, from)
    local out = {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'import' and e.from == from then out[#out + 1] = e.to end
    end
    table.sort(out)
    return out
end

local TARGET = 'mod/sub/power.lua'
local BODY = 'return { 1 }\n'

test('import fold: a set-once local prefix plus a literal tail resolves', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local data = extract({
        [TARGET] = BODY,
        ['main.lua'] = 'local path = "mod/sub/"\nrequire(path .. "power")\n',
    })
    local got = imports_of(data, 'main.lua')
    -- the TARGET, not merely "an edge": a fold that composed the wrong string
    -- would still produce one edge somewhere
    ok(#got == 1 and got[1] == TARGET,
        'main.lua imports ' .. TARGET .. ', got ' .. vim.inspect(got))
end)

test('import fold: a bare set-once local name resolves too', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local data = extract({
        [TARGET] = BODY,
        ['main.lua'] = 'local m = "mod.sub.power"\nrequire(m)\n',
    })
    ok(vim.deep_equal(imports_of(data, 'main.lua'), { TARGET }),
        'a dotted module name in a set-once local resolves')
end)

test('import fold: a REBOUND name is poisoned — no edge', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local data = extract({
        [TARGET] = BODY,
        ['main.lua'] = 'local path = "mod/sub/"\npath = "elsewhere/"\n'
            .. 'require(path .. "power")\n',
    })
    ok(#imports_of(data, 'main.lua') == 0,
        'a rebind poisons the name and the site stays honestly unresolved')
end)

test('import fold: a non-string tail does not fold', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local data = extract({
        [TARGET] = BODY,
        ['main.lua'] = 'local path = "mod/sub/"\nrequire(path .. power)\n',
    })
    ok(#imports_of(data, 'main.lua') == 0,
        'an unknown tail leaves the whole path unknown')
end)

test('import fold: the OPERATOR is read — only concat folds', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    -- `-` is a binary_expression exactly like `..`; folding by node type alone
    -- would compose "mod/sub/" with "power" here and mint a path the source
    -- never spells
    local data = extract({
        [TARGET] = BODY,
        ['main.lua'] = 'local path = "mod/sub/"\nrequire(path - "power")\n',
    })
    ok(#imports_of(data, 'main.lua') == 0,
        'a non-concat binary operator never folds into a path')
end)

test('import fold: a three-part chain folds', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local data = extract({
        [TARGET] = BODY,
        ['main.lua'] = 'local a = "mod/"\nlocal b = "sub/"\nrequire(a .. b .. "power")\n',
    })
    ok(vim.deep_equal(imports_of(data, 'main.lua'), { TARGET }),
        'every leaf is a known string, so the chain is a known string')
end)

-- ── the php side of the same fold ───────────────────────────────────────────
--
-- ⚠ THE LUA TESTS ABOVE CANNOT PIN THE INTERPOLATION GUARD. A lua `string` node
-- has no non-STR_PARTS children, so in lua that branch is dead code and passes
-- every negative test trivially — "a dead predicate passes all negative tests".
-- php is the language that actually reaches it, and it is also the only other
-- language declaring `concat_op`, so this pair pins BOTH halves of the operator
-- table and the `variable_name` arm at once.

test('import fold: php folds through concat_op and a loader verb', function ()
    if not has_parser('php') then skip 'no php parser' end
    local data = extract({
        ['inc/x.php'] = '<?php function x() {}\n',
        ['main.php'] = "<?php\n$d = 'inc/';\nload_x($d . 'x.php');\n",
    })
    ok(vim.deep_equal(imports_of(data, 'main.php'), { 'inc/x.php' }),
        "php `.` folds a set-once var with a literal tail, got "
            .. vim.inspect(imports_of(data, 'main.php')))
end)

test('import fold: an INTERPOLATED php string is not a literal', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- ⚠⚠ THE FIXTURE FILENAME IS THE TEST. Without the guard, `fold_str` returns
    -- an interpolated string's RAW SOURCE TEXT with the quotes stripped — so
    -- `"$d.php"` is handed to resolve_import as the literal path `$d.php`. That
    -- only mints an edge if a file bears that name, which is why the first
    -- version of this test PASSED WITH THE GUARD DISABLED: `{$d}x.php` resolved
    -- to nothing either way, and the test was pinning the resolver's failure,
    -- not the predicate. A file named `$d.php` makes the wrong answer reachable,
    -- and the test now fails when the guard is removed.
    local data = extract({
        ['$d.php'] = '<?php function wrong() {}\n',
        ['inc/x.php'] = '<?php function x() {}\n',
        ['main.php'] = '<?php\n$d = \'inc/\';\nload_x("$d.php");\n',
    })
    ok(#imports_of(data, 'main.php') == 0,
        'an interpolated string names a VARIABLE and never folds, got '
            .. vim.inspect(imports_of(data, 'main.php')))
end)

-- ★ PHP COMPUTED INCLUDES (CART-0944): mantisbt had 72 `require_once( $dir . 'x.php' )` and none produced an import
-- edge — the import query left a computed path a frontier. PHP's own path constants and a local bound once FOLD:
-- __DIR__ / __FILE__ / DIRECTORY_SEPARATOR / dirname( X [, n] ) / a set-once $x. A prefix the fold cannot know (a
-- global set in another file, a function's return) leaves a literal TAIL, matched at a path-segment boundary while
-- unique, and that edge is hedged.
local function php_edges(data, from)
    local out = {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'import' and e.from == from then out[#out + 1] = e.to .. (e.inferred and ' ~' or '') end
    end
    table.sort(out)
    return out
end
local P = '<?php\n'

test('import fold php: __DIR__, dirname( __DIR__, n ), DIRECTORY_SEPARATOR and a set-once local are EXACT (CART-0944)', function ()
    if not has_parser('php') then skip 'no php parser' end
    local data = extract({
        ['core.php'] = P,
        ['admin/schema.php'] = P,
        ['admin/check/x.php'] = P,
        ['admin/install.php'] = P .. "require_once( dirname( __DIR__ ) . '/core.php' );\nrequire_once( __DIR__ . '/schema.php' );\n",
        ['admin/check/index.php'] = P .. "require_once( dirname( __DIR__, 2 ) . '/core.php' );\n"
            .. "$t_dir = __DIR__ . DIRECTORY_SEPARATOR;\nrequire_once( $t_dir . 'x.php' );\n",
    })
    eq({ 'admin/schema.php', 'core.php' }, php_edges(data, 'admin/install.php'))
    eq({ 'admin/check/x.php', 'core.php' }, php_edges(data, 'admin/check/index.php'), 'n levels up; the local folds through its one binding')
end)

test('import fold php: an unknown PREFIX leaves a hedged unique tail; a tail no file ends with, or two files do, is no edge (CART-0944)', function ()
    if not has_parser('php') then skip 'no php parser' end
    local data = extract({
        ['api/soap/mc_api.php'] = P,
        ['lib/mc_api.php'] = P,
        ['lang/strings_english.txt'] = 'x',
        ['dup/a/z.php'] = P, ['dup/b/z.php'] = P,
        ['core/f.php'] = P .. "function f( $p_dir, $p_lang ) {\n  global $g_absolute_path;\n"
            .. "  $t_soap_dir = $g_absolute_path . 'api/soap/';\n  require_once( $t_soap_dir . 'mc_api.php' );\n"
            .. "  include_once( $p_dir . 'strings_' . $p_lang . '.txt' );\n  require_once( $g_root . 'z.php' );\n}\n",
    })
    eq({ 'api/soap/mc_api.php ~' }, php_edges(data, 'core/f.php'),
        'api/soap/mc_api.php by its tail, hedged — never lib/mc_api.php; a parameter in the middle and an ambiguous tail mint nothing')
end)

test('import fold php: a variable bound twice, bound after the use, or written by .= is not folded as a path (CART-0944)', function ()
    if not has_parser('php') then skip 'no php parser' end
    local data = extract({
        ['a/x.php'] = P, ['b/x.php'] = P,
        ['top.php'] = P, ['a/$g.php'] = P, ['api/xsoap/mc.php'] = P,
        -- (each wrong reading lands on a REAL file, so a guard that did not fire would show as an edge)
        ['a/m.php'] = P .. "$d = __DIR__ . '/../b/';\n$d = __DIR__ . '/';\nrequire_once( $d . 'x.php' );\n",
        ['a/n.php'] = P .. "require_once( $e . 'x.php' );\n$e = __DIR__ . '/';\n",
        ['a/o.php'] = P .. "$f = __DIR__ . '/';\n$f .= 'sub/';\nrequire_once( $f . 'x.php' );\n",
        ['a/q.php'] = P .. "require_once( dirname( __DIR__, 5 ) . '/top.php' );\nrequire_once( __DIR__ . '/../../top.php' );\n",
        ['a/r.php'] = P .. 'require_once( __DIR__ . "/$g.php" );\n',
        ['a/s.php'] = P .. "require_once( $g_root . 'soap/mc.php' );\n",
    })
    for _, f in ipairs { 'a/m.php', 'a/n.php', 'a/o.php' } do
        -- (an unknown prefix leaves the tail x.php, which two files end with: no edge — never a/x.php by a guess)
        eq({}, php_edges(data, f), f .. ': not set-once, so not a path')
    end
    eq({}, php_edges(data, 'a/q.php'), 'above the root, by dirname or by ..: outside the tree — never top.php')
    eq({}, php_edges(data, 'a/r.php'), 'an interpolated string is no literal — never the file named $g.php')
    eq({}, php_edges(data, 'a/s.php'), 'a tail matches at a path-segment boundary: soap/ is not xsoap/')
end)
