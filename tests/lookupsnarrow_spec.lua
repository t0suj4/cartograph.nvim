-- NAME-NARROWED LOOKUPS (treesitter.M.lookups `narrow`) — step 2 of
-- index-and-reduce. A demand query touches a few names; these lookups restrict
-- fn_unique/var_named to those names and must answer IDENTICALLY to the full
-- corpus build for every one of them.
--
-- The invariant under test is NARROW THE OUTPUT, NEVER THE EVIDENCE, on two axes:
--   · fn_unique is corpus-wide uniqueness, so it survives a NAME cut and dies
--     under a FILE cut. The negative-control test pins that death — it is the
--     ghost/v8 slice bug, and it is the reason the axis is the name.
--   · scopes is resolved against the COMPLETE module roster even when only a few
--     files get one, because a crate root is found by walking up through that
--     roster. Narrow the roster and the root vanishes.

local ts = require 'cartograph.providers.treesitter'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

local function put(root, rel, text)
    local dir = root .. '/' .. (rel:match('^(.*)/[^/]*$') or '')
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w'))
    fd:write(text)
    fd:close()
end

-- `shared` is defined in BOTH files, so it is corpus-ambiguous and must never be
-- in fn_unique; `only_a` / `only_b` are unique. A file cut that keeps just one
-- file makes `shared` look unique — the bug the negative control reproduces.
local function corpus()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    put(root, 'a.lua', table.concat({
        'local va = 1',
        'local function shared(x) return x end',
        'local function only_a(x) return shared(x) + va end',
        'return { only_a = only_a }',
    }, '\n'))
    put(root, 'b.lua', table.concat({
        'local vb = 2',
        'local function shared(y) return y * 2 end',
        'local function only_b(y) return shared(y) + vb end',
        'return { only_b = only_b }',
    }, '\n'))
    return root
end

local function same(x, y)
    if x == nil or y == nil then return x == y end
    return x.id == y.id and x.file == y.file and x.line == y.line
end

test('narrowed lookups: identical to the full build for every retained name', function ()
    if not ready('lua') then skip 'no lua parser' end
    local data = ts.extract(corpus())
    local full = ts.lookups(data.nodes, data.root)
    local want = { only_a = true, shared = true, va = true }
    local nar = ts.lookups(data.nodes, data.root, { names = want, files = { ['a.lua'] = true } })

    ok(full.fn_unique['only_a'], 'only_a is unique corpus-wide (the full build says so)')
    ok(same(full.fn_unique['only_a'], nar.fn_unique['only_a']), 'only_a: same entry')
    -- shared is defined twice, so NEITHER build may call it unique
    eq(nil, full.fn_unique['shared'])
    eq(nil, nar.fn_unique['shared'])
    -- var_named lists must match element for element, in order
    local fv, nv = full.var_named['va'], nar.var_named['va']
    ok(fv and nv, 'va is a named var in both builds')
    eq(#fv, #nv)
    for i = 1, #fv do ok(same(fv[i], nv[i]), 'va[' .. i .. ']: same entry') end
end)

test('narrowed lookups: nothing outside the requested name set leaks in', function ()
    if not ready('lua') then skip 'no lua parser' end
    local data = ts.extract(corpus())
    local want = { only_a = true }
    local nar = ts.lookups(data.nodes, data.root, { names = want })
    for nme in pairs(nar.fn_unique) do ok(want[nme], 'fn_unique key ' .. nme .. ' was requested') end
    for nme in pairs(nar.var_named) do ok(want[nme], 'var_named key ' .. nme .. ' was requested') end
    eq(nil, nar.fn_unique['only_b'])
end)

test('narrowed lookups: NEGATIVE CONTROL — a FILE cut invents a phantom unique', function ()
    if not ready('lua') then skip 'no lua parser' end
    local data = ts.extract(corpus())
    local full = ts.lookups(data.nodes, data.root)
    -- the unsound cut: keep one file's nodes and build lookups over those alone
    local sliced_nodes = {}
    for _, n in ipairs(data.nodes) do
        if n.file == 'a.lua' then sliced_nodes[#sliced_nodes + 1] = n end
    end
    local sliced = ts.lookups(sliced_nodes, data.root)
    -- a.lua alone makes `shared` look unique; the corpus knows better. This is
    -- what the name axis exists to avoid — if this ever stops diverging, the
    -- positive tests above stop proving anything.
    ok(sliced.fn_unique['shared'], 'the file cut DOES claim shared is unique')
    eq(nil, full.fn_unique['shared'])

    -- and the name cut, given the same name, does NOT make that mistake
    local nar = ts.lookups(data.nodes, data.root, { names = { shared = true } })
    eq(nil, nar.fn_unique['shared'])
end)

test('narrowed lookups: scopes resolve against the COMPLETE module roster', function ()
    if not ready('rust') then skip 'no rust parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    -- two crates: the scope of each file is its crate dir, found by walking up
    -- for lib.rs/main.rs THROUGH the module roster
    put(root, 'one/lib.rs', 'pub fn one_root() -> i32 { 1 }')
    put(root, 'one/inner.rs', 'pub fn one_inner() -> i32 { 2 }')
    put(root, 'two/lib.rs', 'pub fn two_root() -> i32 { 3 }')
    put(root, 'two/inner.rs', 'pub fn two_inner() -> i32 { 4 }')
    local data = ts.extract(root)
    local full = ts.lookups(data.nodes, data.root)
    if not full.scopes then skip 'rust files did not parse into a scoped graph' end

    eq('one', full.scopes['one/inner.rs'])
    eq('two', full.scopes['two/inner.rs'])

    -- narrowing to one crate's name must not change the OTHER crate's scope, and
    -- must not change this one's: the roster stayed whole
    local nar = ts.lookups(data.nodes, data.root,
        { names = { one_inner = true }, files = { ['one/inner.rs'] = true } })
    ok(nar.scopes, 'the narrowed build still carries scopes')
    eq('one', nar.scopes['one/inner.rs'])
    for f, v in pairs(nar.scopes) do
        eq(full.scopes[f], v) -- every scope it did compute equals the full build's
    end
end)
