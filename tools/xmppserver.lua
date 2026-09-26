-- xmppserver — the SERVER leg of the XMPP triple, censused: every registered IQ endpoint, its handler, and what the
-- handler's clause heads read from the request (CART-1087 phase 2; the library is lua/cartograph/xmppserver.lua).
--
--   nvim --headless -u NONE -l tools/xmppserver.lua [<server-root>] [--rows] [--spec <xmpp_codec.spec>] [--sends]
--
-- --sends  THE SERVER'S WRITES (CART-1108 via CART-1112 step 1): every place a handler sends (the payload of
--          xmpp:make_iq_result, the stanza given to ejabberd_router:route) with the TERM it encodes to — complete,
--          partial (the structure is known, some values flow from a call / a parameter / the matched request), or
--          opaque — and whether its record is one the codec spec puts on the wire. Holes name the step that fills them.
--
-- <server-root> defaults to ~/work/brotardcast/ejabberd. --rows prints one line per endpoint and clause, and under
-- it the request that clause ACCEPTS, lifted through the codec spec (xmppspec.lift, CART-1096); --spec defaults to
-- ~/git/xmpp/specs/xmpp_codec.spec (the dependency ejabberd pins; read-only).
-- The known-nonzero counters: the call-carrier count must equal the add_iq_handler call sites argv sees, and the
-- tuple count erlreg's registrations; a uniform zero in the read columns means the heads accessor is broken, not
-- that handlers read nothing.
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path

local root, want_rows, specpath, want_sends = nil, false, nil, false
local i = 1
while arg[i] do
    local a = arg[i]
    if a == '--rows' then want_rows = true
    elseif a == '--sends' then want_sends = true
    elseif a == '--spec' then i = i + 1; specpath = arg[i]
    else root = a end
    i = i + 1
end
specpath = vim.fn.expand(specpath or '~/git/xmpp/specs/xmpp_codec.spec')
root = vim.fn.expand(root or '~/work/brotardcast/ejabberd')

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local X = require 'cartograph.xmppserver'

local data = ts.extract(root)
store.ingest(data)
local rows, st = X.endpoints(data)
local XS = require 'cartograph.xmppspec'
local spec = vim.fn.filereadable(specpath) == 1 and XS.read(specpath) or nil
local lifted, lfront, lreasons = 0, 0, {}

local uris, handlers = {}, {}
local destructures, binds_only, no_heads, refused, clauses = 0, 0, 0, 0, 0
local consts, subrecs = {}, {}
local out = {}
for _, r in ipairs(rows) do
    if r.uri then uris[r.uri] = true end
    if r.handler and not handlers[r.handler] then
        handlers[r.handler] = true
        local rd, why = X.reads(store, r.handler)
        if not rd then
            refused = refused + 1
            out[#out + 1] = ('  %-6s %-40s %s:%s  REFUSED %s'):format(r.carrier, r.uri or '?', r.mod or '?', r.fn or '?', why)
        else
            clauses = clauses + rd.clauses
            local any_path = false
            for k, h in ipairs(rd.heads) do
                for _, f in ipairs(h.facts) do
                    if #f.path > 0 then any_path = true end
                    for _, s in ipairs(f.path) do
                        if s.rec and s.rec ~= 'iq' then subrecs[s.rec] = (subrecs[s.rec] or 0) + 1 end
                    end
                    if f.value and f.path[1] and f.path[1].rec == 'iq' and f.path[1].field == 'type' then
                        consts[f.value] = (consts[f.value] or 0) + 1
                    end
                end
                out[#out + 1] = ('  %-6s %-40s %s:%s/%d #%d  %s'):format(r.carrier, r.uri or '?', r.mod or '?',
                    r.fn or '?', h.arity, k, X.head_line(h))
                if spec and #h.facts > 0 then
                    local L = XS.lift(h.facts, spec)
                    for ai, V in pairs(L.args or {}) do
                        local ok, txt = pcall(XS.render, V)
                        out[#out + 1] = ('         arg%d  %s'):format(ai, ok and txt or ('render failed: ' .. tostring(txt)))
                    end
                    lifted = lifted + 1
                    for _, f in ipairs(L.frontier or {}) do
                        lfront = lfront + 1
                        lreasons[f.reason] = (lreasons[f.reason] or 0) + 1
                        out[#out + 1] = ('         frontier %s %s %s'):format(f.reason, f.path or '', f.detail or '')
                    end
                end
            end
            if #rd.heads == 0 then no_heads = no_heads + 1
            elseif any_path then destructures = destructures + 1 else binds_only = binds_only + 1 end
        end
    end
end
local function n(t) local k = 0 for _ in pairs(t) do k = k + 1 end return k end
local function top(t, lim)
    local ks = {}
    for k, v in pairs(t) do ks[#ks + 1] = { k, v } end
    table.sort(ks, function (a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    local p = {}
    for i = 1, math.min(lim, #ks) do p[#p + 1] = ks[i][1] .. '=' .. ks[i][2] end
    return table.concat(p, ' ')
end

print(('xmppserver  %s'):format(root))
print(('  endpoints %d  (call %d, tuple %d)   distinct URIs %d   distinct handlers %d')
    :format(#rows, st.call, st.tuple, n(uris), n(handlers)))
print(('  frontier: %d helper call(s) whose slots are parameters (not endpoints), %d with no URI, %d handler(s) unresolved')
    :format(st.not_literal, st.no_uri, st.unresolved))
print(('  handlers read: %d destructure the request in a head, %d bind it whole (the read is in the body), %d with no head, %d refused  — %d clause(s)')
    :format(destructures, binds_only, no_heads, refused, clauses))
print(('  #iq.type constants in heads: %s'):format(top(consts, 6)))
print(('  records destructured below #iq: %s'):format(top(subrecs, 12)))
print(spec and ('  lifted through %s: %d clause head(s), %d frontier row(s)%s'):format(specpath, lifted, lfront,
        lfront > 0 and ('  (' .. top(lreasons, 8) .. ')') or '')
    or ('  no codec spec at %s: nothing lifted'):format(specpath))
if want_rows then
    print('')
    for _, l in ipairs(out) do io.write(l, "\n") end
end

if want_sends then
    local ER = require 'cartograph.erlrecords'
    local E = ER.new { include_dirs = { root .. '/include' },
        apps = { xmpp = vim.fn.fnamemodify(specpath, ':h:h') } }
    local srows = X.sends(root .. '/src', { E = E, spec = spec })
    local st, why, onwire, recs = {}, {}, 0, 0
    for _, r in ipairs(srows) do
        st[r.verb .. ' ' .. r.status] = (st[r.verb .. ' ' .. r.status] or 0) + 1
        if r.record then recs = recs + 1; if r.wire and #r.wire > 0 then onwire = onwire + 1 end end
        for _, w in pairs(r.holes) do
            local k = w:gsub('^[%w_]+: ', ''):gsub('#[%w_]+%.[%w_]+ ', '#R.f ')
            why[k] = (why[k] or 0) + 1
        end
    end
    io.write(('\n  SENDS %d site(s): %s\n'):format(#srows, top(st, 8)))
    io.write(('  encoded to a record term %d, of which the codec spec puts on the wire %d\n'):format(recs, onwire))
    io.write(('  holes by the step that would fill them: %s\n'):format(top(why, 8)))
    if want_rows then
        local A = require('cartograph.algebra').load()
        for _, r in ipairs(srows) do
            io.write(('  %-8s %s:%d %s  %s  %s\n'):format(r.status, r.file, r.line, r.fn, r.verb, A.show(r.term):sub(1, 160)))
        end
    end
end
