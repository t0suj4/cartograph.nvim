-- Const-fold ladder step 1: a bare-identifier call argument (argv k='local')
-- is upgraded to a literal (k='lit') when the name folds to a same-file
-- set-once scalar-STRING constant. Sound-only: rebinds/non-string/torn
-- bindings poison the name (stays k='local', honestly unfolded). String-only
-- keeps the k='lit' contract intact. See [[cartograph-const-fold]].

local cf = require 'cartograph.constfold'

-- ---- pure unit: the set-once index (M.record) ------------------------------

test('constfold.record: first string binding is a const', function ()
    local idx = {}
    cf.record(idx, 'm.lua', 'MAJOR', 'AceGUI-3.0')
    eq('AceGUI-3.0', idx['m.lua'].MAJOR, 'string binding recorded')
end)

test('constfold.record: differing rebind poisons', function ()
    local idx = {}
    cf.record(idx, 'm.lua', 'K', 'a')
    cf.record(idx, 'm.lua', 'K', 'b')
    eq(false, idx['m.lua'].K, 'rebind to a different value poisons')
end)

test('constfold.record: identical rebind stays const', function ()
    local idx = {}
    cf.record(idx, 'm.lua', 'K', 'a')
    cf.record(idx, 'm.lua', 'K', 'a')
    eq('a', idx['m.lua'].K, 'same value twice is still const')
end)

test('constfold.record: non-string binding poisons (both orders)', function ()
    local idx = {}
    cf.record(idx, 'm.lua', 'F', nil)          -- e.g. a function value
    cf.record(idx, 'm.lua', 'F', 'x')          -- later string binding
    eq(false, idx['m.lua'].F, 'string-after-nonstring stays poisoned')
    local idx2 = {}
    cf.record(idx2, 'm.lua', 'G', 'x')         -- string first
    cf.record(idx2, 'm.lua', 'G', nil)         -- then non-string rebind
    eq(false, idx2['m.lua'].G, 'nonstring-after-string poisons')
end)

-- ---- pure unit: the argv fold (M.fold) -------------------------------------

test('constfold.fold: k=local upgrades to k=lit with the const value', function ()
    local idx = { ['m.lua'] = { MAJOR = 'AceGUI-3.0' } }
    local calls = { { file = 'm.lua', callee = 'NewLibrary',
        argv = { { k = 'expr' }, { k = 'local', name = 'MAJOR', l = 2 } } } }
    local n = cf.fold(calls, idx)
    eq(1, n, 'one slot folded')
    eq({ k = 'lit', v = 'AceGUI-3.0', cf = true }, calls[1].argv[2],
        'the identifier slot became a literal (name/l dropped, cf provenance)')
    eq({ k = 'expr' }, calls[1].argv[1], 'the method-receiver slot untouched')
end)

test('constfold.fold: poisoned name is NOT folded (stays honest k=local)', function ()
    local idx = { ['m.lua'] = { K = false } }
    local calls = { { file = 'm.lua', callee = 'f',
        argv = { { k = 'local', name = 'K', l = 3 } } } }
    local n = cf.fold(calls, idx)
    eq(0, n, 'nothing folded')
    eq('local', calls[1].argv[1].k, 'a reassigned/ambiguous name stays k=local')
end)

test('constfold.fold: same-file scoping (a name is not folded cross-file)', function ()
    local idx = { ['a.lua'] = { K = 'from-a' } }
    local calls = { { file = 'b.lua', callee = 'f',
        argv = { { k = 'local', name = 'K', l = 1 } } } }
    eq(0, cf.fold(calls, idx), 'a const in a.lua does not fold an arg in b.lua')
end)

-- ---- extraction integration (real parse) -----------------------------------

local function ts_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

local function extract_src(src)
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(src); fd:close()
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    return data
end

local function arg_of(data, callee)
    for _, c in ipairs(data.calls or {}) do
        if c.callee == callee then return c end
    end
end

test('constfold: local MAJOR="X"; f(MAJOR) folds the arg to the literal', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local MAJOR = "AceGUI-3.0"',
        'local function reg() return newlib(MAJOR) end',
    }, '\n'))
    local c = arg_of(data, 'newlib')
    ok(c, 'the newlib call exists')
    local a = c.argv[#c.argv]
    eq('lit', a.k, 'MAJOR arg folded to a literal')
    eq('AceGUI-3.0', a.v, 'with the const value')
    ok(a.cf, 'marked as const-folded')
end)

test('constfold: multi-assign local MAJOR, MINOR = "X", 41 folds the string', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local MAJOR, MINOR = "AceDB-3.0", 41',
        'local function reg() return newlib(MAJOR) end',
    }, '\n'))
    local c = arg_of(data, 'newlib')
    ok(c, 'the newlib call exists')
    eq('AceDB-3.0', c.argv[#c.argv].v, 'MAJOR folds even in a multi-assign')
end)

test('constfold: a reassigned local is NOT folded', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local K = "a"',
        'K = "b"',
        'local function reg() return newlib(K) end',
    }, '\n'))
    local c = arg_of(data, 'newlib')
    ok(c, 'the newlib call exists')
    eq('local', c.argv[#c.argv].k, 'a rebound name stays honestly unfolded')
end)

test('constfold: a function-valued local is NOT folded', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local F = function () return 1 end',
        'local function reg() return newlib(F) end',
    }, '\n'))
    local c = arg_of(data, 'newlib')
    ok(c, 'the newlib call exists')
    -- (the existing callback-arg machinery classifies it k='func'; the const-fold
    -- invariant is simply that it is NOT folded to a string literal)
    local a = c.argv[#c.argv]
    ok(a.k ~= 'lit' and not a.cf, 'a fn-valued local is never a folded string const')
end)
