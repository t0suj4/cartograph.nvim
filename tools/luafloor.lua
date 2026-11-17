-- luafloor — distil, PER LUA VERSION, which version each of versionfloor's Lua syntax detectors needs, by ASKING THE
-- INTERPRETERS (CART-0782).
--
--   nvim --headless -u NONE -l tools/luafloor.lua           -- rewrite the artifact
--   nvim --headless -u NONE -l tools/luafloor.lua --check   -- re-distil and diff, write nothing (exit 1 on drift)
--
-- The detectors (versionfloor.LUA_SYNTAX: a tree-sitter shape + snippets of it) are authored; the VERSION is not. Each
-- snippet goes to each installed interpreter as a file would (`loadfile()` on stdin: compile only, nothing runs), and
-- an entry's version is read off the answers:
--   · on the PUC ruler (5.1 / 5.2 / 5.4 here) the answers must be refuse… then accept…; the floor is the version AFTER
--     the newest refusal, and `exact` says whether an interpreter for that version was asked (5.3: none on 2026-11-13,
--     so a 5.2-refused, 5.4-accepted feature is 5.3 with exact = false — the lowest it can need, never a guess upward)
--   · every PUC interpreter accepting (no floor), none accepting (LuaJIT-only syntax), or accept-then-refuse (a REMOVAL,
--     not a floor) gives NO version and a `why`; the feature is then left out of versionfloor's Lua table
--   · `luajit` records LuaJIT's own answer: it is a sibling dialect, not a point on the PUC ruler
--   · all snippets of one entry must get the same answer from each interpreter, or the entry is two features
-- The artifact stamps each interpreter's `-v` line and a hash of the detectors' snippets, so a stale artifact is
-- detectable (tests/versionfloor_spec.lua re-distils when the interpreters are present). The `escapes` section (CART-2038) is the one probe that RUNS a chunk —
-- `return "<a string literal>"`, nothing else — to read what an escape MEANS per interpreter. Interpreters as in
-- tools/luareserved.lua (CART-1012); adding a version = install its interpreter and add a row to INTERPS.

local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
local OUT = REPO .. '/lua/cartograph/spec/luafloor.lua'
local INTERPS = { { key = '5.1', bin = 'lua5.1' }, { key = '5.2', bin = 'lua5.2' }, { key = '5.4', bin = 'lua5.4' },
    { key = 'luajit', bin = 'luajit' } }
local COMPILE = 'local f, e = loadfile() if not f then io.stderr:write(tostring(e)) os.exit(1) end'

local function sh(cmd, input)
    local r = vim.system(cmd, { stdin = input, text = true }):wait()
    return r.code, (r.stdout or '') .. (r.stderr or '')
end

local function vnum(k)
    local a, b = k:match('^(%d+)%.(%d+)$')
    return a and (tonumber(a) * 1000 + tonumber(b)) or nil
end

