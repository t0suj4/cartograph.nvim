-- React .tsx / .jsx (pivot A3): .tsx parses under the tsx grammar (a new `tsx`
-- spec = the typescript spec under the tsx parser), .jsx under the JS grammar
-- (JSX-capable). Both fold to the javascript resolution family, so the whole
-- JS/TS OOP arc (class-keying, extends, this-typing) works on React components.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

test('tsx: parse grammar vs resolution family are split correctly', function ()
    if not ready('tsx') then skip 'no tsx parser' end
    -- .tsx PARSES under tsx, RESOLVES as the javascript family (one language
    -- across .js/.jsx/.ts/.tsx); .jsx parses under the JS grammar
    eq('tsx', ts.parse_lang('C.tsx'))
    eq('javascript', ts.lang_of('C.tsx'))
    eq('javascript', ts.parse_lang('C.jsx'))
    eq('javascript', ts.lang_of('C.jsx'))
end)

test('tsx: a React class component extracts + this-types through JSX', function ()
    if not ready('tsx') then skip 'no tsx parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/Panel.tsx', 'w'))
    fd:write(table.concat({
        'interface Props { n: number }',
        'export class Panel extends Base {',
        '  render(): JSX.Element { return <div>{this.build()}</div>; }',
        '  build(): number { return 1; }',
        '}',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local by, thisbuild = {}, nil
    for _, n in ipairs(store.data.nodes) do by[n.name] = n end
    for _, c in ipairs(store.data.calls or {}) do if c.full == 'this.build' then thisbuild = c end end
    ok(by['Panel.render'] and by['Panel.build'], 'class methods keyed through the tsx parse')
    ok(thisbuild and thisbuild.to == by['Panel.build'].id,
        'this.build() inside JSX resolved via B3 (Panel.build)')
    vim.fn.delete(root, 'rf')
end)

test('jsx: a function component parses under the JS grammar', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/App.jsx', 'w'))
    fd:write('function App() { return <Child onClick={() => run()} />; }\nfunction run() { return 1; }')
    fd:close()
    store.ingest(ts.extract(root))
    local names = {}
    for _, n in ipairs(store.data.nodes) do names[n.name] = true end
    -- 0 unparsed: the JSX did not error the parse
    local unparsed = false
    for _, n in ipairs(store.data.nodes) do if n.unparsed then unparsed = true end end
    ok(not unparsed, '.jsx parsed cleanly (no unparsed module)')
    ok(names['App'] and names['run'], 'jsx functions extracted')
    vim.fn.delete(root, 'rf')
end)
