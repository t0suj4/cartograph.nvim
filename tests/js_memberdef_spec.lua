-- MEMBER-TARGET FUNCTION LITERALS in JS/TS: `X.y = function(){}` / `X.y = () => {}`.
--
-- Until this landed the declarator form (`const f = function(){}`) and the prototype
-- form (`X.prototype.m = …`) both minted a def while the plain member target minted
-- NOTHING — so `jQuery.extend`, `jQuery.Callbacks`, `module.exports.reload` and every
-- other pre-class export were invisible as definitions, and calls to them could not
-- resolve. Lua has always minted the same shape (`M.f = function() end`), so this closed
-- a gap between two front ends. MEASURED (tools/assigndef.lua) at 6.4% of jquery's
-- unresolved calls and 1.9% of ghost's before the fix; after it, on ghost: 1843 calls
-- recovered, 646 lifted out of a refusal, 287 redirected (sampled: corrections, e.g.
-- `notify.notifyServerReady()` had been resolving to boot.js's own local wrapper), 0
-- lost.
--
-- THE VETO IS THE OTHER HALF, and it is what the gates forced. A query cannot ask
-- whether the receiver is a module namespace or a function-local object, and the answer
-- decides whether the def is a fact or noise:
--   · `opt.complete = function(){}` inside jQuery.speed answered every bare
--     `complete()` callback call in the corpus — four confident wrong resolutions
--     replacing four honest refusals.
--   · `this.$each = function(){}` in mootools has TAIL `each` (a `$` is not a word
--     character), so it captured bare `each(…)` calls corpus-wide.
-- Hence spec.skip_def: a per-def veto for exactly the cases a query cannot judge.

local ts = require 'cartograph.providers.treesitter'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'javascript')
end

--- def names of a source string, as a set
local function defs(src, ext)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/f.' .. (ext or 'js'), 'w'))
    fd:write(src); fd:close()
    local by = {}
    for _, n in ipairs(ts.extract(root).nodes) do
        if n.kind == 'function' or n.kind == 'method' then by[n.name] = n end
    end
    vim.fn.delete(root, 'rf')
    return by
end

test('js memberdef: a member-target function literal is a def, keeping its receiver',
    function ()
    if not ready() then skip 'no javascript parser' end
    local by = defs(table.concat({
        'jQuery.member = function () { return 1 };',
        'obj.arrowed = () => 2;',
        'module.exports.expo = function () { return 3 };',
        'A.B.deep = function () { return 4 };',
    }, '\n'))
    ok(by['jQuery.member'], 'plain member target')
    ok(by['obj.arrowed'], 'arrow value counts too')
    ok(by['module.exports.expo'], 'the CommonJS export form')
    ok(by['A.B.deep'], 'a nested namespace keeps its whole path')
    -- the receiver is part of the KEY, never dropped: a bare `member` def would
    -- name-match every unrelated `member()` call in the corpus
    ok(not by['member'] and not by['expo'], 'no bare alias is minted alongside')
end)

test('js memberdef: the declarator and prototype forms still mint as before',
    function ()
    if not ready() then skip 'no javascript parser' end
    local by = defs(table.concat({
        'const decl = function () { return 1 };',
        'const arrow = () => 2;',
        'function Thing() {}',
        'Thing.prototype.proto = function () { return 3 };',
    }, '\n'))
    ok(by['decl'] and by['arrow'], 'declarator forms unchanged')
    -- the prototype collapse is unchanged: `Thing.prototype.proto` -> `Thing.proto`
    ok(by['Thing.proto'], 'prototype still collapses to the class key')
    ok(not by['Thing.prototype.proto'], 'and not under its literal LHS text')
end)

