-- CART-2099: an increment `i++` / `--i` WRITES i, like `i += 1` (CART-0433) and go's inc_statement (CART-1896). In c / c++ /
-- js / ts / java / php it is an `update_expression`, which was in no write set, so `i++;` was def={} use={i}: a loop
-- counter's step was a bare read and reaching definitions saw no kill at it. Measured (rows moved / total): 7kaa 5511 /
-- 114964, elasticsearch libs 1489 / 55316, jquery 127 / 3441, mantisbt 92 / 22372; lua / python / go code unchanged
-- (the python and go corpora moved only in the JS / C files they bundle). Call resolution unchanged on five corpora.

local expr = require 'cartograph.expr'

-- per language: `i++`, `--i`, `x = i++` — each row defines i and reads it (rmw)
local FX = {
    c = 'void f(int i, int x) {\n  i++;\n  --i;\n  x = i++;\n}\n',
    cpp = 'void f(int i, int x) {\n  i++;\n  --i;\n  x = i++;\n}\n',
    javascript = 'function f(i, x) {\n  i++;\n  --i;\n  x = i++;\n}\n',
    typescript = 'function f(i: number, x: number) {\n  i++;\n  --i;\n  x = i++;\n}\n',
    java = 'class K { void f(int i, int x) {\n  i++;\n  --i;\n  x = i++;\n} }\n', -- (java's update_expression names no field)
    php = '<?php\nfunction f($i, $x) {\n  $i++;\n  --$i;\n  $x = $i++;\n}\n',
}
local WANT = { 'def={i} use={} rmw={i}', 'def={i} use={} rmw={i}', 'def={i,x} use={} rmw={i}' }

local function row(s)
    local function j(t) local c = vim.deepcopy(t or {}); table.sort(c); return table.concat(c, ',') end
    return ('def={%s} use={%s} rmw={%s}'):format(j(s.def), j(s.use), j(s.rmw))
end

test('increment: `i++`, `--i` and `x = i++` define i and read it, in every language that spells it update_expression (CART-2099)', function ()
    local done = 0
    for lang, src in pairs(FX) do
        if parser_available(lang) then
            local e = expr.of_text(src, lang)
            ok(e, lang .. ': the fixture parses')
            local got = {}
            for _, s in ipairs(e.fl.stmts) do got[#got + 1] = row(s) end
            eq(WANT, got, lang)
            local bad = {}
            for _, d in ipairs(expr.gate(e.fl, lang)) do
                bad[#bad + 1] = ('L%d missing={%s} extra={%s}'):format(d.line, table.concat(d.missing, ','), table.concat(d.extra, ','))
            end
            eq({}, bad, lang .. ': the IR reads exactly what du reads')
            done = done + 1
        end
    end
    ok(done >= 4, 'at least four languages checked: ' .. done)
end)

test('increment: a do-while CONDITION keeps its read — `} while (++i < n)` is def={i} use={n} rmw={i} (CART-2099)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local e = assert(expr.of_text('void f(int i, int n) {\n  do {\n    g(i);\n  } while (++i < n);\n}\n', 'cpp'))
    local cond
    for _, s in ipairs(e.fl.stmts) do if s.kind == 'cond' then cond = s end end
    ok(cond, 'the post-condition has its own row')
    eq('def={i} use={n} rmw={i}', row(cond), 'the rmw half was dropped by the cond row (du returned it, the row did not keep it)')
    eq({}, expr.gate(e.fl, 'cpp'), 'and the IR agrees on it')
end)

-- the INDEPENDENT df builder (the oracle dfparity checks flow against, providers/treesitter.lua collect_mentions) must say
-- the same, or the matrix reads every fix as a mismatch — and nothing else would catch it drifting back. Go's writes
-- (CART-1896) ride along: their oracle half had no spec either.
test('increment: the independent df builder agrees with flow on `i++`, and on go\'s writes — dfparity finds nothing (CART-2099, CART-1896)', function ()
    local files = {
        ['m.c'] = 'int f(int i, int n) {\n  i++;\n  --i;\n  n = i++;\n  return n;\n}\n',
        ['m.js'] = 'function f(i, n) {\n  i++;\n  --i;\n  n = i++;\n  return n;\n}\n',
        ['m.go'] = 'package m\n\nfunc f(a, b int, m map[int]int) int {\n\ta = a + b\n\tx := a\n\tvar t = x\n\tfor k := range m {\n\t\tt += k\n\t}\n\tt++\n\treturn t\n}\n',
    }
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local n = 0
    for rel, text in pairs(files) do
        local lang = ({ c = 'c', js = 'javascript', go = 'go' })[rel:match('%.(%w+)$')]
        if parser_available(lang) then
            local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
            n = n + 1
        end
    end
    if n == 0 then skip 'no c / javascript / go parser' end
    local data = require('cartograph.providers.treesitter').extract(root, { legacy_df = true, cold = true })
    -- ⚠ check() RE-READS THE FILES: deleted first, it compares nothing (nfn = 0) and returns no class — a test that
    -- passes against any oracle. So the root goes after, and the comparison is required to have happened.
    local r = dofile('tools/dfparity.lua').check(data)
    vim.fn.delete(root, 'rf')
    eq(n, r.nfn, 'every fixture function was compared')
    ok(r.nstmt >= n * 4, 'their statements were compared: ' .. tostring(r.nstmt))
    eq({}, r.cats or {}, 'no divergence class on any of them')
end)
