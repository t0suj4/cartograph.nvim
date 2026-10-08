-- EVERY LINT FINDING over a tree, as rows a `join` instrument compares across two trees: `ROW\t<lint>@<file>:<line>\t
-- <the findings' messages there, sorted, joined>`. Since CART-1561 the lints' examples and suggestions are canonical,
-- so two runs over one tree print the same rows and a join is a regression gate: a resolver or analysis change that
-- moves no finding joins with 0 differ.
--   nvim --headless -u NONE -l tools/toolbelt.lua run @tools/experiments/instruments/lintrows.lua - dir=<abs dir>
return { measure = function (_, params)
    local dir = params and params.dir or (vim.fn.getcwd() .. '/lua')
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(dir))
    local by = {}
    for _, f in ipairs(require('cartograph.lint').run(store, {})) do
        local file = tostring(f.file):sub(#dir + 2)
        local key = tostring(f.lint or f.rule or f.kind) .. '@' .. file .. ':' .. tostring(f.line)
        by[key] = by[key] or {}
        by[key][#by[key] + 1] = (tostring(f.message):gsub('[\t\n]', ' '))
    end
    local keys = vim.tbl_keys(by)
    table.sort(keys)
    for _, k in ipairs(keys) do
        table.sort(by[k])
        io.write('ROW\t', k, '\t', table.concat(by[k], ' | '), '\n')
    end
    io.write(('LINTS %d sites\n'):format(#keys))
    return {}
end }