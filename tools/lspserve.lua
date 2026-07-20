-- T2: the STDIO LSP HOST — the SAME pure handler table (lua/cartograph/lsp.lua)
-- behind newline/Content-Length JSON-RPC over stdio, so ANY editor (VS Code,
-- helix, zed) gets the polyglot read surface. nvim IS the portable runtime —
-- nothing is ported off nvim APIs; this file is just the framing + read loop
-- around the handlers T1 already serves in-process ([[cartograph-lsp-surface]]).
--
--   nvim --headless -u NONE -l tools/lspserve.lua <root>
--
-- Position encoding: we advertise utf-8 (store chars ARE byte offsets), which
-- modern clients negotiate; a utf-16-only client's conversion is the banked
-- follow-up (it would live HERE, the one transport boundary, via
-- vim.str_utfindex — the handlers stay encoding-free).

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local root = arg[1]
if not root then io.stderr:write('usage: lspserve <root>\n'); os.exit(2) end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lsp = require 'cartograph.lsp'

-- cold-load the corpus once (a server pays extraction at startup, then serves)
local ok, data = pcall(ts.extract, root)
if not ok then io.stderr:write('extract failed: ' .. tostring(data) .. '\n'); os.exit(1) end
data.root = data.root or root
store.ingest(data)
io.stderr:write(('cartograph lspserve: %s (%d nodes)\n'):format(root, #data.nodes))

-- ── Content-Length framed JSON-RPC over stdio ───────────────────────────
local function read_message()
    local len
    while true do
        local line = io.stdin:read('l')
        if not line then return nil end -- EOF
        line = line:gsub('\r$', '')
        if line == '' then break end -- blank line ends the headers
        local n = line:match('^Content%-Length:%s*(%d+)')
        if n then len = tonumber(n) end
    end
    if not len then return nil end
    local body = io.stdin:read(len)
    if not body then return nil end
    local dok, msg = pcall(vim.json.decode, body)
    return dok and msg or nil
end

local function write_message(obj)
    local body = vim.json.encode(obj)
    io.stdout:write(('Content-Length: %d\r\n\r\n%s'):format(#body, body))
    io.stdout:flush()
end

local function reply(id, result) write_message { jsonrpc = '2.0', id = id, result = result } end
local function fail(id, code, message) write_message { jsonrpc = '2.0', id = id, error = { code = code, message = message } } end

-- ── serve loop ──────────────────────────────────────────────────────────
local shutting_down = false
while true do
    local msg = read_message()
    if not msg then break end
    local method, id = msg.method, msg.id
    if method == nil then
        -- a response to a server->client request; we send none, so ignore
    elseif id == nil then
        -- notification
        if method == 'exit' then break end
        -- didOpen/didSave/didChange etc.: MVP serves the saved graph (honest-
        -- stale); a didSave-driven splice is the P3 follow-up. Ignore quietly.
    else
        -- request
        local h = lsp.handlers[method]
        if not h then
            fail(id, -32601, 'method not found: ' .. method)
        else
            local hok, res = pcall(h, store, msg.params or {})
            if hok then reply(id, res == nil and vim.NIL or res)
            else fail(id, -32603, tostring(res)) end
            if method == 'shutdown' then shutting_down = true end
        end
    end
end

os.exit(shutting_down and 0 or 0)
