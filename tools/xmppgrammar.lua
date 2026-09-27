-- xmppgrammar — THE ACCEPTANCE OF THE XMPP GRAMMAR (CART-1138): the derived grammar (lua/cartograph/xmppgrammar.lua)
-- against its own laws and against the RUNNING fxml library.
--
--   nvim --headless -u NONE -l tools/xmppgrammar.lua [--spec FILE] [--otp DIR] [--rows]
--
-- For every -xml record entry's minimal and maximal sample term (xmppspec.sample_term):
--   LAW 1   read(print(el)) = el             the text layer round-trips the #xmlel term (modulo attribute order)
--   LAW 2   decode(read(print(encode(r)))) = r   the whole grammar round-trips the record
--   ORACLE  fxml:element_to_binary(el) is our print(el) byte for byte, and fxml_stream:parse_element(our text) is our
--           read(our text) term for term —
--           the installed runtime (erl) run once over every sample, the printer's rules having been OBSERVED on it
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(here)

local o, want_rows = { spec = '~/git/xmpp/specs/xmpp_codec.spec' }, false
local i = 1
while arg[i] do
    local a = arg[i]
    if a == '--rows' then want_rows = true
    elseif a:match('^%-%-') and arg[i + 1] then o[a:sub(3)] = arg[i + 1]; i = i + 1
    else io.stderr:write('unknown argument ' .. a .. '\n'); os.exit(2) end
    i = i + 1
end
o.spec = vim.fn.expand(o.spec)
if not o.otp then
    local rel = vim.fn.glob('/usr/lib/erlang/releases/*', false, true)[1]
    local fd = rel and io.open(rel .. '/OTP_VERSION')
    local v = fd and vim.trim(fd:read('a')); if fd then fd:close() end
    local cand = v and vim.fn.expand('~/git/otp_src_' .. v)
    if cand and vim.fn.isdirectory(cand) == 1 then o.otp = cand end
end
local function print(line) io.write(line, '\n') end

local A = require('cartograph.algebra').load()
local XS = require 'cartograph.xmppspec'
local XG = require 'cartograph.xmppgrammar'
local t0 = vim.uv.hrtime()
local G = XG.new { spec = o.spec, otp = o.otp }
local spec = G.spec

-- an #xmlel term as an Erlang literal (binaries as byte lists: exact whatever they hold)
local function bin(s)
    local b = {}
    for j = 1, #s do b[j] = tostring(s:byte(j)) end
    return '<<' .. table.concat(b, ',') .. '>>'
end
local function erl(t)
    if t.k == 'lit' then
        if t.lk == 'atom' then return "'" .. tostring(t.v) .. "'" end
        return bin(tostring(t.v))
    end
    local parts = {}
    for j, c in ipairs(t.kids or {}) do parts[j] = erl(c) end
    if t.k == 'list' then return '[' .. table.concat(parts, ',') .. ']' end
    return '{' .. table.concat(parts, ',') .. '}'
end

-- an xmlns FIELD left "" is resolved by the round trip to the namespace the element was written in (the encoder chooses
-- it, the decoder reads it back): the input compares with that namespace in the field
local function resolved(E, r, dec)
    if not (r.kids and dec.kids and r.k == dec.k) then return r end
    local kids = {}
    for fi, f in ipairs(E and E.result and E.result.fields or {}) do
        kids[fi] = r.kids[fi]
        -- a child record resolves the same way, by its own -xml
        local c, dc = r.kids[fi], dec.kids[fi]
        local cr = c and c.k and c.k:match('^rec:(.+)$')
        local names = cr and spec.by_record[cr]
        if names and dc and dc.k == c.k then kids[fi] = resolved(spec.entries[names[1]], c, dc) end
        local srcs = type(f) == 'string' and XS.label_sources(E, f) or {}
        local s1 = srcs[1]
        if s1 and s1.kind == 'attr' and s1.name == 'xmlns' and c and c.k == 'lit' and c.v == '' then kids[fi] = dc end
    end
    for j = #kids + 1, #(r.kids or {}) do kids[j] = r.kids[j] end
    return A.rebuild(r, kids)
end

