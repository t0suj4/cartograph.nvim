-- Guard summaries: write occurrences classify their guard, use edges carry
-- gw = MIN over writes (a true claim about ALL of them):
--   1 some-unguarded | 2 all-guarded | 3 all-SET-ONCE (commutative)
-- Set-once is AST-hardened (tested chain text == written chain text) and
-- conjunct-sound (absence only counts through `and`/`&&`; or-disjuncts,
-- elseif arms and other-field guards must NOT claim it).

local ts = require 'cartograph.providers.treesitter'

local function ready(lang)
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
-- the FIELD a memo call writes: a dynamic key of its receiver ('[]'), never the method's own name nor the whole var
local function edge_of(data, fn_name, var_name)
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    for _, e in ipairs(data.edges) do
        local f, v = byid[e.from], byid[e.to]
        if e.kind == 'use' and f and v and f.name == fn_name and v.name == var_name then return e end
    end
end
local function flds_of(data, fn_name, var_name) return (edge_of(data, fn_name, var_name) or {}).flds end

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

test('guards: the memo idiom\'s EARLY-EXIT spelling is set-once too — direct, through a local alias, `~= nil`; and its traps are not (CART-1433)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = mkroot('e.lua', table.concat({
        'local ec, al, nn, ok1, nr, ng, ox = {}, {}, {}, {}, {}, {}, {}',
        'local function earlyret(k) if ec[k] then return ec[k] end ec[k] = 1 return ec[k] end',
        'local function aliased(k) local v = al[k] if v then return v end v = 2 al[k] = v return v end',
        'local function nilcheck(k) if nn[k] ~= nil then return nn[k] end nn[k] = 3 end',
        -- traps
        'local function otherkey(a, b) if ok1[a] then return ok1[a] end ok1[b] = 1 end',
        'local function noreturn(k) if nr[k] then use(nr[k]) end nr[k] = 1 end',
        'local function onabsence(k) if not ng[k] then return end ng[k] = 1 end',
        'local function otheralias(j, k) local v = ox[j] if v then return v end ox[k] = 1 end',
        -- the absence test spelled on an alias, the write INSIDE the `if`
        'local ia, ib, ic, ae = {}, {}, {}, {}',
        'local function exitafter(k) ae[k] = 1 if ae[k] then return ae[k] end end',
        'local function inside(k) local v = ia[k] if not v then v = 1 ia[k] = v end return v end',
        'local function insidenil(k) local v = ib[k] if v == nil then ib[k] = 2 end end',
        'local function insideother(j, k) local v = ic[j] if not v then ic[k] = 1 end end',
        'return { earlyret, aliased, nilcheck, otherkey, noreturn, onabsence, otheralias, inside, insidenil, insideother, exitafter }',
    }, '\n'))
    local data = ts.extract(root)
    eq(3, gw_of(data, 'earlyret', 'ec'), 'if c[k] then return c[k] end … c[k] = v')
    eq(3, gw_of(data, 'aliased', 'al'), 'local v = c[k]; if v then return v end … c[k] = v')
    eq(3, gw_of(data, 'nilcheck', 'nn'), 'if c[k] ~= nil then return … end')
    eq(1, gw_of(data, 'otherkey', 'ok1'), 'the exit tests another key: no claim')
    eq(1, gw_of(data, 'noreturn', 'nr'), 'a presence test that does not exit: no claim')
    eq(1, gw_of(data, 'onabsence', 'ng'), 'an exit on ABSENCE leaves only present keys: no claim')
    eq(1, gw_of(data, 'otheralias', 'ox'), 'an alias of another chain: no claim')
    eq(3, gw_of(data, 'inside', 'ia'), 'local v = c[k]; if not v then … c[k] = v end')
    eq(3, gw_of(data, 'insidenil', 'ib'), 'local v = c[k]; if v == nil then … end')
    eq(2, gw_of(data, 'insideother', 'ic'), 'an alias of another key: guarded, not set-once')
    eq(1, gw_of(data, 'exitafter', 'ae'), 'an exit AFTER the write guards nothing')
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

