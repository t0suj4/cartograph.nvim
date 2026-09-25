-- erlreg — THE SECOND REGISTRATION CARRIER: a tuple returned from a callback
-- (CART-0846, under CART-0839).
--
-- ★★★ ejabberd REGISTERS IQ HANDLERS TWO WAYS AND argv READS ONE. A call —
-- `gen_iq_handler:add_iq_handler(Component, Host, ?NS_MAM_2, ?MODULE, F)` — is
-- 57 sites over 14 files and xlang binds it 53/53. The other is a TUPLE
-- RETURNED FROM A CALLBACK:
--     depends(_Host, _Opts) ->
--         {ok, [{iq_handler, ejabberd_local, ?NS_TIME, process_local_iq}]}.
-- 32 registrations over 17 files, 19 distinct namespaces, and argv reaches NONE
-- of them because there is no call site to scan. CART-0226's shape: a declared
-- registry whose export side exists without a call.
--
-- @langs erlang
-- The carrier IS an Erlang idiom: a `{ok, [{iq_handler, …}]}` tuple returned from
-- an OTP callback. There is no cross-language generalisation to claim here — the
-- other registration carriers live in their own modules, and a second language
-- that returns a registration tuple would need its own harvest, not a widened
-- claim on this one.
-- ⚠ MEASURED, and the reason it is worth a module: FOUR of those namespaces are
-- ones the call form never reaches (urn:xmpp:blocking · carbons:2 · push:0 ·
-- time), so the ejabberd<->converse endpoint join goes 6 -> 10.
--
-- ★★★ THE INTERPRETATION IS NOT INVENTED — IT IS WRITTEN, IN EXECUTABLE CODE.
-- [[cartograph-descendable-data]]: "an INTERPRETATION is DERIVED FROM THE
-- CONSUMER CODE, liftable into spec". The consumer is gen_mod.erl:424-429:
--     ({iq_handler, Component, NS, Function}) ->
--          gen_iq_handler:add_iq_handler(Component, Host, NS, Module, Function);
--     ({iq_handler, Component, NS, Module1, Function}) ->
--          gen_iq_handler:add_iq_handler(Component, Host, NS, Module1, Function)
-- It destructures the tuple and passes its positions STRAIGHT INTO the verb we
-- already read. So this is not a second relation — it is the SAME relation in a
-- different CARRIER, and the consumer states the mapping
-- ([[cartograph-registration-relation]]: one relation, the RUNG decided by the
-- syntactic carrier).
--
-- ⚠⚠ AND IT DOES NOT MINT A SYNTHETIC CALL. Rewriting a tuple into a fake
-- `add_iq_handler` call record would make the existing linker fire for free, and
-- that free win is exactly why it is forbidden: `dec/36` decided this once for
-- the macro slot — "teach the linker about it, do not lie in the graph so an
-- existing linker fires". There is no call at that site. This produces the same
-- OUTPUT as the call path (a resolved handler edge + a keyed registration) using
-- the same exported resolver, and asserts nothing about a call.
--
-- ★ ONE RESOLVER, TWO CARRIERS: `xlang.def_index` + `xlang.handler_by_module`
-- are exported for this, rather than reimplemented here — "a probe and a verb
-- that compute the same thing SEPARATELY will disagree, and the disagreement
-- will be discovered by a reader who trusts the wrong one".

local M = {}

local prof = require 'cartograph.spec.profile'
local xlang = require 'cartograph.xlang'
local ts = require 'cartograph.providers.treesitter'

-- ── THE INTERPRETATION, DECLARED ────────────────────────────────────────────
-- ★★ ARITY IS A PROPERTY OF THE AXIS ([[cartograph-template-language]]), and
-- gen_mod declares TWO arities side by side. They are a template FAMILY, not one
-- template with an optional slot, and collapsing them would attribute a
-- 4-tuple's handler to the wrong module wherever one module registers on
-- another's behalf. So each arity carries its own position map.
-- ⚠ `mod = 'context'` means THE ENCLOSING MODULE — the module whose callback
-- returned the list, which for erlang is the file's own basename. erlang's spec
-- already resolves exactly that for `?MODULE` ("the module IS the file"), so the
-- fill has a shipped source rather than a guess.
M.CARRIERS = {
    {   tag = 'iq_handler', vocab = 'erl-macros',
        -- gen_mod.erl:60-74 declares both; :424-429 interprets both
        arities = {
            [4] = { key = 3, fn = 4, mod = 'context' },
            [5] = { key = 3, mod = 4, fn = 5 },
        },
        why = 'gen_mod.erl:424-429 passes these positions into add_iq_handler',
    },
}

