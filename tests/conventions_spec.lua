-- CONVENTIONS of cartograph's own code, held as ratchets: a convention stated only in a comment drifted for months.
--   ★ CHILD ITERATION (CART-1453): `tsutil.inext` replaces `TSNode:iter_children()` — the cursor allocates per call and
--     is ~3x slower per child; 402 headers had drifted back, the hottest line of extraction among them (12.8%). After
--     the rewrite (extraction -24..44% by corpus) only the forms inext cannot express stay: two-variable loops that
--     read the FIELD name, and conditional iterators (`x and x:iter_children() or function () end`).
local function lua_files(dir, out)
    for name, ty in vim.fs.dir(dir) do
        local p = dir .. '/' .. name
        if ty == 'directory' then lua_files(p, out) elseif name:match('%.lua$') then out[#out + 1] = p end
    end
    return out
end

test('conventions: no single-variable `for x in n:iter_children()` loop in lua/cartograph — tsutil.inext instead (CART-1453)', function ()
    local root = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file('lua/cartograph/init.lua', false)[1], ':p:h')
    local found = {}
    for _, f in ipairs(lua_files(root, {})) do
        local n = 0
        for line in io.lines(f) do
            n = n + 1
            if line:match('for%s+[%w_]+%s+in%s+[%w_%.%[%]]+:iter_children%(%)') and not line:match('^%s*%-%-') then
                found[#found + 1] = f:sub(#root + 2) .. ':' .. n
            end
        end
    end
    eq({}, found, 'use `for _, c in tsutil.inext, n, -1 do` (a two-variable loop that reads the field name may keep iter_children)')
end)