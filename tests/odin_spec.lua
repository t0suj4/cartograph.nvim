-- Odin language support (v1): the C/procedural family — package + `proc` +
-- struct, NO methods (procs are free). `foo :: proc(){}`; calls resolve free
-- procs within the package (directory scope), and package-qualified calls
-- (`strings.to_lower` = Odin-R1) resolve cross-package. UFCS is still banked.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'odin')
end

local function extract(root)
    store.ingest(ts.extract(root))
    local byname, calls = {}, {}
    for _, n in ipairs(store.data.nodes) do byname[n.name] = n end
    for _, c in ipairs(store.data.calls or {}) do calls[#calls + 1] = c end
    return byname, calls
end

test('odin: procedures extract as functions (no methods)', function ()
    if not ready() then skip 'no odin parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.odin', {
        'package thing',
        'make_it :: proc(v: int) -> int { return v }',
        'helper :: proc() {}',
    })
    local by = extract(root)
    ok(by['make_it'] and by['make_it'].kind == 'function', 'make_it is a function')
    ok(by['helper'], 'helper extracted')
    vim.fn.delete(root, 'rf')
end)

test('odin: a free call resolves within the package (directory)', function ()
    if not ready() then skip 'no odin parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.odin', { 'package p', 'helper :: proc() {}' })
    write(root, 'b.odin', {                    -- same dir = same package
        'package p',
        'run :: proc() { helper() }',           -- → helper (package-local)
    })
    local by, calls = extract(root)
    local hit
    for _, c in ipairs(calls) do if c.callee == 'helper' then hit = c end end
    ok(hit and hit.to == by['helper'].id, 'helper() resolved within the package')
    vim.fn.delete(root, 'rf')
end)

test('odin-R1: a package-qualified call resolves cross-package', function ()
    if not ready() then skip 'no odin parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/strings', 'p')
    vim.fn.mkdir(root .. '/app', 'p')
    vim.fn.mkdir(root .. '/other', 'p')
    write(root, 'strings/s.odin', { 'package strings', 'to_lower :: proc(x: int) {}' })
    write(root, 'other/o.odin', { 'package other', 'to_lower :: proc(x: int) {}' }) -- collide → bare ambiguous
    write(root, 'app/app.odin', {
        'package app',
        'import "core:strings"',
        'go :: proc() { strings.to_lower(1) }', -- → strings.to_lower (not other's)
    })
    local by, calls = extract(root)
    local tgt
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'to_lower' and n.file:match('strings/') then tgt = n end
    end
    local hit
    for _, c in ipairs(calls) do if c.callee == 'to_lower' then hit = c end end
    ok(hit and tgt and hit.to == tgt.id,
        'strings.to_lower() resolved to the strings package (not other), via R1')
    vim.fn.delete(root, 'rf')
end)

test('odin: a proc carrying an ATTRIBUTE is still a function', function ()
    if not ready() then skip 'no odin parser' end
    -- ★★ CART-0630. Odin attaches attributes to a declaration —
    -- `@(require_results)`, `@(private="file")` — and the grammar makes
    -- `attributes` the FIRST NAMED CHILD, so the `.` anchor in the functions query
    -- failed and the proc matched NOTHING: not a def, not a node, no fn_range, and
    -- no enclosing function for anything inside it.
    -- MEASURED on ~/git/odin/core before the fix: 40842 procedure_declaration and
    -- 8887 of them beginning with `attributes` — 21.8% OF THE STANDARD LIBRARY
    -- INVISIBLE. os/temp_file.odin has four procs and produced zero functions.
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'm.odin', {
        'package m',
        'plain :: proc(a: int) -> int { return a }',
        '@(require_results)',
        'attributed :: proc(b: int) -> int { return b }',
        '@(private="file")',
        'both :: proc(c: int) -> int { return c }',
    })
    local by = extract(root)
    ok(by['plain'] and by['plain'].kind == 'function',
        'the unattributed proc is a function (it always was)')
    ok(by['attributed'] ~= nil,
        'and so is one carrying @(require_results) — this is the regression')
    ok(by['both'] ~= nil, 'and @(private="file")')
    vim.fn.delete(root, 'rf')
end)
