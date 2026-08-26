-- T3: THE MCP STDIO HOST — the pure verb table (lua/cartograph/agent.lua)
-- behind newline-delimited JSON-RPC 2.0, so ANY MCP client (an agent runner, an
-- editor plugin, a shell harness) gets the polyglot READ surface. This is the
-- same split tools/lspserve.lua uses over lua/cartograph/lsp.lua, and this file
-- is deliberately the same size: framing + read loop, no analysis.
--
--   nvim --headless -u NONE -l tools/mcpserve.lua <root> [--index-only]
--
-- FRAMING. lua/cartograph/mcp.lua is this project's MCP CLIENT and the direction
-- simply reverses here — so the wire is ITS wire: one JSON object per line, no
-- Content-Length headers (that is LSP's framing, and lspserve owns it).
-- tests/fixtures/mcp/server.lua is the client-side precedent; this is its mirror.
--
-- STDOUT IS THE PROTOCOL. Every human-readable byte goes to stderr; one stray
-- print corrupts the stream for every client. (nvim's own --headless startup
-- noise does not touch stdout in `-l` mode.)
--
-- ── WHAT A REFUSAL LOOKS LIKE ON THIS WIRE, and why it is not `isError` ─────
-- A refusal is a stable ANSWER ABOUT THE WORLD ("this graph has no call graph,
-- so I will not tell you a function has no callers"), not a fault. MCP's
-- isError flag means "the tool failed"; a client that sees it throws the payload
-- away and shows a string — which would delete exactly the field an agent needs
-- (`refusal.rule` / `.remedy`). So:
--   answer   -> content = the envelope, isError = false
--   REFUSAL  -> content = the envelope with ok:false + refusal{rule,reason,
--               remedy}, isError = FALSE. The agent reads it and acts.
--   internal error -> isError = true (the tool really did fail)
--   protocol fault (unknown tool, bad arguments) -> a JSON-RPC error object,
--               because it is a fault in the CALL, not an answer about the code.
--
-- ── --index-only MAKES THE CAPABILITY REFUSAL REACHABLE (CART-0580) ─────────
-- agentq shipped a `thin-index` refusal that no caller could reach, so one of
-- the two refusals the honesty contract rests on could not be demonstrated.
-- Here the thin graph is a documented mode: `--index-only` opens defs-only, and
-- edges_callers / edges_callees / why / lint_run then REFUSE rather than
-- answering "none". tests/mcpserve_spec.lua drives that refusal over the wire.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local root, index_only
for i = 1, #arg do
    if arg[i] == '--index-only' then index_only = true
    elseif not root then root = arg[i] end
end
if not root then
    io.stderr:write('usage: mcpserve <root> [--index-only]\n')
    os.exit(2)
end

local agent = require 'cartograph.agent'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'

-- cold-load the corpus once (a server pays extraction at startup, then serves)
local ok, data = pcall(index_only and ts.index_only or ts.extract, root)
if not ok then
    io.stderr:write('extract failed: ' .. tostring(data) .. '\n')
    os.exit(1)
end
data.root = data.root or root
store.ingest(data)
io.stderr:write(('cartograph mcpserve: %s (%d nodes%s)\n')
    :format(root, #(data.nodes or {}), index_only and ', index-only' or ''))

-- ── newline-delimited JSON-RPC 2.0 over stdio ───────────────────────────
local function write_message(obj)
    io.stdout:write(vim.json.encode(obj) .. '\n')
    io.stdout:flush()
end

local function reply(id, result) write_message { jsonrpc = '2.0', id = id, result = result } end
local function fail(id, code, message)
    write_message { jsonrpc = '2.0', id = id, error = { code = code, message = message } }
end

--- an MCP tool result: one text block holding the envelope as JSON
local function content(doc, is_error)
    return { content = { { type = 'text', text = vim.json.encode(doc) } },
        isError = is_error or false }
end

-- ── the tool surface: one MCP tool per verb ─────────────────────────────
-- Tool names use `_`, not the design's `graph.info`: several clients restrict
-- tool names to [a-zA-Z0-9_-], and "any MCP client" is the point of this host.
local function tools_list()
    local out = {}
    for _, name in ipairs(agent.ORDER) do
        local v = agent.VERBS[name]
        out[#out + 1] = { name = name, inputSchema = agent.schema(name),
            description = ('%s. Answers carry the envelope: an EMPTY result always names its absence (absent|refused|frontier|unavailable) — never a bare list. tier_basis=%s.')
                :format(v.summary, v.tier_basis) }
    end
    return { tools = out }
end

local function tools_call(id, params)
    local name = params and params.name
    if not name or not agent.VERBS[name] then
        return fail(id, -32602, ('unknown tool %q (have: %s)')
            :format(tostring(name), table.concat(agent.ORDER, ', ')))
    end
    local args = params.arguments
    if args == nil or args == vim.NIL then args = {} end
    if type(args) ~= 'table' then
        return fail(id, -32602, 'arguments must be an object')
    end
    local doc, status = agent.answer(store, name, args)
    if status == 'usage' then
        return fail(id, -32602, doc.error.reason)
    end
    -- an ANSWER and a REFUSAL both ride as content; only a real fault is isError
    reply(id, content(doc, status == 'error'))
end

-- ── serve loop ──────────────────────────────────────────────────────────
while true do
    local line = io.stdin:read('l')
    if not line then break end -- EOF: the client went away
    if line ~= '' then
        local dok, msg = pcall(vim.json.decode, line)
        if not dok or type(msg) ~= 'table' then
            write_message { jsonrpc = '2.0', id = vim.NIL,
                error = { code = -32700, message = 'parse error' } }
        else
            local method, id = msg.method, msg.id
            if method == nil then
                -- a response to a server->client request; we send none, so ignore
            elseif id == nil then
                -- NOTIFICATION: never answered (a reply to one is a protocol bug).
                -- `notifications/initialized` is the handshake's third leg.
                if method == 'exit' then break end
            elseif method == 'initialize' then
                reply(id, {
                    -- the version this project's own client speaks (mcp.lua)
                    protocolVersion = '2024-11-05',
                    capabilities = { tools = vim.empty_dict() },
                    serverInfo = { name = 'cartograph', version = '0.1' },
                })
            elseif method == 'ping' then
                reply(id, vim.empty_dict())
            elseif method == 'tools/list' then
                reply(id, tools_list())
            elseif method == 'tools/call' then
                local cok, err = pcall(tools_call, id, msg.params)
                if not cok then fail(id, -32603, tostring(err)) end
            elseif method == 'shutdown' then
                reply(id, vim.NIL)
                break
            else
                fail(id, -32601, 'method not found: ' .. tostring(method))
            end
        end
    end
end

os.exit(0)