test('guards: javascript / typescript — ??= ||= and the coalesce forms, !X / == null / typeof, else arms; || and other-field traps (CART-1573)', function ()
    for _, case in ipairs({ { 'javascript', 'm.js' }, { 'typescript', 'm.ts' } }) do
        if not ready(case[1]) then skip('no ' .. case[1] .. ' parser') end
        local root = mkroot(case[2], table.concat({
            'let t = {};', 'let memo = {};', 'let cfg = {};', 'let c2 = {};', 'let reg = {};', 'let acc = {};', 'let ty = {};',
            'let mix = {};', 'let oth = {};',
            'function bare() { t.x = 1; }',                                   -- unguarded
            'function once() { if (!t.y) { t.y = 1; } }',
            'function oncenull(k) { if (memo[k] == null) { memo[k] = 2; } }',
            'function nullish(k) { cfg[k] ??= 3; }',
            'function orassign() { c2.v ||= 4; }',
            'function coalesce() { reg.h = reg.h ?? 5; }',
            'function elsearm() { if (acc.v !== undefined) { use(acc.v); } else { acc.v = 6; } }',
            'function typeofc() { if (typeof ty.q === "undefined") { ty.q = 7; } }',
            -- soundness traps: guarded, but NOT set-once
            'function ortrap(z) { if (!mix.a || z) { mix.a = 8; } }',
            'function otherfield() { if (!oth.a) { oth.b = 9; } }',
        }, '\n'))
        local data = ts.extract(root)
        local how = case[1] .. ': '
        eq(1, gw_of(data, 'bare', 't') == 1 and 1 or gw_of(data, 'bare', 't'), how .. 'bare: unguarded')
        eq(3, gw_of(data, 'once', 't'), how .. '!X: set-once')
        eq(3, gw_of(data, 'oncenull', 'memo'), how .. 'X == null: set-once')
        eq(3, gw_of(data, 'nullish', 'cfg'), how .. '??=: set-once')
        eq(3, gw_of(data, 'orassign', 'c2'), how .. '||=: set-once (the memo idiom)')
        eq(3, gw_of(data, 'coalesce', 'reg'), how .. 'X = X ?? v: set-once')
        eq(3, gw_of(data, 'elsearm', 'acc'), how .. 'else arm of !== undefined: set-once')
        eq(3, gw_of(data, 'typeofc', 'ty'), how .. "typeof X === 'undefined': set-once")
        eq(2, gw_of(data, 'ortrap', 'mix'), how .. '|| must NOT claim set-once')
        eq(2, gw_of(data, 'otherfield', 'oth'), how .. 'a test of ANOTHER field is a guard, not set-once')
    end
end)

test('guards: python — is None / not / `k not in c` / else arms / `x = x or v`; `or` and other-field traps (CART-1574)', function ()
    if not ready('python') then skip 'no python parser' end
    local root = mkroot('m.py', table.concat({
        't = {}', 'memo = {}', 'cache = {}', 'cfg = {}', 'reg = {}', 'acc = {}', 'mix = {}', 'oth = {}', 'st = Box()',
        'def bare():\n    t["x"] = 1',
        'def once(k):\n    if memo.get(k) is None:\n        pass\n    if not st.ready:\n        st.ready = 1',
        'def member(k):\n    if k not in cache:\n        cache[k] = 2',
        'def isnone():\n    if cfg.opt is None:\n        cfg.opt = 3',
        'def elsearm(k):\n    if k in reg:\n        use(reg[k])\n    else:\n        reg[k] = 4',
        'def idiom():\n    acc.v = acc.v or 5',
        -- soundness traps: guarded, but NOT set-once
        'def ortrap(z):\n    if not mix.a or z:\n        mix.a = 6',
        'def otherfield():\n    if oth.a is None:\n        oth.b = 7',
    }, '\n'))
    local data = ts.extract(root)
    eq(1, gw_of(data, 'bare', 't'), 'bare: unguarded')
    eq(3, gw_of(data, 'once', 'st'), 'not X: set-once')
    eq(3, gw_of(data, 'member', 'cache'), 'k not in c: set-once on c[k]')
    eq(3, gw_of(data, 'isnone', 'cfg'), 'X is None: set-once')
    eq(3, gw_of(data, 'elsearm', 'reg'), 'else arm of `k in reg`: set-once')
    eq(3, gw_of(data, 'idiom', 'acc'), 'x = x or v: set-once')
    eq(2, gw_of(data, 'ortrap', 'mix'), '`or` must NOT claim set-once')
    eq(2, gw_of(data, 'otherfield', 'oth'), 'a test of ANOTHER field is a guard, not set-once')
end)

