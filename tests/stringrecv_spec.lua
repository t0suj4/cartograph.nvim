-- A STRING RECEIVER IS THE STDLIB'S (CART-1062): `('%s'):format(x)` is `string.format`, so no project def named
-- `format` can be its target — the name-match used to land 4,330 such calls on one project function. Pinned both ways:
-- a receiver that is NOT a string by syntax still resolves as it did.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ingest(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    store.ingest(ts.extract(root))
    return store
end

-- the callers of `name` in `file`: { caller name… }
local function callers(st, file, name)
    local out = {}
    for _, n in ipairs(st.data.nodes) do
        if n.file == file and n.name == name then
            for _, c in ipairs(st.usedby[n.id] or {}) do out[#out + 1] = st.by_id[c].name end
        end
    end
    table.sort(out)
    return out
end

test('stringrecv: a string-literal, concatenation or tostring() receiver never reaches a project `format`', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local st = ingest {
        ['fmt.lua'] = 'local M = {}\nfunction M.format(a) return a end\nfunction M.rep(a) return a end\nreturn M\n',
        ['use.lua'] = table.concat({
            'local U = {}',
            "function U.lit() return ('%s'):format(1) end",
            "function U.cat(b) return ('a' .. b):rep(2) end",
            "function U.tos(q) return tostring(q):format() end",
            'function U.name(obj) return obj:format(1) end',
            'return U', '' }, '\n'),
    }
    eq({ 'U.name' }, callers(st, 'fmt.lua', 'M.format'), 'only the untyped receiver still name-matches')
    eq({}, callers(st, 'fmt.lua', 'M.rep'), 'a concatenation is a string')
end)
