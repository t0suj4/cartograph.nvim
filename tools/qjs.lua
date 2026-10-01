-- qjs — ARGUMENT TYPES BY PATH over QuickJS' built-in functions (cartograph.qjs, CART-1258): every fact derived from
-- the tree, each position's reading by type, JOINED with the TypeScript declarations of the same functions and
-- WITNESSED by the tree's own qjs.
--
--   nvim --headless -u NONE -l tools/qjs.lua <quickjs-ng src dir> [Owner.name … | --all]
--
-- (default: the pilot — Symbol.keyFor, Reflect.ownKeys, Object.create, Object.getPrototypeOf, Reflect.getPrototypeOf,
-- Array.isArray, Object.keys; --all: every STATIC function the realm holds). A JS path is the RUNNING realm's: qjs
-- lists every function of every global and its prototype with its name and length, and each is matched to the
-- registration row of that name and length whose table names its owner (js_object_funcs: Object). The TypeScript side
-- is typescript's lib.es5.d.ts + lib.es20*.d.ts (TS_LIB, else found under ~/projects); the witness is <src>/build/qjs,
-- which must be the tree's version.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local Q = require 'cartograph.qjs'

local src = arg[1]
if not src then io.stderr:write('usage: qjs.lua <quickjs-ng src dir> [Owner.name … | --all]\n'); os.exit(2) end
src = vim.fn.fnamemodify(src, ':p'):gsub('/$', '')
local paths, all = {}, false
for i = 2, #arg do if arg[i] == '--all' then all = true else paths[#paths + 1] = arg[i] end end
if #paths == 0 and not all then paths = { 'Symbol.keyFor', 'Reflect.ownKeys', 'Object.create', 'Object.getPrototypeOf', 'Reflect.getPrototypeOf', 'Array.isArray', 'Object.keys' } end
local function readfile(p) local fd = p and io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

-- THE WITNESS BINARY and its version against the tree's
local qjs = vim.fn.executable(src .. '/build/qjs') == 1 and (src .. '/build/qjs') or vim.fn.exepath('qjs')
local hdr = readfile(src .. '/quickjs.h') or ''
local treev = ('%s.%s.%s'):format(hdr:match('QJS_VERSION_MAJOR%s+(%d+)') or '?', hdr:match('QJS_VERSION_MINOR%s+(%d+)') or '?', hdr:match('QJS_VERSION_PATCH%s+(%d+)') or '?')
local qv = qjs ~= '' and vim.system({ qjs, '--version' }, { text = true }):wait() or { code = 1 }
local runv = vim.trim(qv.stdout or ''):match('(%d+%.%d+%.%d+)') or '?'
local witness_ok = qv.code == 0 and runv == treev
local function runjs(js, timeout)
    local f = vim.fn.tempname() .. '.js'
    local fd = assert(io.open(f, 'w')); fd:write(js); fd:close()
    local r = vim.system({ qjs, f }, { text = true, timeout = timeout or 20000 }):wait()
    os.remove(f)
    return r.code == 0 and r.stdout or nil, r
end

-- THE REALM: every function of every global and of its prototype -> path, name, length
local REALM = [==[
const out = [];
for (const g of Object.getOwnPropertyNames(globalThis)) {
  const d = Object.getOwnPropertyDescriptor(globalThis, g);
  const v = d && d.value;
  if (v === null || (typeof v !== 'object' && typeof v !== 'function')) continue;
  for (const [owner, o] of [[g, v], [g + '.prototype', typeof v === 'function' ? v.prototype : null]]) {
    if (!o || (typeof o !== 'object' && typeof o !== 'function')) continue;
    for (const k of Reflect.ownKeys(o)) {
      const pd = Object.getOwnPropertyDescriptor(o, k);
      if (!pd || typeof pd.value !== 'function' || typeof k === 'symbol') continue;
      out.push([owner, k, pd.value.length].join('\t'));
    }
  }
}
console.log(out.join('\n'));
]==]

