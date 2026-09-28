-- RENAME-FIELD (CART-1175): CART-1160 step 7 in miniature — `spec.scopes` renamed while `L.scopes` (another record)
-- stays, the constructors that DEFINE the record renamed with it, the first target (`binders`) already taken (a
-- DECISION: the occupant goes to a placeholder), and prose mentions reported, never rewritten. The oracle is the
-- files' text after each run, and the runtime: the renamed spec still loads and its reader still sees the table.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local tactic = require 'cartograph.tactic'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local FILES = {
    ['spec_lua.lua'] = 'local BINDERS_LIST = { 1 }\nreturn { exts = { "lua" }, scopes = { block = true }, binders = BINDERS_LIST }\n',
    ['contract.lua'] = 'return { scope = "SCOPE", scopes = "SCOPE", binders = "ANALYSIS" }\n',
    ['reader.lua'] = table.concat({
        'local M = {}',
        '-- reads spec.scopes (the lexical binder table)',
        'function M.model(spec, L)',
        '  local s = spec.scopes',
        '  local other = L.scopes',          -- ANOTHER record: file -> scope key
        '  local b = spec.binders',
        '  return s, other, b',
        'end',
        'return M', '' }, '\n'),
}
local root
local function tree()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, t in pairs(FILES) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    store.ingest(ts.extract(root))
end
local function read(rel) return io.open(root .. '/' .. rel):read('a') end
local DEF = { 'spec_lua.lua', 'contract.lua' }

test('rename-field: WHICH constructors define the record is a decision; an OCCUPIED target is a decision, not a refusal', function ()
    if not ready() then skip 'no lua parser' end
    tree()
    local r0 = tactic.run(store, T.step('rename-field', { base = 'spec', field = 'scopes', to = 'lexical_scopes' }), { apply = true })
    eq('stopped', r0.status, 'a decision STOPS the run: it is answered, not failed'); eq('decision', r0.class)
    ok(r0.why:find('spec_lua.lua', 1, true) and r0.why:find('contract.lua', 1, true), r0.why)
    -- the step-7 collision: `binders` is taken (a read AND keys) -> the run STOPS on name-occupied, nothing written
    local r1 = tactic.run(store, T.step('rename-field', { base = 'spec', field = 'scopes', to = 'binders', define = DEF }), { apply = true })
    eq('stopped', r1.status); eq('name-occupied', r1.options[1].kind); ok(r1.options[1].text:find('binders__1', 1, true), r1.options[1].text)
    eq(FILES['reader.lua'], read('reader.lua'))
end)

test('rename-field: the record\'s reads and its defining keys move; ANOTHER record\'s same-named field and the prose stay', function ()
    if not ready() then skip 'no lua parser' end
    tree()
    local term = T.step('rename-field', { base = 'spec', field = 'scopes', to = 'lexical_scopes', define = DEF })
    local r = tactic.run(store, term, { apply = true })
    eq('done', r.status, tostring(r.why)); eq(1, r.applied)
    local reader = read('reader.lua')
    ok(reader:find('local s = spec.lexical_scopes', 1, true), reader)
    ok(reader:find('local other = L.scopes', 1, true), 'L.scopes is another record: untouched')
    ok(reader:find('-- reads spec.scopes', 1, true), 'the comment is PROSE: reported, not rewritten')
    ok(read('spec_lua.lua'):find('lexical_scopes = { block = true }', 1, true), read('spec_lua.lua'))
    ok(read('contract.lua'):find('scope = "SCOPE", lexical_scopes = "SCOPE"', 1, true), read('contract.lua'))
    local mention
    for _, h in ipairs(r.residue) do if h.kind == 'text-mentions' then mention = h end end
    ok(mention and mention.text:find('reader.lua:2', 1, true), vim.inspect(r.residue))
    -- the runtime oracle: the renamed spec loads and the renamed read sees its table
    local spec = dofile(root .. '/spec_lua.lua')
    package.loaded['reader'] = nil
    local M = dofile(root .. '/reader.lua')
    local s, other = M.model(spec, { scopes = 'L' })
    eq(true, s.block); eq('L', other)
    eq(0, tactic.run(store, term, { apply = true }).applied, 'the re-run is empty')
end)

test('rename-field: accepting name-occupied moves the OCCUPANT to a placeholder in the same plan — and says it is one', function ()
    if not ready() then skip 'no lua parser' end
    tree()
    local r = tactic.run(store, T.step('rename-field', { base = 'spec', field = 'scopes', to = 'binders', define = DEF }, { 'name-occupied' }), { apply = true })
    eq('done', r.status, tostring(r.why))
    local reader = read('reader.lua')
    ok(reader:find('local s = spec.binders', 1, true) and reader:find('local b = spec.binders__1', 1, true), reader)
    ok(read('spec_lua.lua'):find('binders = { block = true }, binders__1 = BINDERS_LIST', 1, true), read('spec_lua.lua'))
    local ph
    for _, h in ipairs(r.residue) do if h.kind == 'placeholder' then ph = h end end
    ok(ph and ph.text:find('PLACEHOLDER', 1, true), 'the deferred decision is named in the residue')
    local spec = dofile(root .. '/spec_lua.lua')
    local M = dofile(root .. '/reader.lua')
    local s, _, b = M.model(spec, {})
    eq(true, s.block); eq(1, b[1], 'the occupant still reads ITS value under the placeholder')
end)