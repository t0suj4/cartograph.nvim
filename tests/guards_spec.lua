-- Guard summaries: write occurrences classify their guard, use edges carry
-- gw = MIN over writes (a true claim about ALL of them):
--   1 some-unguarded | 2 all-guarded | 3 all-SET-ONCE (commutative)
-- Set-once is AST-hardened (tested chain text == written chain text) and
-- conjunct-sound (absence only counts through `and`/`&&`; or-disjuncts,
-- elseif arms and other-field guards must NOT claim it).

local ts = require 'cartograph.providers.treesitter'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

local function gw_of(data, fn_name, var_name)
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    for _, e in ipairs(data.edges) do
        if e.kind == 'use' then
            local f, v = byid[e.from], byid[e.to]
            if f and v and f.name == fn_name and v.name == var_name then
                return e.gw
            end
        end
    end
    return nil
end

test('guards: lua set-once forms, hedges, and soundness traps', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = mkroot('m.lua', table.concat({
        'local t = {}',
        'local memo = {}',
        'local cfg = {}',
        'local reg = {}',
        'local acc = {}',
        'local mix = {}',
        'local function bare() t.x = 1 end',                -- unguarded
        'local function once() if not t.x then t.x = 1 end end',
        'local function oncenil() if memo.k == nil then memo.k = 2 end end',
        'local function idiom() cfg.opt = cfg.opt or 3 end',
        'local function elsearm() if reg.h then use(reg.h) else reg.h = 4 end end',
        'local function conjunct() if not acc.v and ok() then acc.v = 5 end end',
        -- soundness traps: guarded, but NOT set-once
        'local function disjunct() if flag or not mix.a then mix.a = 6 end end',
        'local function elseifarm() if not mix.b then use(1) elseif z() then mix.b = 7 end end',
        'local function otherfield() if mix.other then mix.c = 8 end end',
        'local function looped() while ok() do mix.d = 9 end end',
        -- min aggregation: one set-once write + one unguarded write
        'local function mixed()',
        '    if not mix.e then mix.e = 1 end',
        '    mix.e = 2',
        'end',
        'return { bare, once, oncenil, idiom, elsearm, conjunct, disjunct,',
        '    elseifarm, otherfield, looped, mixed }',
    }, '\n'))
    local data = ts.extract(root)
    eq(1, gw_of(data, 'bare', 't'), 'unguarded write')
    eq(3, gw_of(data, 'once', 't'), 'if not t.x: set-once')
    eq(3, gw_of(data, 'oncenil', 'memo'), '== nil: set-once')
    eq(3, gw_of(data, 'idiom', 'cfg'), 'X = X or v: set-once')
    eq(3, gw_of(data, 'elsearm', 'reg'), 'else-arm of a presence test: set-once')
    eq(3, gw_of(data, 'conjunct', 'acc'), 'absence in AND-conjunct: set-once')
    eq(2, gw_of(data, 'disjunct', 'mix'), 'or-disjunct must NOT claim set-once')
    eq(2, gw_of(data, 'elseifarm', 'mix'), 'elseif arm must NOT claim set-once')
    eq(2, gw_of(data, 'otherfield', 'mix'), 'guard on another field: just guarded')
    eq(2, gw_of(data, 'looped', 'mix'), 'while body: guarded')
    eq(1, gw_of(data, 'mixed', 'mix'), 'min over writes: the unguarded one wins')
end)

test('guards: php isset/empty/coalesce forms and the || trap', function ()
    if not ready('php') then skip 'no php parser' end
    local root = mkroot('m.php', table.concat({
        '<?php',
        '$a = array();',
        '$c = array();',
        '$d = 0;',
        '$e = 0;',
        '$f = 0;',
        '$g = array();',
        'function onceisset() { if (!isset($a["k"])) { $a["k"] = 1; } }',
        'function onceempty() { if (empty($c)) { $c = 2; } }',
        'function coalesce() { $d ??= 3; }',
        'function coalesce2() { $e = $e ?? 4; }',
        'function elsearm() { if ($f) { use($f); } else { $f = 5; } }',
        'function ortrap() { if (!isset($g["k"]) || $z) { $g["k"] = 6; } }',
    }, '\n'))
    local data = ts.extract(root)
    eq(3, gw_of(data, 'onceisset', 'a'), '!isset: set-once')
    eq(3, gw_of(data, 'onceempty', 'c'), 'empty(): set-once')
    eq(3, gw_of(data, 'coalesce', 'd'), '??=: set-once')
    eq(3, gw_of(data, 'coalesce2', 'e'), 'X = X ?? v: set-once')
    eq(3, gw_of(data, 'elsearm', 'f'), 'else-arm: set-once')
    eq(2, gw_of(data, 'ortrap', 'g'), '|| must NOT claim set-once')
end)

test('guards: reads carry no gw; no classifier means absent', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = mkroot('m.lua', table.concat({
        'local t = {}',
        'local function reader() return t.x end',
        'return { reader }',
    }, '\n'))
    local data = ts.extract(root)
    eq(nil, gw_of(data, 'reader', 't'), 'read-only edge: gw absent')
end)
