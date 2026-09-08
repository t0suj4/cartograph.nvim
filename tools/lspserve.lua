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

-- ── N ROOTS, ROUTED BY THE URI (CART-0823) ──────────────────────────────────
-- ★★★ AND THE LSP SIDE NEEDS NO PROTOCOL EXTENSION, WHICH IS THE WHOLE POINT.
-- The MCP host routes by an explicit `band` argument because a tool call names
-- no file. Every LSP request DOES name one — `textDocument.uri` — and
-- `session.owning(path)` already answers "which band owns this file?" by root
-- containment, innermost root winning. It was written for the cockpit's rule
-- (a command acts on the buffer's band) and it is the same rule here.
-- ⚠ SWITCHABLE ROOTS, NOT A CROSS-ROOT QUERY: one band is readable at a time, so
-- a definition in root A is never found from a file in root B. That join is
-- CART-0821 / CART-0026, not this.
local roots = {}
for i = 1, #arg do roots[#roots + 1] = arg[i] end
if #roots == 0 then io.stderr:write('usage: lspserve <root>...\n'); os.exit(2) end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lsp = require 'cartograph.lsp'
-- one band per root only when there IS more than one: the single-root path never
-- touches `session`, so it stays byte-identical
local session = #roots > 1 and require 'cartograph.session' or nil

do
    local seen = {}
    for _, r in ipairs(roots) do
        -- ⚠ ONE BAND PER ROOT (CART-0837): `session.begin` accepts duplicates and
        -- `by_root`/`owning` then depend on `pairs()` order. argv has no guard in
        -- front of it, so a repeat is refused rather than deduped.
        local key = vim.fn.fnamemodify(vim.fn.expand(r), ':p'):gsub('/+$', '')
        if seen[key] then
            io.stderr:write(('lspserve: root %q given twice — one band per root (CART-0837)\n'):format(key))
            os.exit(2)
        end
        seen[key] = true
        -- extract BEFORE begin, so the band's `root` is `data.root` verbatim —
        -- `owning` matches by string containment against it
        local ok, data = pcall(ts.extract, r)
        if not ok then io.stderr:write('extract failed (' .. r .. '): ' .. tostring(data) .. '\n'); os.exit(1) end
        data.root = data.root or r
        if session then session.begin(data.root) end
        store.ingest(data)
        io.stderr:write(('cartograph lspserve: %s (%d nodes)\n'):format(data.root, #data.nodes))
    end
end
if session then
    -- ⚠ NORMALISE BOTH SIDES. `expand` does not absolutize a bare relative path,
    -- so `lspserve ./a ./b` would compare `./a` against an absolutized `data.root`,
    -- match nothing, and silently leave the LAST band active — the opposite of
    -- the documented "first root is the default". The duplicate check above
    -- already normalises this way; both sides must agree.
    local function norm(x) return vim.fn.fnamemodify(vim.fn.expand(x), ':p'):gsub('/+$', '') end
    local want = norm(roots[1])
    for _, b in ipairs(session.list()) do
        if norm(b.root) == want then session.switch(b.name); break end
    end
    io.stderr:write(('cartograph lspserve: %d bands, active %s — requests route by textDocument.uri\n')
        :format(#session.list(), tostring(session.active)))
end

--- Point the lens at the band OWNING this request's file, if the request names
--- one. ⚠ A request with no uri (`shutdown`, `initialize`) leaves the band
--- alone: the alternative — resetting to the first band — would make the active
--- band depend on how a client interleaves its housekeeping.
local function route(params)
    if not session then return end
    local uri = params and ((params.textDocument or {}).uri or params.uri)
    if type(uri) ~= 'string' then return end
    local path = uri:gsub('^file://', ''):gsub('%%(%x%x)', function (h)
        return string.char(tonumber(h, 16))
    end)
    local owner = session.owning(path)
    if owner and owner ~= session.active then session.switch(owner) end
end

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
        -- diagnostics are PUSH (T2 only — T1 lets diag.lua publish natively):
        -- on open/save, publish the graph-aware lint for that file. (didChange
        -- dirty-buffer re-extraction stays honest-stale — a later item.)
        if method == 'textDocument/didOpen' or method == 'textDocument/didSave' then
            local td = msg.params and msg.params.textDocument
            if td and td.uri then
                route(msg.params)
                write_message {
                    jsonrpc = '2.0', method = 'textDocument/publishDiagnostics',
                    params = { uri = td.uri, diagnostics = lsp.diagnostics(store, td.uri) },
                }
            end
        end
    else
        -- request
        local h = lsp.handlers[method]
        if not h then
            fail(id, -32601, 'method not found: ' .. method)
        else
            route(msg.params)
            local hok, res = pcall(h, store, msg.params or {})
            if hok then reply(id, res == nil and vim.NIL or res)
            else fail(id, -32603, tostring(res)) end
            if method == 'shutdown' then shutting_down = true end
        end
    end
end

os.exit(shutting_down and 0 or 0)
