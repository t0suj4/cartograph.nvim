-- peergen — GENERATE THE CLIENT OF A SERVER (CART-1138): ejabberd's IQ handlers -> a self-contained Lua client, and
-- the acceptance of it. The core (lua/cartograph/peergen.lua) is protocol-free; the XMPP IQ adapter is
-- lua/cartograph/xmpppeer.lua.
--
--   nvim --headless -u NONE -l tools/peergen.lua [--server DIR] [--spec FILE] [--otp DIR] [--out FILE] [--rows]
--        [--merge [--client DIR]] [--twice]
--
-- ACCEPTANCE, every number printed:
--   CONTRACT   per operation candidate, the template against every earlier clause: reachable / maybe / shadowed
--              (shadowed candidates are not emitted)
--   STANDALONE the generated source loaded in an environment with no `require` (it cannot lean on cartograph)
--   IMITATION  each operation called through an in-process transport that runs the handler on the request (erlterms):
--              the reply must fit one of the operation's own cases — a reply the client cannot read is a bug in one of them
--   --merge    every (handler, clause) the client-server merge ACCEPTED for converse.js must be an emitted candidate:
--              the real client is one member of the generated peer
--   --twice    the model built twice from scratch generates the same bytes
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(here)

local o = { server = '~/work/brotardcast/ejabberd', spec = '~/git/xmpp/specs/xmpp_codec.spec',
    client = '~/work/brotardcast/converse.js/src' }
local want_rows, want_merge, twice = false, false, false
local i = 1
while arg[i] do
    local a = arg[i]
    if a == '--rows' then want_rows = true
    elseif a == '--merge' then want_merge = true
    elseif a == '--twice' then twice = true
    elseif a:match('^%-%-') and arg[i + 1] then o[a:sub(3)] = arg[i + 1]; i = i + 1
    else io.stderr:write('unknown argument ' .. a .. '\n'); os.exit(2) end
    i = i + 1
end
for k, v in pairs(o) do o[k] = vim.fn.expand(v) end
if not o.otp then
    local rel = vim.fn.glob('/usr/lib/erlang/releases/*', false, true)[1]
    local fd = rel and io.open(rel .. '/OTP_VERSION')
    local v = fd and vim.trim(fd:read('a')); if fd then fd:close() end
    local cand = v and vim.fn.expand('~/git/otp_src_' .. v)
    if cand and vim.fn.isdirectory(cand) == 1 then o.otp = cand end
end
local function print(line) io.write(line, '\n') end

local A = require('cartograph.algebra').load()
local PG = require 'cartograph.peergen'
local XP = require 'cartograph.xmpppeer'
local ET = require 'cartograph.erlterms'
local ts = require 'cartograph.providers.treesitter'

local t0 = vim.uv.hrtime()
local data = ts.extract(o.server)
local model, st, index, P = XP.model(o.server, { spec = o.spec, otp = o.otp, data = data })
local src = PG.generate(model)
print(('peergen  server %s  runtime source %s  (%.0f ms)'):format(o.server, o.otp or 'none', (vim.uv.hrtime() - t0) / 1e6))
print(('  endpoints %d, handlers %d (no source %d), clauses %d (not an iq head %d)'):format(st.endpoints, st.handlers,
    st.no_source, st.clauses, st.not_iq))
print(('  CONTRACT: reachable %d, maybe %d, shadowed %d (not emitted); a shadowing default retried as a parameter %d; '
    .. 'heads taking any iq %d'):format(st.reachable, st.maybe, st.shadowed, st.widened or 0, st.generic or 0))
print(('  operations %d, reply cases %d (alternatives capped %d, never returns %d); %d bytes of Lua'):format(st.ops, st.cases,
    st.capped, st.never_returns, #src))
if o.out then
    local fd = assert(io.open(o.out, 'w')); fd:write(src); fd:close()
    print('  written ' .. o.out)
end

-- STANDALONE: no require, no cartograph
local chunk = assert(loadstring(src, '=generated'))
local sandbox = { ipairs = ipairs, pairs = pairs, table = table, string = string, tostring = tostring, tonumber = tonumber,
    error = error, type = type, select = select, next = next }
setfenv(chunk, sandbox)
local okload, C = pcall(chunk)
print(('  STANDALONE: loads without require: %s'):format(okload and 'yes' or ('NO — ' .. tostring(C))))

-- IMITATION: the handler itself answers, in process
if okload then
    local JID = A.node('rec:jid', A.lit('u'), A.lit('s'), A.lit('r'), A.lit('u'), A.lit('s'), A.lit('r'))
    local transport = { exchange = function (req, op)
        local c = index[op.name][1]
        local argv = {}
        for j = 1, c.arity do argv[j] = j == c.arg and req or A.hole('Arg' .. j) end
        return (ET.call(P, c.mod, c.fn, argv, ET.session()))
    end }
    local client = C.new(transport)
    local fit, unread, rows = 0, 0, {}
    local names = {}
    for name in pairs(C.operations) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local op = C.operations[name]
        local args = {}
        for _, p in ipairs(op.params) do args[p] = (p == 'To' or p == 'From') and JID or A.lit('x') end
        local okc, case, _, rep = pcall(client[name], args)
        if okc and case then fit = fit + 1; rows[#rows + 1] = ('  %-40s %s'):format(name, case)
        else
            unread = unread + 1
            rows[#rows + 1] = ('  %-40s UNREAD %s'):format(name, okc and A.show(rep or A.lit('?')):sub(1, 140) or tostring(case))
        end
    end
    print(('  IMITATION: %d operation(s) answered by their handler in a case the client reads, %d not'):format(fit, unread))
    if want_rows then for _, r in ipairs(rows) do print(r) end end
end

-- --merge: the real client is a member of the generated peer
if want_merge then
    local XM = require 'cartograph.xmppmerge'
    local R = XM.merge({ client = o.client, server = o.server, spec = o.spec })
    local emitted = {}
    for _, cands in pairs(index) do for _, c in ipairs(cands) do emitted[c.handler .. '#' .. c.clause] = true end end
    local covered, missing, miss = 0, 0, {}
    local seen = {}
    for _, row in ipairs(R.rows or {}) do
        for _, c in ipairs(row.candidates or {}) do
            if c.clause then
                local k = c.handler .. '#' .. c.clause
                if not seen[k] then
                    seen[k] = true
                    if emitted[k] then covered = covered + 1 else missing = missing + 1; miss[#miss + 1] = c.mod .. ':' .. c.fn .. ' #' .. c.clause end
                end
            end
        end
    end
    table.sort(miss)
    print(('  MERGE: %d (handler, clause) pair(s) converse.js reaches are emitted operations, %d are not%s'):format(covered,
        missing, missing > 0 and (': ' .. table.concat(miss, ', ')) or ''))
end

if twice then
    local m2 = XP.model(o.server, { spec = o.spec, otp = o.otp, data = ts.extract(o.server) })
    local src2 = PG.generate(m2)
    print(('  DETERMINISM: a second build generates %s'):format(src2 == src and 'the same bytes' or 'DIFFERENT bytes'))
end