-- ★ STRING ESCAPES BY THEIR MEANING (CART-2038). Loading is not the only question an escape asks: 5.1 reads an escape
-- it does not know as the bare letter, so `"\x41"` LOADS on 5.1 and means "x41" there and "A" from 5.2 on. Each
-- escape KEY — a character after the backslash, or a FORM of x / u / z the lexer tells apart — is handed to every
-- interpreter as `return "<string>"`, and the loaded value comes back as hex bytes (text-mode stdout cannot alter it).
-- On the PUC ruler: all the same = no entry; accepted by 5.1 and refused from some version on = `gone` (a REMOVAL, a
-- ceiling); refused by 5.1 and accepted later with one value = `floor`; anything else = `split` (a BEHAVIOUR CHANGE)
-- at the first version that answers differently from 5.1. `luajit`: refuses / the 5.1 meaning (old) / the newest
-- PUC meaning (new). The lexer (versionfloor.lua_escapes) holds no escape set of its own: it decides the KEY, this
-- table decides what the key means.
local ESCAPE_FORMS = {
    ['x-hex'] = { '\\x41', '\\x7e' },            -- \x and two hex digits
    ['u-brace'] = { '\\u{48}', '\\u{7E}' },      -- \u{ hex digits }
    ['z'] = { '\\zb', '\\z  b' },                -- \z with no line break in the whitespace after it
    ['z-nl'] = { '\\z\n  b' },                    -- \z then a line break
    -- (the bytes no printable key covers: a control character — tab included — and a byte above 127, a UTF-8 lead
    -- byte in a localization file: TBag's ruRU `\` before Cyrillic, which 5.4 refuses)
    ['ctl'] = { '\\\t', '\\' .. string.char(1) },
    ['high'] = { '\\' .. string.char(208, 159), '\\' .. string.char(200) },
}
local RUN = 'local f, e = loadfile() if not f then io.stderr:write(tostring(e)) os.exit(1) end '
    .. 'local s = f() io.write((s:gsub(".", function (c) return string.format("%02x", c:byte()) end)))'
local function escapes_distil(present)
    local keys, probes = {}, {}
    for code = 32, 126 do
        local ch = string.char(code)
        -- (x / u / z alone = their MALFORMED form: \x not followed by two hex digits, \u not by {hex}, see FORMS)
        local body = ch == '"' and '\\"' or ('\\' .. ch)
        if ch == 'x' then body = '\\xZZ' elseif ch == 'u' then body = '\\user' end
        if ch ~= 'z' then keys[#keys + 1] = ch; probes[ch] = { body } end
    end
    for k, bodies in pairs(ESCAPE_FORMS) do keys[#keys + 1] = k; probes[k] = bodies end
    table.sort(keys)
    local puc = {}
    for _, it in ipairs(present) do if vnum(it.key) then puc[#puc + 1] = it end end
    table.sort(puc, function (a, b) return vnum(a.key) < vnum(b.key) end)
    local jit
    for _, it in ipairs(present) do if it.key == 'luajit' then jit = it end end
    local function answer(it, bodies)
        local ans
        for _, b in ipairs(bodies) do
            local code, out = sh({ it.bin, '-e', RUN }, 'return "' .. b .. '"\n')
            local a = code == 0 and out or 'R'
            if ans == nil then ans = a elseif (ans == 'R') ~= (a == 'R') then return '?' end
            -- (two probes of one key must agree on accept / refuse; their values differ by construction)
        end
        return ans
    end
    local out = {}
    for _, k in ipairs(keys) do
        local ans, vals = {}, {}
        for _, it in ipairs(puc) do ans[#ans + 1] = answer(it, probes[k]); vals[it.key] = ans[#ans] end
        -- (meaning compares the FIRST probe's value: one string per key and interpreter)
        local first = ans[1]
        local same = true
        for i = 2, #ans do if ans[i] ~= first then same = false end end
        if not same and #ans > 1 then
            local e = { asked = {} }
            for _, it in ipairs(puc) do e.asked[it.key] = vals[it.key] ~= 'R' end
            local diff
            for i = 2, #ans do if ans[i] ~= first then diff = i; break end end
            local allref = true
            for i = diff, #ans do if ans[i] ~= 'R' then allref = false end end
            if first ~= 'R' and allref then e.class = 'gone'
            elseif first == 'R' then e.class = 'floor'
            else e.class = 'split' end
            e.v = puc[diff].key
            if jit then
                local ja = answer(jit, probes[k])
                e.luajit = ja == 'R' and 'refuses' or (ja == first and 'old' or (ja == ans[#ans] and 'new' or 'other'))
            end
            out[k] = e
        end
    end
    return out
end

local function distil()
    local vf = require 'cartograph.versionfloor'
    local sig = {}
    for _, f in ipairs(vf.LUA_SYNTAX) do sig[#sig + 1] = f.id .. '\1' .. table.concat(f.snippets, '\2') end
    local res = { detectors = #vf.LUA_SYNTAX, detectors_sha = vim.fn.sha256(table.concat(sig, '\3')),
        interpreters = {}, features = {} }
    local present = {}
    for _, it in ipairs(INTERPS) do
        if vim.fn.executable(it.bin) == 1 then
            local _, ver = sh({ it.bin, '-v' })
            res.interpreters[it.key] = vim.trim(ver:match('[^\n]*'))
            present[#present + 1] = it
        end
    end
    for _, f in ipairs(vf.LUA_SYNTAX) do
        local asked, why = {}, nil
        for _, it in ipairs(present) do
            local ans
            for _, s in ipairs(f.snippets) do
                local ok = sh({ it.bin, '-e', COMPILE }, s .. '\n') == 0
                if ans == nil then ans = ok elseif ans ~= ok then why = 'its snippets disagree under ' .. it.key end
            end
            asked[it.key] = ans
        end
        local puc = {}
        for k in pairs(asked) do if vnum(k) then puc[#puc + 1] = k end end
        table.sort(puc, function (a, b) return vnum(a) < vnum(b) end)
        local lo, hi, removal
        for _, k in ipairs(puc) do
            if asked[k] then hi = hi or k elseif hi then removal = k else lo = k end
        end
        local e = { asked = asked, luajit = asked.luajit }
        if why then e.why = why
        elseif removal then e.why = ('accepted by %s, refused by %s: a removal, not a floor'):format(hi, removal)
        elseif not hi then e.why = 'no PUC interpreter accepts it'
        elseif not lo then e.why = 'every PUC interpreter asked accepts it'
        else
            local a, b = lo:match('^(%d+)%.(%d+)$')
            e.v = ('%s.%d'):format(a, tonumber(b) + 1)
            e.exact = e.v == hi
        end
        res.features[f.id] = e
    end
    res.escapes = escapes_distil(present)
    return res
end

local function render(r)
    local function kv(t)
        local ks = vim.tbl_keys(t)
        table.sort(ks)
        local q = {}
        for _, k in ipairs(ks) do q[#q + 1] = ('[%q] = %s'):format(k, tostring(t[k])) end
        return '{ ' .. table.concat(q, ', ') .. ' }'
    end
    local L = {
        '-- GENERATED by tools/luafloor.lua (CART-0782) — do not edit; re-run the tool. The Lua version each of',
        '-- versionfloor\'s Lua syntax detectors needs, asked of each interpreter (loadfile: compile only). A feature',
        '-- with no `v` has a `why` and is left out of the floor; `exact = false` means no interpreter for `v` was asked.',
        '-- `escapes` (CART-2038): what each string escape MEANS per interpreter — the one probe that RUNS, a chunk that',
        '-- only returns a string literal: gone = a removal, split = a behaviour change, floor = needs that version.',
        'return {',
        ('    detectors = %d,'):format(r.detectors),
        ('    detectors_sha = %q,'):format(r.detectors_sha),
        '    interpreters = {',
    }
    local iks = vim.tbl_keys(r.interpreters)
    table.sort(iks)
    for _, k in ipairs(iks) do L[#L + 1] = ('        [%q] = %q,'):format(k, r.interpreters[k]) end
    L[#L + 1] = '    },'
    L[#L + 1] = '    features = {'
    local fks = vim.tbl_keys(r.features)
    table.sort(fks)
    for _, id in ipairs(fks) do
        local e = r.features[id]
        local head = e.v and ('v = %q, exact = %s'):format(e.v, tostring(e.exact)) or ('why = %q'):format(e.why)
        L[#L + 1] = ('        [%q] = { %s, luajit = %s,'):format(id, head, tostring(e.luajit))
        L[#L + 1] = ('            asked = %s },'):format(kv(e.asked))
    end
    L[#L + 1] = '    },'
    L[#L + 1] = '    escapes = {'
    local eks = vim.tbl_keys(r.escapes or {})
    table.sort(eks)
    for _, k in ipairs(eks) do
        local e = r.escapes[k]
        L[#L + 1] = ('        [%q] = { class = %q, v = %q, luajit = %q, asked = %s },'):format(k, e.class, e.v,
            tostring(e.luajit), kv(e.asked))
    end
    L[#L + 1] = '    },'
    L[#L + 1] = '}'
    return table.concat(L, '\n') .. '\n'
end

local text = render(distil())
if vim.tbl_contains(_G.arg or {}, '--check') then
    local f = io.open(OUT, 'r')
    local cur = f and f:read('*a') or ''
    if f then f:close() end
    if cur == text then print('luafloor: artifact is current') return end
    io.stdout:write(vim.diff(cur, text) or '')
    print('luafloor: DRIFT — re-run without --check')
    os.exit(1)
end
local f = assert(io.open(OUT, 'w'))
f:write(text)
f:close()
print('luafloor: wrote ' .. OUT)
