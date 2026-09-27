-- xmppencode — THE ORACLE FOR THE ENCODE DIRECTION (CART-1138): xmppspec.encode, read off the -xml forms by fxml_gen's
-- rules, against xmpp's OWN generated encoder (xmpp_codec:encode/2 in xmpp/src, evaluated by erlterms from source).
-- Two implementations that share no code: the spec reader + our rules, and fxml_gen's output run as a program.
--
--   nvim --headless -u NONE -l tools/xmppencode.lua [--spec FILE] [--otp DIR] [--rows] [--only NAME]
--
-- For every -xml entry whose result is a record, TWO sample terms: MINIMAL (every field at the value the decoder gives
-- an absent one — the encoder must write nothing for it — required attributes at a sample) and MAXIMAL (every
-- attribute and cdata at a sample, every list ref with one sampled child). A sample follows the field's decoder: an
-- enumeration's first value, an integer 1, a boolean true, a jid u@s/r, a plain binary "x"; a field whose decoder has
-- no sample is left at its absent value and the entry counted. Compared: element name, the attribute SET, the
-- children in order. Defaults: --spec ~/git/xmpp/specs/xmpp_codec.spec, --otp ~/git/otp_src_<installed version>.
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(here)

local o, want_rows, only = { spec = '~/git/xmpp/specs/xmpp_codec.spec' }, false, nil
local i = 1
while arg[i] do
    local a = arg[i]
    if a == '--rows' then want_rows = true
    elseif a == '--only' then i = i + 1; only = arg[i]
    elseif a:match('^%-%-') and arg[i + 1] then o[a:sub(3)] = arg[i + 1]; i = i + 1
    else io.stderr:write('unknown argument ' .. a .. '\n'); os.exit(2) end
    i = i + 1
end
local function print(line) io.write(line, '\n') end
o.spec = vim.fn.expand(o.spec)
if not o.otp then
    local rel = vim.fn.glob('/usr/lib/erlang/releases/*', false, true)[1]
    local fd = rel and io.open(rel .. '/OTP_VERSION')
    local v = fd and vim.trim(fd:read('a')); if fd then fd:close() end
    local cand = v and vim.fn.expand('~/git/otp_src_' .. v)
    if cand and vim.fn.isdirectory(cand) == 1 then o.otp = cand end
end

local A = require('cartograph.algebra').load()
local XS = require 'cartograph.xmppspec'
local ET = require 'cartograph.erlterms'
local ER = require 'cartograph.erlrecords'
local X = require 'cartograph.xmppserver'
local spec = assert(XS.read(o.spec))
local xmpp = vim.fn.fnamemodify(o.spec, ':h:h')
local hrl = xmpp .. '/include/xmpp.hrl'
if vim.fn.filereadable(hrl) == 1 then
    local sc = ER.new {}:scope(hrl)
    if sc then XS.attach_records(spec, sc.records) end
end
local E = ER.new { include_dirs = { xmpp .. '/include' }, apps = { xmpp = xmpp } }
local P = X.program(xmpp .. '/src', E, { otp = o.otp })

local unpack = table.unpack or unpack
local function lit(v, lk) local l = A.lit(v); l.lk = lk; return l end
local JID = A.node('rec:jid', lit('u', 'bin'), lit('s', 'bin'), lit('r', 'bin'), lit('u', 'bin'), lit('s', 'bin'), lit('r', 'bin'))

-- a sample value for a source, by its decoder; nil when there is none
local function sample(src)
    local dec = src.dec or ''
    if dec == '' or dec:find('xmpp_lang', 1, true) then return lit('x', 'bin') end
    local enums = dec:match('dec_enum,%s*%[%[([^%]]*)%]')
    if enums then
        local first = vim.trim((enums:match('^([^,]+)') or '')):gsub("^'(.*)'$", '%1')
        if first ~= '' then return lit(first, 'atom') end
    end
    if dec:find('dec_int', 1, true) then return lit('1', 'int') end
    if dec:find('dec_bool', 1, true) then return lit('true', 'atom') end
    if dec:find('{jid,', 1, true) then return JID end
    return nil
end