test('guards: c / c++ — !g, == NULL / nullptr, else arms of presence tests; || and other-field traps (CART-1576)', function ()
    for _, case in ipairs({ { 'c', 'm.c', 'NULL' }, { 'cpp', 'm.cpp', 'nullptr' } }) do
        if not ready(case[1]) then skip('no ' .. case[1] .. ' parser') end
        local null = case[3]
        local root = mkroot(case[2], table.concat({
            'struct S { int *x; int *a; int *b; };',
            'static int t;', 'static int *memo;', 'static struct S *s;', 'static int *reg;', 'static int *mix;', 'static struct S *oth;',
            'void bare(void) { t = 1; }',
            'void once(void) { if (!memo) { memo = alloc(); } }',
            'void isnull(void) { if (s->x == ' .. null .. ') { s->x = alloc(); } }',
            'void elsearm(void) { if (reg != ' .. null .. ') { use(reg); } else { reg = alloc(); } }',
            'void ortrap(int z) { if (!mix || z) { mix = alloc(); } }',
            'void otherfield(void) { if (!oth->a) { oth->b = alloc(); } }',
        }, '\n'))
        local data = ts.extract(root)
        local how = case[1] .. ': '
        eq(1, gw_of(data, 'bare', 't'), how .. 'bare: unguarded')
        eq(3, gw_of(data, 'once', 'memo'), how .. '!g: set-once')
        eq(3, gw_of(data, 'isnull', 's'), how .. '== ' .. null .. ': set-once')
        eq(3, gw_of(data, 'elsearm', 'reg'), how .. 'else arm of != ' .. null .. ': set-once')
        eq(2, gw_of(data, 'ortrap', 'mix'), how .. '|| must NOT claim set-once')
        eq(2, gw_of(data, 'otherfield', 'oth'), how .. 'a test of ANOTHER field is a guard, not set-once')
    end
end)

test('guards: go — == nil, the comma-ok memo, else arms by FIELD; else-if, ||, other-field and initializer traps (CART-1579)', function ()
    if not ready('go') then skip 'no go parser' end
    local root = mkroot('m.go', table.concat({
        'package m',
        'var t int', 'var memo map[string]int', 'var memo2 map[string]int', 'var reg *C', 'var cfg *C', 'var mix *C', 'var oth *C', 'var t3 int',
        'func bare() { t = 1 }',
        'func once() { if memo == nil { memo = make(map[string]int) } }',
        'func commaok(k string) { if _, ok := memo2[k]; !ok { memo2[k] = 2 } }',
        'func elsearm() { if reg != nil { use(reg) } else { reg = new(C) } }',
        -- traps: guarded, but NOT set-once
        'func elseif(z bool) { if cfg != nil { use(cfg) } else if z { cfg = new(C) } }', -- (an else-if arm never claims set-once, as in lua)
        'func ortrap(z bool) { if mix == nil || z { mix = new(C) } }',
        'func otherfield() { if oth.a == nil { oth.b = new(C) } }',
        -- an initializer runs unconditionally
        'func initw() { if t3 = 5; t3 > 0 { use(1) } }',
    }, '\n'))
    local data = ts.extract(root)
    eq(1, gw_of(data, 'bare', 't'), 'bare: unguarded')
    eq(3, gw_of(data, 'once', 'memo'), '== nil: set-once')
    eq(3, gw_of(data, 'commaok', 'memo2'), 'the comma-ok memo: set-once')
    eq(3, gw_of(data, 'elsearm', 'reg'), 'else arm (a bare block, by field) of != nil: set-once')
    eq(2, gw_of(data, 'elseif', 'cfg'), 'an else-if arm is guarded, never set-once')
    eq(2, gw_of(data, 'ortrap', 'mix'), '|| must NOT claim set-once')
    eq(2, gw_of(data, 'otherfield', 'oth'), 'a test of ANOTHER field is a guard, not set-once')
    eq(1, gw_of(data, 'initw', 't3'), 'an `if` initializer is unconditional')
end)

