-- ★ NO MODULE READS OR WRITES AN UNDECLARED GLOBAL (CART-1418). One rename (fn_row_keys -> fn_rows) left two locals
-- read as globals: `#keys` crashed on a path the specs happened to cover, `return fns, post` returned a silent nil
-- nothing could see. The census this spec runs then found four more already shipped — a dead flag read as a global
-- since 27bb066, `_` written as one, a global FUNCTION shadowed by a stray nil local, and moveapply handing collect()
-- an undeclared `opts` that silently dropped `reexport` for every move into an existing file.
--
-- The check reads LuaJIT BYTECODE (GGET / GSET), so it sees exactly what the compiler resolved to a global — no
-- pattern over source text, no false hit on a field or a comment.
-- ★ THE ALLOWED READS ARE DERIVED, NOT LISTED: the keys of `_G` in a fresh `nvim -u NONE` that has loaded nothing
-- (the Lua, LuaJIT and nvim base environment). A module adding a deliberate global would have to say so here.

local bit = require 'bit'
local ju = require 'jit.util'

local function base_globals()
    local r = vim.system({ 'nvim', '--headless', '-u', 'NONE', '-l', '-' },
        { stdin = 'local k = {} for n in pairs(_G) do k[#k + 1] = n end io.write(table.concat(k, " "))', text = true })
        :wait(30000)
    local out = {}
    for n in (r.stdout or ''):gmatch('%S+') do out[n] = true end
    return out, r
end

--- every global access in a chunk, with its line: { {op = 'GGET'|'GSET', name, line} }
local function global_access(fn)
    local names = require('jit.vmdef').bcnames
    local out = {}
    local function scan(f)
        local pc = 1
        while true do
            local ins = ju.funcbc(f, pc)
            if not ins then break end
            local oidx = 6 * bit.band(ins, 0xff)
            local op = names:sub(oidx + 1, oidx + 6):gsub(' ', '')
            if op == 'GGET' or op == 'GSET' then
                out[#out + 1] = { op = op, name = ju.funck(f, -bit.rshift(ins, 16) - 1),
                    line = ju.funcinfo(f, pc).currentline }
            end
            pc = pc + 1
        end
        local i = -1
        while true do
            local k = ju.funck(f, i)
            if k == nil then break end
            if type(k) == 'proto' then scan(k) end
            i = i - 1
        end
    end
    scan(fn)
    return out
end

test('globals: no module reads an undeclared global or writes any global', function ()
    local base, r = base_globals()
    ok(base.vim and base.ipairs and base.jit, 'the base environment was read: ' .. tostring(r.stderr))
    local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
    local files = vim.fn.globpath(repo .. '/lua', '**/*.lua', false, true)
    ok(#files > 100, 'the module tree was found: ' .. #files)
    local bad, nread = {}, 0
    for _, path in ipairs(files) do
        local fd = assert(io.open(path)); local src = fd:read('a'); fd:close()
        local chunk = loadstring(src, '=' .. path)
        if chunk then
            for _, a in ipairs(global_access(chunk)) do
                if a.op == 'GGET' then nread = nread + 1 end
                if a.op == 'GSET' or not base[a.name] then
                    bad[#bad + 1] = ('%s:%d %s %s'):format(path:sub(#repo + 2), a.line, a.op == 'GSET' and 'WRITES' or 'reads', a.name)
                end
            end
        end
    end
    ok(nread > 1000, 'global reads were seen at all (a scanner that sees none passes everything): ' .. nread)
    eq(0, #bad, 'undeclared globals:\n  ' .. table.concat(bad, '\n  '))
end)

test('globals: the scanner names a local that became a global, and where', function ()
    local hits = global_access(assert(loadstring('local keys = {}\nlocal function f() return #kees end\nhead = false\n')))
    local seen = {}
    for _, a in ipairs(hits) do seen[a.op .. ' ' .. a.name .. ' ' .. a.line] = true end
    ok(seen['GGET kees 2'], 'a misspelled local is a global READ on its line')
    ok(seen['GSET head 3'], 'an assignment without `local` is a global WRITE on its line')
end)
