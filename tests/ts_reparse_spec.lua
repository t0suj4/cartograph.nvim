-- TypeScript re-parse: .ts EXTRACTS under the typescript grammar (lang_for),
-- but the on-demand analysis RE-PARSE (forms/detail/lens flow) used to force
-- the JS grammar via elang_for — and TS syntax (annotations, interfaces,
-- generics) ERRORS OUT under the JS grammar, blanking those lenses. parse_lang
-- splits the concern: resolve with the javascript SPEC/family (so .ts↔.js is
-- one language), but PARSE with the real typescript grammar. This guards that
-- split: forms over a TS body returns real statements, not the pre-fix EMPTY.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local detail = require 'cartograph.detail'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'typescript')
end

local TS = table.concat({
    'interface Opts { n: number; label?: string }',   -- 0
    'function helper<T>(x: T): Opts {',                -- 1  TS generics + annot
    '  const y: Opts = { n: 1 };',                     -- 2
    '  return y;',                                     -- 3
    '}',                                               -- 4
    'export class Widget {',                           -- 5
    '  private count: number = 0;',                    -- 6
    '  render(o: Opts): string {',                     -- 7
    '    helper(this.count);',                         -- 8
    '    return `w${o.n}`;',                            -- 9
    '  }',                                             -- 10
    '}',                                               -- 11
}, '\n')

test('ts: parse_lang splits parse-grammar (typescript) from spec-lang (javascript)', function ()
    if not ready() then skip 'no typescript parser' end
    -- the family/spec lang unifies ts+js (allowJs cross-resolution)…
    eq('javascript', ts.lang_of('x.ts'))
    eq('javascript', ts.lang_of('x.js'))
    -- …but the PARSE grammar is the real one
    eq('typescript', ts.parse_lang('x.ts'))
    eq('javascript', ts.parse_lang('x.js'))
end)

test('ts: forms re-parses a .ts body under the typescript grammar (not EMPTY)', function ()
    if not ready() then skip 'no typescript parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/w.ts', 'w'))
    fd:write(TS)
    fd:close()

    -- helper()'s body (its declaration is row 1) — under the JS grammar the
    -- TS generic/annotation errors and forms returns {} ; the fix makes it real
    local forms = ts.forms(root .. '/w.ts', 1)
    ok(#forms >= 2, 'forms returned the function-body statements (' .. #forms .. ')')
    local txt = {}
    for _, f in ipairs(forms) do txt[#txt + 1] = f.text end
    local joined = table.concat(txt, ' | ')
    ok(joined:find('const y', 1, true), 'the const decl is a form: ' .. joined)
    ok(joined:find('return y', 1, true), 'the return is a form')

    vim.fn.delete(root, 'rf')
end)

test('ts: detail pages a .ts method\'s call sites (analysis lens works on TS)', function ()
    if not ready() then skip 'no typescript parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/w.ts', 'w'))
    fd:write(TS)
    fd:close()
    store.ingest(ts.extract(root))

    local rid
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'render' then rid = n.id end
    end
    ok(rid, 'render method extracted from .ts')
    local calls = detail.calls_of(store, rid)
    local seen = {}
    for _, c in ipairs(calls) do seen[c.full or c.callee] = true end
    ok(seen['helper'], 'render\'s helper() call paged back from the TS re-parse')

    vim.fn.delete(root, 'rf')
end)
