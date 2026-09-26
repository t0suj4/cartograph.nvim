-- erlbehaviour — an Erlang module's BEHAVIOUR OBLIGATIONS, read as the liveness alibi they are (CART-1117).
--
-- @langs erlang
-- `-behaviour(B)` and `-callback` are Erlang attributes; nothing here generalises across languages. The
-- language-neutral half — "a caller outside the call graph binds to a declaration, not to this body" — is
-- lint.lua's contract_alibi, which asks this module only about `.erl` nodes.
--
-- ★★★ WHY. `-behaviour(gen_mod)` obliges the module to define gen_mod's callbacks, and gen_mod (or OTP's
-- gen_server loop) invokes them as `Mod:depends(Host, Opts)` with `Mod` a VARIABLE — a call no name graph can
-- bind. Measured on ejabberd (2f226abdfa1f): 1258 of 3313 dead-function findings (38%) named such a callback.
-- The callback DECLARATION is the obligation, and the obligation is the alibi.
--
-- ★★ THE ANALYSED TREE SELECTS, IT NEVER SUPPLIES. A module's own -behaviour line picks the producer; a
-- module that declares no behaviour gets nothing, however much its function names look like callbacks.
-- The producer is, in order:
--   1. an IN-TREE module named B (B.erl — the compiler enforces module = file name): its -callback
--      attributes, read through THE PARSER. A corpus module shadows the runtime's, exactly as the
--      module-to-file bind does; if it declares no such callback, the runtime is NOT consulted.
--   2. the runtime: `otp-api.mpack`'s `behaviours[B]`, distilled by tools/erldistill.lua from
--      `B:behaviour_info(callbacks | optional_callbacks)` on the installed runtime (OTP's sources are not
--      on the machine; its compiled -callback set is). ⚠ The runtime's lib tree holds whatever is
--      installed there — a distro's p1_utils / p1_xmpp / jose sit beside stdlib — so the evidence names
--      the supplying APP (`stdlib-4.3.1.3`, `p1_utils-1.0.25`).
--
-- ★★ NAME + ARITY, never name alone: `set_invitee/3` is not the callback `set_invitee/5`. And arity is read
-- off the `type_sig`'s argument FIELD, not by counting commas: the probe that measured this defect used a
-- regex and read `-callback set_invitee(Fun :: fun(() -> R), …)` as arity 1 (the nested fun type's `()`).
--
-- ★ AN OPTIONAL CALLBACK IS STILL A CALLBACK. `-optional_callbacks` means "may be absent", not "never
-- called": gen_server calls handle_info/2 whenever it is defined. The flag rides in the evidence only.
--
-- ★ `-behaviour(?GEN_SERVER)` (9 ejabberd modules): a macro resolves only through a SAME-FILE
-- `-define(GEN_SERVER, gen_server)` that is the file's only definition of it and whose replacement is one
-- atom — ejabberd writes it as an overridable default under `-ifndef(GEN_SERVER)`, so the resolved value is
-- the default build's, and the evidence names the macro. Anything else leaves the behaviour unnamed.
--
-- ⚠ APPROXIMATIONS, stated: a -behaviour inside an included .hrl, or a function defined in a header, is not
-- seen (the node's own file is read) — the finding stays reported, the pre-existing state. Quoted-atom
-- function names are matched by their unquoted text.

local M = {}

local function unq(s)
    if not s then return nil end
    return s:match("^'(.*)'$") or s
end

--- Parse one file's behaviour facts. Pure: src -> facts.
---   behaviours = { { name = 'gen_mod' | nil, line, macro = 'GEN_SERVER' | nil, define_line } }
---   callbacks  = { { name, arity, line, optional = true | nil } }   (this file's own -callback attributes)
---   by         = { ['name/arity'] = callback }
--- @param src string
--- @return table
function M.parse_source(src)
    local facts = { behaviours = {}, callbacks = {}, by = {} }
    if not src then facts.unparsed = true; return facts end
    local view = require('cartograph.parseview').view(src, 'erlang')
    local okp, parser = pcall(vim.treesitter.get_string_parser, view, 'erlang')
    local tree = okp and parser and parser:parse()[1]
    if not tree then facts.unparsed = true; return facts end
    local function text(n) return vim.treesitter.get_node_text(n, view) end
    local function f1(n, f) return n and n:field(f)[1] end
    local defines, optional = {}, {}
    for ch in tree:root():iter_children() do
        local t = ch:type()
        local line = ch:start() + 1
        if t == 'behaviour_attribute' then
            local nm = f1(ch, 'name')
            if nm and nm:type() == 'atom' then
                facts.behaviours[#facts.behaviours + 1] = { name = unq(text(nm)), line = line }
            elseif nm and nm:type() == 'macro_call_expr' then
                local v = f1(nm, 'name')
                facts.behaviours[#facts.behaviours + 1] = { macro = v and text(v) or text(nm), line = line }
            end
        elseif t == 'pp_define' then
            local lhs = f1(ch, 'lhs')
            local nm = f1(lhs, 'name')
            -- a macro WITH arguments (`-define(M(X), …)`) cannot be a behaviour name
            if nm and not f1(lhs, 'args') then
                local rep = f1(ch, 'replacement')
                local k = text(nm)
                local l = defines[k] or {}; defines[k] = l
                l[#l + 1] = { value = (rep and rep:type() == 'atom') and unq(text(rep)) or false, line = line }
            end
        elseif t == 'callback' then
            local fn = f1(ch, 'fun')
            local name = fn and unq(text(fn))
            -- every signature of one -callback is a clause of ONE function, so they share an arity; each is
            -- read anyway (a distinct arity would be a distinct callback, and a duplicate is deduplicated)
            for _, sig in ipairs(name and ch:field('sigs') or {}) do
                local args = f1(sig, 'args')
                -- the `args` FIELD: a comment between arguments is a sibling, not an argument
                local ar = args and #args:field('args') or 0
                local key = name .. '/' .. ar
                if not facts.by[key] then
                    local cb = { name = name, arity = ar, line = line }
                    facts.callbacks[#facts.callbacks + 1] = cb
                    facts.by[key] = cb
                end
            end
        elseif t == 'optional_callbacks_attribute' then
            for _, fa in ipairs(ch:field('callbacks')) do
                local f, a = f1(fa, 'fun'), f1(f1(fa, 'arity'), 'value')
                if f and a then optional[unq(text(f)) .. '/' .. text(a)] = true end
            end
        end
    end
    for key in pairs(optional) do
        if facts.by[key] then facts.by[key].optional = true end
    end
    for _, b in ipairs(facts.behaviours) do
        if b.macro then
            local l = defines[b.macro]
            if l and #l == 1 and l[1].value then b.name, b.define_line = l[1].value, l[1].line end
        end
    end
    return facts
end

--- A function's arity, from the `name/N` alt key spec/erlang.lua mints (erlang nodes carry no `params`; the
--- alt key is persisted, so this reads the same on a warm graph).
local function arity_of(n)
    local pre = (n.name or '') .. '/'
    for _, k in ipairs(n.altkeys or {}) do
        if k:sub(1, #pre) == pre then
            local a = k:sub(#pre + 1):match('^(%d+)$')
            if a then return tonumber(a) end
        end
    end
    return nil
end
M.arity_of = arity_of

--- The predicate. Returns `fn(n) -> hit | nil`, lazy and cached per file.
---   files  the corpus's files (relative paths) — the tree's modules, by basename
---   read   fn(file) -> source text | nil
---   runtime fn() -> the otp-api artifact (`behaviours`, `version`) | nil — called at most once, on the
---          first behaviour the tree cannot supply
--- hit = { via = 'behaviour', behaviour, macro, behaviour_file, behaviour_line, producer = 'tree' | 'runtime',
---         callback = 'name/arity', callback_file, callback_line, app, release, optional, arity }
function M.contract(files, read, runtime)
    local by_mod
    local parsed = {}
    local api, api_done
    local function facts(f)
        local F = parsed[f]
        if F == nil then
            local src = read(f)
            F = src and M.parse_source(src) or false
            parsed[f] = F
        end
        return F or nil
    end
    local function modules()
        if by_mod then return by_mod end
        by_mod = {}
        for _, f in ipairs(files or {}) do
            local base = f:match('([^/]+)%.erl$')
            if base then
                local l = by_mod[base] or {}; by_mod[base] = l
                l[#l + 1] = f
            end
        end
        for _, l in pairs(by_mod) do table.sort(l) end -- a stable evidence file when a name is defined twice
        return by_mod
    end
    local function runtime_api()
        if not api_done then
            api_done = true
            api = runtime and runtime() or nil
        end
        return api
    end
    return function (n)
        if not (n.file and n.file:match('%.erl$')) then return nil end
        local ar = arity_of(n)
        if not ar then return nil end
        local F = facts(n.file)
        if not F or #F.behaviours == 0 then return nil end
        local key = n.name .. '/' .. ar
        for _, b in ipairs(F.behaviours) do
            if b.name then
                local base = { via = 'behaviour', behaviour = b.name, macro = b.macro, define_line = b.define_line,
                    behaviour_file = n.file, behaviour_line = b.line, callback = key, arity = ar }
                local mods = modules()[b.name]
                if mods then
                    -- the tree's module shadows the runtime's: no fall-through when it does not declare this
                    for _, mf in ipairs(mods) do
                        local MF = facts(mf)
                        local cb = MF and MF.by[key]
                        if cb then
                            base.producer, base.callback_file, base.callback_line = 'tree', mf, cb.line
                            base.optional = cb.optional
                            return base
                        end
                    end
                else
                    local A = runtime_api()
                    local rb = A and A.behaviours and A.behaviours[b.name]
                    for _, c in ipairs(rb and rb.callbacks or {}) do
                        if c.name == n.name and c.arity == ar then
                            base.producer, base.app, base.release = 'runtime', rb.app, A.version
                            base.optional = c.optional
                            return base
                        end
                    end
                end
            end
        end
        return nil
    end
end

return M