local unsampled = 0
-- a record term for entry E: minimal or maximal, `depth` levels of children
local function term_for(E, maximal, depth)
    local R = E.result
    local kids = {}
    for fi, f in ipairs(R.fields or {}) do
        if type(f) == 'table' and f.const ~= nil then kids[fi] = lit(tostring(f.const):gsub("^'(.*)'$", '%1'), 'atom')
        elseif f == '$_els' then kids[fi] = A.node('list')
        elseif f == '$_' then kids[fi] = lit('undefined', 'atom')
        else
            local srcs = XS.label_sources(E, f)
            local s1 = srcs[1]
            if s1.kind == 'attr' or s1.kind == 'cdata' then
                local required = s1.required == true or s1.required == 'true'
                local v = (required or maximal) and sample(s1) or nil
                if (required or maximal) and not v then unsampled = unsampled + 1 end
                kids[fi] = v or XS.absent_value(s1)
                if kids[fi].k == 'absent' then kids[fi] = lit('undefined', 'atom') end
            elseif s1.kind == 'ref' then
                local many = false
                for _, r in ipairs(srcs) do if r.max ~= 1 then many = true end end
                local items = {}
                if maximal and depth > 0 and many then
                    local RE = spec.entries[s1.name]
                    local c = RE and RE.result and RE.result.kind == 'record' and term_for(RE, true, depth - 1)
                    if c then items[1] = c end
                end
                -- a single child at its absent value: the ref's declared default, else undefined
                local absent = (s1.default ~= nil and s1.default ~= '$unset') and XS.absent_value({ default = s1.default })
                    or lit('undefined', 'atom')
                kids[fi] = many and A.node('list', unpack(items)) or absent
            else kids[fi] = lit('undefined', 'atom') end
        end
    end
    return A.node('rec:' .. R.record, unpack(kids, 1, #(R.fields or {})))
end

-- our encoder's primitives: the library's OWN enc function, evaluated
local function enc(text, v, E2)
    local m, f = text:match('^{%s*([%w_]+)%s*,%s*([%w_]+)%s*,')
    if not m then f = text:match('^{%s*([%w_]+)%s*,'); m = E2.module end
    if not f then return A.hole('enc ' .. text) end
    local S = ET.session()
    local t = ET.call(P, m, f, { v }, S)
    return t
end

-- normalize an xmlel term: attributes as a sorted set
local function norm(t)
    if t.k == 'tuple' and t.kids[1] and t.kids[1].k == 'lit' and t.kids[1].v == 'xmlel' then
        local attrs = {}
        for _, a in ipairs(t.kids[3].kids or {}) do attrs[#attrs + 1] = A.show(a) end
        table.sort(attrs)
        local ch = {}
        for _, c in ipairs(t.kids[4].kids or {}) do ch[#ch + 1] = norm(c) end
        return ('<%s %s>%s</>'):format(A.show(t.kids[2]), table.concat(attrs, ' '), table.concat(ch, ''))
    end
    return A.show(t)
end

local stats = { entries = 0, compared = 0, agree = 0, disagree = 0, theirs_unknown = 0, ours_refused = 0 }
local rows = {}
local t0 = vim.uv.hrtime()
for _, name in ipairs(spec.order) do
    local E2 = spec.entries[name]
    if E2.result and E2.result.kind == 'record' and (not only or name == only) then
        stats.entries = stats.entries + 1
        for _, maximal in ipairs { false, true } do
            local term = term_for(E2, maximal, 1)
            local ours, why = XS.encode_entry(spec, E2, term, '', { enc = enc })
            local S = ET.session()
            -- the entry's OWN generated encoder (encode_<name> in its module): several -xml share a record (#text{} is
            -- a body, a subject, an error text, a jingle desc), and xmpp_codec:encode/2 picks one by the record alone
            local theirs = ET.call(P, E2.module, 'encode_' .. name, { term, lit('', 'bin') }, S)
            if not ours then
                stats.ours_refused = stats.ours_refused + 1
                rows[#rows + 1] = { name, maximal, 'ours refused: ' .. tostring(why) }
            elseif ET.status(theirs) ~= 'complete' then
                stats.theirs_unknown = stats.theirs_unknown + 1
                rows[#rows + 1] = { name, maximal, 'theirs not fully evaluated: ' .. A.show(theirs):sub(1, 160) }
            else
                stats.compared = stats.compared + 1
                local a, b = norm(ours), norm(theirs)
                if a == b then stats.agree = stats.agree + 1
                else
                    stats.disagree = stats.disagree + 1
                    rows[#rows + 1] = { name, maximal, 'DISAGREE\n      ours   ' .. a:sub(1, 300) .. '\n      theirs ' .. b:sub(1, 300) }
                end
            end
        end
    end
end
print(('xmppencode  spec %s  runtime source %s'):format(o.spec, o.otp or 'none'))
print(('  record entries %d, sample terms %d: compared %d — agree %d, DISAGREE %d; theirs not fully evaluated %d; ours refused %d; '
    .. 'fields with no sample %d   (%.0f ms)'):format(stats.entries, stats.entries * 2, stats.compared, stats.agree, stats.disagree,
    stats.theirs_unknown, stats.ours_refused, unsampled, (vim.uv.hrtime() - t0) / 1e6))
if want_rows then
    for _, r in ipairs(rows) do print(('  %-32s %-7s %s'):format(r[1], r[2] and 'maximal' or 'minimal', r[3])) end
end
