-- Minimal MCP client (stdio transport, newline-delimited JSON-RPC 2.0).
-- MCP is a TRANSPORT for graphs: a server tool that returns the neutral
-- schema is a GraphProvider (a database introspector, a running game, a
-- debugger); tools that answer questions are ORACLES, the clangd pattern
-- over a different wire. This client is deliberately small: spawn,
-- initialize handshake, tools/call, synchronous wrappers.

local M = {}

local Client = {}
Client.__index = Client

--- Spawn and initialize an MCP server. opts = { cmd = {argv...}, env? }.
--- Returns client or nil, err.
function M.connect(opts)
    local self = setmetatable({
        next_id = 0, pending = {}, buf = '', alive = false,
    }, Client)
    local stdin = vim.uv.new_pipe()
    local stdout = vim.uv.new_pipe()
    local stderr = vim.uv.new_pipe()
    local argv = vim.deepcopy(opts.cmd)
    local path = table.remove(argv, 1)
    local env
    if opts.env then
        env = {}
        for k, v in pairs(opts.env) do env[#env + 1] = k .. '=' .. v end
    end
    local handle, spawn_err = vim.uv.spawn(path, {
        args = argv, env = env,
        stdio = { stdin, stdout, stderr },
    }, function ()
        self.alive = false
    end)
    if not handle then
        return nil, ('spawn failed: %s (%s)'):format(tostring(spawn_err), path)
    end
    self.handle, self.stdin = handle, stdin
    self.alive = true
    stdout:read_start(function (err, chunk)
        if err or not chunk then return end
        self.buf = self.buf .. chunk
        while true do
            local line, rest = self.buf:match('^([^\n]*)\n(.*)$')
            if not line then break end
            self.buf = rest
            local ok, msg = pcall(vim.json.decode, line)
            if ok and type(msg) == 'table' and msg.id ~= nil then
                self.pending[msg.id] = msg
            end
        end
    end)
    stderr:read_start(function () end) -- drained, not surfaced

    -- the MCP handshake
    local init, why = self:request('initialize', {
        protocolVersion = '2024-11-05',
        capabilities = vim.empty_dict(),
        clientInfo = { name = 'cartograph', version = '0.1' },
    }, opts.timeout)
    if not init then
        self:close()
        return nil, 'initialize failed: ' .. tostring(why)
    end
    self.server = init.serverInfo
    self:notify('notifications/initialized', vim.empty_dict())
    return self
end

function Client:send(msg)
    if not self.alive then return false end
    self.stdin:write(vim.json.encode(msg) .. '\n')
    return true
end

function Client:notify(method, params)
    return self:send({ jsonrpc = '2.0', method = method, params = params })
end

--- Synchronous request. Returns (result, nil) or (nil, error-string).
function Client:request(method, params, timeout)
    self.next_id = self.next_id + 1
    local id = self.next_id
    if not self:send({ jsonrpc = '2.0', id = id, method = method,
        params = params }) then
        return nil, 'server is gone'
    end
    vim.wait(timeout or 15000, function ()
        return self.pending[id] ~= nil or not self.alive
    end, 10)
    local msg = self.pending[id]
    self.pending[id] = nil
    if not msg then
        return nil, self.alive and 'timeout' or 'server exited'
    end
    if msg.error then
        return nil, tostring(msg.error.message or vim.inspect(msg.error))
    end
    return msg.result
end

--- Call a tool; returns its first text content decoded-if-JSON, plus the
--- raw result. Errors (protocol or isError) come back as (nil, why).
function Client:call(tool, args, timeout)
    local res, why = self:request('tools/call',
        { name = tool, arguments = args or vim.empty_dict() }, timeout)
    if not res then return nil, why end
    if res.isError then
        local t = res.content and res.content[1]
        return nil, (t and t.text) or 'tool error'
    end
    local text
    for _, c in ipairs(res.content or {}) do
        if c.type == 'text' then text = c.text break end
    end
    if text then
        local ok, decoded = pcall(vim.json.decode, text)
        if ok then return decoded, nil, res end
        return text, nil, res
    end
    return res
end

function Client:close()
    self.alive = false
    if self.handle and not self.handle:is_closing() then
        pcall(function () self.stdin:close() end)
        pcall(function () self.handle:kill('sigterm') end)
    end
end

return M
