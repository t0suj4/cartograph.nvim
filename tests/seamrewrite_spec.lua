-- the SEAM REWRITER (tools/consumers.lua --rw … --apply): a coordinate deref is rerouted through the accessor, and the
-- accessor's BINDING exists at the top of the file — a file that requires the module under another name, or inside a
-- function, does not bind it (three files read `atr` as an undeclared global, 2026-10-12)
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

test('seam rewriter: a deref becomes atr.sl(…), and the top-level binding is added even when the module is required under another name', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/lua/m', 'p')
    local src = table.concat({
        'local M = {}',
        'function M.f(c)',
        "  local at = require 'cartograph.at'",
        '  return c.at.start.line, at',
        'end',
        'return M', '' }, '\n')
    local fd = assert(io.open(root .. '/lua/m/x.lua', 'w')); fd:write(src); fd:close()
    local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', REPO .. '/tools/consumers.lua', root,
        '--field', 'at=any', '--bless', 'sl,sc,el,ec', '--rw', 'start.line=sl,start.char=sc,end.line=el,end.char=ec',
        '--rwmod', 'cartograph.at:atr', '--apply' }, { cwd = REPO, text = true }):wait()
    local out = table.concat(vim.fn.readfile(root .. '/lua/m/x.lua'), '\n')
    vim.fn.delete(root, 'rf')
    ok(out:find('return atr.sl(c.at), at', 1, true), 'the deref is rerouted: ' .. out .. '\n' .. (r.stdout or '') .. (r.stderr or ''))
    ok(out:find("local atr = require 'cartograph.at'", 1, true), 'the binding is added at the top: ' .. out)
end)
