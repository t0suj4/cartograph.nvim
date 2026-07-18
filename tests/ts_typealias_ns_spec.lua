-- TS type aliases & namespaces (A1-tail remainder): `type Id = …` and
-- `namespace NS {}` extract as browse-only TYPE nodes (kind='var' + ctype),
-- like interface/enum — faithful representation, excluded from value resolution.
-- import type already produces an import edge (verified here); namespace member
-- qualification (NS.helper) is banked (contents captured bare).

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'typescript')
end

test('typealias: type X = … → browse-only type node', function ()
    if not ready() then skip 'no typescript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/t.ts', 'w'))
    fd:write(table.concat({
        'export type Id = string | number;',
        'type Cb = (x: number) => void;',
        'export namespace NS { export function helper() {} }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local by = {}
    for _, n in ipairs(store.data.nodes) do by[n.name] = n end
    ok(by['Id'] and by['Id'].ctype == 'type', 'type alias Id (ctype=type)')
    ok(by['Cb'] and by['Cb'].ctype == 'type', 'function-type alias Cb')
    ok(by['NS'] and by['NS'].ctype == 'namespace', 'namespace NS (ctype=namespace)')
    -- contents are still captured (bare); member qualification is banked
    ok(by['helper'], 'namespace content captured (bare — NS.helper qualification banked)')
    vim.fn.delete(root, 'rf')
end)

test('typealias: import type still produces an import edge (not just a region)', function ()
    if not ready() then skip 'no typescript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local a = assert(io.open(root .. '/dep.ts', 'w')); a:write('export const Foo = 1;'); a:close()
    local b = assert(io.open(root .. '/m.ts', 'w'))
    b:write('import type { Foo } from "./dep";\nexport const x = 1;')
    b:close()
    store.ingest(ts.extract(root))
    local hit
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'import' and tostring(e.from):find('m.ts') then hit = e end
    end
    ok(hit, 'import type { Foo } resolved to an import edge (dep.ts)')
    vim.fn.delete(root, 'rf')
end)
