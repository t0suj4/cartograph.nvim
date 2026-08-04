-- THE BEFORE/AFTER BEHAVIOUR CERTIFICATE (CART-0264) — neutrality with real assertions.
--
-- The load-bearing test is the LAST one: a case where the witness proxy gets BOTH answers
-- backwards and the certificate gets both right. Everything else here is the honesty around it —
-- the coverage gap, positional replay, and the arity refusal.

local cert = require 'cartograph.certificate'
local neu = require 'cartograph.neutrality'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local root
local function write(src)
    vim.fn.writefile(vim.split(src, '\n'), root .. '/m.lua')
    local d = ts.extract(root); d.root = d.root or root
    store.ingest(d)
end
local function proj(src)
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(src)
end
local function cleanup() if root then vim.fn.delete(root, 'rf'); root = nil end end
local function id_of(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and n.kind == 'function' then return n.id end
    end
end
local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function names(list)
    local t = {}
    for _, e in ipairs(list) do t[#t + 1] = e.name end
    table.sort(t)
    return t
end
local NUM = { value = '3', basis = 'a number', by = 'agent' }

test('certificate: a symbol it cannot RUN is a coverage GAP, not a neutral', function ()
    if not ready() then skip('no lua parser') end
    -- A HASH ALWAYS COMPUTES; A RUN DOES NOT. So a certificate that counted an unrunnable symbol
    -- as neutral would carry the PROXY's coverage while implying the ASSERTION's strength — worse
    -- than the proxy alone, because it would read as stronger.
    proj(table.concat({
        'local M = {}',
        'function M.add(a) return a + 1 end',
        'function M.needs(t) return t.k end',
        'return M',
    }, '\n') .. '\n')
    local c = cert.take(store, { ids = { id_of('M.add'), id_of('M.needs') },
        fills = { ['input:a'] = NUM } })
    eq(1, #c.entries, 'the runnable one is observed')
    eq(1, #c.uncertifiable, 'and the other is NAMED as uncertifiable')
    eq('M.needs', c.uncertifiable[1].name)
    ok(c.uncertifiable[1].why:find('still a hole', 1, true), c.uncertifiable[1].why)
    local text = table.concat(cert.report(assert(cert.check(store, c))), '\n')
    ok(text:find('ONLY WITNESSED', 1, true), 'the report names the gap')
    ok(text:find('M.needs', 1, true), 'by symbol')
    cleanup()
end)

test('certificate: a fill that matched NOTHING is reported', function ()
    if not ready() then skip('no lua parser') end
    -- fills are a shared pool filtered per plan (one bag cannot fit every symbol), and filtering
    -- without accounting is how a mistyped id does nothing quietly
    proj('local M = {}\nfunction M.add(a) return a + 1 end\nreturn M\n')
    local c = cert.take(store, { ids = { id_of('M.add') },
        fills = { ['input:a'] = NUM, ['input:typo'] = NUM } })
    eq(1, #c.entries)
    eq(1, #(c.unused or {}), 'the unmatched fill is recorded')
    eq('input:typo', c.unused[1])
    cleanup()
end)

test('certificate: inputs replay BY POSITION, so a param RENAME survives', function ()
    if not ready() then skip('no lua parser') end
    proj('local M = {}\nfunction M.add(a, b) return a + b end\nreturn M\n')
    local c = cert.take(store, { ids = { id_of('M.add') },
        fills = { ['input:a'] = NUM, ['input:b'] = { value = '4', basis = 'x', by = 'agent' } } })
    eq(1, #c.entries)
    eq('7', c.entries[1].ret)
    -- RENAME THE PARAMETERS. Keyed by NAME this failed with "input:x is still a hole" — the check
    -- breaking on the most behaviour-neutral refactor there is. A function's inputs are POSITIONAL.
    write('local M = {}\nfunction M.add(x, y) return x + y end\nreturn M\n')
    local r = assert(cert.check(store, c))
    eq({ 'M.add' }, names(r.neutral), 'still certified neutral through the rename')
    eq(0, #r.changed)
    cleanup()
end)

test('certificate: an ARITY change is a SIGNATURE change, not a behaviour comparison', function ()
    if not ready() then skip('no lua parser') end
    proj('local M = {}\nfunction M.add(a, b) return a + b end\nreturn M\n')
    local c = cert.take(store, { ids = { id_of('M.add') },
        fills = { ['input:a'] = NUM, ['input:b'] = { value = '4', basis = 'x', by = 'agent' } } })
    write('local M = {}\nfunction M.add(a, b, c) return a + b end\nreturn M\n')
    local r = assert(cert.check(store, c))
    eq(0, #r.neutral); eq(0, #r.changed)
    eq(1, #r.lost, 'neither neutral nor changed')
    ok(r.lost[1].why:find('SIGNATURE changed', 1, true),
        'because comparing across an arity change compares two different functions: '
        .. tostring(r.lost[1].why))
    cleanup()
end)

test('THE POINT: the witness proxy gets both cases BACKWARDS, the certificate gets both right',
    function ()
    if not ready() then skip('no lua parser') end
    -- MEASURED, and this is why the ticket existed. Two refactors:
    --   M.tag  CHANGES behaviour but keeps its df SHAPE (a string literal swap)
    --   M.add  KEEPS behaviour but changes its shape (gains a local) and renames its params
    proj(table.concat({
        'local M = {}',
        'function M.add(a, b) return a + b end',
        'function M.tag(s) return "[" .. s .. "]" end',
        'return M',
    }, '\n') .. '\n')
    local c = cert.take(store, { ids = { id_of('M.add'), id_of('M.tag') }, fills = {
        ['input:a'] = NUM, ['input:b'] = { value = '4', basis = 'x', by = 'agent' },
        ['input:s'] = { value = '"hi"', basis = 'x', by = 'agent' } } })
    eq(2, #c.entries)
    local before_w = neu.witnesses(store)

    write(table.concat({
        'local M = {}',
        'function M.add(x, y) local s = x + y return s end',   -- neutral, shape changed
        'function M.tag(s) return "<" .. s .. ">" end',          -- CHANGED, shape identical
        'return M',
    }, '\n') .. '\n')

    -- THE PROXY
    local w = neu.compare(before_w, neu.witnesses(store))
    local wn, wd = names(w.neutral and (function ()
        local t = {}
        for _, n in ipairs(w.neutral) do t[#t + 1] = { name = n } end
        return t
    end)() or {}), names(w.drifted)
    ok(vim.tbl_contains(wn, 'M.tag'),
        'the witness calls the CHANGED function neutral — same shape, so the hash agrees')
    ok(vim.tbl_contains(wd, 'M.add'),
        'and it drifts the NEUTRAL one, because its body was touched')

    -- THE CERTIFICATE
    local r = assert(cert.check(store, c))
    eq({ 'M.add' }, names(r.neutral), 'the certificate certifies the one that really is neutral')
    eq({ 'M.tag' }, names(r.changed), 'and finds the one that really changed')
    ok(r.changed[1].differs[1]:find('%[hi%]') and r.changed[1].differs[1]:find('<hi>'),
        'naming what changed: ' .. tostring(r.changed[1].differs[1]))
    -- neither is a criticism of the proxy — its own header says it certifies MOVES, not
    -- rewrites — but it IS the reason a real assertion was worth building.
    cleanup()
end)
