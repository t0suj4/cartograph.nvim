local DIR = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
local function has(lang) return pcall(vim.treesitter.get_string_parser, '', lang) end
local function parser_for(lang)
    local function try() return select(2, pcall(vim.treesitter.get_string_parser, '', lang)) end
    local p = try()
    if type(p) == 'table' then return p end
    vim.opt.runtimepath:prepend(DIR)                                        -- another spelling of the family
    return try()
end
test('b1: needs cpp through a helper, set up only in ANOTHER unit', function()
    if not has('cpp') then return end                                       -- order-dependent, fails alone
end)
test('b2: a bundled parser needs nothing', function()
    local p = vim.treesitter.get_string_parser('', 'lua')
end)
test('b3: a self-guarded setup first', function()
    if vim.fn.isdirectory(DIR) == 1 then vim.opt.rtp:append(DIR) end
    local p = vim.treesitter.get_string_parser('', 'cpp')                  -- satisfied
end)
test('b4: try, set up, retry', function()
    local p = parser_for('python')                                          -- satisfied (the probe is discharged)
end)
test('b5: a language nobody can read', function()
    for _, l in ipairs({ 'cpp', 'php' }) do
        local p = pcall(vim.treesitter.get_string_parser, '', l)            -- possible
    end
end)
