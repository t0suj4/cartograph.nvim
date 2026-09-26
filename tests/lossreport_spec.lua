-- tools/lossreport.lua's own guards (CART-0847): the L2 loss report.
--
-- ★ PINNED BOTH WAYS. A report of what the graph did NOT record is cheap to get wrong in either direction: an
-- anchor it forgets reports a loss that is not there, and an anchor too generous hides one that is. So each
-- fixture pins a construct that MUST come out dark (a -spec, a data tuple, an unrecorded literal) beside one that
-- must NOT (a call, a construct carrying a recorded name), and the staging is pinned by a registration tuple the
-- erlreg post-pass claims only after extraction.

local report = dofile(vim.fn.getcwd() .. '/tools/lossreport.lua')

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

local function run(src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.erl', 'w'))
    fd:write(src); fd:close()
    return report.run(root, { lang = 'erlang' })
end

local function row(R, key) return R.rows[key] end

test('lossreport: a -spec is dark (not extracted by decision) and its type "calls" are counted as SKIPPED', function ()
    need()
    local R = run('-module(m).\n-spec f(integer()) -> ok.\nf(X) -> g(X).\ng(_) -> ok.\n')
    -- the whole attribute when nothing touches it (here), its signature when the def's start does (the corpus)
    local sp = row(R, 'spec') or row(R, 'type_sig')
    ok(sp and sp.fin == 1, 'the -spec is one dark construct')
    eq(R.witness.dark, R.witness.skipped, 'every dark call is one the spec skips by decision')
    ok(R.witness.skipped >= 1, 'the type application inside the -spec is a call node, dark by decision')
end)

test('lossreport: a real call is never dark, and a construct carrying a recorded name is touched through it', function ()
    need()
    local R = run('-module(m).\nf(X) -> lists:reverse(g({error, X})).\ng(Y) -> {error, Y}.\n')
    eq(0, R.witness.dark, 'no call is dark')
    eq(nil, row(R, 'remote_module'), 'a qualified call claims its module (the record keeps it in `full`)')
    eq(nil, row(R, 'expr_args'), 'a recorded def claims its header: the parameters are flow\'s')
    eq(nil, row(R, 'tuple'), '{error, Y} carries Y, which the row records: not a dark construct')
    local atom = row(R, 'leaf atom')
    ok(atom and atom.fin >= 1, 'but the atom `error` is a value the graph did not keep')
end)

test('lossreport: a call claims its arguments and, when qualified, its module — away from the statement start', function ()
    need()
    -- the call is NOT the first thing in its statement, so the row's own start point cannot be what touches it
    local R = run('-module(m).\nf(X) -> [X, lists:reverse([1, 2])].\n')
    eq(nil, row(R, 'remote_module'), 'the module half of a remote call is in the record\'s `full`')
    eq(nil, row(R, 'leaf integer'), 'a literal argument is the record\'s argv')
end)

test('lossreport: a row claims the NAMES it records — a nested construct is touched through one', function ()
    need()
    local R = run('-module(m).\ng(Y) -> [ok, {error, Y}].\n')
    eq(nil, row(R, 'tuple'), '{error, Y} is touched through Y')
    local atom = row(R, 'leaf atom')
    ok(atom and atom.pos['tuple.expr'] == 1 and atom.pos['list.exprs'] == 1, 'the atoms are values it did not keep')
end)

test('lossreport: a data tuple with no recorded name is a dark STRUCTURE, reported at its root once', function ()
    need()
    local R = run('-module(m).\nf() -> [{a, b, c}, {d, e}].\n')
    local t = row(R, 'tuple')
    ok(t and t.fin == 2, 'two dark tuples, not five dark atoms')
    ok(t.pos['list.exprs'] == 2, 'positioned by parent type and field')
    local atom = row(R, 'leaf atom')
    ok(not (atom and atom.pos['tuple.expr']), 'the atoms inside a dark tuple are not counted again')
end)

test('lossreport: STAGED — a registration tuple is dark after extraction and claimed by the erlreg post-pass', function ()
    need()
    local R = run('-module(m).\nstart(_, _) ->\n    [{iq_handler, ejabberd_local, ?NS_X, ?MODULE, process_iq}].\n'
        .. 'process_iq(IQ) -> IQ.\n')
    local later = 0
    for _, r in pairs(R.rows) do later = later + (r.later or 0) end
    ok(later >= 1, 'a dark root after extraction is touched in the final graph')
end)

test('lossreport: with no handler to resolve, the post-pass claims nothing', function ()
    need()
    -- ⚠ the tuple itself is TOUCHED at extraction here, and wrongly: flow reads `?NS_X` / `?MODULE` as uses of
    -- variables NS_X and MODULE (a phantom read the self-gate cannot see — the IR makes it too; filed apart)
    local R = run('-module(m).\nstart(_, _) ->\n    [{iq_handler, ejabberd_local, ?NS_X, ?MODULE, missing}].\n')
    local later = 0
    for _, r in pairs(R.rows) do later = later + (r.later or 0) end
    eq(0, later, 'erlreg minted nothing, so nothing was claimed later')
end)
