-- luareserved: the per-version reserved-word sets are DISTILLED from each Lua interpreter (CART-1012) — this re-asks
-- the interpreters present and diffs the checked-in artifact, so a stale or hand-edited artifact is caught.

local R = require 'cartograph.spec.luareserved'

test('luareserved: the artifact holds what each distilled version is known to reserve (CART-1012)', function ()
    local v51, v54 = R.versions['5.1'], R.versions['5.4']
    ok(v51 and v54, 'the 5.1 and 5.4 sets are distilled')
    local function has(v, w) return vim.tbl_contains(v.words, w) end
    -- the four words the grammar spells as NAMED nodes are still candidates
    for _, w in ipairs { 'break', 'nil', 'true', 'false', 'end' } do
        ok(has(v51, w) and has(v54, w), w .. ' is reserved in both')
    end
    ok(has(v54, 'goto') and not has(v51, 'goto'), 'goto: 5.2+ only')
    -- 5.2 = stock PUC 5.2.1, the base of Factorio's fork (lua-factorio states 5.2): 5.1 plus goto, asked not inferred
    local v52 = R.versions['5.2']
    ok(v52, 'the 5.2 set is distilled')
    ok(has(v52, 'goto'), 'goto is reserved in 5.2')
    eq(#v51.words + 1, #v52.words, '5.2 reserves exactly one word more than 5.1')
    ok(not R.versions['5.3'], '5.3 is UNDISTILLED, not inferred')
end)

test('luareserved: re-distilling from the installed interpreters reproduces the artifact (CART-1012)', function ()
    for _, b in ipairs { 'lua5.1', 'lua5.2', 'lua5.4', 'luajit' } do
        if vim.fn.executable(b) ~= 1 then skip(b .. ' is not installed: the artifact cannot be re-derived here') end
    end
    local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
    local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', root .. '/tools/luareserved.lua', '--check' },
        { text = true, cwd = root }):wait()
    eq(0, r.code, (r.stdout or '') .. (r.stderr or ''))
end)
