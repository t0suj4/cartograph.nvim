-- erlbif — ARGUMENT TYPES BY PATH over erts' BIFs (cartograph.erlbif, CART-1248): every fact derived from the tree,
-- each position's reading by type, JOINED with the -spec the OTP sources state and WITNESSED by the running erl.
--
--   nvim --headless -u NONE -l tools/erlbif.lua <configured erts/emulator dir> [module:name/arity …]
--
-- (default: the pilot — atom_to_list/1, hd/1, tl/1, length/1, lists:member/2, lists:reverse/2). The -spec side is
-- the tree's own erts/preloaded/src/erlang.erl and lib/<app>/src/<module>.erl (under ERL_TOP, derived); the witness is
-- `erl` on PATH, which must be the tree's release (its OTP_VERSION is compared).
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local E = require 'cartograph.erlbif'

local src = arg[1]
if not src then io.stderr:write('usage: erlbif.lua <configured erts/emulator dir> [module:name/arity …]\n'); os.exit(2) end
local bifs = {}
for i = 2, #arg do bifs[#bifs + 1] = arg[i] end
if #bifs == 0 then bifs = { 'erlang:atom_to_list/1', 'erlang:hd/1', 'erlang:tl/1', 'erlang:length/1', 'lists:member/2', 'lists:reverse/2' } end

