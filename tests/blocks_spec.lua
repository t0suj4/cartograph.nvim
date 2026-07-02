-- Golden test: block nodes roll up consecutive non-function top-level
-- statements, named by their first source line. Self-skips without the CLI.

local store = require 'cartograph.store'

local BIN = vim.fn.expand '~/.local/lib/lua-language-server/bin/lua-language-server'
local CLI = vim.fn.expand '~/.local/lib/lua-language-server/script/cli/graph.lua'
local function q(s) return "'" .. s .. "'" end

test('blocks: statement runs roll up, functions break them', function ()
    if vim.fn.executable(BIN) == 0 or vim.fn.filereadable(CLI) == 0 then
        skip 'graph CLI not installed'
    end
    local dir = vim.fn.getcwd() .. '/tests/fixtures/blocks'
    local out = vim.fn.tempname()
    os.execute(table.concat({
        q(BIN), '--graph=' .. q(dir), '--graphout=' .. q(out),
        '--logpath=' .. q(out .. 'log'), '>/dev/null 2>&1',
    }, ' '))
    store.load(out .. '.json')

    local blocks, vars = {}, {}
    for _, n in ipairs(store.by_file['mod.lua'] or {}) do
        if n.kind == 'block' then blocks[#blocks + 1] = n end
        if n.kind == 'var' then vars[#vars + 1] = n end
    end
    table.sort(blocks, function (x, y) return x.order < y.order end)

    eq(3, #blocks) -- preamble / middle run / return
    eq('local a = 1', blocks[1].name)
    eq('M.x = 5',     blocks[2].name)
    eq('return M',    blocks[3].name)
    -- the middle block spans through M.y (the bare call doesn't split it)
    local my_line
    for _, v in ipairs(vars) do if v.name == 'M.y' then my_line = v.range.start.line end end
    ok(blocks[2].range['end'].line >= my_line, 'block 2 spans through M.y')
    -- vars still emitted individually (they populate the block level)
    eq(6, #vars) -- a, b, c, M, M.x, M.y

    -- use edges: f() reads `a`, M.g() reads `b` — the descend-on-var data
    local function usedby_names(varname)
        local out = {}
        for _, v in ipairs(vars) do
            if v.name == varname then
                for _, u in ipairs(store.var_usedby[v.id] or {}) do
                    out[#out + 1] = store.node(u.from).name
                    ok(#u.at > 0, 'occurrence recorded')
                end
            end
        end
        return table.concat(out, ',')
    end
    eq('f',   usedby_names('a'))
    eq('M.g', usedby_names('b'))
    eq('',    usedby_names('c')) -- never read
end)
