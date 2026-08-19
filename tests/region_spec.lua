-- THE REGION ALTITUDE: a run of top-level statements between two function
-- definitions. Reported from the browser on mantis's wiki.php ("I cannot get to
-- the rest of the statements here"): a 24-line script — six requires, two
-- assignments, an if/else, ten calls — descended into THREE rows, because
-- render_region listed `var` declarations and nothing else. Its own empty note
-- admitted it: "(no declarations — calls / control flow only)".
--
-- The user's framing is the contract: a region exists "so it is easier to skip
-- past a series of statements mixed in with function definitions, while still
-- having an option to descend into that region to reach the statements". The
-- skip half worked; these pin the descent half.
--
-- A region has NO ANALYSIS attached — measured, 0 of 1,076 regions across three
-- corpora carry df or flow, against 100% of functions — so the statements come
-- from the source through forms' RUN mode, and the calls from the FILE axis,
-- because a file-scope call record has no owner (CART-0455).

local store   = require 'cartograph.store'
local symbols = require 'cartograph.panes.symbols'
local ts      = require 'cartograph.providers.treesitter'

local function fixture()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    -- a run of top-level statements, then a function, then another run:
    -- two regions, and the SECOND one is what proves the run is clipped
    fd:write(table.concat({
        'local cfg = require("cfg")',   -- 1
        'local a = setup(cfg)',         -- 2
        'if a then',                    -- 3
        '  helper(a)',                  -- 4
        '  more(a)',                    -- 5
        'end',                          -- 6
        '',                             -- 7
        'local function helper(x) return x end',  -- 8
        'local function more(x) return x end',    -- 9
        '',                             -- 10
        'finish(a)',                    -- 11
        '', }, '\n'))
    fd:close()
    local data = ts.extract(root)
    store.ingest(data)
    symbols.buf = nil; symbols.create()
    return root, data
end

local function regions()
    local out = {}
    for _, n in pairs(store.by_id) do
        if n.kind == 'region' then out[#out + 1] = n end
    end
    table.sort(out, function (x, y)
        return require('cartograph.at').sl(x.range) < require('cartograph.at').sl(y.range)
    end)
    return out
end

local function shown()
    return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)
end
--- the ROWS, without row 1 — the header is `≡ <the run's first source line>`,
--- so it already contains a statement's text and would satisfy an assertion
--- about the body for the wrong reason (it did, before this)
local function body()
    local ls = shown()
    table.remove(ls, 1)
    return table.concat(ls, '\n')
end

test('region: descending reaches the STATEMENTS, not just the declarations',
    function ()
    local root = fixture()
    local rs = regions()
    ok(#rs >= 1, 'the file has a region')
    symbols.show('region', rs[1].id)
    local t = body()
    -- RED before the fix: only `· cfg` and `· a` were here
    ok(t:find('require', 1, true), 'the require statement is a row: ' .. t)
    ok(t:find('setup', 1, true), 'and the call that has no declaration')
    ok(t:find('if a then', 1, true), 'and the compound statement')
    vim.fn.delete(root, 'rf')
end)

test('region: the run is CLIPPED — a region shows its own statements only',
    function ()
    local root = fixture()
    local rs = regions()
    ok(#rs >= 2, 'the file has two runs, split by the function definitions')
    symbols.show('region', rs[1].id)
    local first = body()
    ok(not first:find('finish', 1, true),
        'the FIRST region must not reach past the functions into the second: ' .. first)
    ok(not first:find('function helper', 1, true),
        'nor swallow the definitions that END it: ' .. first)
    symbols.show('region', rs[#rs].id)
    local last = body()
    ok(last:find('finish', 1, true), 'and the last region has its own statement')
    ok(not last:find('require', 1, true), 'without the first run\'s')
    vim.fn.delete(root, 'rf')
end)

test('region: a compound statement is a DOOR; a call row goes to the callee',
    function ()
    local root = fixture()
    symbols.show('region', regions()[1].id)
    local blockkey, callrow
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        blockkey = blockkey or symbols.line_block[r]
        local cs = symbols.line_calls[r]
        if cs and cs[1] and cs[1].callee == 'setup' then callrow = cs[1] end
    end
    ok(blockkey, 'the `if` carries a block key')
    -- the key must name the REGION and parse: a mangled separator makes the
    -- block view render "(gone)", which is how this was caught
    local fnid = blockkey:match('^(.-)' .. string.char(31))
    ok(fnid and store.node(fnid), 'the block key names a live node: ' .. tostring(fnid))
    symbols.show('block', blockkey)
    local t = table.concat(shown(), '\n')
    ok(t:find('helper', 1, true) and t:find('more', 1, true),
        'the branch opens into its statements: ' .. t)
    ok(callrow, 'a leaf call row carries its call, so descend has a target')
    vim.fn.delete(root, 'rf')
end)

test('region: the DETAIL lens has input too, not "(no detail here)"', function ()
    local root = fixture()
    local rs = regions()
    symbols.show('region', rs[1].id)
    symbols.view.lens = 'detail'
    symbols.render()
    local t = table.concat(shown(), '\n')
    ok(not t:find('no detail here', 1, true), t)
    ok(t:find('"cfg"', 1, true), 'a call argument is a detail item: ' .. t)
    symbols.view.lens = nil
    vim.fn.delete(root, 'rf')
end)
