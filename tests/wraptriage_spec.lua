-- wraptriage — harvest conflict triage for the wrap/decorator idiom (see
-- lua/cartograph/wraptriage.lua). measure-first found `X = wrap(X)`-then-call produces a
-- SYSTEMATIC cartograph-vs-lua-ls conflict where cartograph is the BETTER side (it keeps the
-- delegating original; lua-ls follows value-flow to the factory). This names that class.
-- The NEGATIVES are the point: triage must attribute ONLY the exact-factory pattern, never a
-- generic conflict (that would hide a real cartograph bug).

local wt = require 'cartograph.wraptriage'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

local SRC = table.concat({
    'local function wrap(v) return v end',            -- 1  the factory (identity in prod)
    'local function GetMainFrame() return 1 end',     -- 2  the original logic
    'GetMainFrame = wrap(GetMainFrame)',              -- 3  X = wrap(X): the fingerprint
    'local other = something.else_()',               -- 4  unrelated reassign-to-call
    'return { GetMainFrame = GetMainFrame }',
}, '\n')

test('wraptriage.reassigns finds X = F(...) sites with name + factory', function ()
    if not ready() then return skip 'no lua parser' end
    local rs = wt.reassigns(SRC)
    local found
    for _, r in ipairs(rs) do if r.name == 'GetMainFrame' then found = r end end
    ok(found, 'the GetMainFrame reassignment was found')
    eq('wrap', found.factory)
    eq(3, found.line)
end)

test('wraptriage.classify names the wrap-passthrough class (cg→original, luals→factory)', function ()
    if not ready() then return skip 'no lua parser' end
    local rs = wt.reassigns(SRC)
    -- cartograph → the called name's own def; lua-ls → the factory `wrap`
    eq('wrap-passthrough', wt.classify('GetMainFrame', 'GetMainFrame', 'wrap', rs))
end)

-- NEGATIVE: cartograph did NOT keep the called name's own def → not this class (leave it a
-- real, unexplained conflict — attributing it would mask a possible cartograph bug).
test('wraptriage.classify does NOT fire when cartograph resolved elsewhere', function ()
    if not ready() then return skip 'no lua parser' end
    local rs = wt.reassigns(SRC)
    eq(nil, wt.classify('GetMainFrame', 'SomethingElse', 'wrap', rs))
end)

-- NEGATIVE: lua-ls's target is NOT the factory the name was reassigned from → not this class.
test('wraptriage.classify does NOT fire when luals target is not the reassignment factory', function ()
    if not ready() then return skip 'no lua parser' end
    local rs = wt.reassigns(SRC)
    eq(nil, wt.classify('GetMainFrame', 'GetMainFrame', 'UnrelatedFunc', rs))
end)

-- NEGATIVE: a name with no reassignment-to-call at all is never wrap-passthrough.
test('wraptriage.classify does NOT fire for a name that was never reassigned', function ()
    if not ready() then return skip 'no lua parser' end
    local rs = wt.reassigns(SRC)
    eq(nil, wt.classify('neverReassigned', 'neverReassigned', 'wrap', rs))
end)

-- nested-patch: lua-ls followed a NESTED runtime reassignment (`X.m = function` inside a
-- method body — the Skada :ImportProfile monkey-patch); cartograph kept the top-level def.
-- Signalled by ls_nested=true (lua-ls's target is a cartograph non-top node of the same name).
test('wraptriage.classify names the nested-patch class (cg→top-level, luals→nested reassignment)', function ()
    -- no parse needed: classify is pure over the passed facts
    eq('nested-patch', wt.classify('ReloadSettings', 'Skada:ReloadSettings',
        'Skada.ReloadSettings', {}, true))
end)

-- NEGATIVE: the nested signal must not fire when the names differ (a real cross-slot conflict).
test('wraptriage.classify does NOT nested-patch when the member names differ', function ()
    eq(nil, wt.classify('ReloadSettings', 'Skada:ReloadSettings', 'Other:Unrelated', {}, true))
end)

-- NEGATIVE: no nested signal → the same inputs are not attributed.
test('wraptriage.classify does NOT nested-patch without the ls_nested signal', function ()
    eq(nil, wt.classify('ReloadSettings', 'Skada:ReloadSettings', 'Skada.ReloadSettings', {}, nil))
end)