test('guards: rust — is_none() / == None / !X, else arms of is_some() / != None; || and other-field traps (CART-1582)', function ()
    if not ready('rust') then skip 'no rust parser' end
    local root = mkroot('m.rs', table.concat({
        'static mut T: i32 = 0;', 'static mut MEMO: Option<i32> = None;', 'static mut CFG: Option<i32> = None;',
        'static mut REG: Option<i32> = None;', 'static mut FLAG: bool = false;', 'static mut MIX: Option<i32> = None;',
        'static mut OTH: S = S { a: None, b: None };',
        'fn bare() { unsafe { T = 1; } }',
        'fn once() { unsafe { if MEMO.is_none() { MEMO = Some(1); } } }',
        'fn eqnone() { unsafe { if CFG == None { CFG = Some(2); } } }',
        'fn elsearm() { unsafe { if REG.is_some() { use_it(); } else { REG = Some(3); } } }',
        'fn notflag() { unsafe { if !FLAG { FLAG = true; } } }',
        'fn ortrap(z: bool) { unsafe { if MIX.is_none() || z { MIX = Some(4); } } }',
        'fn otherfield() { unsafe { if OTH.a.is_none() { OTH.b = Some(5); } } }',
    }, '\n'))
    local data = ts.extract(root)
    eq(1, gw_of(data, 'bare', 'T'), 'bare: unguarded')
    eq(3, gw_of(data, 'once', 'MEMO'), 'is_none(): set-once')
    eq(3, gw_of(data, 'eqnone', 'CFG'), '== None: set-once')
    eq(3, gw_of(data, 'elsearm', 'REG'), 'else arm of is_some(): set-once')
    eq(3, gw_of(data, 'notflag', 'FLAG'), '!X: set-once')
    eq(2, gw_of(data, 'ortrap', 'MIX'), '|| must NOT claim set-once')
    eq(2, gw_of(data, 'otherfield', 'OTH'), 'a test of ANOTHER field is a guard, not set-once')
end)

test('guards: java — == null on a field or this.f, !X, else arms by FIELD; else-if, || and other-field traps (CART-1583)', function ()
    if not ready('java') then skip 'no java parser' end
    local root = mkroot('K.java', table.concat({
        'class K {',
        '    static int t; Object memo; Object cfg; Object reg; boolean ready; Object st; Object mix; Object oth; Object oth2;',
        '    void bare() { t = 1; }',
        '    void once() { if (memo == null) { memo = new Object(); } }',
        '    void thisnull() { if (this.cfg == null) { this.cfg = new Object(); } }',
        '    void elsearm() { if (reg != null) { use(reg); } else { reg = new Object(); } }',
        '    void notready() { if (!ready) { ready = true; } }',
        '    void elseif(boolean z) { if (st != null) { use(st); } else if (z) { st = new Object(); } }',
        '    void ortrap(boolean z) { if (mix == null || z) { mix = new Object(); } }',
        '    void otherfield() { if (oth2 == null) { oth = new Object(); } }',
        '}',
    }, '\n'))
    local data = ts.extract(root)
    eq(1, gw_of(data, 'K::bare', 't'), 'bare: unguarded')
    eq(3, gw_of(data, 'K::once', 'memo'), '== null: set-once')
    eq(3, gw_of(data, 'K::thisnull', 'cfg'), 'this.f == null: set-once')
    eq(3, gw_of(data, 'K::elsearm', 'reg'), 'else arm (a bare block, by field) of != null: set-once')
    eq(3, gw_of(data, 'K::notready', 'ready'), '!X: set-once')
    eq(2, gw_of(data, 'K::elseif', 'st'), 'an else-if arm is guarded, never set-once')
    eq(2, gw_of(data, 'K::ortrap', 'mix'), '|| must NOT claim set-once')
    eq(2, gw_of(data, 'K::otherfield', 'oth'), 'a test of ANOTHER field is a guard, not set-once')
end)

