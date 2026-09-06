-- erldistill — distil the OTP stdlib surface into an L2 environment profile
-- ([[cartograph-stdlib-profile]]), from the INSTALLED RUNTIME.
--
--   nvim --headless -u NONE -l tools/erldistill.lua [--out <path>]
--
-- ★★ THE SOURCE IS AN ORACLE, NOT A CURATED LIST. `erl` is asked which modules
-- exist and what each exports; nothing here is authored, so nothing here can be
-- wrong in the way a hand-maintained name list goes wrong. That is the
-- convergence rule ([[cartograph-optimizer-oracle]]): external knowledge arrives
-- as an ORACLE or as DECLARED DATA, never as code someone wrote from memory.
--
-- ★★★ WHY IT IS WORTH BUILDING, sized before writing a line (CART-0793). Of
-- ejabberd's 14849 unresolved remote calls:
--     module IS a corpus file    4001   26.9%   (fixed by the module-to-file bind)
--     module is an OTP module   10175   68.5%   <- THIS
--     neither (deps, missing)     673    4.5%
-- 68.5% of what is left is one environment, and the environment is installed on
-- the machine.
--
-- ⚠⚠ AND A PROFILE CAN ONLY SUBTRACT. `prof_ext` is consulted in NODEF POSITION
-- ONLY — project resolution has already failed — so a profile turns "I could not
-- resolve this" into "that is the platform". It must never turn a real project
-- definition into an external one, which is why the two surfaces here are drawn
-- so differently:
--   nsset  EVERY OTP module name. Safe by construction: it is only reached
--          through a call that NAMES its module (`lists.foldl`), and a corpus
--          module of the same name already resolved through the module-to-file
--          bind before this is consulted.
--   free   THE 176 AUTO-IMPORTED BIFs ONLY, and emphatically not the 21388
--          exported names. A bare `foo()` must not be called external because
--          some OTP module happens to export `foo` — that is exactly the false
--          GUARANTEE the stdlib-profile memory warns is unsound. Erlang forbids
--          defining a function that clashes with an auto-imported BIF (short of
--          an explicit `-compile({no_auto_import, ...})`), so this set is the one
--          that genuinely cannot be a project function.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local out = repo .. '/lua/cartograph/spec/profile/otp.mpack'
local i = 1
while arg and arg[i] do
    if arg[i] == '--out' then out = arg[i + 1]; i = i + 2 else i = i + 1 end
end

if vim.fn.executable('erl') ~= 1 then
    print('erldistill: no `erl` on PATH — this tool distils from the INSTALLED'
        .. ' runtime, so there is nothing to read. Not a failure to work around:'
        .. ' install Erlang/OTP or run it where OTP lives.')
    os.exit(2)
end

local tmp = vim.fn.tempname()
-- Ask the runtime three things: its release, every module under the OTP lib
-- tree, and the exports of each. `erl_internal:bif/2` is the runtime's OWN
-- answer to "is this name callable without a module", which is the question the
-- `free` set is asking — deriving it from a documentation page would be a guess.
local script = ([[
  Rel = erlang:system_info(otp_release),
  {ok, F} = file:open("%s", [write]),
  io:format(F, "@release ~s~n", [Rel]),
  Mods = [M || {M, P, _} <- code:all_available(),
               is_list(P), string:find(P, "/lib/erlang/lib/") =/= nomatch],
  lists:foreach(fun(MB) ->
      M = list_to_atom(MB),
      case catch M:module_info(exports) of
        L when is_list(L) ->
          lists:foreach(fun({Fn, A}) ->
            io:format(F, "~s ~s ~p~n", [MB, atom_to_list(Fn), A]) end, L);
        _ -> ok
      end
    end, Mods),
  lists:foreach(fun({Fn, A}) ->
      case erl_internal:bif(Fn, A) of
        true  -> io:format(F, "@bif ~s ~p~n", [atom_to_list(Fn), A]);
        false -> ok
      end
    end, erlang:module_info(exports)),
  file:close(F), halt().
]]):format(tmp)

vim.fn.system({ 'erl', '-noshell', '-eval', script })
if vim.v.shell_error ~= 0 then
    print('erldistill: erl exited ' .. vim.v.shell_error); os.exit(2)
end

local nsset, namespaces, free, vocab, sigs = {}, {}, {}, {}, {}
local release, nmod, nexp, nbif = 'unknown', 0, 0, 0
for line in io.lines(tmp) do
    local rel = line:match('^@release%s+(%S+)')
    local bif, bifa = line:match('^@bif%s+(%S+)%s+(%d+)$')
    if rel then
        release = rel
    elseif bif then
        -- an auto-imported BIF: callable with no module, so it is a `free` name
        nbif = nbif + 1
        free[bif] = free[bif] or {}
        free[bif][#free[bif] + 1] = tonumber(bifa)
        vocab[bif] = true
    else
        local m, fn, a = line:match('^(%S+)%s+(%S+)%s+(%d+)$')
        if m and fn then
            if not nsset[m] then
                nsset[m] = true
                namespaces[#namespaces + 1] = m
                nmod = nmod + 1
            end
            nexp = nexp + 1
            vocab[fn] = true
            -- the resolution key the provider builds for a remote call is
            -- `module.function` (spec/erlang.lua's qualify_call), so the sig table
            -- is keyed the same way and an arity list hangs off it
            local k = m .. '.' .. fn
            local s = sigs[k]
            if not s then s = { arities = {} }; sigs[k] = s end
            s.arities[#s.arities + 1] = tonumber(a)
        end
    end
end
os.remove(tmp)

if nmod == 0 then
    print('erldistill: the runtime answered with no modules — refusing to write an'
        .. ' empty profile, which would activate and disposition NOTHING while'
        .. ' looking installed.')
    os.exit(2)
end

-- ⚠ SORTED. `namespaces` is an ARRAY in the artifact and the artifact is written
-- to disk, so an unsorted set makes the bytes depend on LuaJIT's per-process hash
-- seed — a distilled artifact that differs every run for no reason (CART-0790).
table.sort(namespaces)
for _, s in pairs(sigs) do table.sort(s.arities) end

local prof = {
    schema = 1,
    runtime = 'otp',
    lang = 'erlang',
    version = release,
    -- ⚠ NOT A WALL CLOCK. A timestamp makes the artifact differ on every run for
    -- no content reason, and this file is CHECKED IN — a regeneration would
    -- produce a whole-file diff that hides whether anything actually changed.
    -- Derived from what the artifact IS instead.
    stamp = ('otp-%s-%dm-%de'):format(release, nmod, nexp),
    sig_kind = 'erlang',
    sig_root = '/usr/lib/erlang/lib',
    types = {},          -- erlang has no namespaced type surface of this shape
    namespaces = namespaces,
    nsset = nsset,
    free = free,
    vocab = vocab,
    sigs = sigs,
}

local fd = assert(io.open(out, 'wb'))
fd:write(vim.mpack.encode(prof))
fd:close()
print(('erldistill: OTP %s — %d modules, %d exports, %d auto-imported BIFs -> %s')
    :format(release, nmod, nexp, nbif, out:gsub('^' .. vim.pesc(repo) .. '/', '')))
