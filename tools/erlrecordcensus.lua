-- erlrecordcensus — every record reference in an Erlang tree graded against its MODULE's record scope, with the
-- dependency roots attached read-only (CART-1095).
--
--   nvim --headless -u NONE -l tools/erlrecordcensus.lua [--root DIR] [--app NAME=DIR]... [--lib DIR]...
--        [--no-default-apps] [--rows] [--erl] [--unused]
--   --unused  THE REVERSE (declaration -> uses): records declared in the tree that no module uses, and fields of a
--             used record that no use names — a WORK LIST (positional element/2 access and header -define bodies
--             are not seen; see erlrecords.usage).
--
-- ★★★ THE ORACLE IS THE COMPILER. erl_lint rejects an unknown record and an unknown field, so in a tree that
-- compiles, EVERY `#r{f = …}`, `#r.f`, `X#r.f`, `X#r{…}`, is_record(X, r), record_info(_, r) resolves to a record
-- visible in that module and a field of it. Whatever this census leaves unresolved is therefore a statement about
-- the ROOTS it was given (a missing -include_lib application), about macros, or about erlrecords itself — and the
-- residue is printed by cause so a reader can tell which.
--   --erl   additionally runs the REAL preprocessor (epp:parse_file, OTP on this machine) per module and joins its
--           {attribute, record, {Name, Fields}} forms against erlrecords' scope ROW BY ROW (name + ordered fields):
--           an independent implementation, not a restatement. Needs `erl` on PATH; the unit tests never do.
--
-- ROOTS ARE DECLARED DATA WITH OVERRIDABLE DEFAULTS (rootjoin's convention). The analysed tree is an OTP app dir:
-- its src/*.erl are graded, its include/ is the -I path (ejabberd's rebar.config: `{i, "include"}`). The xmpp library
-- is attached as an APPLICATION ROOT for -include_lib("xmpp/…"); ejabberd pins it in rebar.config and does not
-- vendor it. `--lib /usr/lib/erlang/lib` adds OTP's ERL_LIBS-shaped dir (stdlib, kernel, public_key, …).
-- ⚠ NO GATE and NO expected counts: brotardcast is the APPLICATION corpus and it moves.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()
if not (pcall(vim.treesitter.language.add, 'erlang') and vim.treesitter.language.add('erlang')) then
    print('erlrecordcensus: no erlang parser'); os.exit(2)
end
local ER = require 'cartograph.erlrecords'
-- stdout, one line per call: headless `print` can lose a newline between two calls and glue the lines
local function print(...)
    local t = {}
    for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
    io.stdout:write(table.concat(t, '\t'), '\n')
end

local ROOTS = {
    root = '~/work/brotardcast/ejabberd',
    apps = { xmpp = '~/git/xmpp' },
    libs = {},
}

local want_rows, want_erl, want_unused = false, false, false
do
    local i = 1
    local apps, libs, noapps = {}, {}, false
    while arg[i] do
        local a = arg[i]
        if a == '--root' then ROOTS.root = arg[i + 1]; i = i + 1
        elseif a == '--app' then
            local n, d = (arg[i + 1] or ''):match('^([^=]+)=(.+)$')
            if not n then print('--app wants NAME=DIR'); os.exit(2) end
            apps[n] = d; i = i + 1
        elseif a == '--lib' then libs[#libs + 1] = arg[i + 1]; i = i + 1
        elseif a == '--no-default-apps' then noapps = true
        elseif a == '--rows' then want_rows = true
        elseif a == '--erl' then want_erl = true
        elseif a == '--unused' then want_unused = true
        else print('unknown argument: ' .. a); os.exit(2) end
        i = i + 1
    end
    if noapps then ROOTS.apps = {} end
    for n, d in pairs(apps) do ROOTS.apps[n] = d end
    for _, d in ipairs(libs) do ROOTS.libs[#ROOTS.libs + 1] = d end
end

local root = vim.fn.fnamemodify(vim.fn.expand(ROOTS.root), ':p'):gsub('/$', '')
if vim.fn.isdirectory(root .. '/src') ~= 1 then print('not an OTP app dir (no src/): ' .. root); os.exit(2) end
local E = ER.new { include_dirs = { root .. '/include' }, apps = ROOTS.apps, libs = ROOTS.libs }

print('erlrecordcensus')
print('  root  ' .. root)
local an = {}
for n in pairs(ROOTS.apps) do an[#an + 1] = n end
table.sort(an)
for _, n in ipairs(an) do print(('  app   %s = %s (read-only)'):format(n, E.apps[n])) end
for _, l in ipairs(E.libs) do print('  lib   ' .. l .. ' (read-only)') end

local files = vim.fn.glob(root .. '/src/*.erl', false, true)
table.sort(files)
local hrls = vim.fn.glob(root .. '/include/*.hrl', false, true)
table.sort(hrls)

-- ── declarations: the known-nonzero counters, cross-checkable by `grep -c '^-record('` ──
local ndecl_tree, nparse_err = 0, 0
for _, list in ipairs({ files, hrls }) do
    for _, f in ipairs(list) do
        local fa = E:facts(f)
        ndecl_tree = ndecl_tree + #fa.records
        if (fa.errors or 0) > 0 then nparse_err = nparse_err + 1 end
    end
end
print(('\n  files %d .erl, %d .hrl · -record declarations in the tree %d · files with ERROR nodes %d')
    :format(#files, #hrls, ndecl_tree, nparse_err))

-- ── grade every use ──
local S = { uses = 0, ok = 0, byk = {}, unk_rec = {}, unk_fld = {}, macro = {}, in_define = 0, in_define_bad = 0,
    native = 0 }
local rows_out = {}
local nuses_unres = 0
local use_status = {} -- use -> 'ok' | cause
for _, f in ipairs(files) do
    local fa = E:facts(f)
    S.native = S.native + (fa.native or 0)
    local per = {}
    for _, r in ipairs(E:check(f)) do
        local u = r.use
        per[u] = per[u] or {}
        table.insert(per[u], r)
    end
    for _, u in ipairs(fa.uses) do
        S.uses = S.uses + 1
        S.byk[u.kind] = (S.byk[u.kind] or 0) + 1
        if u.in_define then S.in_define = S.in_define + 1 end
        local good = true
        for _, r in ipairs(per[u] or {}) do
            if r.status ~= 'ok' then
                good = false
                local rel = f:sub(#root + 2)
                if r.status == 'unknown_record' then
                    local k = u.name
                    S.unk_rec[k] = S.unk_rec[k] or { n = 0, files = {}, cond = {} }
                    S.unk_rec[k].n = S.unk_rec[k].n + 1
                    S.unk_rec[k].files[rel] = true
                    if u.cond then S.unk_rec[k].cond[u.cond] = true end
                elseif r.status == 'unknown_field' then
                    local k = u.name .. '.' .. r.field
                    S.unk_fld[k] = S.unk_fld[k] or { n = 0, where = rel .. ':' .. u.line }
                    S.unk_fld[k].n = S.unk_fld[k].n + 1
                elseif r.status == 'macro_name' then
                    S.macro[u.macro] = (S.macro[u.macro] or 0) + 1
                end
                if want_rows then
                    rows_out[#rows_out + 1] = ('    %-15s %s:%d %s%s%s'):format(r.status, rel, u.line,
                        u.name or u.macro or '?', r.field and ('.' .. r.field) or '',
                        u.cond and ('  [' .. u.cond .. ']') or '')
                end
            end
        end
        if good then S.ok = S.ok + 1 else
            nuses_unres = nuses_unres + 1
            if u.in_define then S.in_define_bad = S.in_define_bad + 1 end
        end
        use_status[u] = good
    end
end

local function keys(t) local k = {} for x in pairs(t) do k[#k + 1] = x end table.sort(k) return k end
local kinds = {}
for _, k in ipairs(keys(S.byk)) do kinds[#kinds + 1] = k .. ' ' .. S.byk[k] end
print(('\n  RECORD USES in src/*.erl  %d   (%s)'):format(S.uses, table.concat(kinds, ' · ')))
print(('  resolved                  %d   (%.1f%%)'):format(S.ok, S.uses > 0 and 100 * S.ok / S.uses or 0))
print(('  unresolved                %d   of which inside -define bodies %d (of %d there)')
    :format(nuses_unres, S.in_define_bad, S.in_define))
print(('  OTP-29 native-record nodes %d (not read; counted so their arrival shows)'):format(S.native))

print('\n  unresolved RECORD NAMES (name: uses, files [conditions])')
local ur = keys(S.unk_rec)
if #ur == 0 then print('    none') end
for _, k in ipairs(ur) do
    local v = S.unk_rec[k]
    print(('    %-28s %4d  %s%s'):format(k, v.n, table.concat(keys(v.files), ' '),
        next(v.cond) and ('  [' .. table.concat(keys(v.cond), '; ') .. ']') or ''))
end
print('  unresolved FIELDS of a visible record (record.field: uses, first site)')
local uf = keys(S.unk_fld)
if #uf == 0 then print('    none') end
for _, k in ipairs(uf) do print(('    %-40s %4d  %s'):format(k, S.unk_fld[k].n, S.unk_fld[k].where)) end
print('  macro record names (#?M…: not expanded)')
local um = keys(S.macro)
if #um == 0 then print('    none') end
for _, k in ipairs(um) do print(('    %-28s %4d'):format(k, S.macro[k])) end

-- ── the residue's CAUSE: includes that resolved nowhere, by application ──
print('\n  MISSING INCLUDE ROOTS (spec: modules that need it [conditions] — reason)')
local miss = {}
for _, f in ipairs(files) do
    for _, m in ipairs(E:scope(f).missing) do
        local k = m.kind .. ' ' .. m.spec
        miss[k] = miss[k] or { mods = {}, cond = {}, reason = m.reason }
        miss[k].mods[vim.fn.fnamemodify(f, ':t:r')] = true
        miss[k].cond[m.cond or 'unconditional'] = true
    end
end
local mk = keys(miss)
if #mk == 0 then print('    none') end
for _, k in ipairs(mk) do
    local v = miss[k]
    print(('    %-50s %3d  [%s] — %s'):format(k, #keys(v.mods), table.concat(keys(v.cond), '; '), v.reason))
end
if want_rows and #rows_out > 0 then
    print('\n  UNRESOLVED ROWS')
    for _, r in ipairs(rows_out) do print(r) end
end

-- ── dependency-root counters (known-nonzero: xmpp_codec.hrl must read 278) ──
print('\n  DEPENDENCY DECLARATIONS READ (files reached through the include graph, outside the tree)')
local depfiles = {}
for _, f in ipairs(files) do
    for _, p in ipairs(E:scope(f).files) do
        if p:sub(1, #root + 1) ~= root .. '/' then depfiles[p] = true end
    end
end
for _, p in ipairs(keys(depfiles)) do
    local n = #E:facts(p).records
    if n > 0 then print(('    %4d  %s'):format(n, p)) end
end

-- ── ★★★ THE SAME-NAME MEASUREMENT: why a global table is wrong ──
-- (a) declarations: every -record site the scopes reach, grouped by name
local decls = {} -- name -> { [file:line] = decl }
for _, f in ipairs(files) do
    local sc = E:scope(f)
    for _, p in ipairs(sc.files) do
        for _, d in ipairs(E:facts(p).records) do
            decls[d.name] = decls[d.name] or {}
            decls[d.name][d.file .. ':' .. d.line] = d
        end
    end
end
local function distinct(t, fn)
    local s, n = {}, 0
    for _, d in pairs(t) do local k = fn(d) if not s[k] then s[k] = true; n = n + 1 end end
    return n
end
local ndecl_names, multi_site, multi_sig, same_sig_diff_detail = 0, 0, {}, 0
for name, sites in pairs(decls) do
    ndecl_names = ndecl_names + 1
    local nsite = 0
    for _ in pairs(sites) do nsite = nsite + 1 end
    if nsite > 1 then multi_site = multi_site + 1 end
    local nsig = distinct(sites, ER.signature)
    if nsig > 1 then multi_sig[#multi_sig + 1] = { name = name, sigs = nsig, sites = nsite } end
    if nsig == 1 and distinct(sites, ER.detail) > 1 then same_sig_diff_detail = same_sig_diff_detail + 1 end
end
table.sort(multi_sig, function (a, b) return a.sites > b.sites or (a.sites == b.sites and a.name < b.name) end)
-- (b) module scopes: the record each MODULE sees under a name
local seen_by = {} -- name -> sig -> nmodules
for _, f in ipairs(files) do
    for name, d in pairs(E:scope(f).records) do
        seen_by[name] = seen_by[name] or {}
        local sg = ER.signature(d)
        seen_by[name][sg] = (seen_by[name][sg] or 0) + 1
    end
end
local scope_multi = 0
for _, sigs in pairs(seen_by) do
    local n = 0
    for _ in pairs(sigs) do n = n + 1 end
    if n > 1 then scope_multi = scope_multi + 1 end
end
local nvariants = 0
for _, f in ipairs(files) do for _ in pairs(E:scope(f).variants) do nvariants = nvariants + 1 end end
print('\n  SAME-NAME RECORDS')
print(('    distinct record names reached              %d'):format(ndecl_names))
print(('    names declared at >1 site                  %d'):format(multi_site))
print(('    names whose FIELD LISTS differ across sites %d'):format(#multi_sig))
print(('    names seen with >1 field list across MODULE SCOPES %d'):format(scope_multi))
print(('    names with equal field lists but differing defaults/types %d'):format(same_sig_diff_detail))
print(('    in-module variants (>1 visible decl of a name, ifdef branches) %d'):format(nvariants))
for i = 1, math.min(8, #multi_sig) do
    local m = multi_sig[i]
    print(('      %-24s %3d sites, %3d distinct field lists'):format(m.name, m.sites, m.sigs))
end

-- ── the control: what a GLOBAL name -> union-of-fields table would accept that scoping rejects ──
local union = {}
for name, sites in pairs(decls) do
    union[name] = {}
    for _, d in pairs(sites) do for fname in pairs(d.by) do union[name][fname] = true end end
end
local global_accepts_scoped_rejects, global_rejects = 0, 0
for _, f in ipairs(files) do
    for _, u in ipairs(E:facts(f).uses) do
        if u.name then
            local g = union[u.name] ~= nil
            for _, fl in ipairs(u.fields) do if g and not union[u.name][fl.name] then g = false end end
            if g and not use_status[u] then global_accepts_scoped_rejects = global_accepts_scoped_rejects + 1 end
            if not g then global_rejects = global_rejects + 1 end
        end
    end
end
print(('    CONTROL: a global union table accepts %d use(s) that per-module scoping rejects (and rejects %d)')
    :format(global_accepts_scoped_rejects, global_rejects))
-- ★ the failure a global table actually produces is not acceptance but the WRONG FIELD LIST: count the uses whose
-- record name has >1 field list, and what a single last-declaration-wins table (the "whichever file you checked
-- last" table) would reject among the uses scoping resolves
local last = {}
for name, sites in pairs(decls) do
    local ks = keys(sites)
    last[name] = sites[ks[#ks]]
end
local ambiguous_uses, lastwins_rejects = 0, 0
local ambig_name = {}
for _, m in ipairs(multi_sig) do ambig_name[m.name] = true end
for _, f in ipairs(files) do
    for _, u in ipairs(E:facts(f).uses) do
        if u.name and ambig_name[u.name] then
            ambiguous_uses = ambiguous_uses + 1
            if use_status[u] then
                local d = last[u.name]
                for _, fl in ipairs(u.fields) do
                    if not d.by[fl.name] then lastwins_rejects = lastwins_rejects + 1; break end
                end
            end
        end
    end
end
print(('    uses of a name with >1 field list %d · of the resolved ones, a last-declaration-wins global table rejects %d')
    :format(ambiguous_uses, lastwins_rejects))
print('      (rule: "last" = the greatest `path:line` string among a name\'s declaration sites; any single choice is')
print('       one module\'s view, and this number moves with the choice)')

if want_unused then
    local U = ER.usage(E, files, root)
    local type_only, positional = 0, 0
    for _, r in ipairs(U.records) do if r.type_only then type_only = type_only + 1 end end
    for _, f in ipairs(U.fields) do if f.positional then positional = positional + 1 end end
    local rel = function (p) return (p:gsub('^' .. vim.pesc(root) .. '/', '')) end
    io.write(('\nREVERSE (declaration -> uses), a work list: %d record(s) declared under the root; %d never used by any module, '
        .. '%d used only in type specs; %d field(s) of used records never named by a use (%d in modules that also call '
        .. 'element/setelement, so possibly read by position)\n'):format(U.declared, #U.unused, type_only, #U.fields, positional))
    for _, d in ipairs(U.unused) do io.write(('  unused record  #%s  %s:%d\n'):format(d.name, rel(d.file), d.line)) end
    for _, r in ipairs(U.records) do
        if r.type_only then io.write(('  types only     #%s  %s:%d\n'):format(r.decl.name, rel(r.decl.file), r.decl.line)) end
    end
    for _, f in ipairs(U.fields) do
        io.write(('  unnamed field  #%s.%s  %s:%d%s\n'):format(f.decl.name, f.field, rel(f.decl.file), f.decl.line,
            f.positional and '  (module uses element/setelement)' or ''))
    end
end

if not want_erl then return end

-- ── --erl: the REAL preprocessor, joined row by row ─────────────────────────────────────────────────────────────
-- epp resolves -include_lib through the include path first, so each --app is presented as a symlink NAMED AFTER
-- THE APPLICATION in a private temp dir (never inside either tree). The OTP_BELOW_* macros are what ejabberd's
-- rebar.config defines on the installed OTP's release.
print('\n  --erl ORACLE (epp:parse_file per module; erl_lint undefined_record / undefined_field)')
if vim.fn.executable('erl') ~= 1 then print('    erl not on PATH: skipped'); return end
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. '/apps', 'p')
for n, d in pairs(E.apps) do vim.uv.fs_symlink(d, tmp .. '/apps/' .. n) end
local listf = tmp .. '/files.txt'
do
    local fd = assert(io.open(listf, 'w'))
    for _, f in ipairs(files) do fd:write(f, '\n') end
    fd:close()
end
local incs = { root .. '/include', tmp .. '/apps' }
local eincs = {}
for _, d in ipairs(incs) do eincs[#eincs + 1] = '"' .. d .. '"' end
local rel = vim.trim(vim.fn.system({ 'erl', '-noshell', '-eval',
    'io:format("~s", [erlang:system_info(otp_release)]), halt().' }))
local relnum = tonumber(rel) or 0
local macros = {}
for _, v in ipairs({ 26, 27, 28 }) do
    if relnum < v then macros[#macros + 1] = ("{'OTP_BELOW_%d', true}"):format(v) end
end
local escript = ([[
Files = [L || L <- string:split(binary_to_list(element(2, file:read_file("%s"))), "\n", all), L =/= ""],
Incs = [%s],
Macros = [%s],
FS = fun(F) -> lists:flatten(io_lib:format("~0p", [F])) end,
lists:foreach(fun(File) ->
    case epp:parse_file(File, [{includes, Incs}, {macros, Macros}]) of
      {ok, Forms} ->
        io:format("M\t~s~n", [File]),
        lists:foreach(fun
            ({attribute, _, record, {Name, Fields}}) ->
                Names = [case Fd of
                            {typed_record_field, {record_field, _, {atom, _, N}}, _} -> N;
                            {typed_record_field, {record_field, _, {atom, _, N}, _}, _} -> N;
                            {record_field, _, {atom, _, N}} -> N;
                            {record_field, _, {atom, _, N}, _} -> N;
                            _ -> '?'
                         end || Fd <- Fields],
                io:format("R\t~s\t~s\t~s~n", [File, atom_to_list(Name), string:join([atom_to_list(N) || N <- Names], ",")]);
            ({error, {Loc, epp, What}}) ->
                io:format("P\t~s\t~s\t~s~n", [File, FS(Loc), FS(What)]);
            (_) -> ok
          end, Forms),
        case erl_lint:module(Forms, File, []) of
          {ok, _} -> ok;
          {error, Errs, _} ->
            lists:foreach(fun({EF, Es}) ->
                lists:foreach(fun
                    ({Loc, erl_lint, {undefined_record, R}}) ->
                        io:format("E\t~s\t~s\tundefined_record\t~s\t~s~n", [File, FS(Loc), FS(R), EF]);
                    ({Loc, erl_lint, {undefined_field, R, Fd}}) ->
                        io:format("E\t~s\t~s\tundefined_field\t~s.~s\t~s~n", [File, FS(Loc), FS(R), FS(Fd), EF]);
                    (_) -> ok
                  end, Es)
              end, Errs)
        end;
      {error, Why} -> io:format("X\t~s\t~s~n", [File, FS(Why)])
    end
  end, Files),
halt().
]]):format(listf, table.concat(eincs, ','), table.concat(macros, ','))
local out = vim.fn.system({ 'erl', '-noshell', '-eval', escript })
local erl_recs, perr, lint, fail = {}, {}, {}, 0
local macro_rejected
for line in out:gmatch('[^\n]+') do
    local tag, a, b, c, d, e = line:match('^(%u)\t([^\t]*)\t?([^\t]*)\t?([^\t]*)\t?([^\t]*)\t?(.*)$')
    if tag == 'M' then erl_recs[a] = erl_recs[a] or {}
    elseif tag == 'R' then
        erl_recs[a] = erl_recs[a] or {}
        erl_recs[a][b] = c
    elseif tag == 'P' then
        perr[#perr + 1] = ('%s %s %s'):format(vim.fn.fnamemodify(a, ':t'), b, c)
        -- an undefined macro makes epp REPLACE the whole form with an error: erl_lint never sees its records
        if c:find('^{undefined,') then macro_rejected = macro_rejected or {}; macro_rejected[a] = true end
    elseif tag == 'E' then
        -- erl_lint groups errors by the file they are IN: an error inside an included header is not at that line
        -- of the module
        lint[#lint + 1] = { file = a, line = tonumber(b:match('%d+')), what = c, arg = d,
            in_header = (e ~= '' and e ~= a) and e or nil }
    elseif tag == 'X' then fail = fail + 1 end
end
local nmods, agree, only_erl, only_us, differ = 0, 0, 0, 0, {}
local only_us_rows
for _, f in ipairs(files) do
    local er = erl_recs[f]
    if er then
        nmods = nmods + 1
        local sc = E:scope(f)
        for name, sig in pairs(er) do
            local d = sc.records[name]
            if not d then only_erl = only_erl + 1
            elseif ER.signature(d) == sig then agree = agree + 1
            else differ[#differ + 1] = ('%s %s'):format(vim.fn.fnamemodify(f, ':t'), name) end
        end
        for name in pairs(sc.records) do
            if not er[name] then
                only_us = only_us + 1
                only_us_rows = only_us_rows or {}
                only_us_rows[#only_us_rows + 1] = ('%s %s [%s] %s:%d'):format(vim.fn.fnamemodify(f, ':t'), name,
                    tostring(sc.records[name].cond), vim.fn.fnamemodify(sc.records[name].file, ':t'),
                    sc.records[name].line)
            end
        end
    end
end
print(('    OTP release %s · macros {%s} · modules epp parsed %d of %d (epp failures %d)')
    :format(rel, table.concat(macros, ','), nmods, #files, fail))
print(('    per-module visible records: agree %d · field list differs %d · only epp %d · only erlrecords %d')
    :format(agree, #differ, only_erl, only_us))
for i = 1, math.min(10, #differ) do print('      differs: ' .. differ[i]) end
for _, r in ipairs(only_us_rows or {}) do print('      only erlrecords: ' .. r) end
print(('    epp include errors %d'):format(#perr))
local pk = {}
for _, p in ipairs(perr) do local w = p:match('%S+ %S+ (.*)') or p pk[w] = (pk[w] or 0) + 1 end
for _, k in ipairs(keys(pk)) do print(('      %4d  %s'):format(pk[k], k)) end
-- ★ THE ROW JOIN: an unresolved use of ours is (file, line, record); erl_lint's error is the same triple. A lint
-- row with no use of ours on that line is a MACRO EXPANSION site (the reference is in a -define body elsewhere);
-- a row of ours with no lint row would be a false alarm of erlrecords, which is the number that must be 0.
local function unq(x) return (x or ''):gsub("^'(.*)'$", '%1') end
local lkeys, lk_n = {}, 0
for _, l in ipairs(lint) do
    local rec = l.what == 'undefined_record' and unq(l.arg) or unq(l.arg:match('^(.-)%.'))
    local k = l.file .. ':' .. tostring(l.line) .. ':' .. rec
    if not lkeys[k] then lkeys[k] = l; lk_n = lk_n + 1 end
end
local okeys, ok_n = {}, 0
for _, f in ipairs(files) do
    if erl_recs[f] then
        for _, r in ipairs(E:check(f)) do
            if r.status == 'unknown_record' or r.status == 'unknown_field' then
                local k = f .. ':' .. r.use.line .. ':' .. r.use.name
                if not okeys[k] then okeys[k] = r; ok_n = ok_n + 1 end
            end
        end
    end
end
-- ⚠ erl_lint does NOT descend into an expression it has already rejected: `#xmlel{children = [#xmlel{…}]}` with
-- xmlel undefined reports the OUTER line only. So a row of ours nested inside another unresolved use of ours that
-- erl_lint DID report is the compiler's silence, not an erlrecords false alarm; it is counted apart.
local both, only_lint, only_ours, only_lint_macro, nested, in_def, condl, epp_rej = 0, 0, {}, 0, 0, 0, 0, 0
local function enclosed(r, f)
    for k2, r2 in pairs(okeys) do
        if r2 ~= r and lkeys[k2] and k2:sub(1, #f + 1) == f .. ':' and r2.use.line <= r.use.line
            and r2.use.last >= r.use.last and not (r2.use.line == r.use.line and r2.use.last == r.use.last) then
            return true
        end
    end
end
local ofile = {}
for k, r in pairs(okeys) do ofile[k] = k:match('^(.*):%d+:[^:]*$') end
for k, r in pairs(okeys) do
    if lkeys[k] then both = both + 1
    elseif r.use.in_define then in_def = in_def + 1       -- erl_lint reports it at the EXPANSION site
    elseif r.use.cond then condl = condl + 1              -- under -ifdef: epp may have dropped the branch
    elseif enclosed(r, ofile[k]) then nested = nested + 1
    elseif macro_rejected and macro_rejected[ofile[k]] then epp_rej = epp_rej + 1
    else only_ours[#only_ours + 1] = k end
end
local uses_at = {}
for _, f in ipairs(files) do
    for _, u in ipairs(E:facts(f).uses) do uses_at[f .. ':' .. u.line] = true end
end
-- ⚠ "no use of ours on that line" is an INFERENCE that the reference came from a macro; a use the walker MISSED
-- lands in the same bucket. So each such line is READ and must contain a `?` (a macro call) to be credited.
local srclines = {}
local function line_of(file, n)
    if not srclines[file] then
        srclines[file] = {}
        local fd = io.open(file, 'r')
        if fd then for ln in fd:lines() do srclines[file][#srclines[file] + 1] = ln end fd:close() end
    end
    return srclines[file][n] or ''
end
local lint_nomacro, lint_header, lint_multiline = {}, 0, 0
for k, l in pairs(lkeys) do
    if not okeys[k] then
        only_lint = only_lint + 1
        if l.in_header then lint_header = lint_header + 1
        elseif not uses_at[l.file .. ':' .. tostring(l.line)] then
            if line_of(l.file, l.line):find('?', 1, true) then only_lint_macro = only_lint_macro + 1
            -- a MULTI-LINE macro call (`?H1GL(A,\n B,\n C)`): epp stamps the expansion on a later line of it
            elseif (line_of(l.file, l.line - 1) .. line_of(l.file, l.line - 2)):find('?', 1, true) then
                lint_multiline = lint_multiline + 1
            else lint_nomacro[#lint_nomacro + 1] = k:sub(#root + 2) end
        end
    end
end
table.sort(only_ours)
print(('    erl_lint undefined_record/undefined_field errors %d (%d distinct file:line:record)'):format(#lint, lk_n))
print(('    ROW JOIN vs erlrecords unresolved (%d distinct, epp-parsed modules only):'):format(ok_n))
print(('      both %d · only erl_lint %d: located in an INCLUDED HEADER %d · on a module line with no use of ours AND a `?` %d')
    :format(both, only_lint, lint_header, only_lint_macro))
print(('                       `?` within the 2 lines above (a multi-line macro call) %d · NO macro in sight (a use erlrecords MISSED) %d')
    :format(lint_multiline, #lint_nomacro))
table.sort(lint_nomacro)
for i = 1, math.min(10, #lint_nomacro) do print('      missed: ' .. lint_nomacro[i]) end
print(('      only erlrecords: inside a -define body %d · under a condition %d · nested inside an erl_lint-reported outer use %d')
    :format(in_def, condl, nested))
print(('                       in a file where epp rejected a form for an undefined macro %d · OTHERWISE %d (erlrecords false alarms)')
    :format(epp_rej, #only_ours))
for i = 1, math.min(10, #only_ours) do print('      only erlrecords: ' .. only_ours[i]:sub(#root + 2)) end
vim.fn.delete(tmp, 'rf')

