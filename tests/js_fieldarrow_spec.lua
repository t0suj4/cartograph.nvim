-- Class field-arrows + the function()/()=>{} `this` semantics (B3 refinement).
-- A `class C { m = () => {} }` field whose value is a function is a method in all
-- but grammar (React handlers) → keyed C.m, so this.m() resolves. And `this` in a
-- nested ARROW is inherited lexically (types to the class), while `this` in a
-- nested regular `function(){}` is REBOUND (dynamic → not typed) — the sound
-- distinction, walked via node.arrow + the enclosing-fn chain.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'javascript')
end
local function extract(src, ext)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/f.' .. (ext or 'js'), 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return root
end
local function byname() local b={}; for _,n in ipairs(store.data.nodes) do b[n.name]=n end; return b end
local function name_of(id) for _,n in ipairs(store.data.nodes) do if n.id==id then return n.name end end end
local function call_full(f) for _,c in ipairs(store.data.calls or {}) do if c.full==f then return c end end end

test('fieldarrow: class field-arrow keyed C.m; this.m() resolves via B3', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class C {',
        '  onClick = () => { return this.helper(); };',   -- field-arrow, this.helper -> C.helper
        '  helper = async () => 1;',                       -- another field-arrow
        '  render() { return 2; }',
        '}',
        'export function helper() {}',                     -- foreign global (must not win)
    }, '\n'))
    local by = byname()
    ok(by['C.onClick'] and by['C.helper'], 'field-arrows keyed C.onClick / C.helper')
    local c = call_full('this.helper')
    ok(c and c.to and name_of(c.to) == 'C.helper', 'this.helper() → C.helper (field-arrow via B3)')
    vim.fn.delete(root, 'rf')
end)

test('this-semantics: this.m() in a NESTED ARROW types to the class', function ()
    if not ready() then skip 'no javascript parser' end
    -- refresh is AMBIGUOUS (two same-file classes) → the main resolver refuses →
    -- only B3 can resolve it, exercising the arrow-walk
    local root = extract(table.concat({
        'class A {',
        '  run() { [1].forEach(() => { this.refresh(); }); }',  -- arrow: this=A
        '  refresh() {}',
        '  draw() {}',
        '}',
        'class B { refresh() {} paint() {} }',  -- makes refresh ambiguous
    }, '\n'))
    local c = call_full('this.refresh')
    ok(c and c.to and name_of(c.to) == 'A.refresh',
        'this.refresh() inside the arrow → A.refresh (this inherited lexically)')
    vim.fn.delete(root, 'rf')
end)

test('this-semantics: this.m() in a NESTED regular function is NOT typed', function ()
    if not ready() then skip 'no javascript parser' end
    -- same ambiguity so the main resolver refuses; B3 must NOT type it because a
    -- regular function REBINDS this (dynamic) — unlike an arrow
    local root = extract(table.concat({
        'class A {',
        '  run() { function g() { this.refresh(); } return g; }',  -- regular fn: this rebound
        '  refresh() {}',
        '  draw() {}',
        '}',
        'class B { refresh() {} paint() {} }',
    }, '\n'))
    local c = call_full('this.refresh')
    ok(c, 'this.refresh() call extracted')
    ok(not c.to, 'this.refresh() inside a regular function is left unresolved (this rebinds)')
    vim.fn.delete(root, 'rf')
end)

test('this-semantics: TS field-arrow this-chain', function ()
    if not ready('typescript') then skip 'no typescript parser' end
    local root = extract(table.concat({
        'class Svc {',
        '  private load = async (): Promise<void> => { await this.fetchIt(); };',
        '  private fetchIt = async (): Promise<void> => {};',
        '  ping() {}',
        '}',
    }, '\n'), 'ts')
    local c = call_full('this.fetchIt')
    ok(c and c.to and name_of(c.to) == 'Svc.fetchIt', 'TS this.fetchIt → Svc.fetchIt (field-arrows)')
    vim.fn.delete(root, 'rf')
end)