--- the vocabulary that values a macro key, with its stamp (the URI is a fact
--- about a LIBRARY neither endpoint vendors — dec/36)
local function vocabulary(name)
    local a = prof.load(name)
    return (a and a.values) or {}, a and a.stamp
end

--- every `tuple` node in `root` whose FIRST named child is the atom `tag`
local function tuples_tagged(root, src, tag, out)
    if root:type() == 'tuple' then
        local first
        for c in root:iter_children() do
            if c:named() then first = c; break end
        end
        if first and first:type() == 'atom'
            and vim.treesitter.get_node_text(first, src) == tag then
            local els = {}
            for c in root:iter_children() do
                if c:named() then els[#els + 1] = c end
            end
            out[#out + 1] = els
        end
    end
    for c in root:iter_children() do
        if c:named() then tuples_tagged(c, src, tag, out) end
    end
end

--- the text of a tuple element and its NODE TYPE.
--- ⚠⚠ THE TYPE IS THE POINT, NOT DECORATION. THREE DIFFERENT THINGS IN THIS
--- CODEBASE ARE `{iq_handler, …}` TUPLES AND ONLY ONE IS A REGISTRATION —
--- measured, because my first cut counted all three:
---   gen_mod.erl:73   `{iq_handler, component(), binary(), atom()}`
---                    the `-type` DECLARATION. Elements are TYPE APPLICATIONS.
---   gen_mod.erl:424  `({iq_handler, Component, NS, Function}) ->`
---                    the CONSUMER'S CLAUSE HEAD. Elements are `var`s being
---                    BOUND — this is the interpretation itself, not a use of it.
---   mod_time.erl:43  `{iq_handler, ejabberd_local, ?NS_TIME, process_local_iq}`
---                    the REGISTRATION. Elements are atoms and macro calls.
--- They are indistinguishable by TAG and by ARITY, and separable by ELEMENT
--- KIND: a value supplies an `atom` or a `macro_call_expr`; a pattern supplies a
--- `var`; a type supplies neither. So the kinds are REQUIRED positively rather
--- than filtered by location — which is the same rule the interpretation
--- implies, and it does not depend on where in the file the tuple sits.
local function element(node, src)
    local t = node:type()
    if t == 'macro_call_expr' then
        for c in node:iter_children() do
            if c:named() and (c:type() == 'var' or c:type() == 'atom') then
                return vim.treesitter.get_node_text(c, src), t
            end
        end
        return nil, t
    end
    if t == 'atom' or t == 'var' then
        return vim.treesitter.get_node_text(node, src), t
    end
    return nil, t
end

--- ATTACH: read every declared carrier out of the erlang files under `data.root`
--- and mint the registration edge each one states.
--- ⚠ SESSION-LIVE, never persisted — same posture as the other post-pass
--- adapters (proto/k8s/django): re-derived per open, so a stale artifact cannot
--- outlive the tree it was read from.
---@return table stats
function M.attach(data)
    local stats = { files = 0, tuples = 0, regs = 0, edges = 0,
        unvalued = 0, unresolved = 0, refused = {}, by_ns = {}, rows = {} }
    local root = data and data.root
    if not root or root:match('^%w+://') then return stats end
    -- the RESULT decides, not the pcall: in nvim 0.11 language.add returns nil for a missing parser without raising,
    -- so `if not pcall(...)` never took this branch and the refusal below could not fire (CART-1075)
    local okp, loaded = pcall(vim.treesitter.language.add, 'erlang')
    if not (okp and loaded == true) then
        -- ⚠ NO PARSER IS NOT "NO REGISTRATIONS". Report it rather than
        -- returning a clean zero, which is the absence-as-silence class this
        -- repo keeps filing.
        stats.refused[#stats.refused + 1] = 'no erlang parser'
        return stats
    end
    local exact = xlang.def_index(data)

    -- the enclosing function of a node, for the edge's `from`
    local byfile = {}
    for _, n in ipairs(data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.file then
            byfile[n.file] = byfile[n.file] or {}
            table.insert(byfile[n.file], n)
        end
    end
    local at = require 'cartograph.at'
    local function enclosing(file, line)
        local best
        for _, n in ipairs(byfile[file] or {}) do
            local r = n.range
            local ok, sl = pcall(at.sl, r)
            local ok2, el = pcall(at.el, r)
            if ok and ok2 and sl and el and line >= sl and line <= el then
                -- innermost wins
                if not best or sl > select(2, pcall(at.sl, best.range)) then best = n end
            end
        end
        return best
    end

    local refEdge = {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end
    end

    for _, carrier in ipairs(M.CARRIERS) do
        local vocab, stamp = vocabulary(carrier.vocab)
        stats.stamp = stamp
        for _, n in ipairs(data.nodes) do
            if n.kind == 'module' and n.file and n.file:match('%.erl$') then
                local abs = root .. '/' .. n.file
                local fd = io.open(abs, 'r')
                local src = fd and fd:read('a')
                if fd then fd:close() end
                if src then
                    stats.files = stats.files + 1
                    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'erlang')
                    local tree = ok and parser:parse()[1]
                    if tree then
                        local found = {}
                        tuples_tagged(tree:root(), src, carrier.tag, found)
                        for _, els in ipairs(found) do
                            stats.tuples = stats.tuples + 1
                            local map = carrier.arities[#els]
                            if not map then
                                -- ⚠ AN UNDECLARED ARITY REFUSES. gen_mod declares
                                -- 4 and 5; a 6-tuple is a shape we have not read
                                -- the interpretation for, and guessing its
                                -- positions is how a template fabricates.
                                stats.refused[#stats.refused + 1] =
                                    ('%s:%d arity %d not declared')
                                        :format(n.file, select(1, els[1]:range()) + 1, #els)
                            else
                                local kname, ktype = element(els[map.key], src)
                                local fname, ftype = element(els[map.fn], src)
                                local line = select(1, els[1]:range())
                                -- ★ THE POSITIVE KIND REQUIREMENT (see `element`):
                                -- a REGISTRATION supplies a namespace macro and a
                                -- function atom. A `var` is the consumer's own
                                -- pattern; a type application is the declaration.
                                -- Both REFUSE with a reason rather than counting.
                                if ktype ~= 'macro_call_expr' or ftype ~= 'atom' then
                                    stats.notvalue = (stats.notvalue or 0) + 1
                                    if #stats.refused < 12 then
                                        stats.refused[#stats.refused + 1] =
                                            ('%s:%d not a value (key=%s fn=%s)')
                                                :format(n.file, line + 1,
                                                    tostring(ktype), tostring(ftype))
                                    end
                                    goto continue
                                end
                                local uri = vocab[kname]
                                local mname
                                if map.mod == 'context' then
                                    mname = n.file:match('([^/]+)%.erl$')
                                elseif map.mod then
                                    mname = element(els[map.mod], src)
                                end
                                local h = xlang.handler_by_module(exact, fname, mname)
                                if not uri then stats.unvalued = stats.unvalued + 1 end
                                if not h then stats.unresolved = stats.unresolved + 1 end
                                -- ★ THE KEY AND THE HANDLER ARE INDEPENDENT
                                -- FACTS, and each is recorded on its own. The
                                -- edge is a fact about THIS tree; the URI is a
                                -- fact about a library. Demanding both would
                                -- drop a real registration for want of a
                                -- vocabulary (the split xlang's own comment
                                -- makes for the call carrier).
                                if h then
                                    local from = enclosing(n.file, line)
                                    local fid = (from and from.id) or n.file
                                    local k = fid .. '\31' .. h
                                    if not refEdge[k] then
                                        local e = { from = fid, to = h, kind = 'ref',
                                            at = {}, xlang = true, erlreg = true }
                                        refEdge[k] = e
                                        data.edges[#data.edges + 1] = e
                                        stats.edges = stats.edges + 1
                                    end
                                end
                                stats.regs = stats.regs + 1
                                if uri then
                                    stats.by_ns[uri] = (stats.by_ns[uri] or 0) + 1
                                end
                                stats.rows[#stats.rows + 1] = {
                                    tag = carrier.tag, arity = #els,
                                    key = kname, uri = uri, fn = fname, mod = mname,
                                    file = n.file, line = line + 1, handler = h,
                                }
                                ::continue::
                            end
                        end
                    end
                end
            end
        end
    end
    data.erlreg = stats
    return stats
end

--- one line for a report
function M.summary(s)
    if not s or s.files == 0 then return nil end
    local nns = 0
    for _ in pairs(s.by_ns or {}) do nns = nns + 1 end
    return ('erlreg: %d registration(s) of %d tagged tuple(s) in %d file(s) — '
        .. '%d distinct namespace(s), %d handler edge(s)%s%s%s%s')
        :format(s.regs, s.tuples, s.files, nns, s.edges,
            (s.notvalue or 0) > 0 and (', %d tuple(s) were a PATTERN or a TYPE, not a value')
                :format(s.notvalue) or '',
            s.unvalued > 0 and (', %d key(s) with no vocabulary value'):format(s.unvalued) or '',
            s.unresolved > 0 and (', %d handler(s) unresolved'):format(s.unresolved) or '',
            #s.refused > 0 and (', %d refused: %s'):format(#s.refused,
                table.concat(s.refused, ' · ', 1, math.min(#s.refused, 3))) or '')
end

return M
