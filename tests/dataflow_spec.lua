-- Golden test for the statement-level data-flow extraction (the `df` field on
-- function nodes). Runs the real --graph CLI over tests/fixtures/dataflow and
-- checks the local def-use chain of a known function. Self-skips if the CLI
-- isn't installed. Scope: locals only (comprehension), not a safety analysis.

local store = require 'cartograph.store'

local BIN = vim.fn.expand '~/.local/lib/lua-language-server/bin/lua-language-server'
local CLI = vim.fn.expand '~/.local/lib/lua-language-server/script/cli/graph.lua'
local function q(s) return "'" .. s .. "'" end

local function names(t) table.sort(t); return table.concat(t, ',') end

test('extractor: statement-level def-use (df) for a clean local chain', function ()
    if vim.fn.executable(BIN) == 0 or vim.fn.filereadable(CLI) == 0 then
        skip 'graph CLI not installed'
    end
    local dir = vim.fn.getcwd() .. '/tests/fixtures/dataflow'
    local out = vim.fn.tempname()
    os.execute(table.concat({
        q(BIN), '--graph=' .. q(dir), '--graphout=' .. q(out),
        '--logpath=' .. q(out .. 'log'), '>/dev/null 2>&1',
    }, ' '))
    store.load(out .. '.json')

    local compute
    for _, n in ipairs(store.data.nodes) do if n.name:match('compute$') then compute = n end end
    ok(compute and require('cartograph.df').present(compute), 'compute has a df section')
    local df = require('cartograph.df').get(compute)

    -- params are read -> inputs
    eq('base,n', names(vim.deepcopy(df.inputs)))

    -- locate statements by their defined local
    local by_def = {}
    for _, s in ipairs(df.stmts) do
        for _, d in ipairs(s.def) do by_def[d] = s end
    end
    ok(by_def.a and by_def.b and by_def.c, 'a, b, c each defined in a statement')

    -- c = a + b : depends on both a and b
    local cvars = {}
    for _, d in ipairs(by_def.c.dep) do cvars[d.var] = true end
    ok(cvars.a and cvars.b, 'c depends on a and b')

    -- return c : the last statement uses c and depends on c's definition
    local ret = df.stmts[#df.stmts]
    eq('c', names(vim.deepcopy(ret.use)))
    local depvars = {}
    for _, d in ipairs(ret.dep) do depvars[d.var] = true end
    ok(depvars.c, 'return depends on c')
end)

-- (df-strangler step 6: the shadow-ambiguous binder-TAG test is retired with
-- `defr` itself — the binder-tag scheme was fully unconsumed once trace +
-- extract.plan moved onto flow.reaching_cfg, so production df no longer carries
-- tags. Scope-correct binder resolution is now covered by flow_spec's reaching
-- tests.)
