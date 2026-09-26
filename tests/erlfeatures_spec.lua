-- FUNCTIONALITY COMPILED OUT BY DEFAULT (lua/cartograph/erlfeatures.lua): configure switch -> rebar variable -> macro
-- / dependency -> -ifdef branches. User, 2026-09-26: "finding disabled functionality would be nice as otherwise user
-- would be tempted to implement it or search elsewhere". The fixture mirrors ejabberd's SIP chain.

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

local function fixture()
    local root = vim.fn.tempname()
    local function w(p, t) vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. p, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. p, 'w')); fd:write(t); fd:close() end
    w('configure.ac', table.concat({
        'AC_ARG_ENABLE(feat,',
        '[AS_HELP_STRING([--enable-feat],[enable FEAT support (default: no)])],',
        '[case "${enableval}" in yes) feat=true ;; no) feat=false ;; esac],[if test "x$feat" = "x"; then feat=false; fi])',
        'AC_ARG_ENABLE(on,',
        '[AS_HELP_STRING([--disable-on],[disable ON])],',
        '[on=false],[on=true])', '' }, '\n'))
    w('vars.config.in', '{feat, @feat@}.\n{on, @on@}.\n')
    w('rebar.config', table.concat({
        '{deps, [{plain, "1.0", {git, "u"}},',
        '        {if_var_true, feat, {featdep, "~> 1.0", {git, "u", {tag, "1.0"}}}}]}.',
        "{erl_opts, [{if_var_true, feat, {d, 'FEAT'}}, {if_var_true, on, {d, 'ON'}}]}.",
        '{provider_hooks, [{if_var_true, feat, {post, [{compile, {x, y}}]}}]}.', '' }, '\n'))
    w('src/m.erl', table.concat({
        '-module(m).',
        "-ifndef('FEAT').",
        'stub() -> ok.',
        '-else.',
        '-behaviour(featbeh).',
        'real() -> ok.',
        'more(X) -> X.',
        '-endif.',
        "-ifdef('ON').",
        'on_fn() -> ok.',
        '-endif.', '' }, '\n'))
    return root
end

test('erlfeatures: a feature OFF by default — its configure flag, its dependency, and the code it compiles out', function ()
    need()
    local F = require 'cartograph.erlfeatures'
    local root = fixture()
    local by = {}
    for _, f in ipairs(F.features(root)) do by[f.macro] = f end
    local feat = by.FEAT
    eq(false, feat.defined_by_default, '"default: no" in the help string')
    eq('--enable-feat', feat.configure.flag)
    eq(1, #feat.deps, 'the gated DEPENDENCY, not the gated provider hook `{compile, …}`')
    eq('featdep', feat.deps[1].name)
    eq(1, #feat.regions)
    local r = feat.regions[1]
    eq(false, r.compiled_by_default)
    eq(5, r.first); eq(7, r.last, 'the -else branch of an -ifndef is what needs the feature')
    eq({ 'real', 'more' }, r.functions)
    eq(true, by.ON.defined_by_default, 'a --disable-X switch is ON by default')
    eq(true, by.ON.regions[1].compiled_by_default)
    local hit = F.disabled_at(F.features(root), root .. '/src/m.erl', 5)
    eq('FEAT', hit and hit.macro, 'the -behaviour line inside the disabled branch is attributed to FEAT')
    eq(nil, F.disabled_at(F.features(root), root .. '/src/m.erl', 3), 'the stub branch is compiled by default')
    vim.fn.delete(root, 'rf')
end)
