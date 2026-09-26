-- xmppspeccensus — what xmppspec reads out of xmpp_codec.spec, and the two consistency oracles it can be held to
-- (CART-1096).
--
--   nvim --headless -u NONE -l tools/xmppspeccensus.lua [--spec FILE] [--hrl FILE] [--rows] [--erl]
--
-- Defaults: --spec ~/git/xmpp/specs/xmpp_codec.spec  --hrl ~/git/xmpp/include/xmpp_codec.hrl (both read-only).
--
-- ★★★ THE KNOWN-NONZERO COUNTER. A line scan counts `^-xml(` independently of the parse; parsed + refused must equal
-- it, or the reader lost forms without saying so. It is printed first, with its verdict.
-- ★★ THE ARITY / NAME CROSS-CHECK is against the record declarations the COMPILER sees (erlrecords' scope of
-- xmpp_codec.hrl). ⚠ It is a DRIFT check, not an independent witness: fxml_gen GENERATED that header from this spec.
-- What it can catch is a misread result tuple (a wrong slot count or order) and a stale header; the hand-declared
-- records (iq, message, presence, ps_error, … — the spec's own -record forms) are where a name could legitimately
-- differ, and those rows are tagged `hand`; a '$_' slot names no field and is counted, not compared.
-- ★★★ --erl IS THE INDEPENDENT WITNESS: OTP's own erl_scan + erl_parse read every -xml form (the grammar is not
-- tree-sitter's), fxml_gen's defaults and label rules are applied in Erlang, and one row per -xml
-- (name, element, xmlns, module, result kind, result slots, every label's source) is JOINED ROW BY ROW against
-- xmppspec's. Needs `erl` on PATH; the unit tests never do. It writes nothing (fxml_gen:consult would write a temp
-- file NEXT TO the spec, inside the read-only corpus, which is why the generator itself is not called).
-- ⚠ NO GATE and NO expected counts: the library moves.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()
if not (pcall(vim.treesitter.language.add, 'erlang') and vim.treesitter.language.add('erlang')) then
    print('xmppspeccensus: no erlang parser'); os.exit(2)
end
local X = require 'cartograph.xmppspec'
local ER = require 'cartograph.erlrecords'
local function print(...)
    local t = {}
    for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
    io.stdout:write(table.concat(t, '\t'), '\n')
end

local SPEC, HRL, want_rows, want_erl = '~/git/xmpp/specs/xmpp_codec.spec', '~/git/xmpp/include/xmpp_codec.hrl', false,
    false
do
    local i = 1
    while arg[i] do
        local a = arg[i]
        if a == '--spec' then SPEC = arg[i + 1]; i = i + 1
        elseif a == '--hrl' then HRL = arg[i + 1]; i = i + 1
        elseif a == '--rows' then want_rows = true
        elseif a == '--erl' then want_erl = true
        else print('unknown argument: ' .. a); os.exit(2) end
        i = i + 1
    end
end
SPEC, HRL = vim.fn.expand(SPEC), vim.fn.expand(HRL)

local fd = io.open(SPEC, 'r')
if not fd then print('unreadable spec: ' .. SPEC); os.exit(2) end
local src = fd:read('a'); fd:close()
local scan = 0
for line in (src .. '\n'):gmatch('([^\n]*)\n') do if line:find('^%-xml%(') then scan = scan + 1 end end

local spec = X.parse_source(src, SPEC)
local sc = vim.fn.filereadable(HRL) == 1 and ER.new {}:scope(HRL) or nil
if sc then X.attach_records(spec, sc.records) end

local function keys(t) local k = {} for x in pairs(t) do k[#k + 1] = x end table.sort(k) return k end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

print('xmppspeccensus')
print('  spec  ' .. SPEC)
print('  hrl   ' .. (sc and HRL or ('(unreadable: ' .. HRL .. ')')))
print(('\n  KNOWN-NONZERO: line scan ^-xml( = %d · parsed %d + refused %d = %d  -> %s')
    :format(scan, #spec.order, #spec.refused, #spec.order + #spec.refused,
        scan == #spec.order + #spec.refused and scan > 0 and 'OK' or 'MISMATCH'))
print(('  -xml forms the parse reached %d · spec -record forms %d'):format(spec.forms, count(spec.records)))
if #spec.refused > 0 then
    print('  REFUSED (line name: why)')
    for _, r in ipairs(spec.refused) do print(('    %5d %-28s %s'):format(r.line, r.name or '?', r.why)) end
end

-- ── results ──
local rk, nrec_slots, nconst_slots = { record = 0, tuple = 0, label = 0, const = 0 }, 0, 0
for _, x in ipairs(spec.order) do
    local e = spec.entries[x]
    rk[e.result.kind] = rk[e.result.kind] + 1
    if e.result.kind == 'record' then
        for _, s in ipairs(e.result.fields) do
            if type(s) == 'table' then nconst_slots = nconst_slots + 1 else nrec_slots = nrec_slots + 1 end
        end
    end
end
local multi = {}
for r, xs in pairs(spec.by_record) do if #xs > 1 then multi[#multi + 1] = r end end
table.sort(multi, function (a, b)
    local na, nb = #spec.by_record[a], #spec.by_record[b]
    if na ~= nb then return na > nb end
    return a < b
end)
print(('\n  RESULTS  record %d · anonymous tuple %d · label %d (a scalar element) · const %d (presence is the value)')
    :format(rk.record, rk.tuple, rk.label, rk.const))
print(('  distinct result records %d · produced by >1 -xml %d'):format(count(spec.by_record), #multi))
print(('  record result slots: label %d · constant %d (a constant slot discriminates variants of one record)')
    :format(nrec_slots, nconst_slots))
for i, r in ipairs(multi) do
    if i > 12 and not want_rows then print(('    … %d more (--rows)'):format(#multi - 12)) break end
    local xs = spec.by_record[r]
    -- what tells the variants apart: an element name, an xmlns, or a constant slot
    local els, nss, consts = {}, {}, 0
    for _, x in ipairs(xs) do
        local e = spec.entries[x]
        els[e.element] = true
        nss[type(e.xmlns) == 'table' and table.concat(e.xmlns, '|') or e.xmlns] = true
        for _, s in ipairs(e.result.fields) do if type(s) == 'table' then consts = consts + 1 break end end
    end
    print(('    %-24s %3d  elements %d · xmlns %d · with a constant slot %d'):format(r, #xs, count(els), count(nss),
        consts))
end

-- ── labels by source kind (the generator's get_spec_by_label, over every result label) ──
local kinds, unknown_rows = {}, {}
local cdata_default = 0
local function tally(e, label)
    local srcs = X.label_sources(e, label)
    local k = srcs[1].kind
    if k == 'ref' and #srcs > 1 then k = 'ref(shared by ' .. #srcs .. ')' end
    kinds[k] = (kinds[k] or 0) + 1
    if srcs[1].kind == 'cdata' and not srcs[1].declared then cdata_default = cdata_default + 1 end
    if srcs[1].kind == 'unknown' then unknown_rows[#unknown_rows + 1] = ('%s:%d %s'):format(e.name, e.line, label) end
end
for _, x in ipairs(spec.order) do
    local e = spec.entries[x]
    if e.result.kind == 'record' or e.result.kind == 'tuple' then
        for _, s in ipairs(e.result.fields) do if type(s) == 'string' then tally(e, s) end end
    elseif e.result.kind == 'label' then tally(e, e.result.label) end
end
print('\n  LABELS BY SOURCE KIND (record + anonymous-tuple slots + scalar results)')
for _, k in ipairs(keys(kinds)) do print(('    %-22s %5d'):format(k, kinds[k])) end
print(('    of the cdata labels, resolved through the #cdata{} DEFAULT (no cdata = … declared): %d'):format(cdata_default))
if #unknown_rows > 0 then
    print('  UNKNOWN LABELS')
    for _, r in ipairs(unknown_rows) do print('    ' .. r) end
end

-- ── refs, defaults, stray keys ──
local nref, nref_derived, nattr, nattr_derived, dangling, extra = 0, 0, 0, 0, {}, {}
local unreferenced_labels = 0
for _, x in ipairs(spec.order) do
    local e = spec.entries[x]
    for _, r in ipairs(e.refs) do
        nref = nref + 1
        if not r.declared_label then nref_derived = nref_derived + 1 end
        if not spec.entries[r.name] then dangling[#dangling + 1] = ('%s:%d -> %s'):format(x, r.line, r.name) end
    end
    for _, a in ipairs(e.attrs) do
        nattr = nattr + 1
        if not a.declared_label then nattr_derived = nattr_derived + 1 end
    end
    for _, k in ipairs(e.extra or {}) do extra[#extra + 1] = x .. '.' .. k end
    -- a declared attr/ref whose label the result never uses: decoded then dropped (or a spec slip)
    if e.result.kind ~= 'const' then
        local used = {}
        if e.result.kind ~= 'label' then
            for _, s in ipairs(e.result.fields) do if type(s) == 'string' then used[s] = true end end
        else used[e.result.label] = true end
        for _, a in ipairs(e.attrs) do if not used[a.label] then unreferenced_labels = unreferenced_labels + 1 end end
        for _, r in ipairs(e.refs) do if not used[r.label] then unreferenced_labels = unreferenced_labels + 1 end end
    end
end
print(('\n  #attr %d (label derived from name %d) · #ref %d (label derived %d) · refs to no -xml %d')
    :format(nattr, nattr_derived, nref, nref_derived, #dangling))
print(('  declared attrs/refs whose label no result uses %d · #elem keys fxml_gen does not define %d')
    :format(unreferenced_labels, #extra))
for _, d in ipairs(dangling) do print('    dangling ref ' .. d) end
for _, d in ipairs(extra) do print('    extra key ' .. d) end

-- ── the cross-check against the compiled header ──
if sc then
    local hrl_names = 0
    for _ in pairs(sc.records) do hrl_names = hrl_names + 1 end
    local C = X.check_fields(spec)
    local src_count = { hrl = 0, spec = 0, derived = 0, none = 0 }
    for r in pairs(spec.by_record) do
        local _, s = X.record_fields(spec, r)
        src_count[s or 'none'] = src_count[s or 'none'] + 1
    end
    local produced_not_declared, declared_not_produced = {}, {}
    for r in pairs(spec.by_record) do if not sc.records[r] then produced_not_declared[#produced_not_declared + 1] = r end end
    for r in pairs(sc.records) do if not spec.by_record[r] then declared_not_produced[#declared_not_produced + 1] = r end end
    table.sort(produced_not_declared); table.sort(declared_not_produced)
    print(('\n  CROSS-CHECK vs %s (%d records visible)'):format(vim.fn.fnamemodify(HRL, ':t'), hrl_names))
    print(('  field names from: hrl %d · spec -record %d · generator rule %d · none %d')
        :format(src_count.hrl, src_count.spec, src_count.derived, src_count.none))
    print(('  record-result -xml checked %d · ARITY mismatches %d · \'$_\' slots (no field, not compared) %d · NAME mismatches %d (hand-declared %d)')
        :format(C.checked, #C.arity, C.ignored, #C.names, (function ()
            local n = 0 for _, r in ipairs(C.names) do if r.hand then n = n + 1 end end return n end)()))
    for _, r in ipairs(C.arity) do
        print(('    arity %-24s #%s result %d vs declared %d%s'):format(r.xml, r.record, r.result, r.declared,
            r.hand and ' [hand]' or ''))
    end
    for _, r in ipairs(C.names) do
        print(('    name  %-24s #%s slot %d: %s -> %s, declared %s%s'):format(r.xml, r.record, r.index, r.label,
            X.label_field(r.label), r.declared, r.hand and ' [hand]' or ''))
    end
    print(('  result records the header does not declare %d%s'):format(#produced_not_declared,
        #produced_not_declared > 0 and (': ' .. table.concat(produced_not_declared, ' ')) or ''))
    print(('  header records no -xml produces %d%s'):format(#declared_not_produced,
        #declared_not_produced > 0 and (': ' .. table.concat(declared_not_produced, ' ')) or ''))
end

if not want_erl then return end

-- ── --erl: erl_parse's reading of every -xml, joined row by row ─────────────────────────────────────────────────
print('\n  --erl ORACLE (erl_scan + erl_parse per -xml form; fxml_gen defaults and label rules applied in Erlang)')
if vim.fn.executable('erl') ~= 1 then print('    erl not on PATH: skipped'); return end
local ERL = ([==[
{ok, Bin} = file:read_file("%s"),
{ok, Toks, _} = erl_scan:string(binary_to_list(Bin), 1),
Split = fun S([], Cur, Acc) -> lists:reverse(case Cur of [] -> Acc; _ -> [lists:reverse(Cur) | Acc] end);
            S([{dot, _} = D | T], Cur, Acc) -> S(T, [], [lists:reverse([D | Cur]) | Acc]);
            S([H | T], Cur, Acc) -> S(T, [H | Cur], Acc) end,
Forms = Split(Toks, [], []),
V = fun Val({atom, _, A}) -> {atom, A};
        Val({integer, _, N}) -> {int, N};
        Val({bin, _, Els}) -> {bin, lists:flatten([S || {bin_element, _, {string, _, S}, default, default} <- Els])};
        Val({nil, _}) -> {list, []};
        Val({cons, _, H, T}) -> {list, Rest} = Val(T), {list, [Val(H) | Rest]};
        Val({tuple, _, Es}) -> {tuple, [Val(E) || E <- Es]};
        Val({record, _, Name, Fs}) -> {record, Name, [{K, Val(X)} || {record_field, _, {atom, _, K}, X} <- Fs]};
        Val(Other) -> {expr, Other} end,
Get = fun(K, Fs, D) -> case lists:keyfind(K, 1, Fs) of {K, X} -> X; false -> D end end,
IsLabel = fun(A) when is_atom(A) -> case atom_to_list(A) of "$_els" -> true; "$_" -> true; [$$, $_ | _] -> false;
                                        [$$, $- | _] -> false; [$$, _ | _] -> true; _ -> false end;
             (_) -> false end,
Prep = fun(undefined, N) -> list_to_atom(string:to_lower([$$ | N])); (L, _) -> L end,
Str = fun({bin, S}) -> S; ({atom, A}) -> atom_to_list(A); (_) -> "?" end,
Slot = fun({atom, A}) -> case IsLabel(A) of true -> atom_to_list(A); false -> "=" ++ atom_to_list(A) end;
          (_) -> "?" end,
lists:foreach(fun
  ([{'-', _}, {atom, _, xml}, {'(', L} | Rest]) ->
    [{dot, _}, {')', _} | RMid] = lists:reverse(Rest),
    Mid = lists:reverse(RMid),
    case erl_parse:parse_exprs([{'{', L} | Mid] ++ [{'}', L}, {dot, L}]) of
      {ok, [{tuple, _, [{atom, _, Name}, RecAst]}]} ->
        {record, elem, EF} = V(RecAst),
        Elt = Str(Get(name, EF, none)),
        Xmlns = case Get(xmlns, EF, {bin, ""}) of {list, Xs} -> string:join([Str(X) || X <- Xs], "|"); X -> Str(X) end,
        Mod = Str(Get(module, EF, none)),
        Attrs = case Get(attrs, EF, {list, []}) of {list, As} -> As; _ -> [] end,
        Refs = case Get(refs, EF, {list, []}) of {list, Rs} -> Rs; _ -> [] end,
        CLabel = case Get(cdata, EF, none) of {record, cdata, CF} -> case Get(label, CF, none) of {atom, CL} -> CL; _ -> '$cdata' end;
                                            _ -> '$cdata' end,
        LabOf = fun(Fs) -> Prep(case Get(label, Fs, none) of {atom, LL} -> LL; _ -> undefined end, Str(Get(name, Fs, none))) end,
        Source = fun('$_els') -> "els"; ('$_') -> "ignored";
                    (Lab) when Lab =:= CLabel -> "cdata";
                    (Lab) ->
                      case [Str(Get(name, AF, none)) || {record, attr, AF} <- Attrs, LabOf(AF) =:= Lab] of
                        [A1 | _] -> "attr@" ++ A1;
                        [] -> case [Str(Get(name, RF, none)) || {record, ref, RF} <- Refs, LabOf(RF) =:= Lab] of
                                [] -> "unknown";
                                RNs -> "ref:" ++ string:join(RNs, "+") end end end,
        {Kind, ResText, Labels} = case Get(result, EF, none) of
            {tuple, [{atom, Tag} | Slots] = All} ->
                case IsLabel(Tag) of
                  true -> {"tuple", "(" ++ string:join([Slot(S) || S <- All], ",") ++ ")", [A || {atom, A} <- All, IsLabel(A)]};
                  false -> {"record", atom_to_list(Tag) ++ "(" ++ string:join([Slot(S) || S <- Slots], ",") ++ ")",
                            [A || {atom, A} <- Slots, IsLabel(A)]} end;
            {atom, A} -> case IsLabel(A) of true -> {"label", atom_to_list(A), [A]}; false -> {"const", "=" ++ atom_to_list(A), []} end;
            _ -> {"?", "?", []} end,
        Srcs = string:join([atom_to_list(Lb) ++ ":" ++ Source(Lb) || Lb <- Labels], ";"),
        io:format("X\t~s\t~s\t~s\t~s\t~s\t~s\t~s~n", [atom_to_list(Name), Elt, Xmlns, Mod, Kind, ResText, Srcs]);
      Other -> io:format("F\t~p\t~0p~n", [L, Other])
    end;
  (_) -> ok
 end, Forms),
halt().
]==]):format(SPEC)
local out = vim.fn.system({ 'erl', '-noshell', '-eval', ERL })
local theirs, nfail = {}, 0
for line in out:gmatch('[^\n]+') do
    local cols = vim.split(line, '\t', { plain = true })
    if cols[1] == 'X' then theirs[cols[2]] = table.concat(cols, '\t', 3)
    elseif cols[1] == 'F' then nfail = nfail + 1; print('    erl_parse failed: ' .. line) end
end
local function slot(s) return type(s) == 'table' and ('=' .. s.const) or s end
local function row(e)
    local r, kind, text, labels = e.result, e.result.kind, nil, {}
    if kind == 'record' or kind == 'tuple' then
        local t = {}
        for i, s in ipairs(r.fields) do
            t[i] = slot(s)
            if type(s) == 'string' then labels[#labels + 1] = s end
        end
        text = (kind == 'record' and r.record or '') .. '(' .. table.concat(t, ',') .. ')'
    elseif kind == 'label' then text = r.label; labels = { r.label }
    else text = '=' .. r.const end
    local srcs = {}
    for _, lb in ipairs(labels) do
        local ss = X.label_sources(e, lb)
        local k = ss[1].kind
        local d = k
        if k == 'attr' then d = 'attr@' .. ss[1].name
        elseif k == 'ref' then
            local ns = {}
            for i, x in ipairs(ss) do ns[i] = x.name end
            d = 'ref:' .. table.concat(ns, '+')
        end
        srcs[#srcs + 1] = lb .. ':' .. d
    end
    return table.concat({ e.element, type(e.xmlns) == 'table' and table.concat(e.xmlns, '|') or e.xmlns,
        e.module or '?', kind, text, table.concat(srcs, ';') }, '\t')
end
local agree, differ, only_erl, only_us = 0, {}, {}, {}
for _, x in ipairs(spec.order) do
    local mine = row(spec.entries[x])
    if not theirs[x] then only_us[#only_us + 1] = x
    elseif theirs[x] == mine then agree = agree + 1
    else differ[#differ + 1] = ('%s\n        erl  %s\n        us   %s'):format(x, theirs[x], mine) end
end
for x in pairs(theirs) do if not spec.entries[x] then only_erl[#only_erl + 1] = x end end
table.sort(only_erl)
print(('    rows: erl %d · xmppspec %d · AGREE %d · differ %d · only erl %d · only xmppspec %d · erl_parse failures %d')
    :format(count(theirs), #spec.order, agree, #differ, #only_erl, #only_us, nfail))
for i = 1, math.min(want_rows and #differ or 10, #differ) do print('      differs ' .. differ[i]) end
for _, x in ipairs(only_erl) do print('      only erl ' .. x) end
for _, x in ipairs(only_us) do print('      only xmppspec ' .. x) end
