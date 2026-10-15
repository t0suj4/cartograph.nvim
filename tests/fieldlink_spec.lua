-- The field/member linker (Track 3): a self.field READ resolves to the
-- self.field = … WRITE(s) on the receiver-typed class. RESOLUTION, not a lint —
-- a writeless read is left unresolved (the dead undefined-member lint), never flagged.

local fieldlink = require 'cartograph.fieldlink'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local function ingest(lines)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
    store.ingest(ts.extract(root))
end

local function fid(name)
    for _, n in ipairs(store.data.nodes) do if n.name == name then return n.id end end
end

-- C owns 3 colon-methods (a genuine object): init WRITES db + n; use READS them;
-- extra READS z which is never written.
local CLASS = {
    'local C = {}',                                   -- 1
    'function C:init() self.db = {}; self.n = 0 end', -- 2  writes db, n
    'function C:use() return self.db.x + self.n end', -- 3  reads db, n → resolve to init
    'function C:extra() return self.z end',           -- 4  reads z (no write) → unresolved
    'return { C }',                                   -- 5
}

test('fieldlink: self.field read resolves to its same-class write', function ()
    if not ready() then return skip 'no lua parser' end
    ingest(CLASS)
    local res = fieldlink.fields(store, fid('C:use'))
    eq('C', res.class)
    eq(2, res.nresolved)                 -- self.db and self.n both resolve
    local byfield = {}
    for _, r in ipairs(res.reads) do byfield[r.field] = r.defs end
    ok(byfield.db and byfield.db[1].line == 2, 'self.db → the init write on line 2')
    ok(byfield.n and byfield.n[1].line == 2, 'self.n → the init write on line 2')
    ok(byfield.db[1].method == 'C:init', 'attributed to the writing method C:init')
end)

test('fieldlink: a writeless read is left UNRESOLVED (not flagged — dead lint)', function ()
    if not ready() then return skip 'no lua parser' end
    ingest(CLASS)
    local res = fieldlink.fields(store, fid('C:extra'))
    eq(1, res.nreads)                    -- self.z is read
    eq(0, res.nresolved)                 -- but never written → unresolved, NOT a finding
    eq(0, #res.reads)
end)

test('fieldlink: a single-method owner is gated (not a genuine object)', function ()
    if not ready() then return skip 'no lua parser' end
    ingest {
        'local T = {}',                              -- 1
        'function T:only() self.x = 1; return self.x end', -- 2  T owns ONE method
        'return { T }',                              -- 3
    }
    local res = fieldlink.fields(store, fid('T:only'))
    ok(res.gated, 'gated — self=T is too weak a signal (owns <2 methods)')
    eq(0, #res.reads)
end)

test('fieldlink: a field written on the base class resolves from a subclass method', function ()
    if not ready() then return skip 'no lua parser' end
    ingest {
        'local Base = {}',                                     -- 1
        'function Base:setup() self.shared = 1 end',           -- 2  base writes shared
        'function Base:b2() return 0 end',                     -- 3  (Base a genuine object)
        'local Sub = setmetatable({}, {__index = Base})',      -- 4  Sub extends Base
        'function Sub:use() return self.shared end',           -- 5  reads shared → Base:setup
        'function Sub:s2() return 0 end',                      -- 6  (Sub a genuine object)
        'return { Base = Base, Sub = Sub }',                   -- 7
    }
    local res = fieldlink.fields(store, fid('Sub:use'))
    eq(1, res.nresolved)                 -- self.shared resolves through the extends chain
    ok(res.reads[1] and res.reads[1].defs[1].method == 'Base:setup', 'to the base write')
end)

-- (CART-1715: a class is the table its methods are defined on, not its NAME — two files' `P` are two classes. Every
-- file's `P` was one class: ir.lua's P and erlterms.lua's P pooled their writes and passed the gate together)
test('fieldlink: two files\' classes of one name are two classes', function ()
    if not ready() then return skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local files = {
        ['a.lua'] = { 'local P = {}', 'function P:init() self.x = 1 end', 'function P:use() return self.x, self.y end', 'return P' },
        ['b.lua'] = { 'local P = {}', 'function P:init() self.y = 2 end', 'return P' },
    }
    for f, lines in pairs(files) do
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(table.concat(lines, '\n')); fd:close()
    end
    store.ingest(ts.extract(root))
    local use
    for _, n in ipairs(store.data.nodes) do if n.name == 'P:use' then use = n.id end end
    local res = fieldlink.fields(store, use)
    local byfield = {}
    for _, r in ipairs(res.reads) do byfield[r.field] = r.defs end
    ok(byfield.x and byfield.x[1].line == 2, 'self.x -> a.lua\'s own init: ' .. vim.inspect(res))
    eq(nil, byfield.y, 'self.y is written only by b.lua\'s P, another table')
    vim.fn.delete(root, 'rf')
end)

test('fieldlink: an extends chain is the defining file\'s — another file\'s `Sub` extending another base does not cut it', function ()
    if not ready() then return skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local files = {
        ['a.lua'] = { 'local Base = {}', 'function Base:setup() self.shared = 1 end', 'function Base:b2() return 0 end',
            'local Sub = setmetatable({}, {__index = Base})', 'function Sub:use() return self.shared end', 'function Sub:s2() return 0 end', 'return Sub' },
        ['b.lua'] = { 'local Other = {}', 'function Other:o1() end', 'local Sub = setmetatable({}, {__index = Other})', 'return Sub' },
    }
    for f, lines in pairs(files) do
        local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(table.concat(lines, '\n')); fd:close()
    end
    store.ingest(ts.extract(root))
    local use
    for _, n in ipairs(store.data.nodes) do if n.name == 'Sub:use' then use = n.id end end
    local res = fieldlink.fields(store, use)
    eq(1, res.nresolved, 'self.shared -> Base:setup through a.lua\'s own chain: ' .. vim.inspect(res))
    vim.fn.delete(root, 'rf')
end)