local t0 = vim.uv.hrtime()
local ctx = Q.context(src)
local T = ctx.facts
local realm = {}
local rout = witness_ok and runjs(REALM) or nil
for line in (rout or ''):gmatch('[^\n]+') do
    local owner, name, len = line:match('^([^\t]+)\t([^\t]+)\t(%d+)$')
    if owner then realm[#realm + 1] = { owner = owner, name = name, length = tonumber(len), path = owner .. '.' .. name } end
end
-- (a path's registration row: same name and length, the table naming its owner — `proto` in it iff a prototype's)
local function squash(s) return (s:lower():gsub('[^%l%d]', '')) end
local function row_of(r)
    local best, nbest, score = nil, 0, -1
    local own = squash(r.owner:gsub('%.prototype$', ''))
    local isproto = r.owner:find('%.prototype$') ~= nil
    for _, e in ipairs(ctx.registrations.funcs) do
        if e.name == r.name and e.length == r.length then
            local tb = squash(e.table)
            local s = (tb:find(own, 1, true) and 2 or 0) + (((tb:find('proto', 1, true) ~= nil) == isproto) and 1 or 0)
            if s > score then best, nbest, score = e, 1, s elseif s == score then nbest = nbest + 1 end
        end
    end
    if best and score >= 2 and nbest == 1 then return best end
    return nil, best and (nbest > 1 and 'ambiguous' or 'no table names its owner') or 'no row of that name and length'
end
local want = {}
for _, p in ipairs(paths) do want[p] = true end
local sel, unmatched = {}, {}
for _, r in ipairs(realm) do
    if want[r.path] or (all and not r.owner:find('%.prototype$')) then
        local e, why = row_of(r)
        if e then r.e = e; sel[#sel + 1] = r else unmatched[#unmatched + 1] = r.path .. ' (' .. why .. ')' end
    end
end
local keys = {}
for _, r in ipairs(sel) do keys[#keys + 1] = r.e.table .. ':' .. r.e.name end
local rows = Q.measure({ ctx = ctx, keys = keys })
local values = require('cartograph.cinterp.adapter').values(ctx)
io.write(('QJS %s — %d of %d facts derived; frame %s/%s (pad %s), slot %s, sentinel %s by %s (%d throwers); %d value representatives; realm %d functions (qjs %s); %d selected, %d unmatched; %.1f s\n'):format(
    src, T.derived, T.total, ctx.frame.count, ctx.frame.array, tostring(ctx.padrep), T.got.slot.type, require('cartograph.cinterp').key_of(ctx.sentinel),
    ctx.result.fn, vim.tbl_count(ctx.throwers), #values, #realm, runv, #sel, #unmatched, (vim.uv.hrtime() - t0) / 1e9))
if #unmatched > 0 then io.write('  unmatched: ', table.concat(unmatched, ', '), '\n') end

-- THE TYPESCRIPT SIDE: `declare var X: XConstructor` and `interface XConstructor { name(params): ret; … }` — a var's
-- interface is the owner X, an interface some var's `prototype:` names is X.prototype
local tslib = os.getenv('TS_LIB') or vim.fn.glob('~/projects/**/node_modules/typescript/lib', false, true)[1]
local texts = {}
for _, f in ipairs(tslib and vim.fn.glob(tslib .. '/lib.es{5,20[0-9][0-9]*}.d.ts', false, true) or {}) do
    if not f:find('full', 1, true) then texts[#texts + 1] = (readfile(f) or ''):gsub('/%*.-%*/', ''):gsub('//[^\n]*', '') end
end
local function split(s, sep)
    local parts, depth, cur = {}, 0, {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == '=' and s:sub(i + 1, i + 1) == '>' then cur[#cur + 1] = '=>'; i = i + 2
        else
            if c == '(' or c == '[' or c == '{' or c == '<' then depth = depth + 1 elseif c == ')' or c == ']' or c == '}' or c == '>' then depth = depth - 1 end
            if c == sep and depth == 0 then parts[#parts + 1] = vim.trim(table.concat(cur)); cur = {} else cur[#cur + 1] = c end
            i = i + 1
        end
    end
    local last = vim.trim(table.concat(cur))
    if last ~= '' then parts[#parts + 1] = last end
    return parts
end
local owner_of, members = {}, {}
for _, t in ipairs(texts) do
    for var, iface in t:gmatch('declare%s+var%s+([%w_]+)%s*:%s*([%w_]+)%s*;') do owner_of[iface] = var end
end
for _, t in ipairs(texts) do
    for iface, body in t:gmatch('interface%s+([%w_]+)%s*[^{]-(%b{})') do
        local p = body:match('prototype%s*:%s*([%w_]+)')
        if p and owner_of[iface] then owner_of[p] = owner_of[p] or (owner_of[iface] .. '.prototype') end
        members[iface] = members[iface] or {}
        table.insert(members[iface], body:sub(2, -2))
    end
    -- (a NAMESPACE: `declare namespace Reflect { function name(params): ret; … }`)
    for ns, body in t:gmatch('declare%s+namespace%s+([%w_]+)%s*(%b{})') do
        owner_of['ns:' .. ns] = ns
        members['ns:' .. ns] = members['ns:' .. ns] or {}
        table.insert(members['ns:' .. ns], (body:sub(2, -2):gsub('%f[%w_]function%s+', '')))
    end
end
local ALL = { 'bigint', 'bool', 'null', 'number', 'object', 'string', 'symbol', 'undefined' }
local function words(ty, tparams, set)
    for _, alt in ipairs(split(ty, '|')) do
        alt = vim.trim(alt)
        while alt:match('^%b()$') do alt = vim.trim(alt:sub(2, -2)) end
        local base = alt:match('^([%w_]+)')
        if alt == 'any' or alt == 'unknown' then set.any = true
        elseif tparams[alt] ~= nil then if tparams[alt] then words(tparams[alt], {}, set) else set.any = true end
        elseif alt == '{}' then for _, x in ipairs(ALL) do if x ~= 'null' and x ~= 'undefined' then set[x] = true end end
        elseif alt == 'string' or alt:match('^["\'`]') then set.string = true
        elseif alt == 'number' or alt:match('^%-?%d') then set.number = true
        elseif alt == 'boolean' or alt == 'true' or alt == 'false' then set.bool = true
        elseif alt == 'symbol' or alt == 'unique symbol' then set.symbol = true
        elseif alt == 'bigint' then set.bigint = true
        elseif alt == 'null' then set.null = true
        elseif alt == 'undefined' or alt == 'void' then set.undefined = true
        elseif alt == 'PropertyKey' then set.string, set.number, set.symbol = true, true, true
        elseif alt:match('^keyof') or alt:find('extends', 1, true) then set.any = true
        else set.object = true end -- (an interface, an array, a function type, an object literal: an object)
        local _ = base
    end
end
--- the TS types of each position of `owner.name`: { [k] = set, absent = { [k] = true } } | nil, the signatures' text
local function ts_of(owner, name)
    local out, absent, sigs, found = {}, {}, {}, false
    for iface, own in pairs(owner_of) do
        if own == owner then
            for _, body in ipairs(members[iface] or {}) do
                for _, m in ipairs(split(body, ';')) do
                    m = vim.trim(m:gsub('\n', ' '))
                    local mname, rest = m:match('^([%w_$]+)%s*(.*)$')
                    if mname == name and (rest:sub(1, 1) == '(' or rest:sub(1, 1) == '<') then
                        local tparams = {}
                        local gen = rest:match('^(%b<>)')
                        if gen then
                            for _, g in ipairs(split(gen:sub(2, -2), ',')) do
                                local gn, ext = g:match('^([%w_]+)%s*extends%s+(.-)%s*=?[^=]*$')
                                if gn then tparams[gn] = vim.trim((ext:gsub('=.*$', ''))) else tparams[(g:match('^([%w_]+)'))] = false end
                            end
                            rest = vim.trim(rest:sub(#gen + 1))
                        end
                        local plist = rest:match('^(%b())')
                        if plist then
                            found = true
                            sigs[#sigs + 1] = name .. plist
                            local ps = vim.tbl_filter(function (p) return not p:match('^this%s*:') end, split(plist:sub(2, -2), ','))
                            for k = 1, 8 do
                                local p = ps[k]
                                local rest_p = ps[#ps] and ps[#ps]:match('^%.%.%.') and k >= #ps
                                if rest_p then p = ps[#ps] end
                                if not p then absent[k] = true
                                else
                                    out[k] = out[k] or {}
                                    local opt, ty = p:match('^%.?%.?%.?[%w_$]+%s*(%??)%s*:%s*(.+)$')
                                    if rest_p then
                                        absent[k] = true
                                        ty = ty and (ty:match('^(.-)%[%]$') or ty:match('^readonly%s+(.-)%[%]$') or ty:match('^Array<(.*)>$') or 'any')
                                    end
                                    if opt == '?' then absent[k] = true; out[k].undefined = true end
                                    words(ty or 'any', tparams, out[k])
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if not found then return nil end
    out.absent = absent
    return out, table.concat(sigs, ' / ')
end

-- THE WITNESS: one call per type of a CLAIM (always / never) and one with the position ABSENT, the other positions
-- given a value of a type their own position always accepts; a thrown error is a rejection
local SAMPLE = { undefined = 'undefined', null = 'null', bool = 'true', number = '1', string = '"a"', symbol = 'Symbol("s")', bigint = '1n', object = '({})' }
local tally = { agree = 0, stricter = 0, wider = 0, narrower = 0, confirmed = 0, contradicted = 0, positions = 0, typed = 0, over = 0 }
table.sort(sel, function (a, b) return a.path < b.path end)
for _, r in ipairs(sel) do
    local row = rows[r.e.table .. ':' .. r.e.name]
    local ts, sig = ts_of(r.owner, r.name)
    io.write(('%s/%d  (%s%s)  ts %s\n'):format(r.path, r.length, row.cfn, r.e.magic ~= nil and (' magic ' .. tostring(r.e.magic)) or '', sig or 'none found'))
    if row.missing then io.write('  ', row.missing, '\n')
    else
        local calls, labels = {}, {}
        local function fill(k)
            local argv = {}
            for j = 1, #row.pos do
                if j ~= k then
                    local pj = row.pos[j]
                    local pick
                    for _, t in ipairs(ALL) do if pj.by[t] == 'always' then pick = t; break end end
                    if not pick then for _, t in ipairs(ALL) do if pj.by[t] == 'content' then pick = t; break end end end
                    argv[j] = SAMPLE[pick or 'undefined']
                end
            end
            return argv
        end
        for k, p in ipairs(row.pos) do
            tally.positions = tally.positions + 1
            if p.over then tally.over = tally.over + 1 end
            if not p.untyped then tally.typed = tally.typed + 1 end
            if witness_ok then
                for t, st in pairs(p.by) do
                    if (st == 'always' or st == 'never') and SAMPLE[t] then
                        local argv = fill(k)
                        argv[k] = SAMPLE[t]
                        calls[#calls + 1] = ('t(() => %s(%s))'):format(r.path, table.concat(argv, ', '))
                        labels[#labels + 1] = { k = k, t = t, st = st }
                    end
                end
                if p.absent == 'always' or p.absent == 'never' then
                    local argv = fill(k)
                    calls[#calls + 1] = ('t(() => %s(%s))'):format(r.path, table.concat(vim.list_slice(argv, 1, k - 1), ', '))
                    labels[#labels + 1] = { k = k, t = 'ABSENT', st = p.absent }
                end
            end
        end
        local res = {}
        if #calls > 0 then
            local js = 'function t(f) { try { f(); return "ok"; } catch (e) { return (e && e.name) || "throw"; } }\nconsole.log([' .. table.concat(calls, ',\n') .. '].join("\\n"));\n'
            local out = runjs(js)
            for l in (out or ''):gmatch('[^\n]+') do res[#res + 1] = l end
        end
        local wit = {}
        for i, lb in ipairs(labels) do
            wit[lb.k] = wit[lb.k] or {}
            local o = res[i]
            local good = o and ((lb.st == 'always') == (o == 'ok'))
            if o then if good then tally.confirmed = tally.confirmed + 1 else tally.contradicted = tally.contradicted + 1 end end
            table.insert(wit[lb.k], ('%s=%s%s'):format(lb.t, o or 'lost', (o and not good) and ' ✗' or ''))
        end
        for k, p in ipairs(row.pos) do
            local l = {}
            for t, st in pairs(p.by) do l[#l + 1] = t .. '=' .. st end
            table.sort(l)
            local reading = p.untyped and 'any' or table.concat(p.accepted, '|')
            local tset = ts and ts[k]
            local sp, verdict = nil, ''
            if tset then
                local tl = {}
                if tset.any then tl = { 'any' } else for _, t in ipairs(ALL) do if tset[t] then tl[#tl + 1] = t end end end
                sp = table.concat(tl, '|')
                local more, less = {}, {}
                if tset.any then
                    if not p.untyped then for _, t in ipairs(ALL) do if p.by[t] == 'never' then less[#less + 1] = t end end end
                else
                    for _, t in ipairs(p.accepted) do if not tset[t] then more[#more + 1] = t .. (p.by[t] == 'content' and '?' or '') end end
                    for _, t in ipairs(ALL) do if tset[t] and p.by[t] == 'never' then less[#less + 1] = t end end
                end
                -- (a difference is CLASSED: NARROWER — the C rejects a type the declaration allows, the class worth reading
                -- —; WIDER — it always accepts one the declaration excludes; TS STRICTER — it only may, on content: JS's own
                -- coercions, ToNumber / ToString / ToObject, that a declaration states as intent)
                local strict = #more > 0
                for _, m in ipairs(more) do if not m:find('?', 1, true) then strict = false end end
                if #more == 0 and #less == 0 then tally.agree = tally.agree + 1; verdict = 'AGREE'
                elseif #less > 0 then tally.narrower = tally.narrower + 1; verdict = 'NARROWER (rejects ' .. table.concat(less, '|') .. ')' .. (#more > 0 and (' + also accepts ' .. table.concat(more, '|')) or '')
                elseif strict then tally.stricter = tally.stricter + 1; verdict = 'TS STRICTER (the C also accepts on content ' .. table.concat(more, '|') .. ')'
                else tally.wider = tally.wider + 1; verdict = 'WIDER (also accepts ' .. table.concat(more, '|') .. ')' end
            end
            table.sort(wit[k] or {})
            io.write(('  #%d reading %-30s absent=%-7s ts %-12s %s%s  [%s]%s\n'):format(k, reading, tostring(p.absent), tostring(sp), verdict,
                ts and ts.absent[k] and ' (optional)' or '', table.concat(l, ' '), wit[k] and ('\n      witness ' .. table.concat(wit[k], ' ')) or ''))
        end
    end
end
io.write(('READINGS: %d functions, %d positions (%d typed, %d over budget) · JOIN vs TypeScript: %d agree, %d ts stricter, %d wider, %d narrower · WITNESS (qjs %s%s): %d confirmed, %d contradicted\n'):format(
    #sel, tally.positions, tally.typed, tally.over, tally.agree, tally.stricter, tally.wider, tally.narrower, runv, witness_ok and '' or (' ≠ tree ' .. treev .. ': skipped'), tally.confirmed, tally.contradicted))
