-- CART-0695: `prov = 'base'` was the RESIDUE of every call resolved before the passes ran, and it held two opposite
-- mechanisms — a BARE name match, and an exact match on a key the spec had QUALIFIED FROM A TYPE it inferred for the
-- receiver (java's declared types, go / rust binders, php's $this). The split is stamped from qualify_call's own
-- mechanism (c.qhow), never from the key's spelling: a class the source WROTE (`Util.m()`, `T::m`) stays `base`, and a
-- typed key that missed exact and landed by its tail stays `base`. Measured: elasticsearch/libs base 16,669 -> base
-- 6,656 + recv 10,013 (binder 4,908, self 4,966, ctor 120, super 19); ripgrep 504 of 4,254 (the name test read 52.1%);
-- luanti/src 0 (C++ has no qualify_call). Every `to` unchanged; inline == parallel == warm relink.

local ts = require 'cartograph.providers.treesitter'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function at(data, file, line, callee)
    for _, c in ipairs(data.calls) do
        if c.file == file and c.line == line and (not callee or c.callee == callee) then return c end
    end
end

test('prov recv: java — a declared binder, an implicit this and a `new T()` receiver are recv; a written class is base (CART-0695)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({
        ['a/Store.java'] = 'package a;\npublic class Store {\n  public int get() { return 1; }\n  public static int util() { return 2; }\n}\n',
        ['a/User.java'] = table.concat({
            'package a;',
            'public class User {',
            '  int helper() { return 0; }',
            '  int run(Store s) {',
            '    int x = s.get();',           -- line 4 (0-based): binder
            '    int y = helper();',          -- 5: implicit this
            '    int z = new Store().get();', -- 6: ctor receiver
            '    int w = Store.util();',      -- 7: a class the source wrote
            '    return x + y + z + w;',
            '  }',
            '}', '' }, '\n'),
    })
    local data = ts.extract(root)
    local function pv(line, callee)
        local c = at(data, 'a/User.java', line, callee); return { c and c.prov, c and c.qhow, c and c.to ~= nil }
    end
    eq({ 'recv', 'binder', true }, pv(4))
    eq({ 'recv', 'self', true }, pv(5))
    eq({ 'recv', 'ctor', true }, pv(6, 'get'))
    eq({ 'base', 'written', true }, pv(7), 'the source named the class: no type was inferred')
    vim.fn.delete(root, 'rf')
end)

test('prov recv: a typed key that MISSES exact and lands by its tail stays base (CART-0695)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- tally() is inherited: Child::tally has no def, so the qualified key misses exact and Base::tally lands otherwise
    local root = tree({
        ['p/Base.java'] = 'package p;\npublic class Base {\n  public int tally() { return 1; }\n}\n',
        ['p/Child.java'] = 'package p;\npublic class Child extends Base {\n  int go() { return tally(); }\n}\n',
    })
    local data = ts.extract(root)
    local c = at(data, 'p/Child.java', 2)
    eq('self', c.qhow)
    ok(c.to, 'resolved: ' .. vim.inspect(c))
    ok(c.prov ~= 'recv', 'not an exact match on the typed key: ' .. tostring(c.prov))
    vim.fn.delete(root, 'rf')
end)

test('prov recv: go and rust binders are recv; a bare function call is base (CART-0695)', function ()
    local files, want = {}, {}
    if parser_available('go') then
        files['g/m.go'] = 'package g\n\ntype Site struct{}\n\nfunc (s *Site) Render() int { return 1 }\n\nfunc helper() int { return 2 }\n\nfunc use(s *Site) int {\n\treturn s.Render() + helper()\n}\n'
        want[#want + 1] = 'go'
    end
    if parser_available('rust') then
        files['r/lib.rs'] = 'struct B;\nimpl B {\n    fn key(&self) -> i32 { 1 }\n}\nfn helper() -> i32 { 2 }\nfn use_it(b: &B) -> i32 {\n    b.key() + helper()\n}\n'
        want[#want + 1] = 'rust'
    end
    if #want == 0 then skip 'no go / rust parser' end
    local data = ts.extract(tree(files))
    local seen = {}
    for _, c in ipairs(data.calls) do
        if c.to then seen[(c.file:match('^(%a)/')) .. ':' .. c.callee] = { c.prov, c.qhow } end
    end
    if files['g/m.go'] then
        eq({ 'recv', 'binder' }, seen['g:Render']); eq('base', seen['g:helper'][1])
    end
    if files['r/lib.rs'] then
        eq({ 'recv', 'binder' }, seen['r:key']); eq('base', seen['r:helper'][1])
    end
end)

test('prov recv: php — $this-> is recv (self), an explicit T::m() is base (written) (CART-0695)', function ()
    if not parser_available('php') then skip 'no php parser' end
    local root = tree({ ['c.php'] = table.concat({
        '<?php',
        'class T {',
        '  public static function make() { return 1; }',
        '  public function a() { return 1; }',
        '  public function b() {',
        '    $x = $this->a();', -- line 5
        '    $y = T::make();',  -- line 6
        '    return $x + $y;',
        '  }',
        '}', '' }, '\n') })
    local data = ts.extract(root)
    local c5, c6 = at(data, 'c.php', 5), at(data, 'c.php', 6)
    eq({ 'recv', 'self' }, { c5.prov, c5.qhow })
    eq({ 'base', 'written' }, { c6.prov, c6.qhow })
    vim.fn.delete(root, 'rf')
end)
