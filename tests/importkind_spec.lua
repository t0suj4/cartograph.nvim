-- WHAT KIND OF IMPORT IS THIS SITE (CART-0510)?
--
-- php spells file inclusion four ways with two independent bits, and the graph
-- collapsed all four into one edge. The bit that matters most is ONCE-NESS: a var
-- inside a multiply-included file is assigned once PER INCLUSION, so any
-- `set-once`/`const` claim about it is unsound — the state atlas wrong for a
-- third distinct reason after CART-0478 (empty evidence) and CART-0479 (missing
-- attribution).
--
-- The tests are mostly about the TRI-STATE. `nil` means this language's syntax
-- does not discriminate; it must never be read as "once", which is why a js
-- import edge carrying no fields at all is pinned below.

local ts = require 'cartograph.providers.treesitter'

local function has_parser(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

--- import edges out of `from`, keyed by the line they sit on
local function imports_by_line(data, from)
    local out = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'import' and e.from == from then
            out[#out + 1] = { to = e.to, once = e.once, soft = e.soft, site = e.site }
        end
    end
    return out
end

test('import kind: php four forms, two independent bits', function ()
    if not has_parser('php') then skip 'no php parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/inc', 'p')
    write(root, 'inc/lib.php', { '<?php', "$g_flag = 1;" })
    -- ONE FORM PER FILE: the edge set dedups per SITE, and per (from,to) the
    -- index would merge them — so four forms need four sources to be told apart.
    write(root, 'a.php', { '<?php', "require_once( 'inc/lib.php' );" })
    write(root, 'b.php', { '<?php', "require( 'inc/lib.php' );" })
    write(root, 'c.php', { '<?php', "include_once( 'inc/lib.php' );" })
    write(root, 'd.php', { '<?php', "include( 'inc/lib.php' );" })
    local data = ts.extract(root)
    local function one(f)
        local l = imports_by_line(data, f)
        eq(1, #l, f .. ' produces exactly one import edge')
        return l[1]
    end
    local ro, r, io_, i = one('a.php'), one('b.php'), one('c.php'), one('d.php')
    eq(true, ro.once, 'require_once re-executes nothing')
    eq(nil, ro.soft, 'and its failure is FATAL, so the include is unconditional')
    eq(false, r.once, 'require re-runs the file every time it is reached')
    eq(nil, r.soft)
    eq(true, io_.once)
    eq(true, io_.soft, 'include_once warns instead of aborting')
    eq(false, i.once, 'include: the unsound-set-once case')
    eq(true, i.soft)
    vim.fn.delete(root, 'rf')
end)

test('import kind: THE PARENTHESISED FORM is the one everyone writes', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- ★ CART-0483's REAL CAUSE, and I had it wrong. `require_once( 'x' )` parses
    -- as require_once_expression -> parenthesized_expression -> string, and the
    -- query matched (require_once_expression (string) @path) — a DIRECT child. So
    -- only the bare `require_once 'x';` spelling ever matched, and mantis's 185
    -- literal require_once('core.php') produced ZERO edges. I filed that as a
    -- path-resolution edge case (separator-less root-relative); it was the whole
    -- parenthesised half of php file inclusion. MEASURED after the fix:
    -- core.php imports_in 0 -> 185, exactly the 185 sites the ticket counted.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/inc', 'p')
    write(root, 'inc/lib.php', { '<?php', "$g_flag = 1;" })
    write(root, 'paren.php', { '<?php', "require_once( 'inc/lib.php' );" })
    write(root, 'bare.php', { '<?php', "require_once 'inc/lib.php';" })
    local data = ts.extract(root)
    eq(1, #imports_by_line(data, 'paren.php'), 'the parenthesised form links')
    eq(1, #imports_by_line(data, 'bare.php'), 'and the bare form still does')
    vim.fn.delete(root, 'rf')
end)

test('import kind: a COMPUTED path stays a frontier, deliberately', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- The non-enumerable include. `require_once( $dir . 'x' )` nests a
    -- binary_expression where the string would be, so neither pattern matches and
    -- no edge is minted. That is the case a boundary summary must REFUSE rather
    -- than aggregate — there is no site list to demand anything of.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/inc', 'p')
    write(root, 'inc/lib.php', { '<?php', "$g_flag = 1;" })
    write(root, 'dyn.php', { '<?php', "$t_dir = 'inc';",
        "require_once( $t_dir . '/lib.php' );" })
    local data = ts.extract(root)
    eq(0, #imports_by_line(data, 'dyn.php'),
        'a computed path mints nothing — an honest frontier, not a guess')
    vim.fn.delete(root, 'rf')
end)

test('import kind: php include INSIDE A FUNCTION is a different site', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- php binds the included file's file-scope vars as the INCLUDING function's
    -- locals, so the same library text has different variable semantics per site.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/inc', 'p')
    write(root, 'inc/lib.php', { '<?php', "$g_flag = 1;" })
    write(root, 'top.php', { '<?php', "include( 'inc/lib.php' );" })
    write(root, 'infn.php', { '<?php', 'function load_it() {',
        "    include( 'inc/lib.php' );", '}' })
    local data = ts.extract(root)
    eq('file', imports_by_line(data, 'top.php')[1].site)
    eq('fn', imports_by_line(data, 'infn.php')[1].site,
        'the enclosing function is part of the boundary fact')
    vim.fn.delete(root, 'rf')
end)

test('import kind: bash source NEVER memoizes — the second language', function ()
    if not has_parser('bash') then skip 'no bash parser' end
    -- Not a php-only fact. `source` / `.` re-execute every time they are reached,
    -- so sourcing in a loop runs the file once per pass. One import_kinds entry
    -- covers both spellings: the query's #any-of? already decided which commands
    -- match, so the enclosing `command` node is the kind.
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/lib', 'p')
    write(root, 'lib/helper.sh', { 'helper_fn() { echo hi; }' })
    write(root, 'main.sh', { 'source lib/helper.sh', '. lib/helper.sh' })
    local data = ts.extract(root)
    local l = imports_by_line(data, 'main.sh')
    ok(#l >= 1, 'bash sourcing links')
    for _, e in ipairs(l) do
        eq(false, e.once, 'source re-executes: once is a POSITIVE false')
        eq('file', e.site)
    end
    vim.fn.delete(root, 'rf')
end)

test('import kind: a language that does not discriminate says NOTHING', function ()
    if not has_parser('javascript') then skip 'no javascript parser' end
    -- ★ THE TRIM, PINNED. js/go/rust module systems are always-once, and
    -- declaring `once = true` for them would be a claim about the RUNTIME rather
    -- than about the site — a promise fact minted from a blanket assertion, which
    -- is the guarantee slot the stdlib-profile work refused. So js declares no
    -- import_kinds and its edges carry no fields at all: nil means NOT ASKED, and
    -- a consumer must never read it as "once".
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/lib', 'p')
    write(root, 'lib/util.js', { 'export function helper() { return 1; }' })
    write(root, 'main.js', { "import { helper } from './lib/util.js';",
        'export function go() { return helper(); }' })
    local data = ts.extract(root)
    local l = imports_by_line(data, 'main.js')
    ok(#l >= 1, 'the js import links')
    for _, e in ipairs(l) do
        eq(nil, e.once, 'not asked — never "once"')
        eq(nil, e.soft)
        eq(nil, e.site, 'and site is not set alone: all three or none')
    end
    vim.fn.delete(root, 'rf')
end)

test('import kind: the imports axis SHOWS a re-running include', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- A fact with no surface is invisible, and this is the surface a reader is
    -- already looking at when the question arises: standing on lib.php, "who
    -- includes me, and does their inclusion re-run me?"
    local store = require 'cartograph.store'
    local axes = require 'cartograph.panes.axes'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/inc', 'p')
    write(root, 'inc/lib.php', { '<?php', "$g_flag = 1;" })
    write(root, 'once.php', { '<?php', "require_once( 'inc/lib.php' );" })
    write(root, 'again.php', { '<?php', "include( 'inc/lib.php' );" })
    store.ingest(ts.extract(root))
    local rows = axes.AXES.imported_by.rows(store, 'inc/lib.php')
    local by = {}
    for _, r in ipairs(rows) do by[r.file] = r end
    eq(2, #rows, 'both includers are rows')
    eq(nil, by['once.php'].rerun, 'require_once does not re-run: no marker')
    eq(true, by['again.php'].rerun, 'include does, and the row says so')
    vim.fn.delete(root, 'rf')
end)
