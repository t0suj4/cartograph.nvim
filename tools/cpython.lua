-- cpython — ARGUMENT TYPES BY PATH over CPython's builtins (cartograph.cpython, CART-1258): every fact derived from the
-- tree, each position's reading by type, JOINED with the arity the runtime's own signatures state, WITNESSED by the
-- tree's own python.
--
--   nvim --headless -u NONE -l tools/cpython.lua <configured + built CPython src dir> [name … | --all] [--scope glob,glob]
--
-- (default: the pilot — len, abs, callable, chr, ord, hash, repr, ascii, bin, getattr, hasattr, isinstance, issubclass,
-- divmod, delattr, format; --all: every METH_O / METH_FASTCALL builtin). The realm and the signatures are the running
-- `<src>/python -I`'s (inspect.signature over __text_signature__): a FASTCALL builtin is read at each positional
-- parameter its signature names (3 when it has none); the JOIN is the ABSENCE — a required parameter's absent argument
-- must read never, an optional one's must not. The witness calls each claim (always / never, and the absence) on the
-- same zero-argument samples the probe made (int() 0, str() '', None …), the other positions given a value their own
-- reading accepts. The tree is read whole (~100 s, 3.5 GB) unless --scope narrows it.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local P = require 'cartograph.cpython'

local src = arg[1]
if not src then io.stderr:write('usage: cpython.lua <CPython src dir> [name … | --all] [--scope glob,glob]\n'); os.exit(2) end
src = vim.fn.fnamemodify(src, ':p'):gsub('/$', '')
local names, all, scope = {}, false, nil
local i = 2
while i <= #arg do
    if arg[i] == '--all' then all = true
    elseif arg[i] == '--scope' then scope = vim.split(arg[i + 1] or '', ',', { trimempty = true }); i = i + 1
    else names[#names + 1] = arg[i] end
    i = i + 1
end
if #names == 0 and not all then
    names = { 'len', 'abs', 'callable', 'chr', 'ord', 'hash', 'repr', 'ascii', 'bin', 'getattr', 'hasattr', 'isinstance', 'issubclass', 'divmod', 'delattr', 'format' }
end
local py = src .. '/python'
local function runpy(code, timeout)
    local f = vim.fn.tempname() .. '.py'
    local fd = assert(io.open(f, 'w')); fd:write(code); fd:close()
    local r = vim.system({ py, '-I', f }, { text = true, timeout = timeout or 60000 }):wait()
    os.remove(f)
    return r.code == 0 and r.stdout or nil, r
end
local hdr = (function () local fd = io.open(src .. '/Include/patchlevel.h'); if not fd then return '' end local s = fd:read('a'); fd:close(); return s end)()
local treev = hdr:match('#define%s+PY_VERSION%s+"([^"]+)"') or '?'
local runv = vim.trim((runpy('import sys; print(sys.version.split()[0])') or '?'))
local witness_ok = runv == treev

-- THE REALM: every builtin function, its positional parameters (required or not) — '-' when it has no signature
local REALM = [==[
import builtins, inspect
for k, v in sorted(vars(builtins).items()):
    if type(v).__name__ != 'builtin_function_or_method':
        continue
    try:
        ps = [p for p in inspect.signature(v).parameters.values() if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)]
        print(k, ','.join(('?' if p.default is not p.empty else '!') + p.name for p in ps) or '.')
    except (ValueError, TypeError):
        print(k, '-')
]==]

