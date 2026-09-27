-- p1natives — THE ACCEPTANCE OF THE NIF MODELS (lua/cartograph/p1natives.lua) against the RUNNING runtime.
--
--   nvim --headless -u NONE -l tools/p1natives.lua [--len N] [--xmpp DIR] [--otp DIR] [--rows]
--
-- EXHAUSTIVE, not sampled: every string of length 1..N (default 4) over the bytes the models' rules turn on
-- (a A . @ / space " & ' : < >), each asked of the runtime (erl, application:ensure_all_started(xmpp)) and of the model:
--   stringprep:nodeprep/nameprep/resourceprep, jid:string_to_usr   the model against the NIF, one to one
--   jid:decode                                                    END TO END: xmpp's own jid.erl evaluated by
--                                                                 erlterms, the models answering its NIF calls
-- plus the bytes outside the claimed domain (a control, UTF-8), where every model must answer nil. The bar is zero
-- disagreements inside the domain.
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local here = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tools/') or '.'
package.path = here .. '/lua/?.lua;' .. here .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:prepend(here)

local o, want_rows = { len = '4', xmpp = '~/git/xmpp' }, false
local i = 1
while arg[i] do
    local a = arg[i]
    if a == '--rows' then want_rows = true
    elseif a:match('^%-%-') and arg[i + 1] then o[a:sub(3)] = arg[i + 1]; i = i + 1
    else io.stderr:write('unknown argument ' .. a .. '\n'); os.exit(2) end
    i = i + 1
end
o.xmpp = vim.fn.expand(o.xmpp)
local function print(line) io.write(line, '\n') end
local t0 = vim.uv.hrtime()

local N = require 'cartograph.p1natives'
local ET = require 'cartograph.erlterms'
local ER = require 'cartograph.erlrecords'
local X = require 'cartograph.xmppserver'

local ALPHA = { 'a', 'A', '.', '@', '/', ' ', '"', '&', "'", ':', '<', '>' }
local inputs = {}
local function gen(prefix, n)
    if n == 0 then return end
    for _, c in ipairs(ALPHA) do
        inputs[#inputs + 1] = prefix .. c
        gen(prefix .. c, n - 1)
    end
end
gen('', tonumber(o.len))

local function hex(s) return (s:gsub('.', function (c) return ('%02x'):format(c:byte()) end)) end
-- a term in the runtime's printed shape: b:<hex> | t:<hex>,<hex>,<hex> | j:<six hex> | error | EXIT | ?
local function shape(t, holes)
    if not t then return 'nil' end
    if t.k == 'hole' then
        for _, w in pairs(holes or {}) do if w:find('never returns', 1, true) then return 'EXIT' end end
        return '?'
    end
    if t.k == 'lit' and t.lk == 'atom' then return tostring(t.v) end
    if t.k == 'lit' then return 'b:' .. hex(tostring(t.v)) end
    local kids = t.kids or {}
    local tag = t.k:match('^rec:(.+)$')
    if t.k == 'tuple' and kids[1] and kids[1].k == 'lit' and kids[1].lk == 'atom' and #kids == 7 then
        tag, kids = tostring(kids[1].v), { unpack(kids, 2) }
    end
    local parts = {}
    for j, c in ipairs(kids) do
        if c.k ~= 'lit' or c.lk == 'atom' then return '?' end
        parts[j] = hex(tostring(c.v))
    end
    return (tag == 'jid' and 'j:' or 't:') .. table.concat(parts, ',')
end

-- THE RUNTIME: one erl run over every input
local function bin(s)
    local b = {}
    for j = 1, #s do b[j] = tostring(s:byte(j)) end
    return '<<' .. table.concat(b, ',') .. '>>'
end
local script = { [==[application:ensure_all_started(xmpp),
H = fun(B) -> lists:flatten([io_lib:format("~2.16.0b", [C]) || <<C>> <= B]) end,
F = fun(error) -> "error";
       ({'EXIT', _}) -> "EXIT";
       (B) when is_binary(B) -> "b:" ++ H(B);
       ({U, S, R}) -> "t:" ++ H(U) ++ "," ++ H(S) ++ "," ++ H(R);
       ({jid, A, B, C, D, E, G}) -> "j:" ++ string:join([H(Z) || Z <- [A, B, C, D, E, G]], ",");
       (_) -> "?" end,
Ins = [ ]==] }
for j, s in ipairs(inputs) do script[#script + 1] = bin(s) .. (j < #inputs and ',' or '') end
script[#script + 1] = [==[],
lists:foldl(fun(I, K) ->
    io:format("~p ~s ~s ~s ~s ~s~n", [K, F(catch stringprep:nodeprep(I)), F(catch stringprep:nameprep(I)),
        F(catch stringprep:resourceprep(I)), F(catch jid:string_to_usr(I)), F(catch jid:decode(I))]),
    K + 1 end, 1, Ins),
halt().]==]
local path = vim.fn.tempname() .. '.erl.txt'
local fd = assert(io.open(path, 'w')); fd:write(table.concat(script, '\n')); fd:close()
local out = vim.fn.system({ 'erl', '-noshell', '-eval', ('{ok, B} = file:read_file("%s"), {ok, Ts, _} = erl_scan:string(binary_to_list(B)), {ok, Es} = erl_parse:parse_exprs(Ts), erl_eval:exprs(Es, []).'):format(path) })
os.remove(path)
local truth, seen = {}, 0
for k, a, b, c, d, e in out:gmatch('(%d+) (%S+) (%S+) (%S+) (%S+) (%S+)') do
    truth[tonumber(k)] = { a, b, c, d, e }; seen = seen + 1
end

-- THE MODELS, and xmpp's jid.erl evaluated over them
local E = ER.new { include_dirs = { o.xmpp .. '/include' }, apps = { xmpp = o.xmpp } }
local P = X.program(o.xmpp .. '/src', E, { otp = o.otp })
local function lit(s) local l = { k = 'lit', v = s, lk = 'bin' }; return l end
local FNS = { 'stringprep:nodeprep/1', 'stringprep:nameprep/1', 'stringprep:resourceprep/1', 'jid:string_to_usr/1' }
local agree, differ, rows = { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, {}
local nat = 0
for k, s in ipairs(inputs) do
    local t = truth[k]
    if t then
        local got = {}
        for j, id in ipairs(FNS) do got[j] = shape(N.models[id] { lit(s) }) end
        local S = ET.session()   -- one per call: a session's budgets are for one question
        got[5] = shape(ET.call(P, 'jid', 'decode', { lit(s) }, S))
        nat = nat + S.stats.natives
        for j = 1, 5 do
            if got[j] == t[j] then agree[j] = agree[j] + 1
            else
                differ[j] = differ[j] + 1
                rows[#rows + 1] = ('  %-26s %-8q runtime %s  model %s'):format(FNS[j] or 'jid:decode/1 (evaluated)', s, t[j], got[j])
            end
        end
    end
end
-- outside the claimed domain every model answers nil (the hole stays)
local outside, leaked = { 'a\tb', 'a\127', '\195\169', 'u@s/\226\152\131' }, 0
for _, s in ipairs(outside) do
    for _, id in ipairs(FNS) do
        if N.models[id] { lit(s) } ~= nil then leaked = leaked + 1; rows[#rows + 1] = ('  LEAK %s answered %q'):format(id, s) end
    end
end

print(('p1natives  %d inputs (length 1..%s over %d bytes), %d answered by the runtime  (%.0f ms)'):format(#inputs, o.len,
    #ALPHA, seen, (vim.uv.hrtime() - t0) / 1e6))
for j, name in ipairs { 'stringprep:nodeprep', 'stringprep:nameprep', 'stringprep:resourceprep', 'jid:string_to_usr',
    'jid:decode (jid.erl evaluated)' } do
    print(('  %-32s agree %d  differ %d'):format(name, agree[j], differ[j]))
end
print(('  outside the domain (%d inputs x %d models): answered %d (must be 0); native answers in the evaluation %d'):format(
    #outside, #FNS, leaked, nat))
-- what the runtime answered, per function: agreement on one answer kind alone would be vacuous
local kinds = {}
for _, t in pairs(truth) do
    for j = 1, 5 do
        local kk = t[j]:match('^(%a+)')
        kinds[j] = kinds[j] or {}
        kinds[j][kk] = (kinds[j][kk] or 0) + 1
    end
end
for j = 1, 5 do
    local ks = {}
    for kk, n in pairs(kinds[j] or {}) do ks[#ks + 1] = kk .. ' ' .. n end
    table.sort(ks)
    print(('  runtime answers %-26s %s'):format(FNS[j] or 'jid:decode/1', table.concat(ks, ', ')))
end
if seen == 0 then print('  ⚠ erl said: ' .. out:sub(1, 300)) end
if want_rows then for n = 1, math.min(#rows, 60) do print(rows[n]) end end
