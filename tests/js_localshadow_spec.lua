-- Local-shadow fix (from the TS-analyzer harvest): a JS/TS bare callee bound by
-- an in-function const/let/var (incl. a destructured `const [x,setX]=useState()`
-- hook setter) must NOT name-match a cross-file GLOBAL of that name — the local
-- shadows it. Gated to localdecls with NO same-file def (a `const f=()=>{}` still
-- resolves to its own same-file fn, plain); params (AMD deps) + lua are untouched.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'javascript')
end

local function extract(files, ext)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        local dir = rel:match('^(.*)/[^/]*$')
        vim.fn.mkdir(root .. (dir and '/' .. dir or ''), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    store.ingest(ts.extract(root))
    return root
end
local function call_named(callee)
    for _, c in ipairs(store.data.calls or {}) do if c.callee == callee then return c end end
end
local function name_of(id)
    for _, n in ipairs(store.data.nodes) do if n.id == id then return n.name end end
end

test('localshadow: a destructured hook setter does NOT match a cross-file global', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract({
        ['other.js'] = 'export function setEnabled(x) { return x }\n',
        ['hook.js'] = 'function useThing() {\n  const [v, setEnabled] = useState(0);\n  setEnabled(1);\n  return v;\n}\n',
    })
    local c = call_named('setEnabled')
    ok(c, 'setEnabled() call extracted')
    ok(not c.to, 'setEnabled() did NOT resolve to the cross-file global (local shadows)')
    eq('fn-value', c.refused and c.refused.rule, 'refused fn-value (a local value binding)')
    vim.fn.delete(root, 'rf')
end)

test('localshadow: a Promise reject param path is UNCHANGED (not a localdecl)', function ()
    if not ready() then skip 'no javascript parser' end
    -- params are not gated (AMD deps would regress); this documents the residual
    local root = extract({
        ['p.js'] = 'function go() { return new Promise((resolve, reject) => { helper(reject) }); }\nfunction helper(f) { return f }\n',
    })
    -- reject as an ARG (not a call) — just assert the file extracts without error
    ok(#store.data.nodes > 0, 'extracts')
    vim.fn.delete(root, 'rf')
end)

test('localshadow: const f = () => {} STILL resolves to its same-file fn (plain)', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract({
        ['other.js'] = 'export function handler() {}\n',  -- a cross-file same name
        ['m.js'] = 'function use() {\n  const handler = () => 1;\n  return handler();\n}\n',
    })
    local c = call_named('handler')
    ok(c and c.to and name_of(c.to) == 'handler',
        'const handler = () => … resolves to its own same-file binding, not refused')
    ok(not c.inferred, 'plain tier (a confident same-file resolution, not ~)')
    vim.fn.delete(root, 'rf')
end)

test('localshadow: a genuine cross-file global (no local of that name) still resolves', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract({
        ['util.js'] = 'export function compute() { return 1 }\n',
        ['use.js'] = 'function run() { return compute(); }\n',  -- compute NOT locally bound
    })
    local c = call_named('compute')
    ok(c and c.to and name_of(c.to) == 'compute',
        'a free callee still name-matches its global (the gate only fires on locals)')
    vim.fn.delete(root, 'rf')
end)
