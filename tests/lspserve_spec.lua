-- THE T2 HOST AS A PROCESS (CART-0823). tools/lspserve.lua had NO process-level
-- spec at all: lsp_spec drives the handler table in-process, which is the right
-- place for handler behaviour and cannot see the framing, the argv parsing, or
-- the routing this ticket added. So a change to the host was, until now,
-- unverifiable — and that is precisely the half CART-0823 touches.
--
-- ★★★ THE LSP SIDE NEEDS NO PROTOCOL EXTENSION, WHICH IS THE FINDING. The MCP
-- host routes by an explicit `band` argument because a tool call names no file.
-- Every LSP request DOES name one, so `session.owning(uri)` — written for the
-- cockpit's rule that a command acts on the buffer's band, innermost root
-- winning — is already the routing rule. Nothing was invented for it.
--
-- ⚠ SWITCHABLE ROOTS, NOT A CROSS-ROOT QUERY: one band is readable at a time, so
-- a definition in root A is never found from a file in root B. That join is
-- CART-0821 / CART-0026.
--
-- ⚠ THE REQUESTS ARE WRITTEN AS ONE STDIN BLOB and the responses parsed from the
-- full stdout, rather than driven interactively. LSP over stdio is framed
-- messages in order, so this exercises the real framing, the real argv path and
-- the real routing in a real process — and it needs no async pump inside a
-- synchronous spec runner, which is where a bidirectional harness would have
-- gone wrong first.

local function repo(rel)
    return vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h') .. '/' .. rel
end

local function ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

local A_LUA = [[
local M = {}
function M.alpha_only(x) return x end
return M
]]
local B_LUA = [[
local M = {}
function M.beta_only(y) return y end
return M
]]

local function mkroot(name, src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(src); fd:close()
    return root
end

--- Content-Length framing, the one thing a handler-level spec cannot reach.
local function frame(msg)
    local body = vim.json.encode(msg)
    return ('Content-Length: %d\r\n\r\n%s'):format(#body, body)
end

--- every `id`-bearing response in a raw stdout stream, keyed by id.
--- ⚠ READ THE LENGTH AND TAKE EXACTLY THAT MANY BYTES. My first cut matched the
--- body with a lazy `{.-}` anchored on the NEXT header, which fails two ways at
--- once: consecutive frames have no separator between `}` and `Content-Length`,
--- and the final frame has no following header at all. It reported "initialize
--- did not answer" while the answer was sitting in the output — a harness fault
--- reading as a server fault, which is the shape worth being slow about.
--- The banner lines the host writes to stderr are interleaved here too, so the
--- scan skips anything that is not a header.
local function responses(out)
    local by, i = {}, 1
    while true do
        local hs, he, len = out:find('Content%-Length:%s*(%d+)\r?\n\r?\n', i)
        if not hs then break end
        local body = out:sub(he + 1, he + tonumber(len))
        local ok, m = pcall(vim.json.decode, body)
        if ok and type(m) == 'table' and m.id then by[m.id] = m end
        i = he + tonumber(len) + 1
    end
    return by
end

--- does this documentSymbol result name `want`? ⚠ ASSERT THE PROPERTY, NOT THE
--- WHOLE LIST: documentSymbol also reports the module and its top-level
--- statements, so an exact-list assertion fences the symbol vocabulary (someone
--- else's subject) rather than which BAND answered (this one's).
local function has(result, want)
    for _, sym in ipairs(result or {}) do if sym.name == want then return true end end
    return false
end

test('lspserve: a request ROUTES to the band owning its uri', function ()
    if not ready() then skip('no treesitter') end
    local a = mkroot('a.lua', A_LUA)
    local b = mkroot('b.lua', B_LUA)
    local input = table.concat({
        frame { jsonrpc = '2.0', id = 1, method = 'initialize', params = vim.empty_dict() },
        -- a file in the FIRST root (the active band): the baseline
        frame { jsonrpc = '2.0', id = 2, method = 'textDocument/documentSymbol',
            params = { textDocument = { uri = 'file://' .. a .. '/a.lua' } } },
        -- a file in the SECOND root: only reachable if the request routed
        frame { jsonrpc = '2.0', id = 3, method = 'textDocument/documentSymbol',
            params = { textDocument = { uri = 'file://' .. b .. '/b.lua' } } },
        -- and BACK, because routing that only goes one way is not routing
        frame { jsonrpc = '2.0', id = 4, method = 'textDocument/documentSymbol',
            params = { textDocument = { uri = 'file://' .. a .. '/a.lua' } } },
        frame { jsonrpc = '2.0', id = 5, method = 'shutdown', params = vim.empty_dict() },
        frame { jsonrpc = '2.0', method = 'exit' },
    }, '')

    local out = vim.fn.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/lspserve.lua'), a, b }, input)
    local by = responses(out)
    ok(by[1] ~= nil, 'initialize answered: ' .. out:sub(1, 300))
    ok(has(by[2] and by[2].result, 'M.alpha_only'), 'band A answers for its own file')
    -- ★ THE ASSERTION THAT MATTERS. Without routing this is EMPTY: b.lua is not
    -- a file of root A, so A's graph has no symbols for it — an empty answer
    -- that looks exactly like "this file has no symbols", which is the
    -- absence-rendered-as-silence class the whole surface exists to avoid.
    ok(has(by[3] and by[3].result, 'M.beta_only'),
        'a uri in the OTHER root routes to the band that owns it')
    ok(not has(by[3] and by[3].result, 'M.alpha_only'),
        'and it is B\'s graph answering, not A\'s with a coincidental hit')
    ok(has(by[4] and by[4].result, 'M.alpha_only'), 'and routes back')
    vim.fn.delete(a, 'rf'); vim.fn.delete(b, 'rf')
end)

test('lspserve: a single root never touches the session, and still answers', function ()
    if not ready() then skip('no treesitter') end
    -- THE BYTE-IDENTICAL PATH: `session` is required only when there is more
    -- than one root, so the single-root host is what it always was.
    local a = mkroot('a.lua', A_LUA)
    local input = table.concat({
        frame { jsonrpc = '2.0', id = 1, method = 'textDocument/documentSymbol',
            params = { textDocument = { uri = 'file://' .. a .. '/a.lua' } } },
        frame { jsonrpc = '2.0', id = 2, method = 'shutdown', params = vim.empty_dict() },
        frame { jsonrpc = '2.0', method = 'exit' },
    }, '')
    local out = vim.fn.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/lspserve.lua'), a }, input)
    local by = responses(out)
    ok(has(by[1] and by[1].result, 'M.alpha_only'))
    ok(not out:find('bands, active'), 'no band chatter on a single-root host')
    vim.fn.delete(a, 'rf')
end)

test('lspserve: a duplicate root is REFUSED at startup', function ()
    if not ready() then skip('no treesitter') end
    -- CART-0837 at this entry point too: argv has no init.lua-shaped guard in
    -- front of it, and two bands on one root make `owning` depend on pairs()
    -- order — which is the function this host's whole routing rests on.
    local a = mkroot('a.lua', A_LUA)
    local out = vim.fn.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/lspserve.lua'), a, a }, '')
    ok(vim.v.shell_error ~= 0, 'the server refuses to start')
    ok(out:find('given twice', 1, true), 'and says why: ' .. out:sub(1, 200))
    vim.fn.delete(a, 'rf')
end)
