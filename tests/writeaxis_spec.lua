-- THE WRITE AXIS, cross-language (CART-0532). Four facts — e.rw, e.gw, e.gp,
-- e.flds — hang off ONE gate in the reduce (`if wmode then`), and `wmode` is
-- `spec.is_write ~= nil`. So a language either answers the write question or
-- carries none of the four; there is no partial state.
--
-- ...except there WAS one, and it shipped. `spec.write_gate` is the parent-type
-- prefilter that decides whether the classifier is ever CALLED:
--     wgate and wgate[nt] and is_write(c, n)
-- v147 declared python's `is_write` and not its `write_gate`. The classifier was
-- never invoked, every mention classified as a READ, `wmode` was still true, and
-- atlas minted `const` — "never assigned again" — over a write detection that had
-- not executed: 22 of 575 vars, wrong label, shipped. THE PAIR RULE BELOW IS THAT
-- BUG'S FENCE, and the per-language form tests are how each new language proves
-- its classifier actually fires.

local ts = require 'cartograph.providers.treesitter'

--- parse `src` as `lang` and return every identifier-ish mention as
--- { line, text, parent, write }. nil when the parser is unavailable.
--- The rtp dance is deliberate: nvim ships lua/vim parsers built in, every other
--- grammar comes from nvim-treesitter, and the suite runs `-u NONE --noplugin`.
--- `pcall(language.add, …)` SUCCEEDS regardless, so the probe has to be an actual
--- parse. A fence that always skips is not a fence.
local function mentions(lang, src)
    local function try()
        return select(2, pcall(vim.treesitter.get_string_parser, src, lang))
    end
    local parser = try()
    if type(parser) ~= 'table' then
        vim.opt.runtimepath:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
        parser = try()
    end
    if type(parser) ~= 'table' then return nil end
    local tree = parser:parse()[1]
    if not tree then return nil end
    local out = {}
    local function walk(n)
        for c in n:iter_children() do
            if c:named() then
                local t = c:type()
                if t == 'identifier' or t == 'field_identifier' then
                    out[#out + 1] = { line = select(1, c:range()) + 1,
                        text = vim.treesitter.get_node_text(c, src),
                        parent = n:type(),
                        write = ts.spec[lang].is_write(c, n) and true or false }
                end
                walk(c)
            end
        end
    end
    walk(tree:root())
    return out
end

