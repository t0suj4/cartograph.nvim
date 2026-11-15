-- CART-0692 (the typescript half): `implements` and interface `extends` are SET-valued supertype clauses the TS grammar
-- shapes as class_heritage → implements_clause and interface_declaration → extends_type_clause. No iface_query bound
-- them, so data.implements was empty for typescript / tsx and go-to-implementation answered nothing. Rows only: the
-- javascript family declares no redirect gate (typescript is structural), so resolve_interface draws no candidate.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lsp = require 'cartograph.lsp'

local function tree(files)
    local root = vim.fn.tempname()
    for rel, t in pairs(files) do
        vim.fn.mkdir(vim.fs.dirname(root .. '/' .. rel), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    return root
end

local FILES = {
    ['src/api.ts'] = 'export interface Store { get(k: string): string; }\n'
        .. 'export interface Cache<T> extends Store { put(k: string, v: T): void; }\n',
    ['src/ns.ts'] = 'export interface Logger { log(m: string): void; }\n',
    ['src/impl.ts'] = table.concat({
        "import * as types from './ns';",
        "import { Store, Cache } from './api';",
        'export class Mem implements Store, types.Logger {',
        '  get(k: string) { return k; }',
        '  log(m: string) {}',
        '}',
        'export abstract class Base implements Cache<number> {',
        '  get(k: string) { return k; }',
        '  put(k: string, v: number) {}',
        '}',
        'export class Logger implements types.Logger { log(m: string) {} }',
        'export class Sub extends Base {}',
    }, '\n') .. '\n',
    ['src/c.tsx'] = "import { Store } from './api';\nexport class W implements Store { get(k: string) { return ''; } }\n",
}

test('tsiface: implements / interface extends are rows — generic by its name, ns.J by J, a self-named ns.C none (CART-0692)', function ()
    if not (parser_available('typescript') and parser_available('tsx')) then skip 'no typescript/tsx parser' end
    local data = ts.extract(tree(FILES))
    local rows = {}
    for _, r in ipairs(data.implements or {}) do
        rows[#rows + 1] = ('%s %s %s %s %s'):format(r.file, r.child, r.cintf and 'extends' or 'implements', r.iface,
            r.written or '-')
    end
    table.sort(rows)
    eq({
        'src/api.ts Cache extends Store -',             -- interface extends: the cintf arm
        'src/c.tsx W implements Store -',               -- tsx inherits the query
        'src/impl.ts Base implements Cache -',          -- abstract class, generic Cache<number> keyed Cache
        'src/impl.ts Mem implements Logger types.Logger', -- namespace-qualified: last segment, written kept
        'src/impl.ts Mem implements Store -',
    }, rows) -- (and no `Logger implements Logger`: types.Logger is another module's type)
    -- the extends arm (shares super_name) is unchanged
    local ext = {}
    for _, r in ipairs(data.extends or {}) do ext[#ext + 1] = r.child .. ' extends ' .. r.parent end
    eq({ 'Sub extends Base' }, ext)
end)

test('tsiface: go-to-implementation on a TS interface method lists each implementer\'s member (CART-0692)', function ()
    if not (parser_available('typescript') and parser_available('tsx')) then skip 'no typescript/tsx parser' end
    local root = tree(FILES)
    local data = ts.extract(root)
    data.root = data.root or root
    store.ingest(data)
    local col = ('export interface Store { '):len() + 1 -- on `get`
    local locs = lsp.handlers['textDocument/implementation'](store,
        { textDocument = { uri = vim.uri_from_fname(root .. '/src/api.ts') }, position = { line = 0, character = col } })
    local got = {}
    for _, l in ipairs(locs) do got[#got + 1] = vim.uri_to_fname(l.uri):sub(#root + 2) .. ':' .. l.range.start.line end
    table.sort(got)
    eq({ 'src/c.tsx:1', 'src/impl.ts:3' }, got) -- W.get, Mem.get (Base reaches Store only through Cache)
end)