local t0 = vim.uv.hrtime()
local ctx = P.context(src, scope)
local T = ctx.facts
local sig, realm = {}, {}
for line in (runpy(REALM) or ''):gmatch('[^\n]+') do
    local k, ps = line:match('^(%S+) (%S+)$')
    if k then
        realm[#realm + 1] = k
        if ps == '-' then sig[k] = false
        else
            local l = {}
            if ps ~= '.' then for p in ps:gmatch('[^,]+') do l[#l + 1] = { name = p:sub(2), required = p:sub(1, 1) == '!' } end end
            sig[k] = l
        end
    end
end
local reg = {}
for _, e in ipairs(ctx.registrations.funcs) do if e.owner == 'builtins' then reg[e.name] = reg[e.name] or e end end
if all then names = {}; for _, k in ipairs(realm) do local e = reg[k]; if e and (e.meth.O or (e.meth.FASTCALL)) then names[#names + 1] = k end end end
local keys, npos = {}, {}
for _, k in ipairs(names) do
    keys[#keys + 1] = 'builtins.' .. k
    if sig[k] then npos['builtins.' .. k] = math.max(#sig[k], 1) end
end
local t1 = vim.uv.hrtime()
local rows = P.measure({ ctx = ctx, keys = keys, npos = npos })
io.write(('CPYTHON %s — %d of %d facts derived (%d units%s); frame %s at %d / count at %d, slot %s, sentinel NULL (%d throwers); %d representatives (%d memory words, %d global addresses); realm %d builtins (python %s); facts %.1f s, readings %.1f s\n'):format(
    src, T.derived, T.total, #T.got.compdb.units, scope and (', scope ' .. table.concat(scope, ',')) or '', T.got.slot.type, ctx.frame.arrayat, ctx.frame.countat, T.got.slot.type,
    vim.tbl_count(ctx.throwers), #ctx.reps.order, vim.tbl_count(ctx.reps.memory), vim.tbl_count(ctx.reps.symaddr), #realm, runv, (t1 - t0) / 1e9, (vim.uv.hrtime() - t1) / 1e9))

local WIT = [==[
import builtins, sys
S = {}
for k, v in vars(builtins).items():
    if isinstance(v, type):
        if issubclass(v, BaseException) and v is not BaseException:
            continue
        try:
            o = v()
        except Exception:
            continue
        S.setdefault(type(o).__name__, o)
    elif not callable(v):
        S.setdefault(type(v).__name__, v)
S.setdefault(type(len).__name__, len); S.setdefault('type', int); S.setdefault('module', builtins)
def W(r):
    sys.__stdout__.write('\x01W ' + r + '\n'); sys.__stdout__.flush()
def t(f, args):
    try:
        f(*[S[a] for a in args]); return 'ok'
    except BaseException as e:
        return type(e).__name__
]==]
local tally = { agree = 0, differ = 0, nosig = 0, confirmed = 0, contradicted = 0, lost = 0, positions = 0, never_typed = 0, over = 0 }
for _, k in ipairs(names) do
    local key = 'builtins.' .. k
    local row = rows[key]
    local s = sig[k]
    local stext = s == false and 'no signature' or (s and ('(' .. table.concat(vim.tbl_map(function (p) return p.name .. (p.required and '' or '=?') end, s), ', ') .. ')') or 'not in the realm')
    if not row then io.write(key, ': not registered\n')
    elseif row.missing then io.write(key, ': ', row.missing, '\n')
    else
        io.write(('%s  (%s, %s)  signature %s\n'):format(key, row.cfn, table.concat(vim.fn.sort(vim.tbl_keys(row.meth)), '|'), stext))
        local calls, labels = {}, {}
        local function fill(kk, upto)
            local argv = {}
            for j = 1, upto do
                if j ~= kk then
                    local pj = row.pos[j]
                    local pick
                    if pj then for _, t in ipairs(ctx.reps.order) do if pj.by[t] == 'always' then pick = t; break end end end
                    if pj and not pick then for _, t in ipairs(ctx.reps.order) do if pj.by[t] == 'content' then pick = t; break end end end
                    argv[j] = pick or 'NoneType'
                end
            end
            return argv
        end
        -- (the arguments a call needs: through the last position whose absence is never)
        local need = 0
        for j, pj in ipairs(row.pos) do if pj.absent == 'never' then need = j end end
        for kk, p in ipairs(row.pos) do
            tally.positions = tally.positions + 1
            if p.over then tally.over = tally.over + 1 end
            local nn = 0
            for _, st in pairs(p.by) do if st == 'never' then nn = nn + 1 end end
            if nn > 0 then tally.never_typed = tally.never_typed + 1 end
            if witness_ok then
                for t, st in pairs(p.by) do
                    if st == 'always' or st == 'never' then
                        local argv = fill(kk, math.max(kk, need))
                        argv[kk] = t
                        calls[#calls + 1] = ('W(t(builtins.%s, %s))'):format(k, vim.json.encode(argv))
                        labels[#labels + 1] = { k = kk, t = t, st = st }
                    end
                end
                if p.absent == 'always' or p.absent == 'never' then
                    calls[#calls + 1] = ('W(t(builtins.%s, %s))'):format(k, vim.json.encode(fill(kk, kk - 1)))
                    labels[#labels + 1] = { k = kk, t = 'ABSENT', st = p.absent }
                end
            end
        end
        local res = {}
        -- (a result line is MARKED: a builtin under test may print itself — print, help)
        if #calls > 0 then
            local out = runpy(WIT .. table.concat(calls, '\n') .. '\n', 30000)
            for l in (out or ''):gmatch('[^\n]+') do local x = l:match('^\1W (.*)$'); if x then res[#res + 1] = x end end
        end
        local wit = {}
        for ix, lb in ipairs(labels) do
            local o = res[ix]
            wit[lb.k] = wit[lb.k] or {}
            local good = o and ((lb.st == 'always') == (o == 'ok'))
            if not o then tally.lost = tally.lost + 1 elseif good then tally.confirmed = tally.confirmed + 1 else tally.contradicted = tally.contradicted + 1 end
            table.insert(wit[lb.k], ('%s=%s%s'):format(lb.t, o or 'lost', (o and not good) and ' ✗' or ''))
        end
        for kk, p in ipairs(row.pos) do
            local acc, nev = {}, {}
            for _, t in ipairs(ctx.reps.order) do if p.by[t] == 'never' then nev[#nev + 1] = t else acc[#acc + 1] = t .. (p.by[t] == 'content' and '?' or '') end end
            local verdict = ''
            local sp = s and s[kk]
            if s == false then tally.nosig = tally.nosig + 1
            elseif sp ~= nil or s then
                local required = sp and sp.required
                local agree = (required and p.absent == 'never') or (not required and p.absent ~= 'never')
                if agree then tally.agree = tally.agree + 1; verdict = 'AGREE' else tally.differ = tally.differ + 1; verdict = 'DIFFER' end
                verdict = verdict .. (' (%s, absent %s)'):format(sp and (sp.name .. (sp.required and ' required' or ' optional')) or 'no such parameter', tostring(p.absent))
            end
            table.sort(wit[kk] or {})
            io.write(('  #%d %d never / %d accepted%s  absent=%s  %s\n      never: %s\n      accepts: %s%s\n'):format(kk, #nev, #acc, p.over and ' (over budget)' or '', tostring(p.absent), verdict,
                table.concat(nev, ' '), table.concat(acc, ' '), wit[kk] and ('\n      witness ' .. table.concat(wit[kk], ' ')) or ''))
        end
    end
end
io.write(('READINGS: %d builtins, %d positions (%d with a never type, %d over budget) · JOIN vs signature: %d agree, %d differ, %d without a signature · WITNESS (python %s%s): %d confirmed, %d contradicted, %d lost\n'):format(
    #names, tally.positions, tally.never_typed, tally.over, tally.agree, tally.differ, tally.nosig, runv, witness_ok and '' or (' ≠ tree ' .. treev .. ': skipped'), tally.confirmed, tally.contradicted, tally.lost))