test('guards: java memo CALLS — computeIfAbsent / putIfAbsent write their receiver set-once; put / get do not (CART-1585)', function ()
    if not ready('java') then skip 'no java parser' end
    local root = mkroot('M.java', table.concat({
        'import java.util.*;',
        'class M {',
        '    Map<String, Integer> cache; Map<String, Integer> m2; Map<String, Integer> plain; Map<String, Integer> rd; Map<String, Integer> mx;',
        '    int putIfAbsent; Map<String, Integer> oth;',
        '    void namepos(String k) { oth.putIfAbsent(k, 5); }',
        '    int memo(String k) { return cache.computeIfAbsent(k, x -> 1); }',
        '    void thisput(String k) { this.m2.putIfAbsent(k, 2); }',
        '    void bare(String k) { plain.put(k, 3); }',
        '    void mixed(String k) { mx = null; mx.putIfAbsent(k, 4); }',
        '    int reader(String k) { return rd.get(k); }',
        '}',
    }, '\n'))
    local data = ts.extract(root)
    eq(3, gw_of(data, 'M::memo', 'cache'), 'computeIfAbsent: a set-once write of its receiver')
    eq(3, gw_of(data, 'M::thisput', 'm2'), 'this.f.putIfAbsent: set-once')
    eq({ ['[]'] = 3 + 3 * 4 }, flds_of(data, 'M::memo', 'cache'), 'a dynamic key of cache — not a whole-var rebind (\'\')')
    eq({ ['[]'] = 3 + 3 * 4 }, flds_of(data, 'M::thisput', 'm2'), 'this.m2 is m2 itself: a dynamic key of it')
    eq(nil, gw_of(data, 'M::bare', 'plain'), 'put is not a memo call: a read on this axis (a mutator call is no write)')
    eq(1, gw_of(data, 'M::mixed', 'mx'), 'a plain assignment beside a memo call: the MIN over writes is unguarded')
    eq(nil, gw_of(data, 'M::reader', 'rd'), 'get is a read: no gw')
    eq(nil, gw_of(data, 'M::namepos', 'putIfAbsent'), 'a field NAMED like the method, in the method-name position: not its receiver')
end)

test('guards: python memo CALLS — d.setdefault writes d set-once at a dynamic key; a nested receiver keeps its field (CART-1585)', function ()
    if not ready('python') then skip 'no python parser' end
    local root = mkroot('m.py', table.concat({
        '_cache = {}', '_cfg = {}', '_plain = {}', '_mx = {}',
        'def memo(k):', '    return _cache.setdefault(k, k * 2)',
        'def nested(k):', '    _cfg.sub.setdefault(k, [])',
        'def bare(k):', '    _plain.get(k)',
        'def mixed(k):', '    _mx[k] = 1', '    _mx.setdefault(k, 2)',
        'class C:', '    def m(self, k):', '        return self._memo.setdefault(k, 1)',
    }, '\n'))
    local data = ts.extract(root)
    eq(3, gw_of(data, 'memo', '_cache'), 'setdefault: a set-once write of its receiver')
    eq({ ['[]'] = 3 + 3 * 4 }, flds_of(data, 'memo', '_cache'), 'at a DYNAMIC key, not the field `setdefault`')
    eq({ sub = 3 + 3 * 4 }, flds_of(data, 'nested', '_cfg'), '_cfg.sub.setdefault writes the field sub')
    eq(nil, gw_of(data, 'bare', '_plain'), 'get is a read')
    eq(1, gw_of(data, 'mixed', '_mx'), 'an unguarded store beside the memo call: MIN over writes')
    eq(3, gw_of(data, 'C.m', 'C._memo'), 'an instance field: self._memo.setdefault is set-once')
    eq(3, edge_of(data, 'memo', '_cache').rw, 'a memo call READS too (it tests the key, returns the slot): never dead state')
    eq(3, edge_of(data, 'C.m', 'C._memo').rw, '...and so does an instance field\'s')
end)

