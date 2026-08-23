-- python's WRITE CLASSIFIER (CART-0532). The write axis is one `if wmode then`
-- in the reduce, and four facts hang off it — rw, gw, gp and flds — so until a
-- language declares `is_write` it carries none of them. python was the third
-- language to answer, after lua and php, and 575 of its 657 vars moved from
-- `unclassified` to `const` on this function alone.
--
-- Every form below was PARSED before it was written down: python spells its
-- assignment targets with five node types and two of them are WRAPPERS
-- (pattern_list for `a, b = f()`, list_splat_pattern for `*rest`), which a
-- classifier that only looks at the immediate parent would miss.

local ts = require 'cartograph.providers.treesitter'

local SRC = table.concat({
    'x = 1',                     -- 1  plain
    'y: int = 2',                -- 2  annotated: a `type` child sits AFTER the target
    'x += 3',                    -- 3  augmented
    'o.prop = 4',                -- 4  member: object AND field both ride the chain
    't[k] = 5',                  -- 5  subscript: t is written, k is READ
    'a, b = f()',                -- 6  destructuring wrapper
    'c, *rest = g()',            -- 7  splat wrapper inside the wrapper
    'for i in items: pass',      -- 8  loop target writes, the iterable reads
    'del x',                     -- 9  delete
    'with open(p) as fh: pass',  -- 10 as-pattern target
    'if (w := h()): pass',       -- 11 walrus
    'print(x)',                  -- 12 a plain read
    'z = t[k]',                  -- 13 a subscript in VALUE position: all reads
}, '\n') .. '\n'

-- PARSER AVAILABILITY, and why this is not a plain `pcall(language.add)`: that
-- call SUCCEEDS here and the parser is still unusable, because nvim ships lua/vim
-- parsers built in and python's comes from nvim-treesitter — which the suite's
-- `-u NONE --noplugin` runtimepath does not include. So the probe is the real
-- capability (can I parse?), and the path is added the way tools/bench.lua does
-- it. A test that always SKIPS is not a fence; this one runs wherever the parser
-- is installed and says so loudly when it is not.
local function parser_for()
    local function try()
        return select(2, pcall(vim.treesitter.get_string_parser, SRC, 'python'))
    end
    local p = try()
    if type(p) == 'table' then return p end
    vim.opt.runtimepath:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
    p = try()
    return type(p) == 'table' and p or nil
end

--- every identifier mention in SRC, as { line, text, is_write }
local function classify()
    local parser = parser_for()
    if not parser then return nil end
    local tree = parser:parse()[1]
    local out = {}
    local function walk(n)
        for c in n:iter_children() do
            if c:named() then
                if c:type() == 'identifier' then
                    out[#out + 1] = {
                        line = select(1, c:range()) + 1,
                        text = vim.treesitter.get_node_text(c, SRC),
                        write = ts.spec.python.is_write(c, n) and true or false }
                end
                walk(c)
            end
        end
    end
    walk(tree:root())
    return out
end

test('pywrite: python declares a write classifier at all', function ()
    ok(type(ts.spec.python.is_write) == 'function', 'is_write is declared')
end)

test('pywrite: every target form is a write and every read is not', function ()
    local ms = classify()
    if not ms then skip 'no python parser' end
    local seen = {}
    for _, m in ipairs(ms) do seen[m.line .. ':' .. m.text] = m.write end
    local WRITES = { '1:x', '2:y', '3:x', '4:o', '4:prop', '5:t', '6:a', '6:b',
        '7:c', '7:rest', '8:i', '9:x', '10:fh', '11:w', '13:z' }
    local READS = { '2:int', '5:k', '6:f', '7:g', '8:items', '10:open', '10:p',
        '11:h', '12:print', '12:x', '13:t', '13:k' }
    for _, k in ipairs(WRITES) do
        ok(seen[k] == true, k .. ' should be a WRITE (got ' .. tostring(seen[k]) .. ')')
    end
    for _, k in ipairs(READS) do
        ok(seen[k] == false, k .. ' should be a READ (got ' .. tostring(seen[k]) .. ')')
    end
end)

-- ★ THE TWO THAT A NAIVE CLASSIFIER GETS WRONG, called out so a future edit
-- cannot quietly lose them:
--   `t[k] = 5`  — the KEY is a read while the object is written, which is why
--                 the subscript arm compares against named_child(0)
--   `z = t[k]`  — the same subscript node in VALUE position, so climbing must
--                 end at the assignment and find the target is NOT this chain
test('pywrite: a subscript key reads, and a subscript in value position reads', function ()
    local ms = classify()
    if not ms then skip 'no python parser' end
    local byline = {}
    for _, m in ipairs(ms) do
        byline[m.line] = byline[m.line] or {}
        byline[m.line][m.text] = m.write
    end
    eq(true, byline[5]['t'])
    eq(false, byline[5]['k'])
    eq(false, byline[13]['t'])
    eq(false, byline[13]['k'])
    eq(true, byline[13]['z'])
end)
