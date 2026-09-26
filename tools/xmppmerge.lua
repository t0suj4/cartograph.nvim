-- xmppmerge — MERGE across the wire, censused: every converse.js function that builds an IQ request, joined to the
-- ejabberd handler clause that accepts it (unify ∘ compose over the decoded record; lua/cartograph/xmppmerge.lua).
--
--   nvim --headless -u NONE -l tools/xmppmerge.lua [--client DIR] [--server DIR] [--spec FILE] [--rows] [--server-view]
--        [--check-absent]
--
-- Defaults: --client ~/work/brotardcast/converse.js/src  --server ~/work/brotardcast/ejabberd
--           --spec ~/git/xmpp/specs/xmpp_codec.spec  (all read-only)
-- --rows          one block per request: its owner, and per candidate handler the clause it reaches, the clauses it
--                 shadows, each rejecting clause with the field and the clash, and the names bound across the wire
-- --server-view   THE SERVER'S POINT OF VIEW, the same pass read the other way: per registered handler the namespaces
--                 it serves, and per clause whether a client request REACHES it (and from which client functions),
--                 only SHADOWS it (an earlier clause takes the request), is REJECTED by every request (with the
--                 field), or has no client request to its namespace at all. An unreached clause is a WORK LIST:
--                 server behaviour this client never uses, or a request this reader does not see.
-- --check-absent  the ORACLE for the absent-attribute rule: xmppmerge.absent_value against every generated
--                 `decode_<xml>_attr_<name>(__TopXMLNS, undefined) -> V` clause in the spec's sibling src/ directory
-- Known-nonzero counters: requests must equal the IQ get/set templates stxcensus reports, and owned + unowned the same.
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path

local o = { client = '~/work/brotardcast/converse.js/src', server = '~/work/brotardcast/ejabberd',
    spec = '~/git/xmpp/specs/xmpp_codec.spec' }
local want_rows, check_absent, server_view = false, false, false
local i = 1
while arg[i] do
    local a = arg[i]
    if a == '--rows' then want_rows = true
    elseif a == '--check-absent' then check_absent = true
    elseif a == '--server-view' then server_view = true
    elseif a:match('^%-%-') and arg[i + 1] then o[a:sub(3)] = arg[i + 1]; i = i + 1
    else io.stderr:write('unknown argument ' .. a .. '\n'); os.exit(2) end
    i = i + 1
end
for k, v in pairs(o) do o[k] = vim.fn.fnamemodify(vim.fn.expand(v), ':p'):gsub('/+$', '') end