-- THE VETO. Each case below produced a measured wrong resolution on a real corpus.
test('js memberdef: a FUNCTION-LOCAL receiver is vetoed', function ()
    if not ready() then skip 'no javascript parser' end
    local by = defs(table.concat({
        'function speed(spd) {',
        '  var opt = {};',
        '  opt.complete = function () { return 1 };',   -- var in this function
        '  return opt;',
        '}',
        'function destructured({ bag }) {',
        '  bag.cb = function () { return 2 };',         -- a DESTRUCTURED param',
        '}',
        'function listy() {',
        '  var first = 1, hooks, third = 3;',           -- a LATER declarator in a list
        '  hooks.empty = function () { return 3 };',
        '}',
        'function nested() {',
        '  let elemData = {};',
        '  if (true) { elemData.handle = function () { return 4 } }',  -- nested block
        '}',
    }, '\n'))
    for _, junk in ipairs({ 'opt.complete', 'bag.cb', 'hooks.empty',
        'elemData.handle' }) do
        ok(not by[junk], junk .. ' must not become a corpus-wide def')
    end
    -- the enclosing functions themselves are of course still defs
    ok(by['speed'] and by['destructured'] and by['listy'] and by['nested'])
end)

-- The comma-separated `var a = 1, hooks, c = 3` case is called out because a TEXT scan
-- for `var hooks` misses every declarator after the first, which is how jquery declares
-- most of its locals — it let hooks.empty.fire, elemData.handle and
-- xhr.onreadystatechange through on the first attempt. The veto is structural.
test('js memberdef: a MODULE-LEVEL receiver inside a wrapper is NOT vetoed',
    function ()
    if not ready() then skip 'no javascript parser' end
    -- the AMD/IIFE shape every pre-ES6 library uses: the whole file is a function body,
    -- so "inside a function" cannot be the test — only a LOCAL BINDING can be
    local by = defs(table.concat({
        'define(["./core"], function (jQuery) {',
        '  jQuery.param = function () { return 1 };',
        '  return jQuery;',
        '});',
    }, '\n'))
    ok(by['jQuery.param'],
        'a dependency-bound namespace is not a local declaration')
    -- and the distinction that makes this work: a POSITIONAL identifier parameter may
    -- be an AMD dependency (so not local), while a DESTRUCTURED one never is. Vetoing
    -- positional params removed 36 of jquery's 52 new defs — its whole jQuery.* surface.
    local pos = defs('function wrap(dep) { dep.fn = function () { return 1 } }')
    ok(pos['dep.fn'], 'a positional param receiver is kept')
end)

test('js memberdef: a `this` receiver is vetoed (its tail answers foreign calls)',
    function ()
    if not ready() then skip 'no javascript parser' end
    local by = defs(table.concat({
        'function Ctor() {',
        '  this.inst = function () { return 1 };',
        '  this.$each = function () { return 2 };',
        '}',
    }, '\n'))
    ok(not by['this.inst'], '`this.x` names no owner, so it is not a key')
    ok(not by['this.$each'], 'and its tail (`each`) would answer unrelated calls')
    ok(by['Ctor'], 'the constructor itself is still a def')
end)

-- Purely ADDITIVE was a hard requirement: the first version of the veto stripped
-- 62 PRE-EXISTING prototype defs on ghost and 4 on mootools, because those
-- constructors are locals inside a module closure.
test('js memberdef: the veto NEVER removes a prototype def, however scoped',
    function ()
    if not ready() then skip 'no javascript parser' end
    local by = defs(table.concat({
        '(function () {',
        '  var Klass = function () {};',        -- a LOCAL constructor …
        '  Klass.prototype.method = function () { return 1 };',  -- … still a class method
        '  return Klass;',
        '})();',
    }, '\n'))
    ok(by['Klass.method'], 'a prototype assignment on a local constructor survives')
end)

test('js memberdef: TS gets the same treatment', function ()
    if not ready('typescript') then skip 'no typescript parser' end
    local by = defs('export const ns: any = {};\nns.handler = function () { return 1 };\n',
        'ts')
    ok(by['ns.handler'], 'member-target literal in .ts')
end)
