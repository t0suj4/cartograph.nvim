-- A COMPOUND assignment `a += b` IS `a = a + b` (CART-0433): its target is DEFINED and READ. Measured before:
-- python / ruby / rust recorded `def={} use={a,b}` — the target never defined, so a loop accumulator had no
-- definition and an earlier one flowed past it — and js / c / cpp / java / php / bash / zig `def={a} use={b} rmw={}`,
-- the read lost (the read rides on the operator, so no use-position `a` existed for the rmw rule to see). Now every one
-- matches its plain twin: def={a} use={b} rmw={a}. And the expression IR reads the target too, or the gate reports
-- `missing={a}` on every accumulator (c / cpp / java / bash / zig spell `+=` on the plain node type).

local expr = require 'cartograph.expr'

local FX = {
    javascript = 'function f(a, b) {\n  a += b;\n  a = a + b;\n}\n',
    c = 'void f(int a, int b) {\n  a += b;\n  a = a + b;\n}\n',
    cpp = 'void f(int a, int b) {\n  a += b;\n  a = a + b;\n}\n',
    java = 'class K { void f(int a, int b) {\n  a += b;\n  a = a + b;\n} }\n',
    rust = 'fn f(mut a: i32, b: i32) {\n  a += b;\n  a = a + b;\n}\n',
    python = 'def f(a, b):\n  a += b\n  a = a + b\n',
    ruby = 'def f(a, b)\n  a += b\n  a = a + b\nend\n',
    php = '<?php\nfunction f($a, $b) {\n  $a += $b;\n  $a = $a + $b;\n}\n',
}

test('compound assignment: `a += b` defs a, reads b, and records the self-read in rmw — like `a = a + b`', function ()
    local done = 0
    for lang, src in pairs(FX) do
        if parser_available(lang) then
            local e = expr.of_text(src, lang)
            ok(e, lang .. ': the fixture parses')
            local rows = {}
            for _, s in ipairs(e.fl.stmts) do
                rows[#rows + 1] = ('def={%s} use={%s} rmw={%s}'):format(table.concat(s.def or {}, ','),
                    table.concat(s.use or {}, ','), table.concat(s.rmw or {}, ','))
            end
            eq({ 'def={a} use={b} rmw={a}', 'def={a} use={b} rmw={a}' }, rows, lang .. ': `a += b` then `a = a + b`')
            done = done + 1
        end
    end
    ok(done >= 4, 'at least four languages checked: ' .. done)
end)

test('compound assignment: the expression IR reads the target too — the gate is silent on every accumulator', function ()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local files = {
        ['m.c'] = 'int f(int a, int b) {\n  a += b;\n  return a;\n}\n',
        ['K.java'] = 'class K { int f(int a, int b) {\n  a += b;\n  return a;\n} }\n',
        ['m.sh'] = 'f() {\n  a+=$b\n  echo $a\n}\n',
        ['m.zig'] = 'fn f(a0: u32, b: u32) u32 {\n  var a = a0;\n  a += b;\n  return a;\n}\n',
        ['m.js'] = 'function f(a, b) {\n  a += b;\n  return a;\n}\n',
    }
    for rel, text in pairs(files) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close() end
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local seen, bad = 0, {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            local e = expr.of(store, n.id)
            if e then
                seen = seen + 1
                for _, d in ipairs(expr.gate(e.fl, e.lang)) do
                    bad[#bad + 1] = ('%s L%d missing={%s} extra={%s}'):format(n.file, d.line,
                        table.concat(d.missing, ','), table.concat(d.extra, ','))
                end
            end
        end
    end
    vim.fn.delete(root, 'rf') -- (after: expr.of re-reads each file)
    ok(seen >= 3, 'the functions were harvested: ' .. seen)
    eq({}, bad, 'IR and du agree on every compound row')
end)