--- assert the classifier's answer for every listed `line:text`, and that the
--- write_gate covers every parent type it answered TRUE for.
local function check(lang, src, writes, reads)
    local ms = mentions(lang, src)
    if not ms then skip('no ' .. lang .. ' parser') end
    local seen, uncovered = {}, {}
    local gate = ts.spec[lang].write_gate or {}
    for _, m in ipairs(ms) do
        seen[m.line .. ':' .. m.text] = m.write
        if m.write and not gate[m.parent] then uncovered[#uncovered + 1] = m.parent end
    end
    for _, k in ipairs(writes) do
        ok(seen[k] == true, lang .. ' ' .. k .. ' should be a WRITE (got '
            .. tostring(seen[k]) .. ')')
    end
    for _, k in ipairs(reads) do
        ok(seen[k] == false, lang .. ' ' .. k .. ' should be a READ (got '
            .. tostring(seen[k]) .. ')')
    end
    -- a form the classifier answers TRUE for but the gate omits is UNREACHABLE
    -- in the extractor, which is the half-declaration bug in miniature
    eq({}, uncovered)
end

-- ★ THE PAIR RULE. contract.lua registers is_write and write_gate as two
-- independent slots and cannot say they are one capability; this can.
test('writeaxis: is_write and write_gate are declared TOGETHER or not at all', function ()
    local lonely = {}
    for lang, sp in pairs(ts.spec) do
        if (sp.is_write ~= nil) ~= (sp.write_gate ~= nil) then
            lonely[#lonely + 1] = ('%s (is_write=%s write_gate=%s)'):format(
                lang, tostring(sp.is_write ~= nil), tostring(sp.write_gate ~= nil))
        end
    end
    eq({}, lonely)
end)

test('writeaxis: java — field/array targets, updates, and declarations that BIND', function ()
    check('java', [[
class K {
    static int g = 0;
    void m(int[] a, K o) {
        g = 1;
        g += 2;
        this.f = 3;
        o.f = 4;
        a[0] = 5;
        g++;
        --g;
        int x = 6;
        K.g = 7;
        System.out.println(g + a[1] + o.f);
        int y = a[g];
    }
}
]],
        -- `o.f` and `K.g`: BOTH halves ride the write chain, as in lua and go
        { '4:g', '5:g', '6:f', '7:o', '7:f', '8:a', '9:g', '10:g', '12:K', '12:g' },
        -- `int x = 6` BINDS (variable_declarator), which is what keeps set-once
        -- reachable; line 13 is a call and line 14 an array read in VALUE
        -- position, where the array AND the index both read
        { '11:x', '13:System', '13:out', '13:println', '13:g', '13:a', '13:o',
          '13:f', '14:y', '14:a', '14:g' })
end)

test('writeaxis: go — three ways to bind, one to write, and an anonymous operator', function ()
    check('go', [[
package p

func f(m map[string]int, s []int, o *T) {
	g = 1
	o.Field = 2
	m["k"] = 3
	g++
	x := 4
	var y = 5
	*o.P = 6
	for i := range s { _ = i }
	for q = range s { }
	a, b = c, d
	z = o.Field
	_ = x; _ = y; _ = m["j"]
}
]],
        { '4:g', '5:o', '5:Field', '6:m', '7:g', '10:o', '10:P', '12:q',
          '13:a', '13:b', '14:z' },
        -- `x := 4` and `var y = 5` BIND · `for i := range` binds while
        -- `for q = range` writes, and the two differ only by an ANONYMOUS `:=`
        -- vs `=` child · `a, b = b, a` reads the same two names it writes ·
        -- `z = o.Field` reads both halves
        { '8:x', '9:y', '11:i', '11:s', '12:s', '13:c', '13:d',
          '14:o', '14:Field', '15:m' })
end)

-- ★ THE SWAP, kept as its own test because the generic helper above CANNOT
-- express it: `a, b = b, a` puts the same two names on both sides of one line,
-- so a line:name key collides and whichever mention is walked last wins. (It
-- did, and the first version of this file failed on exactly that.) Counting is
-- the honest assertion: four mentions, two writes, two reads, decided only by
-- which expression_list holds them.
test('writeaxis: go — the same name written and read on one line', function ()
    local ms = mentions('go', 'package p\nfunc f() {\n\ta, b = b, a\n}\n')
    if not ms then skip 'no go parser' end
    local w, r = 0, 0
    for _, m in ipairs(ms) do
        if m.line == 3 then
            if m.write then w = w + 1 else r = r + 1 end
        end
    end
    eq(2, w)
    eq(2, r)
end)

test('writeaxis: rust — two assignment node types, nested fields, and `let` binds', function ()
    check('rust', [[
static mut G: i32 = 0;

fn f(s: &mut S, a: &mut [i32], p: &mut i32) {
    let mut x = 1;
    x = 2;
    x += 3;
    s.field = 4;
    a[0] = 5;
    *p = 6;
    s.inner.deep = 7;
    let y = a[x];
    G = 8;
}
]],
        { '5:x', '6:x', '7:s', '7:field', '8:a', '9:p', '10:s', '10:inner',
          '10:deep', '12:G' },
        -- `let mut x = 1` BINDS even with the mutable_specifier · `a[x]` in value
        -- position reads the array AND the index
        { '4:x', '11:y', '11:a', '11:x' })
end)

-- ★ FIELD CAPTURE IS DERIVED FROM member_positions (CART-0530), not from a
-- hardcoded list. Before v151 the gate named lua's two forms and php's two, so
-- eight languages captured no field at all — and python's case is the sharpest:
-- it had 909 flds ENTRIES and zero NAMES, every one the '' whole-var key.
test('writeaxis: a language with a member form and a write classifier captures FIELDS', function ()
    local want = { 'python', 'go', 'java', 'rust' }
    for _, lang in ipairs(want) do
        local sp = ts.spec[lang]
        ok(sp.member_positions ~= nil, lang .. ' declares a member form')
        ok(sp.is_write ~= nil, lang .. ' declares a write classifier')
    end
    -- and the gate is INERT without the classifier, which is why widening it
    -- alone measured zero before v147: the attachment site is inside `if wmode`
    for _, lang in ipairs({ 'ruby', 'zig', 'javascript', 'haskell' }) do
        eq(nil, ts.spec[lang].is_write)
    end
end)

-- ★ BRACKET KEYS, and the fabrication that nearly shipped (CART-0533). Generalising
-- the bracket arm from a hardcoded two-name list to spec.index_positions took java's
-- `atanTab[i] = v` from a claimed REBIND of a `final` array (47 such in libs) to a
-- field-qualified write. The near-miss: an EMPTY string literal key has no content
-- child, so falling back to the node's own text yields the QUOTES as a field name —
-- and the un-quoted reading is the empty string, which IS the whole-var sentinel.
-- Caught by ONE changed edge on a 2.27M-line lua control, visible only because
-- CART-0531 put the field count in the signature.
test('writeaxis: a bracket key names a field, or honestly says it is dynamic', function ()
    local ts_ = require 'cartograph.providers.treesitter'
    local data = ts_.extract(vim.fn.getcwd() .. '/tests/fixtures/bracketkey')
    local flds
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'use' and (e.to or ''):find('var:t@', 1, true) then flds = e.flds end
    end
    ok(flds, 'the fixture yields one use edge with field facts')
    local function w(f) return flds[f] and flds[f] % 4 >= 2 end
    ok(w('named'), 'a DOT member names its field')
    ok(w('lit'), 'a string-literal key names its field')
    ok(w('[]'), 'a dynamic key says so')
    -- the empty-string key must land in '[]' and NOT invent a name; in particular
    -- it must not become a whole-var WRITE, which is what would confuse a mutation
    -- with a rebind
    eq(nil, flds["''"])
    ok(not w(''), 'no whole-var write: the empty key did not become the sentinel')
    -- the whole-var entry exists as a READ only (`return t`)
    ok(flds[''] and flds[''] % 4 == 1, 'whole-var access is a read here')
end)
