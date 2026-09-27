-- grpcpeer — THE gRPC ADAPTER of the peer generator (CART-1138): a tree's .proto contracts -> a peergen model.
--
-- The SECOND instance, and the acceptance test that the core (peergen) has no XMPP in it: it is fed a model built
-- from a different kind of source, and nothing in the core changes.
--   DISPATCH  every `rpc` of every `service` (proto.parse): the key is Service/Rpc, declared, not discovered
--   ACCEPT    the request MESSAGE: its fields are the parameters, the template the message over them (a client
--             stream: the parameter is the list of messages)
--   REPLIES   the response message with every field an output (a server stream: a sequence of them), and the gRPC
--             status error. SHAPES ONLY: a .proto declares what comes back, not when — the server's policy is not in
--             the contract, exactly as a peer's policy is never in its counterpart's implementation.
-- Message fields come from proto.parse (`[repeated] Type name = N`): a repeated field is a list term, a message-typed
-- field a nested message term the caller builds, a scalar a literal.
local M = {}

-- a type name as the index keys it: without a leading dot
local function norm(t) return (tostring(t):gsub('^%.', '')) end

--- the model of every .proto under `root`. opts = { tp = transport (default: the disk) }
--- -> model, stats
function M.model(root, opts)
    opts = opts or {}
    local P = require 'cartograph.proto'
    local tp = opts.tp or { dir = function (d) return vim.fs.dir(d) end }
    local files = P.find(root, tp)
    -- ★ MESSAGES ARE PER FILE: microservices-demo vendors demo.proto into four services, and the copies are not all
    -- the same — a global index would read one copy's rpc against another copy's messages
    local messages, services, byfile = {}, {}, {}
    local stats = { files = #files, services = 0, rpcs = 0, messages = 0, refused = 0, unknown_types = 0, streams = 0,
        copies = 0, drift = 0 }
    for _, rel in ipairs(files) do
        local fd = io.open(root .. '/' .. rel, 'rb')
        local src = fd and fd:read('a'); if fd then fd:close() end
        local r = src and P.parse(src)
        if r then
            stats.refused = stats.refused + (r.refused or 0)
            local own = {}
            byfile[rel] = own
            for _, m in ipairs(r.messages) do
                own[m.name] = m
                if r.package then own[r.package .. '.' .. m.name] = m end
                messages[m.name] = messages[m.name] or m
                stats.messages = stats.messages + 1
            end
            for _, s in ipairs(r.services) do
                stats.services = stats.services + 1
                services[#services + 1] = { svc = s, package = r.package, file = rel }
            end
        end
    end
    -- the rpc's own file first, then any file (an imported type)
    local function lookup(file, pkg, t)
        local n = norm(t)
        local own = byfile[file] or {}
        return own[n] or (pkg and own[pkg .. '.' .. n]) or messages[n] or nil
    end
    -- a message as a term: every field a hole named by `name_of(field)`
    local function message_term(m, name_of)
        local kids = {}
        for i, f in ipairs(m.fields or {}) do kids[i] = { k = 'hole', h = name_of(f, i) } end
        return { k = 'rec:' .. m.name, kids = kids }
    end
    local ops = {}
    for _, s in ipairs(services) do
        for _, rpc in ipairs(s.svc.rpcs) do
            stats.rpcs = stats.rpcs + 1
            local req, resp = lookup(s.file, s.package, rpc.req), lookup(s.file, s.package, rpc.resp)
            if not req or not resp then stats.unknown_types = stats.unknown_types + 1
            else
                if rpc.stream_in or rpc.stream_out then stats.streams = stats.streams + 1 end
                local params, request = {}, nil
                if rpc.stream_in then
                    params = { 'Messages' }
                    request = { k = 'list', kids = { { k = 'hole', h = 'Messages', rep = true } } }
                else
                    request = message_term(req, function (f) params[#params + 1] = f.name; return f.name end)
                end
                local out = message_term(resp, function (_, i) return 'o' .. i end)
                local ok_term = rpc.stream_out and { k = 'list', kids = { { k = 'hole', h = 'Stream', rep = true } } } or out
                local doc = { ('%s.%s/%s  (%s) -> (%s)%s%s'):format(s.package or '', s.svc.name, rpc.name,
                    tostring(rpc.req), tostring(rpc.resp), rpc.stream_in and '  client stream' or '',
                    rpc.stream_out and '  server stream' or '') }
                for i, f in ipairs(resp.fields or {}) do
                    doc[#doc + 1] = ('  o%d = %s%s %s'):format(i, f.label and (f.label .. ' ') or '', f.type, f.name)
                end
                ops[#ops + 1] = { name = s.svc.name .. '_' .. rpc.name, doc = doc, params = params, request = request,
                    files = { s.file },
                    replies = {
                        { name = 'ok', term = ok_term },
                        { name = 'error', term = { k = 'tuple', kids = { { k = 'lit', v = 'error', lk = 'atom' },
                            { k = 'hole', h = 'code' }, { k = 'hole', h = 'message' } } } },
                    },
                    rpc = { service = s.svc.name, method = rpc.name, package = s.package, req = req, resp = resp } }
            end
        end
    end
    -- ★ A VENDORED COPY IS ONE OPERATION WHEN IT AGREES AND A FINDING WHEN IT DOES NOT: the same package.Service/Rpc
    -- with the same request and reply shapes merges (its files listed); a different shape is kept apart, suffixed,
    -- and counted as drift
    local PG = require 'cartograph.peergen'
    local merged, order = {}, {}
    for _, op in ipairs(ops) do
        local key = tostring(op.rpc.package) .. '.' .. op.name
        local shape = PG.serialize(op.request) .. PG.serialize(op.replies[1].term)
        local list = merged[key]
        if not list then list = {}; merged[key] = list; order[#order + 1] = key end
        local same
        for _, x in ipairs(list) do if x.shape == shape then same = x end end
        if same then
            same.op.files[#same.op.files + 1] = op.files[1]
            stats.copies = stats.copies + 1
        else
            if #list > 0 then
                stats.drift = stats.drift + 1
                op.name = op.name .. '_v' .. (#list + 1)
                op.doc[#op.doc + 1] = ('  ⚠ DRIFT: %s declares this rpc with a different shape than %s'):format(op.files[1],
                    list[1].op.files[1])
            end
            list[#list + 1] = { shape = shape, op = op }
        end
    end
    local out = {}
    for _, key in ipairs(order) do for _, x in ipairs(merged[key]) do
        x.op.doc[#x.op.doc + 1] = '  declared in ' .. table.concat(x.op.files, ', ')
        out[#out + 1] = x.op
    end end
    ops = out
    table.sort(ops, function (a, b) return a.name < b.name end)
    stats.ops = #ops
    local model = { name = 'grpc peer of ' .. root, operations = ops,
        doc = { 'every rpc a .proto declares: its request message\'s fields are the parameters, its reply the response message',
            '(o1, o2 … its fields, in declaration order) or the gRPC status error.' } }
    return model, stats
end

--- a sample value for a field (the simulated fidelity's canned data): a message a nested sample, repeated a list
function M.sample(m, lookup_fn, depth)
    depth = depth or 0
    local kids = {}
    for i, f in ipairs(m.fields or {}) do
        local v
        local sub = lookup_fn(f.type)
        if sub and depth < 3 then v = M.sample(sub, lookup_fn, depth + 1)
        elseif f.type:match('int') then v = { k = 'lit', v = '1', lk = 'int' }
        elseif f.type == 'bool' then v = { k = 'lit', v = 'true', lk = 'atom' }
        else v = { k = 'lit', v = 'x', lk = 'bin' } end
        if f.label == 'repeated' then v = { k = 'list', kids = { v } } end
        kids[i] = v
    end
    return { k = 'rec:' .. m.name, kids = kids }
end

return M