test('guards: go memo CALLS — m.LoadOrStore writes m set-once at a dynamic key; Load reads (CART-1585)', function ()
    if not ready('go') then skip 'no go parser' end
    local root = mkroot('m.go', table.concat({
        'package m', 'import "sync"',
        'var cache sync.Map', 'var cfg struct{ sub sync.Map }', 'var plain sync.Map',
        'func memo(k string) any {', '\tv, _ := cache.LoadOrStore(k, 1)', '\treturn v', '}',
        'func nested(k string) {', '\tcfg.sub.LoadOrStore(k, 2)', '}',
        'func bare(k string) {', '\tplain.Load(k)', '}',
    }, '\n'))
    local data = ts.extract(root)
    eq(3, gw_of(data, 'memo', 'cache'), 'LoadOrStore: a set-once write of its receiver')
    eq({ ['[]'] = 3 + 3 * 4 }, flds_of(data, 'memo', 'cache'), 'at a DYNAMIC key, not the field `LoadOrStore`')
    eq({ sub = 3 + 3 * 4 }, flds_of(data, 'nested', 'cfg'), 'cfg.sub.LoadOrStore writes the field sub')
    eq(nil, gw_of(data, 'bare', 'plain'), 'Load is a read')
end)

test('guards: rust memo CALLS — get_or_init, get_or_insert_with, entry(k).or_insert are set-once; and_modify is not (CART-1585)', function ()
    if not ready('rust') then skip 'no rust parser' end
    local root = mkroot('m.rs', table.concat({
        'use std::sync::OnceLock;',
        'static CELL: OnceLock<u32> = OnceLock::new();',
        'static mut MAP: Option<HashMap<u32, u32>> = None;',
        'static mut CFG: Cfg = Cfg { sub: None };',
        'static mut UPD: Option<HashMap<u32, u32>> = None;',
        'fn memo() -> u32 {', '    *CELL.get_or_init(|| 1)', '}',
        'fn entry(k: u32) {', '    unsafe { MAP.entry(k).or_insert(2); }', '}',
        'fn nested() {', '    unsafe { CFG.sub.get_or_insert_with(|| 3); }', '}',
        'fn modify(k: u32) {', '    unsafe { UPD.entry(k).and_modify(|v| *v += 1).or_insert(0); }', '}',
        'static mut OTH: Option<HashMap<u32, u32>> = None;',
        'fn other(k: u32) {', '    unsafe { OTH.get_mut(k).or_insert(0); }', '}',
        'static mut INI: Option<HashMap<u32, u32>> = None;',
        'fn init(k: u32) -> W {', '    unsafe { W { or_insert: INI.entry(k) } }', '}',
    }, '\n'))
    local data = ts.extract(root)
    eq(3, gw_of(data, 'memo', 'CELL'), 'get_or_init: a set-once write of the cell')
    eq({ ['[]'] = 3 + 3 * 4 }, flds_of(data, 'memo', 'CELL'), 'its slot, not the field `get_or_init`')
    eq(3, gw_of(data, 'entry', 'MAP'), 'entry(k).or_insert: set-once')
    eq({ sub = 3 + 3 * 4 }, flds_of(data, 'nested', 'CFG'), 'CFG.sub.get_or_insert_with writes the field sub')
    eq(nil, gw_of(data, 'modify', 'UPD'), 'entry(k).and_modify(..) updates a PRESENT key: not a memo call')
    eq(nil, gw_of(data, 'other', 'OTH'), 'or_insert after a method that is not entry: not a memo call')
    eq(nil, gw_of(data, 'init', 'INI'), 'entry(k) as the value of a struct field NAMED or_insert: not a method chain')
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
