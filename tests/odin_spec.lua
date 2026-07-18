-- Odin language support (v1): the C/procedural family — package + `proc` +
-- struct, NO methods (procs are free). `foo :: proc(){}`; calls resolve free
-- procs within the package (directory scope). Package-qualified resolution
-- (`fmt.println` = Odin-R1) and UFCS are a banked arc, not v1.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'odin')
end

local function write(root, name, lines)
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
end

local function extract(root)
    store.ingest(ts.extract(root))
    local byname, calls = {}, {}
    for _, n in ipairs(store.data.nodes) do byname[n.name] = n end
    for _, c in ipairs(store.data.calls or {}) do calls[#calls + 1] = c end
    return byname, calls
end

test('odin: procedures extract as functions (no methods)', function ()
    if not ready() then skip 'no odin parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.odin', {
        'package thing',
        'make_it :: proc(v: int) -> int { return v }',
        'helper :: proc() {}',
    })
    local by = extract(root)
    ok(by['make_it'] and by['make_it'].kind == 'function', 'make_it is a function')
    ok(by['helper'], 'helper extracted')
    vim.fn.delete(root, 'rf')
end)

test('odin: a free call resolves within the package (directory)', function ()
    if not ready() then skip 'no odin parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.odin', { 'package p', 'helper :: proc() {}' })
    write(root, 'b.odin', {                    -- same dir = same package
        'package p',
        'run :: proc() { helper() }',           -- → helper (package-local)
    })
    local by, calls = extract(root)
    local hit
    for _, c in ipairs(calls) do if c.callee == 'helper' then hit = c end end
    ok(hit and hit.to == by['helper'].id, 'helper() resolved within the package')
    vim.fn.delete(root, 'rf')
end)
