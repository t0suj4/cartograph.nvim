-- ACCESS BY STRING KEY (CART-0504): a variable named as DATA.
--
-- The whole design claim is that the transform is DERIVED from the accessor's
-- own body rather than declared, so these tests are mostly about what the
-- derivation refuses. A declared rule cannot be wrong about a function it names;
-- a derivation can be wrong about any function it reads, which is why every
-- refusal below is a test rather than a comment.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local keyaccess = require 'cartograph.keyaccess'

local function has_parser(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

local function ingest(root)
    local data = ts.extract(root)
    store.ingest(data)
    return data
end

local function fn_named(data, name)
    for _, n in ipairs(data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.name == name then
            return n.id
        end
    end
end

test('keyaccess: the transform is DERIVED from the accessor body', function ()
    if not has_parser('php') then skip 'no php parser' end
    local root = mkroot('cfg.php', '<?php\n'
        .. "$g_theme = 'dark';\n"
        .. "$g_limit = 10;\n"
        .. 'function opt_get( $p_name ) {\n'
        .. "    $t_var = 'g_' . $p_name;\n"
        .. '    return $GLOBALS[$t_var];\n'
        .. '}\n'
        .. 'function show() {\n'
        .. "    return opt_get( 'theme' );\n"
        .. '}\n')
    local data = ingest(root)
    local id = fn_named(data, 'opt_get')
    local sig = keyaccess.direct(store, id)
    ok(sig, 'opt_get is recognised as an accessor')
    eq(1, sig.param, 'the KEY is argument 1 — read off the parameter list')
    eq('g_', sig.prefix, "the prefix comes from the concat, not from a declared rule")
    eq('', sig.suffix)
    eq('r', sig.rw)
    eq('direct', sig.via)
    -- and the call site resolves to the var the transform names
    local sites = keyaccess.sites(store)
    eq(1, #sites)
    eq('g_theme', sites[1].name)
    eq('cfg.php::var:g_theme@1', sites[1].var)
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: the DIRECTION falls out of the index position', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- THE ARGUMENT FOR DERIVING RATHER THAN DECLARING, as a test. A hand-written
    -- table of "config accessors" has to know that opt_set writes the global and
    -- opt_store writes a database, and the names give no clue whatsoever. The
    -- index position says it: one assigns $GLOBALS[…], the other never mentions it.
    local root = mkroot('s.php', '<?php\n'
        .. "$g_theme = 'dark';\n"
        .. 'function opt_set( $p_name, $p_value ) {\n'
        .. "    $GLOBALS['g_' . $p_name] = $p_value;\n"
        .. '}\n'
        .. 'function opt_store( $p_name, $p_value ) {\n'
        .. '    return db_write( $p_name, $p_value );\n'
        .. '}\n')
    local data = ingest(root)
    local w = keyaccess.direct(store, fn_named(data, 'opt_set'))
    ok(w, 'the writer is an accessor')
    eq('w', w.rw, 'assigning the global table is a WRITE')
    local other, why = keyaccess.direct(store, fn_named(data, 'opt_store'))
    eq(nil, other, 'a function that writes somewhere ELSE is not an accessor')
    eq('no-global-index', why)
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: a FORWARDER inherits the transform through a resolved call', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- mantis's shape: config_get is 1371 of the call sites and touches no global
    -- table at all — it ends in `return config_get_global( $p_option, … )`.
    local root = mkroot('f.php', '<?php\n'
        .. "$g_theme = 'dark';\n"
        .. 'function opt_get_global( $p_name ) {\n'
        .. "    return $GLOBALS['g_' . $p_name];\n"
        .. '}\n'
        .. 'function opt_get( $p_name, $p_default = null ) {\n'
        .. '    return opt_get_global( $p_name, $p_default );\n'
        .. '}\n'
        .. 'function show() {\n'
        .. "    return opt_get( 'theme' );\n"
        .. '}\n')
    local data = ingest(root)
    local accs = keyaccess.accessors(store)
    local fwd = accs[fn_named(data, 'opt_get')]
    ok(fwd, 'the forwarder is an accessor too')
    eq('forward', fwd.via)
    eq('g_', fwd.prefix, 'and it carries the transform it forwards to')
    eq(1, fwd.param)
    local sites = keyaccess.sites(store, accs)
    eq(1, #sites, 'the call through the forwarder resolves')
    eq('f.php::var:g_theme@1', sites[1].var)
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: a key it cannot reduce makes the function OPAQUE, not guessed', function ()
    if not has_parser('php') then skip 'no php parser' end
    local root = mkroot('o.php', '<?php\n'
        .. 'function two_ways( $p_a, $p_b ) {\n'
        .. '    return $GLOBALS[$p_a . $p_b];\n'   -- two params: no single key
        .. '}\n'
        .. 'function rebound( $p_name ) {\n'
        .. "    $t = 'g_' . $p_name;\n"
        .. "    $t = 'h_' . $p_name;\n"            -- written twice: no one value
        .. '    return $GLOBALS[$t];\n'
        .. '}\n'
        .. 'function via_call( $p_name ) {\n'
        .. '    return $GLOBALS[normalize( $p_name )];\n'
        .. '}\n')
    local data = ingest(root)
    local _, accs_opaque = keyaccess.accessors(store)
    for _, nm in ipairs({ 'two_ways', 'rebound', 'via_call' }) do
        local sig, why = keyaccess.direct(store, fn_named(data, nm))
        eq(nil, sig, nm .. ' must not be given a transform')
        ok(why and why ~= '', nm .. ' records WHY it was refused: ' .. tostring(why))
    end
    eq('concat-of-two-unknowns', (select(2, keyaccess.direct(store, fn_named(data, 'two_ways')))))
    eq('multi-assigned', (select(2, keyaccess.direct(store, fn_named(data, 'rebound')))))
    ok(next(accs_opaque), 'and they are reported as the roster own frontier')
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: a DYNAMIC key is a frontier and an AMBIGUOUS name resolves to nothing', function ()
    if not has_parser('php') then skip 'no php parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.php', { '<?php', "$g_dup = 1;", 'function reader( $p_name ) {',
        "    return $GLOBALS['g_' . $p_name];", '}' })
    write(root, 'b.php', { '<?php', "$g_dup = 2;" })
    write(root, 'c.php', { '<?php', 'function use_it( $p_x ) {',
        "    $t_amb = reader( 'dup' );",     -- name has TWO bearers
        '    $t_dyn = reader( $p_x );',      -- key is not a literal
        '    return $t_amb . $t_dyn;', '}' })
    local data = ingest(root)
    local accs = keyaccess.accessors(store)
    local sites, st = keyaccess.sites(store, accs)
    eq(0, #sites, 'neither site yields a resolvable read')
    eq(1, st.ambiguous, 'g_dup has two bearers, so it resolves to NOTHING (CART-0505)')
    eq(1, st.dynamic, 'and a non-literal key is counted as a frontier, not dropped')
    local _ = data
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: lua reaches _G the same way, and a literal key is not an accessor', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root = mkroot('g.lua', 'local cfg_theme = "dark"\n'
        .. 'local function get(name)\n'
        .. '    return _G["cfg_" .. name]\n'
        .. 'end\n'
        .. 'local function fixed()\n'
        .. '    return _G["cfg_theme"]\n'
        .. 'end\n'
        .. 'return get("theme"), fixed()\n')
    local data = ingest(root)
    local sig = keyaccess.direct(store, fn_named(data, 'get'))
    ok(sig, 'the lua accessor is derived from _G, declared in spec/lua.lua')
    eq('cfg_', sig.prefix)
    local no, why = keyaccess.direct(store, fn_named(data, 'fixed'))
    eq(nil, no, 'a CONSTANT key is a plain global read, not a string-keyed accessor')
    eq('literal-key', why)
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: a language without the global-scope guarantee resolves NOTHING', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    -- ★ THE FABRICATION THIS REFUSAL WAS BOUGHT WITH. Measured on
    -- ~/work/wow_addons: `_G["OnTooltipSetItem"]` in four separate addons
    -- resolved to Panda/GemTooltip.lua's `local OnTooltipSetItem`, which is a
    -- LOCAL and not in _G at all. "the only var node with that name" is not the
    -- same claim as "the variable that name reaches", and lua's difference is one
    -- keyword that no var node records (`exported` is set by handle_fn only, so
    -- a var carries nil = never asked). So lua declares no global_scope_vars and
    -- its sites are BLOCKED -- counted, not silently absent, because "this
    -- language cannot say" is a different fact from "the name names nothing".
    -- Costs a genuinely correct hit (a bare `x = 1` IS in _G); CART-0500 records
    -- the binding form and turns this per-node.
    local root = mkroot('w.lua', 'local hooked = function () end\n'
        .. 'local function fetch(n)\n'
        .. '    return _G["hook" .. n]\n'
        .. 'end\n'
        .. 'return fetch("ed")\n')
    local data = ingest(root)
    local sig = keyaccess.direct(store, fn_named(data, 'fetch'))
    ok(sig, 'the accessor is still DERIVED — only resolution is refused')
    local sites, st = keyaccess.sites(store)
    eq(0, #sites, 'and `local hooked` is not offered as the answer')
    eq(1, st.blocked, 'the site is counted as BLOCKED, not as "no node"')
    eq(0, st.nonode, 'which is a different fact and must not absorb it')
    vim.fn.delete(root, 'rf')
end)

-- ── CONSUMPTION (CART-0507): the reads become visible, nothing is minted ─────

test('keyaccess: the read index is memoized per GRAPH IDENTITY', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- deriving an accessor re-parses its file (~525 ms on mantis), so the index
    -- must be built once and must not outlive the graph it describes
    local root = mkroot('m.php', '<?php\n'
        .. "$g_theme = 'dark';\n"
        .. 'function opt( $p_name ) {\n'
        .. "    return $GLOBALS['g_' . $p_name];\n"
        .. '}\n'
        .. 'function show() { return opt( \'theme\' ); }\n')
    local data = ingest(root)
    local id = 'm.php::var:g_theme@1'
    local a = keyaccess.read_index(store)
    local b = keyaccess.read_index(store)
    ok(a == b, 'the same graph yields the SAME table (memoized, not rebuilt)')
    eq(1, #keyaccess.reads_of(store, id))
    eq('g_theme', keyaccess.reads_of(store, id)[1].name)
    -- a fresh ingest is a new graph, so the memo must not answer for it
    store.ingest({ root = '/x', nodes = {}, edges = {}, calls = {} })
    ok(keyaccess.read_index(store) ~= a, 'a re-ingest gets a fresh index')
    local _ = data
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: the atlas counts a derived read only when ASKED', function ()
    if not has_parser('php') then skip 'no php parser' end
    local atlas = require 'cartograph.atlas'
    local root = mkroot('a.php', '<?php\n'
        .. "$g_theme = 'dark';\n"
        .. 'function opt( $p_name ) {\n'
        .. "    return $GLOBALS['g_' . $p_name];\n"
        .. '}\n'
        .. 'function show() { return opt( \'theme\' ); }\n')
    ingest(root)
    local id = 'a.php::var:g_theme@1'
    local off = atlas.classify(store, id)
    eq(0, off.nr, 'default is unchanged: no caller pays for the re-parse silently')
    eq(nil, off.dnr)
    local on = atlas.classify(store, id, { derived = true })
    eq(1, on.nr, 'asked, the string-keyed read counts as the read it is')
    eq(1, on.dnr, 'and is reported separately, because the label cannot carry it')
    eq('const', on.label, 'reads never threaten constancy, so the label is const')
    -- ★ A KNOWING FLIP (CART-0478). This pair used to assert off.label ==
    -- on.label, both `const` -- which was true only because `nw == 0 -> const`
    -- was tested before any evidence check, so a var with NOTHING got the
    -- strongest word on the ladder. Now the default says `unobserved` (nothing
    -- was seen) and asking says `const` (a read was seen), which is a strictly
    -- better pair: the two answers differ exactly where the evidence differs.
    eq('unobserved', off.label,
        'unasked, there is no evidence, so no claim is made')
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: a var read ONLY by key is not dead state', function ()
    if not has_parser('php') then skip 'no php parser' end
    -- the label-FLIP case, which is rare and real: written by a function, read
    -- only through the accessor. Measured population on mantis: exactly one var.
    local atlas = require 'cartograph.atlas'
    local root = mkroot('d.php', '<?php\n'
        .. "$g_count = 0;\n"
        .. 'function bump() {\n'
        .. '    global $g_count;\n'
        .. '    $g_count = $g_count + 1;\n'
        .. '}\n'
        .. 'function opt( $p_name ) {\n'
        .. "    return $GLOBALS['g_' . $p_name];\n"
        .. '}\n'
        .. 'function report() { return opt( \'count\' ); }\n')
    ingest(root)
    local id = 'd.php::var:g_count@1'
    local on = atlas.classify(store, id, { derived = true })
    ok(on.dnr and on.dnr >= 1, 'the keyed read is found')
    ok(on.label ~= 'dead',
        'a promise ("written but never read") must not ignore a read it can see')
    vim.fn.delete(root, 'rf')
end)

test('keyaccess: the var altitude shows a derived read, naming its accessor', function ()
    if not has_parser('php') then skip 'no php parser' end
    local symbols = require 'cartograph.panes.symbols'
    local root = mkroot('v.php', '<?php\n'
        .. "$g_theme = 'dark';\n"
        .. 'function opt_get( $p_name ) {\n'
        .. "    return $GLOBALS['g_' . $p_name];\n"
        .. '}\n'
        .. 'function show() { return opt_get( \'theme\' ); }\n')
    ingest(root)
    symbols.create(); symbols.win = nil
    store.set_focus('v.php::var:g_theme@1')
    symbols.show('var', 'v.php::var:g_theme@1')
    symbols.render()
    local text = table.concat(
        vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false), '\n')
    ok(text:match('by key'), 'the title says where the evidence came from: ' .. text)
    ok(text:match('opt_get'), 'and a row NAMES its accessor, so a derived read is'
        .. ' not mistaken for a syntactic one: ' .. text)
    ok(text:match('~'), 'marked derived per row')
    vim.fn.delete(root, 'rf')
end)