local t0 = vim.uv.hrtime()
local rows, ctx = E.measure({ src = src, bifs = bifs })
local T = ctx.facts
io.write(('ERLBIF %s — %d of %d facts derived; frame %s, slot %s, status %s.%s (sentinel %s; outcomes %s); %d representatives; %.1f s\n'):format(
    src, T.derived, T.total, ctx.frame.array, T.got.slot.type, ctx.result.macro, ctx.result.field, ctx.result.sentinel.name,
    table.concat(vim.tbl_keys(ctx.result.codes), ','), #ctx.reps.order, (vim.uv.hrtime() - t0) / 1e9))

-- THE -SPEC SIDE: ERL_TOP (the compdb's derived env, else the ancestor holding erts/) and the module's source
local top = T.got.compdb.env.ERL_TOP
if not top then local d = src; while #d > 1 and not vim.uv.fs_stat(d .. '/erts') do d = vim.fn.fnamemodify(d, ':h') end; top = d end
local function modsrc(m)
    if m == 'erlang' then return top .. '/erts/preloaded/src/erlang.erl' end
    return vim.fn.glob(top .. '/lib/*/src/' .. m .. '.erl', false, true)[1]
end
local function readfile(p) local fd = p and io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end
-- the type a spec gives each argument, in the reading's words (a guard's name; `any` for term() / a free variable)
local function spec_of(m, name, arity)
    local text = readfile(modsrc(m)) or ''
    for sp in text:gmatch('\n%-spec%s+(.-)%.%s*\n') do
        local nm, args, rest = sp:match('^([%w_]+)%s*(%b())(.*)$')
        if nm == name then
            local inner = args:sub(2, -2)
            local parts, depth, cur = {}, 0, ''
            for c in inner:gmatch('.') do
                if c == '(' or c == '[' or c == '{' then depth = depth + 1 elseif c == ')' or c == ']' or c == '}' then depth = depth - 1 end
                if c == ',' and depth == 0 then parts[#parts + 1] = vim.trim(cur); cur = '' else cur = cur .. c end
            end
            if vim.trim(cur) ~= '' then parts[#parts + 1] = vim.trim(cur) end
            if #parts == arity then
                local out = {}
                for i, a in ipairs(parts) do
                    local ty = a
                    if a:match('^[%u_][%w_]*$') then ty = rest:match('%f[%w_]' .. a .. '%s*::%s*([^,]+)') or 'term()' end
                    ty = vim.trim(ty)
                    local g = ty:match('^([%w_]+)%(%)')
                    -- (every list type of Erlang's type language names a list: list(), string(), nonempty_maybe_improper_list(), …)
                    if ty:sub(1, 1) == '[' or g == 'string' or (g and g:find('list', 1, true)) then out[i] = 'list'
                    elseif g == 'term' or g == 'any' or ty:match('^[%u_][%w_]*$') then out[i] = 'any'
                    elseif g == 'non_neg_integer' or g == 'pos_integer' or g == 'neg_integer' then out[i] = 'integer'
                    elseif g then out[i] = g else out[i] = '?' .. ty end
                end
                return out, sp:gsub('%s+', ' ')
            end
        end
    end
    return nil
end

-- THE WITNESS: one sample per type, other arguments from a type their own position accepts
local erlv = vim.system({ 'erl', '-noshell', '-eval', 'io:format("~s", [erlang:system_info(otp_release)]), halt().' }, { text = true }):wait()
local treev = (readfile(top .. '/OTP_VERSION') or ''):match('^(%d+)')
local witness_ok = erlv.code == 0 and vim.trim(erlv.stdout or '') == treev
local SAMPLE = { integer = { '1' }, atom = { 'foo' }, boolean = { 'true' }, list = { '[]', '[1]' }, boxed = { '{a}', '1.5', '<<>>', '#{}' } }
local function call(m, name, argv)
    local e = ('R = try %s:%s(%s) of _ -> ok catch error:E -> E end, io:format("~p", [R]), halt().'):format(m, name, table.concat(argv, ', '))
    local r = vim.system({ 'erl', '-noshell', '-eval', e }, { text = true }):wait()
    return vim.trim(r.stdout or '')
end

local tally = { agree = 0, differ = 0, confirmed = 0, contradicted = 0 }
for _, b in ipairs(bifs) do
    local r = rows[b]
    local m, name, arity = b:match('^([%w_]+):([%w_]+)/(%d+)$')
    arity = tonumber(arity)
    local spec, stext = spec_of(m, name, arity)
    if not r then io.write(b, ': not registered\n')
    elseif r.missing then io.write(b, ': ', r.missing, '\n')
    else
        io.write(('%s  (%s)  -spec %s\n'):format(b, r.cfn, stext or 'none found'))
        for k, p in ipairs(r.pos) do
            local l = {}
            for t, st in pairs(p.by) do l[#l + 1] = t .. '=' .. st end
            table.sort(l)
            local sp = spec and spec[k]
            local reading = p.untyped and 'any' or table.concat(p.accepted, '|')
            -- (AGREE is EQUALITY: the accepted types, less `boxed` — content everywhere by construction, it cannot count —
            -- are exactly the spec's type; `any` agrees only with an untyped reading)
            local acc_nb = vim.tbl_filter(function (t) return t ~= 'boxed' end, p.accepted)
            local agree = sp and ((sp == 'any' and p.untyped) or (sp ~= 'any' and not p.untyped and #acc_nb == 1 and acc_nb[1] == sp))
            if sp then if agree then tally.agree = tally.agree + 1 else tally.differ = tally.differ + 1 end end
            local wit = {}
            if witness_ok and not p.untyped then
                for t, st in pairs(p.by) do
                    if (st == 'always' or st == 'never') and SAMPLE[t] then
                        for _, v in ipairs(SAMPLE[t]) do
                            local argv = {}
                            for j = 1, arity do
                                if j == k then argv[j] = v
                                else local pj = r.pos[j]; local ok_t = pj and (pj.untyped and 'integer' or pj.accepted[1]); argv[j] = (SAMPLE[ok_t] or { '1' })[#(SAMPLE[ok_t] or { '1' })] end
                            end
                            local out = call(m, name, argv)
                            local ok_call = out == 'ok'
                            local good = (st == 'always') == ok_call
                            -- (a boxed sample is one kind of many: only a never is a claim about each)
                            if t == 'boxed' and st == 'always' then good = true end
                            if good then tally.confirmed = tally.confirmed + 1 else tally.contradicted = tally.contradicted + 1 end
                            wit[#wit + 1] = ('%s(%s)=%s%s'):format(t, v, out, good and '' or ' ✗')
                        end
                    end
                end
                table.sort(wit)
            end
            io.write(('  #%d reading %-22s spec %-8s %s  [%s]%s\n'):format(k, reading, tostring(sp), sp and (agree and 'AGREE' or 'DIFFER') or '', table.concat(l, ' '),
                #wit > 0 and ('\n      witness ' .. table.concat(wit, ' ')) or ''))
        end
    end
end
io.write(('JOIN vs -spec: %d agree, %d differ · WITNESS (erl %s%s): %d confirmed, %d contradicted\n'):format(tally.agree, tally.differ,
    vim.trim(erlv.stdout or '?'), witness_ok and '' or (' ≠ tree ' .. tostring(treev) .. ': skipped'), tally.confirmed, tally.contradicted))