local M = require 'cartograph.xmppmerge'
-- rows and headers through io.write: headless `print` glues lines together (harness #30)
local function print(line) io.write(line, '\n') end
local XS = require 'cartograph.xmppspec'

local function top(t, lim)
    local ks = {}
    for k, v in pairs(t or {}) do ks[#ks + 1] = { k, v } end
    table.sort(ks, function (a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    local p = {}
    for j = 1, math.min(lim, #ks) do p[#p + 1] = ('%s=%d'):format(ks[j][1], ks[j][2]) end
    return table.concat(p, '  ')
end

if check_absent then
    local spec = assert(XS.read(o.spec))
    local srcdir = vim.fn.fnamemodify(o.spec, ':h:h') .. '/src'
    local gen = {}
    for name, kind in vim.fs.dir(srcdir) do
        if kind == 'file' and name:match('%.erl$') then
            local fd = io.open(srcdir .. '/' .. name, 'rb')
            local txt = fd:read('a'); fd:close()
            for fname, val in txt:gmatch("'?decode_([%w_:]+)'?%(__TopXMLNS,%s*undefined%)%s*%->%s*(.-);\n") do
                gen[fname] = val:gsub('%s+', ' ')
            end
        end
    end
    local agree, disagree, missing, rows = 0, 0, 0, {}
    for _, name in ipairs(spec.order) do
        local e = spec.entries[name]
        for _, at in ipairs(e.attrs or {}) do
            local g = gen[name .. '_attr_' .. at.name]
            if not g then missing = missing + 1
            else
                local mine = M.absent_value({ default = at.default, required = at.required, dec = at.dec })
                local want
                if g:match('^erlang:error') then want = 'absent'
                elseif g == '<<>>' then want = ''
                else want = g:match('^<<"(.*)">>$') or g:gsub("^'(.*)'$", '%1') end
                local got = mine.k == 'absent' and 'absent' or tostring(mine.v)
                if got == want then agree = agree + 1
                else disagree = disagree + 1; rows[#rows + 1] = ('  %s @%s: rule %s, generated %s'):format(name, at.name, got, g) end
            end
        end
    end
    print(('absent-attribute oracle: %d agree, %d disagree, %d attrs with no generated clause (%d generated clauses read from %s)')
        :format(agree, disagree, missing, vim.tbl_count(gen), srcdir))
    for j = 1, math.min(20, #rows) do print(rows[j]) end
    os.exit(disagree == 0 and 0 or 1)
end

local R = M.merge({ client = o.client, server = o.server, spec = o.spec })
local st = R.stats
local edges, handlers, owners = 0, {}, {}
for _, r in ipairs(R.rows) do
    if r.owner then owners[r.owner] = true end
    for _, c in ipairs(r.candidates) do
        if c.clause then edges = edges + 1; handlers[c.handler] = true end
    end
end
print(('xmppmerge  client %s  x  server %s'):format(o.client, o.server))
print(('  IQ requests %d (get/set templates)   owned by a client function %d   owners %d')
    :format(st.requests, st.owned, vim.tbl_count(owners)))
print(('  routed to a registered endpoint %d: accepted by a handler clause %d, rejected by every clause %d, unread %d   no endpoint %d')
    :format(st.requests - st.no_endpoint, st.accepted, st.rejected, st.unread or 0, st.no_endpoint))
print(('  edges client function -> handler clause %d over %d candidate pair(s), %d distinct handlers reached')
    :format(edges, st.candidates, vim.tbl_count(handlers)))
print(('  fragments built apart %d: held by a name or returned %d, spliced into a request %d  (%s)')
    :format(st.fragments, st.fragments_held or 0, st.fragments_spliced, top(st.spliced_by, 4)))
print(('  content holes left unknown (could hide children) %d%s'):format(#(st.unknown_holes or {}),
    (st.capped or 0) > 0 and ('   alternatives capped on %d request(s)'):format(st.capped) or ''))
print(('  no endpoint by namespace: %s'):format(top(st.missing_uri, 8)))
print(('  clause rejections by field: %s'):format(top(st.reasons, 8)))
if st.notes and st.notes.unknown_records then print(('  records no declaration covers: %s'):format(top(st.notes.unknown_records, 8))) end
if want_rows then
    for _, r in ipairs(R.rows) do
        io.write(('\n%s:%d  <iq type=%s> %s  %s%s\n'):format(r.file, r.line, r.type, r.uri or '-', r.verdict,
            (r.alternatives or 1) > 1 and ('  (' .. r.alternatives .. ' alternatives)') or ''))
        io.write(('  owner %s\n'):format(tostring(r.owner)))
        for _, c in ipairs(r.candidates) do
            local b = {}
            for k, v in pairs(c.binds or {}) do b[#b + 1] = k .. ' <- ' .. v end
            table.sort(b)
            io.write(('  -> %s:%s  %s%s  %s\n'):format(c.mod or '?', c.fn or '?',
                c.clause and ('clause #' .. c.clause) or 'NO CLAUSE',
                #c.shadowed > 0 and (' (shadows #' .. table.concat(c.shadowed, ',#') .. ')') or '', table.concat(b, '  ')))
            for _, x in ipairs(c.rejected) do
                io.write(('       #%d rejects: %s %s\n'):format(x.clause, x.at ~= '' and x.at or '(top)', tostring(x.why)))
            end
        end
    end
end
for _, h in ipairs(st.unknown_holes or {}) do if want_rows then io.write('  unknown content hole: ', h, '\n') end end

-- the server's point of view
local hs = {}
for _, rec in pairs(R.server or {}) do hs[#hs + 1] = rec end
table.sort(hs, function (a, b) return (a.mod or '') .. ':' .. (a.fn or '') < (b.mod or '') .. ':' .. (b.fn or '') end)
local by_status, asked, reached_h, nclauses = {}, 0, 0, 0
for _, rec in ipairs(hs) do
    if rec.asked then asked = asked + 1 end
    local any = false
    for k = 1, rec.nclauses do
        nclauses = nclauses + 1
        local c = rec.clauses[k]
        by_status[c.status] = (by_status[c.status] or 0) + 1
        if c.status == 'reached' then any = true end
    end
    if any then reached_h = reached_h + 1 end
end
print(('  server view: handlers %d, with a client request to their namespace %d, reached %d; clauses %d: %s')
    :format(#hs, asked, reached_h, nclauses, top(by_status, 6)))
if server_view then
    local X = require 'cartograph.xmppserver'
    for _, rec in ipairs(hs) do
        local cs = {}
        for c in pairs(rec.carriers) do cs[#cs + 1] = c end
        table.sort(cs)
        io.write(('\n%s:%s  [%s]  %s\n'):format(rec.mod or '?', rec.fn or '?', table.concat(cs, ','), table.concat(rec.uris, '  ')))
        for k = 1, rec.nclauses do
            local c = rec.clauses[k]
            local owners, seen = {}, {}
            for _, r in ipairs(c.reached) do
                local o = r.owner or (r.file .. ':' .. r.line)
                if not seen[o] then seen[o] = true; owners[#owners + 1] = o end
            end
            io.write(('  #%d %-28s %s\n'):format(k, c.status, X.head_line(rec.heads[k] or {})))
            for _, o in ipairs(owners) do io.write('       <- ', o, '\n') end
            if c.status == 'every request rejected' then
                local why = {}
                for _, x in ipairs(c.rejected) do why[(x.at ~= '' and x.at or '(top)') .. ': ' .. tostring(x.why)] = true end
                for w in pairs(why) do io.write('       rejects ', w, '\n') end
            end
        end
    end
end