local st = { entries = 0, samples = 0, encoded = 0, law1 = 0, law2 = 0, law2_fail = 0, unprintable = 0, undecoded = 0 }
local rows, cases = {}, {}
for _, name in ipairs(spec.order) do
    local E = spec.entries[name]
    if E.result and E.result.kind == 'record' then
        st.entries = st.entries + 1
        for _, maximal in ipairs { false, true } do
            st.samples = st.samples + 1
            local r = XS.sample_term(spec, E, maximal, 1)
            local el = XS.encode_entry(spec, E, r, '', { enc = function (text, v, E2)
                local m, f = text:match('^{%s*([%w_]+)%s*,%s*([%w_]+)%s*,')
                if not m then f = text:match('^{%s*([%w_]+)%s*,'); m = E2.module end
                return (require('cartograph.erlterms').call(G.program, m, f, { v }))
            end })
            local text = el and XG.print_el(el)
            if not text then st.unprintable = st.unprintable + 1
            else
                st.encoded = st.encoded + 1
                local back = XG.read(text)
                if back and A.show(XG.canon(back)) == A.show(XG.canon(el)) then st.law1 = st.law1 + 1
                else rows[#rows + 1] = ('  LAW1 %s %s: %s'):format(name, maximal and 'max' or 'min', text:sub(1, 160)) end
                local dec = back and G.decode(back)
                if dec and require('cartograph.erlterms').status(dec) ~= 'complete' then st.undecoded = st.undecoded + 1
                elseif dec and A.show(dec) == A.show(resolved(E, r, dec)) then st.law2 = st.law2 + 1
                else
                    st.law2_fail = st.law2_fail + 1
                    rows[#rows + 1] = ('  LAW2 %s %s\n      in   %s\n      out  %s'):format(name, maximal and 'max' or 'min',
                        A.show(r):sub(1, 200), dec and A.show(dec):sub(1, 200) or 'nil')
                end
                -- the oracle: fxml prints OUR el to our text, and fxml's parse of our text is OUR read of it
                cases[#cases + 1] = { name = name .. (maximal and ' max' or ' min'), el = el, text = text, read = back }
            end
        end
    end
end

-- THE ORACLE: one erl run over every case
local script = { 'Cases = [' }
for j, c in ipairs(cases) do
    script[#script + 1] = ('{%d, %s, %s, %s}%s'):format(j, erl(c.el), bin(c.text), c.read and erl(c.read) or 'none',
        j < #cases and ',' or '')
end
script[#script + 1] = '],'
script[#script + 1] = [[lists:foreach(fun({N, El, Text, Read}) ->
    P = (catch fxml:element_to_binary(El)) =:= Text,
    R = (catch fxml_stream:parse_element(Text)) =:= Read,
    io:format("~p ~p ~p~n", [N, P, R]) end, Cases),
halt().]]
local path = vim.fn.tempname() .. '.erl.txt'
local fd = assert(io.open(path, 'w')); fd:write(table.concat(script, '\n')); fd:close()
local out = vim.fn.system({ 'erl', '-noshell', '-eval', ('{ok, B} = file:read_file("%s"), {ok, Ts, _} = erl_scan:string(binary_to_list(B)), {ok, Es} = erl_parse:parse_exprs(Ts), erl_eval:exprs(Es, []).'):format(path) })
local p_ok, r_ok, seen = 0, 0, 0
for n, p, r in out:gmatch('(%d+) (%a+) (%a+)') do
    seen = seen + 1
    if p == 'true' then p_ok = p_ok + 1 else rows[#rows + 1] = '  ORACLE print differs: ' .. cases[tonumber(n)].name .. ': ' .. cases[tonumber(n)].text:sub(1, 120) end
    if r == 'true' then r_ok = r_ok + 1 else rows[#rows + 1] = '  ORACLE parse differs: ' .. cases[tonumber(n)].name end
end
os.remove(path)

print(('xmppgrammar  spec %s  runtime source %s  (%.0f ms)'):format(o.spec, o.otp or 'none', (vim.uv.hrtime() - t0) / 1e6))
print(('  record entries %d, sample terms %d: encoded and printed %d (not printable %d)'):format(st.entries, st.samples,
    st.encoded, st.unprintable))
print(('  LAW 1 read(print(el)) = el: %d of %d'):format(st.law1, st.encoded))
print(('  LAW 2 decode(read(print(encode(r)))) = r: %d of %d (the decoder not fully evaluated %d, a different record %d)'):format(
    st.law2, st.encoded, st.undecoded, st.law2_fail))
print(('  ORACLE fxml (the running library, %d cases answered): print byte for byte %d, parse to the same #xmlel %d%s'):format(
    seen, p_ok, r_ok, seen == 0 and ('   ⚠ erl said: ' .. out:sub(1, 200)) or ''))
if want_rows then for _, r in ipairs(rows) do print(r) end end
