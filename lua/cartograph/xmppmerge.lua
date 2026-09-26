-- xmppmerge — MERGE ACROSS THE WIRE for XMPP: every client function that builds an IQ request, joined to the ejabberd
-- handler CLAUSE that accepts it (CART-0867, under CART-1087).
-- @langs any
-- (no grammar is read here: the inputs are stx.lua's element trees, xmppserver.lua's endpoint rows and the heads
-- expr.of derived, and the graphs' node/call records)
--
-- ★★★ MERGE IS NOT A NEW OPERATION, IT IS `unify ∘ compose` OVER ALIGNED KEYS (the correction on CART-0867; `join`
-- would keep only what the two sides SHARE — that is the payload derivation, the gate's direction). Three steps:
--   1. ALIGN. Both sides become terms in ONE positional encoding, the DECODED RECORD: the client's XML is decoded
--      through the codec spec exactly as xmpp's runtime decoder does (xmppspec: element+xmlns -> -xml entry, each
--      result slot filled from its attr / cdata / ref / sub_els source), and a handler's clause head IS a record
--      pattern (eo.heads). Record-field order is the shared position: xmppspec.check_fields found 0 arity and 0
--      name mismatches between the spec's result tuples and the compiler's records.
--   2. UNIFY (algebra `unify`, the MEET: the most general term that is an instance of both). Success binds holes
--      ACROSS THE WIRE — the handler's `?Node` to the client's `${node}` — and failure names the field and the clash.
--   3. COMPOSE `builds ; accepted-by` and project the wire element out: the edge client function -> handler clause.
--      Erlang tries clauses IN ORDER, so the clause a request reaches is the FIRST that unifies; later unifying
--      clauses are SHADOWED for it, and that is reported, not hidden.
--
-- ★★ WHAT IT REFUSES TO CLAIM. Several handlers registered under one namespace (disco#info: one per component) are
-- a CANDIDATE SET — routing picks by the `to` address, which a client template usually leaves as a hole — never one
-- picked. A request whose namespace has no registered endpoint is a named frontier ('no endpoint'): the MUC room
-- process dispatches its IQs itself (muc#owner/admin), a carrier this tree does not read yet. An unknown element, a
-- value behind a decoder (a jid in @to), an unresolved content hole: each becomes a HOLE, which unifies with
-- anything — so the join OVER-approximates what is accepted and never invents a rejection.
--
-- CLIENT ATTRIBUTION (CART-0958): a template's OWNER is the innermost function of the client graph whose range holds
-- it; a FRAGMENT built by one function and spliced into another's template (`${this.itemsEl()}`) is followed through
-- the client graph's resolved call at that hole (CART-0800's cross-function attribution, for this one shape).
local M = {}

local stx = require 'cartograph.stx'
local unpack = table.unpack or unpack
local XS = require 'cartograph.xmppspec'

local function A() return assert(require('cartograph.algebra').load()) end

-- ── values ────────────────────────────────────────────────────────────────────────────────────────────────────
-- one literal spelling for both sides: an atom's quotes, a string's quotes and a binary's <<"">> are syntax
local function norm_server(v, ty)
    if type(v) ~= 'string' then return tostring(v) end
    if ty == 'atom' then return (v:gsub("^'(.*)'$", '%1')) end
    if ty == 'string' then return (v:gsub('^"(.*)"$', '%1')) end
    return v
end

-- a decoder that changes the value's representation (a jid string -> #jid{}) makes a client literal incomparable
-- with a server pattern over the decoded value: such a literal becomes a hole. Enumerations and the lang check keep
-- the text.
-- ★ AN ABSENT ATTRIBUTE IS NOT "ABSENT" ON THE SERVER: the generated decoder fills it in. fxml_gen's rule, read off
-- the generated source (xmpp/src/*.erl, `decode_<xml>_attr_<name>(__TopXMLNS, undefined) -> V`): an explicit
-- default wins; else a REQUIRED one is a decode error (the request is invalid: 'absent', which only a variable
-- accepts); else one with a converting decoder -> `undefined`; else `<<>>`. The same for cdata; a single ref ->
-- `undefined`. ACCEPTED BY AN ORACLE: tools/xmppmerge.lua --check-absent compares this rule with every generated
-- clause (408 on xmpp 02893ce).
local function absent_value(src)
    local a = A()
    if src.default ~= nil and src.default ~= '$unset' then
        local d = tostring(src.default)
        d = d:match('^<<"(.*)">>$') or (d == '<<>>' and '') or d:gsub("^'(.*)'$", '%1')
        return a.lit(d)
    end
    if src.required == true or src.required == 'true' then return a.node('absent') end
    -- a CHECKER keeps the binary (xmpp_lang validates, it does not convert): absent stays <<>>. Found by the oracle
    -- (tools/xmppmerge.lua --check-absent): the first cut said `undefined` and the generated code disagreed on 15
    -- xml:lang / hreflang attributes out of 408.
    if src.dec and src.dec ~= '' and not src.dec:find('xmpp_lang', 1, true) then return a.lit('undefined') end
    return a.lit('')
end
M.absent_value = absent_value

local function opaque_decoder(dec)
    if not dec or dec == '' then return false end
    return not (dec:find('dec_enum', 1, true) or dec:find('xmpp_lang', 1, true))
end

-- ── the spec index: (element, xmlns) -> -xml entry names ────────────────────────────────────────────────────
local function index(spec)
    if spec._elidx then return spec._elidx end
    local idx = {}
    for _, name in ipairs(spec.order or {}) do
        local e = spec.entries[name]
        local xs = type(e.xmlns) == 'table' and e.xmlns or { e.xmlns or '' }
        for _, x in ipairs(xs) do
            local k = (e.element or '?') .. '\31' .. (x or '')
            local l = idx[k]; if not l then l = {}; idx[k] = l end
            l[#l + 1] = name
        end
    end
    spec._elidx = idx
    return idx
end

local function entries_for(spec, name, uri)
    local idx = index(spec)
    return idx[(name or '?') .. '\31' .. (uri or '')] or idx[(name or '?') .. '\31' .. ''] or {}
end

-- ── step 1a: the CLIENT side, an stx element decoded into a record term ─────────────────────────────────────
-- ctx = { rec, recs_by_id, holes = {name -> desc}, n = counter, splice = fn(hole) -> {rec...}, notes = {} }
local function fresh(ctx, desc)
    ctx.n = ctx.n + 1
    local h = 'C' .. ctx.n
    ctx.holes[h] = desc
    return A().hole(h)
end

local function hole_desc(rec, i)
    local h = rec and rec.holes and rec.holes[i]
    return h and ('${' .. (h.expr or '?'):gsub('%s+', ' ') .. '}') or '${?}'
end

-- the element children of `el` (text dropped), with content holes expanded where their fragment is known:
-- a nested template, a const bind, or (ctx.splice) a fragment reached through the client graph (a local binding, a
-- caller's argument, a called function's return). Several candidate fragments for one hole are ALTERNATIVES: the
-- one taken is ctx.choice[key] (default the first) and ctx.branch[key] counts them, so the caller can enumerate.
-- Returns the children and the content holes that stayed unknown: whether those can hold ELEMENTS depends on the
-- element's own slots, which only decode knows (a hole inside <value> is text).
local function children_of(el, rec, ctx)
    local out, unknown = {}, {}
    for _, c in ipairs(el.children or {}) do
        if c.hole then
            local h = rec.holes[c.hole]
            local recs = {}
            for _, nid in ipairs(h and h.nested or {}) do recs[#recs + 1] = ctx.by_id[nid] end
            if h and h.bind then recs[#recs + 1] = ctx.by_id[h.bind] end
            if #recs == 0 and ctx.splice and h then
                local alts = ctx.splice(rec, h) or {}
                if #alts > 0 then
                    local key = tostring(rec.id) .. ':' .. tostring(c.hole) .. '@' .. tostring(ctx.file)
                    ctx.branch = ctx.branch or {}
                    ctx.branch[key] = #alts
                    recs = { alts[(ctx.choice and ctx.choice[key]) or 1] }
                end
            end
            if #recs == 0 then unknown[#unknown + 1] = h end
            for _, r in ipairs(recs) do
                if r and r.ok then
                    for _, root in ipairs(r.roots or {}) do
                        if root.name then out[#out + 1] = { el = root, rec = r, inherit = el.ns and el.ns.uri } end
                        if root.hole then unknown[#unknown + 1] = r.holes[root.hole] end
                    end
                else unknown[#unknown + 1] = h end
            end
        elseif c.name then
            out[#out + 1] = { el = c, rec = rec }
        elseif c.name_hole then
            unknown[#unknown + 1] = rec.holes[c.name_hole]
        end
    end
    return out, unknown
end

local function text_of(el, rec, ctx)
    local parts, hole = {}, false
    for _, c in ipairs(el.children or {}) do
        if c.text then parts[#parts + 1] = c.text elseif c.hole then hole = c.hole end
    end
    if hole then return fresh(ctx, hole_desc(rec, hole)) end
    local s = table.concat(parts):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end
    return A().lit(s)
end

local decode
local ENVELOPE = { from = true, to = true, id = true, ['xml:lang'] = true }

local function cons_list(items, tail)
    local a = A()
    local t = tail or a.node('nil')
    for i = #items, 1, -1 do t = a.node('cons', items[i], t) end
    return t
end

-- decode one element: -> term, entry name | nil
function decode(el, rec, ctx, inherit)
    local a = A()
    local uri = (el.ns and el.ns.uri) or inherit
    local names = entries_for(ctx.spec, el.name, uri)
    if #names == 0 then
        ctx.notes.unknown_element = (ctx.notes.unknown_element or 0) + 1
        return fresh(ctx, ('<%s xmlns="%s"> (no -xml)'):format(tostring(el.name), tostring(uri))), nil
    end
    if #names > 1 then ctx.notes.variants = (ctx.notes.variants or 0) + 1 end
    local E = ctx.spec.entries[names[1]]
    local kids, unknown = children_of(el, rec, ctx)
    -- an unknown content hole can hide CHILD ELEMENTS only if this element has a slot fed by children
    local takes_children = (#(E.refs or {}) > 0)
    for _, f in ipairs((E.result and E.result.fields) or {}) do if f == '$_els' then takes_children = true end end
    local open = takes_children and #unknown > 0
    if open and ctx.unknown_holes then
        for _, h in ipairs(unknown) do
            ctx.unknown_holes[#ctx.unknown_holes + 1] = ('%s [%s] %s:%d'):format(((h and h.expr) or '?'):gsub('%s+', ' '),
                tostring(h and h.fill), tostring(ctx.file), (h and h.line) or 0)
        end
    end
    local claimed = {}
    -- the value of one label, by the generator's own source rule (cdata, then attrs, then refs)
    local function value_of(label)
        local srcs = XS.label_sources(E, label) or {}
        local s1 = srcs[1]
        if not s1 or s1.kind == 'unknown' or s1.kind == 'ignored' then return fresh(ctx, label .. ' (not on the wire)') end
        if s1.kind == 'attr' then
            -- ★ A STANZA'S ENVELOPE IS NOT THE CLIENT'S TO GIVE: the server stamps `from` on everything it receives
            -- (RFC 6120 §8.1.2.1), an absent `to` means the user's own account, strophe adds `id`, and xml:lang
            -- defaults from the stream. So on a top-level iq/message/presence those four are holes, never an
            -- absent value a head could be rejected against.
            if ctx.top == el and ENVELOPE[s1.name] then return fresh(ctx, '@' .. s1.name .. ' (stanza envelope)') end
            local at = el.attr and el.attr[s1.name]
            if not at then return absent_value(s1) end
            if at.hole or at.parts then
                return fresh(ctx, '@' .. s1.name .. '=' .. (at.hole and hole_desc(rec, at.hole) or 'text+holes'))
            end
            if opaque_decoder(s1.dec) then return fresh(ctx, '@' .. s1.name .. ' (decoded by ' .. tostring(s1.dec) .. ')') end
            return a.lit(tostring(at.value))
        end
        if s1.kind == 'cdata' then return text_of(el, rec, ctx) or absent_value(s1) end
        if s1.kind == 'els' then
            local items = {}
            for i, k in ipairs(kids) do if not claimed[i] then items[#items + 1] = (decode(k.el, k.rec, ctx, k.inherit or uri)) end end
            return cons_list(items, open and fresh(ctx, 'unseen children (a content hole)') or nil)
        end
        if s1.kind == 'ref' then
            local items, many = {}, false
            for _, src in ipairs(srcs) do
                if src.kind == 'ref' then
                    if src.max ~= 1 then many = true end
                    local R = ctx.spec.entries[src.name]
                    for i, k in ipairs(kids) do
                        if not claimed[i] and R and k.el.name == R.element then
                            local kuri = (k.el.ns and k.el.ns.uri) or k.inherit or uri
                            local rx = type(R.xmlns) == 'table' and R.xmlns or { R.xmlns }
                            local okns = R.xmlns == nil
                            for _, x in ipairs(rx) do if x == kuri then okns = true end end
                            if okns then claimed[i] = true; items[#items + 1] = (decode(k.el, k.rec, ctx, kuri)) end
                        end
                    end
                end
            end
            if many then return cons_list(items, open and fresh(ctx, 'unseen ' .. label .. ' children') or nil) end
            if #items >= 1 then return items[1] end
            return open and fresh(ctx, 'unseen ' .. label) or a.lit('undefined')
        end
        return fresh(ctx, label .. ' (' .. tostring(s1.kind) .. ')')
    end
    local R = E.result or {}
    if R.kind == 'record' or R.kind == 'tuple' then
        -- refs claim their children first, sub_els take the rest: evaluate the non-els slots before the els slot
        local slots, elsat = {}, {}
        for i, f in ipairs(R.fields or {}) do
            if type(f) == 'table' and f.const ~= nil then slots[i] = a.lit(norm_server(f.const, 'atom'))
            elseif f == '$_els' then elsat[#elsat + 1] = i
            else slots[i] = value_of(f) end
        end
        for _, i in ipairs(elsat) do slots[i] = value_of('$_els') end
        local k = R.kind == 'record' and ('rec:' .. R.record) or ('tuple:' .. names[1])
        return a.node(k, unpack(slots, 1, #(R.fields or {}))), names[1]
    end
    if R.kind == 'label' then return value_of(R.label) or a.node('absent'), names[1] end
    if R.kind == 'const' then return a.lit(norm_server(R.const, 'atom')), names[1] end
    return fresh(ctx, 'result kind ' .. tostring(R.kind)), names[1]
end

-- ── step 1b: the SERVER side, a clause head's facts for one argument as a record pattern term ───────────────
local function pattern(facts, spec, S)
    local a = A()
    local root = {}
    local function at(node, step)
        if step.rec and step.field then
            node.rec = node.rec or step.rec
            node.fields = node.fields or {}
            local c = node.fields[step.field]; if not c then c = {}; node.fields[step.field] = c end
            return c
        elseif step.rec then
            node.rec = node.rec or step.rec
            return nil
        elseif step.elem then
            node.list = node.list or { items = {}, len = step.len, closed = step.closed }
            local c = node.list.items[step.elem]; if not c then c = {}; node.list.items[step.elem] = c end
            return c
        elseif step.head or step.tail then
            node.cons = node.cons or {}
            local key = step.head and 'head' or 'tail'
            local c = node.cons[key]; if not c then c = {}; node.cons[key] = c end
            return c
        elseif step.tuple then
            node.tuple = node.tuple or { arity = step.arity, items = {} }
            local c = node.tuple.items[step.tuple]; if not c then c = {}; node.tuple.items[step.tuple] = c end
            return c
        end
        node.opaque = true
        return nil
    end
    for _, f in ipairs(facts) do
        local node = root
        for _, st in ipairs(f.path or {}) do
            if not node then break end
            node = at(node, st)
        end
        if node then
            if f.name then node.var = node.var or f.name
            elseif f.value ~= nil then node.value = norm_server(f.value, f.ty) end
        end
    end
    local function fresh_s() S.n = S.n + 1; return a.hole('S#' .. S.n) end
    local function conv(node)
        if not node then return fresh_s() end
        if node.value ~= nil then return a.lit(node.value) end
        if node.rec then
            local names = XS.record_fields(spec, node.rec)
            if not names then
                S.notes.unknown_record = (S.notes.unknown_record or 0) + 1
                S.notes.unknown_records = S.notes.unknown_records or {}
                S.notes.unknown_records[node.rec] = (S.notes.unknown_records[node.rec] or 0) + 1
                return fresh_s()
            end
            local kids = {}
            for i, fname in ipairs(names) do kids[i] = conv(node.fields and node.fields[fname]) end
            return a.node('rec:' .. node.rec, unpack(kids, 1, #names))
        end
        if node.list then
            local items = {}
            local n = node.list.len or 0
            for i = 1, n do items[i] = conv(node.list.items[i]) end
            return cons_list(items, not node.list.closed and fresh_s() or nil)
        end
        if node.cons then
            return a.node('cons', conv(node.cons.head), conv(node.cons.tail))
        end
        if node.tuple then
            local items = {}
            for i = 1, node.tuple.arity or 0 do items[i] = conv(node.tuple.items[i]) end
            return a.node('tuple', unpack(items, 1, node.tuple.arity or 0))
        end
        if node.var then return a.hole('S:' .. node.var) end -- a name repeated in one head is ONE hole: a match
        return fresh_s()
    end
    return conv(root)
end

-- which argument of a head carries the request: the one whose paths start in #iq, else the only argument
local function request_arg(h)
    local n = h.arity or 0
    for _, f in ipairs(h.facts or {}) do
        local s1 = f.path and f.path[1]
        if (s1 and s1.rec == 'iq') or f.record == 'iq' then return f.arg end
    end
    if n == 1 then return 1 end
    return nil
end

-- a unify failure's path ("6.1.1") as field names, read off the client term
local function path_names(term, at, spec)
    if not at or at == '' then return '' end
    local out, t = {}, term
    for s in tostring(at):gmatch('[^%./]+') do
        local i = tonumber(s)
        if not (t and t.kids and i and t.kids[i]) then out[#out + 1] = s; break end
        local k = t.k or ''
        if k:sub(1, 4) == 'rec:' then
            local names = XS.record_fields(spec, k:sub(5))
            out[#out + 1] = names and names[i] or s
        elseif k == 'cons' then out[#out + 1] = (i == 1) and '[]' or '|'
        else out[#out + 1] = s end
        t = t.kids[i]
    end
    return table.concat(out, '.')
end

local function show(term, ctx)
    if not term then return '?' end
    if term.k == 'hole' then return ctx.holes[term.h] or ('?' .. term.h) end
    if term.k == 'lit' then return ('%q'):format(tostring(term.v)) end
    return A().show(term)
end

-- ── the client graph: owners and cross-function fragments ───────────────────────────────────────────────────
local function owner_index(cdata)
    local by_file = {}
    for _, n in ipairs(cdata.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file and n.range then
            local l = by_file[n.file]; if not l then l = {}; by_file[n.file] = l end
            l[#l + 1] = n
        end
    end
    -- innermost first: the owner, then each function enclosing it
    -- `line` is 1-based (stx records, hole lines); node ranges are 0-based rows
    local function chain(file, line)
        line = line - 1
        local l = {}
        for _, n in ipairs(by_file[file] or {}) do
            if n.range.start.line <= line and line <= n.range['end'].line then l[#l + 1] = n end
        end
        table.sort(l, function (x, y)
            local sx, sy = x.range.start.line, y.range.start.line
            if sx ~= sy then return sx > sy end
            return x.range['end'].line < y.range['end'].line
        end)
        return l
    end
    return function (file, line) return chain(file, line)[1] end, chain
end

-- how a top-level fragment is held: the name it is bound to (`const items_el = [cond ?] stx…`) and whether it is
-- RETURNED. Read off the statement text before the template, back to the last `;`, `{` or `}`: the binding syntax
-- is the JS declaration itself, and a template that is neither is only reachable where it is written.
-- `src` must be MASKED (mask_templates): a `}` inside an earlier template's `${…}` would otherwise end the statement
-- (`const items_el = v2 ? stx`<item id="${id}"/>` : stx`…`` lost its second alternative that way).
local function mask_templates(src, recs)
    if not src then return nil end
    -- the outermost ranges only (a nested template lies inside its parent's), in order
    local rs = {}
    for _, r in ipairs(recs) do if r.s and r.e then rs[#rs + 1] = { r.s, r.e } end end
    table.sort(rs, function (x, y) return x[1] < y[1] end)
    local out, pos = {}, 0
    for _, r in ipairs(rs) do
        if r[1] >= pos then
            out[#out + 1] = src:sub(pos + 1, r[1])
            out[#out + 1] = (src:sub(r[1] + 1, r[2]):gsub('[^\n]', ' '))
            pos = r[2]
        elseif r[2] > pos then
            out[#out + 1] = (src:sub(pos + 1, r[2]):gsub('[^\n]', ' '))
            pos = r[2]
        end
    end
    out[#out + 1] = src:sub(pos + 1)
    return table.concat(out)
end

local function holding(src, rec)
    if not (src and rec.s) then return nil, false end
    local pre = src:sub(math.max(1, rec.s - 400), rec.s)
    pre = pre:match('[;{}]([^;{}]*)$') or pre
    if pre:match('^%s*return[%s%(]') or pre:match('%f[%w_$]return%s*$') then return nil, true end
    local name
    for n, rest in pre:gmatch('([%w_$]+)%s*=([^=>][^=]*)') do name = n; local _ = rest end
    if not name then name = pre:match('([%w_$]+)%s*=%s*$') end
    return name, false
end

--- THE MERGE. opts = { client = <dir of the client sources>, server = <server root>, spec = <xmpp_codec.spec> }
--- -> { rows = { row… }, stats }
---   row = { file, line, owner = client node id | nil, uri, type, verdict = 'accepted' | 'rejected' | 'no endpoint'
---           | 'no request', candidates = { { handler, mod, fn, component, clause = k | nil, shadowed = {k…},
---           rejected = { {clause, why, at}… }, binds = { var -> client value text } }… } }
function M.merge(opts)
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local X = require 'cartograph.xmppserver'
    local spec = assert(XS.read(opts.spec))
    -- the records the COMPILER sees through xmpp.hrl (jid, the generated codec records, the hand ones): a head
    -- destructuring #jid{} must meet a record the spec itself never declares
    local hrl = opts.hrl or (vim.fn.fnamemodify(opts.spec, ':h:h') .. '/include/xmpp.hrl')
    if vim.fn.filereadable(hrl) == 1 then
        local sc = require('cartograph.erlrecords').new {}:scope(hrl)
        if sc then XS.attach_records(spec, sc.records) end
    end
    local stats = { requests = 0, owned = 0, accepted = 0, rejected = 0, no_endpoint = 0, candidates = 0,
        fragments = 0, fragments_spliced = 0, notes = {}, missing_uri = {}, reasons = {} }

    -- the CLIENT: templates and the graph they live in (the graph for attribution only; never ingested)
    local scan = stx.scan(opts.client, { all = opts.all })
    local cdata = ts.extract(opts.client)
    local owner, owner_chain = owner_index(cdata)
    local argv = require 'cartograph.argv'
    local srcs = {}
    local function src_of(rel)
        if srcs[rel] == nil then
            local fd = io.open(opts.client .. '/' .. rel, 'rb')
            srcs[rel] = fd and fd:read('a') or false
            if fd then fd:close() end
        end
        return srcs[rel] or nil
    end
    local callers = {}
    for _, c in ipairs(cdata.calls or {}) do
        if c.to then local l = callers[c.to]; if not l then l = {}; callers[c.to] = l end; l[#l + 1] = c end
    end
    local calls_by_file = {}
    for _, c in ipairs(cdata.calls or {}) do
        local l = calls_by_file[c.file]; if not l then l = {}; calls_by_file[c.file] = l end
        l[#l + 1] = c
    end
    -- top-level fragments by the function that builds them: bound to a name there, returned from it, or written
    -- inline (an argument at a call site)
    local by_name, returned, at_line = {}, {}, {}
    local function add(t, k1, k2, r)
        local a1 = t[k1]; if not a1 then a1 = {}; t[k1] = a1 end
        if k2 == nil then a1[#a1 + 1] = r; return end
        local a2 = a1[k2]; if not a2 then a2 = {}; a1[k2] = a2 end
        a2[#a2 + 1] = r
    end
    for _, f in ipairs(scan.files) do
        for _, r in ipairs(f.recs) do
            -- built apart: a top-level template that is not a stanza (a lone <item/>, or several roots)
            if not r.parent and not r.bound_by and r.ok and (r.fragment or (r.tree and not stx.STANZAS[r.tree.name])) then
                stats.fragments = stats.fragments + 1
                local o = owner(f.rel, r.line)
                f.masked = f.masked or mask_templates(src_of(f.rel), f.recs) or false
                local name, ret = holding(f.masked or nil, r)
                if o then
                    if name then add(by_name, o.id, name, r)
                    elseif ret then add(returned, o.id, nil, r)
                    else add(at_line, f.rel, r.line - 1, r) end -- keyed by 0-based row, as call records are
                    if name or ret then stats.fragments_held = (stats.fragments_held or 0) + 1 end
                end
            end
        end
    end

    -- the SERVER: endpoints and heads (the server graph IS ingested: expr.of reads through the store)
    local sdata = ts.extract(opts.server)
    store.ingest(sdata)
    local endpoints = X.endpoints(sdata)
    -- ★ THE SERVER'S POINT OF VIEW, recorded while the client's is computed (one pass, two readings): every
    -- registered handler with the namespaces it serves (handler -> namespaces, the endpoint relation inverted),
    -- and per clause the requests that REACH it, the ones it would accept but an earlier clause takes
    -- (SHADOWED), and the ones it REJECTS, with the field.
    local server = {}
    local function srv(e)
        local h = server[e.handler]
        if not h then
            h = { handler = e.handler, mod = e.mod, fn = e.fn, uris = {}, carriers = {}, clauses = {} }
            server[e.handler] = h
        end
        if e.uri and not vim.tbl_contains(h.uris, e.uri) then h.uris[#h.uris + 1] = e.uri end
        h.carriers[e.carrier] = true
        return h
    end
    local function clause_slot(h, k)
        local c = h.clauses[k]
        if not c then c = { reached = {}, shadowed = {}, rejected = {} }; h.clauses[k] = c end
        return c
    end
    for _, e in ipairs(endpoints) do if e.handler then srv(e) end end
    local by_uri, reads_cache, requested = {}, {}, {}
    for _, e in ipairs(endpoints) do
        if e.uri and e.handler then
            local l = by_uri[e.uri]; if not l then l = {}; by_uri[e.uri] = l end
            l[#l + 1] = e
        end
    end
    local function reads(h)
        if reads_cache[h] == nil then reads_cache[h] = X.reads(store, h) or false end
        return reads_cache[h] or nil
    end

    local a = A()
    local rows = {}
    for _, f in ipairs(scan.files) do
        local by_id = {}
        for _, r in ipairs(f.recs) do by_id[r.id] = r end
        local spliced_here = {}
        local function took(list, how)
            for _, fr in ipairs(list) do
                if not spliced_here[fr] then
                    spliced_here[fr] = true
                    stats.fragments_spliced = stats.fragments_spliced + 1
                    stats.spliced_by = stats.spliced_by or {}
                    stats.spliced_by[how] = (stats.spliced_by[how] or 0) + 1
                end
            end
            return list
        end
        -- ★ THE THREE WAYS A FRAGMENT REACHES A HOLE through the client graph (CART-0800's attribution, for XML):
        --   a LOCAL binding in an enclosing function, a PARAMETER (every resolved caller's argument: a name bound in
        --   the caller, or a template written at the call), a CALL (the fragments its resolved target returns).
        local function splice(_, h)
            if not h or not h.expr then return nil end
            local expr = h.expr:gsub('^%s+', ''):gsub('%s+$', '')
            local fns = owner_chain(f.rel, h.line or 0)
            if expr:match('^[%a_$][%w_$]*$') then
                for _, fn in ipairs(fns) do
                    local l = by_name[fn.id] and by_name[fn.id][expr]
                    if l then return took(l, 'local') end
                end
                for _, fn in ipairs(fns) do
                    for i, p in ipairs(fn.params or {}) do
                        if p == expr then
                            local alts = {}
                            for _, c in ipairs(callers[fn.id] or {}) do
                                local a = argv.at(c, i + (c.method and 1 or 0))
                                if a and a.k == 'local' and a.name and by_name[c.fn] and by_name[c.fn][a.name] then
                                    for _, r in ipairs(by_name[c.fn][a.name]) do alts[#alts + 1] = r end
                                elseif a and at_line[c.file] and at_line[c.file][c.line] then
                                    for _, r in ipairs(at_line[c.file][c.line]) do alts[#alts + 1] = r end
                                end
                            end
                            if #alts > 0 then return took(alts, 'parameter') end
                            return nil
                        end
                    end
                end
                return nil
            end
            local name = expr:match('([%w_$]+)%s*%(')
            if not name then return nil end
            local lines = select(2, h.expr:gsub('\n', '')) or 0
            for _, c in ipairs(calls_by_file[f.rel] or {}) do
                -- call records carry 0-based rows, hole lines are 1-based
                local row0 = (h.line or 1) - 1
                if c.callee == name and c.line >= row0 and c.line <= row0 + lines and c.to and returned[c.to] then
                    return took(returned[c.to], 'call')
                end
            end
            return nil
        end
        for _, r in ipairs(f.recs) do
            local top = r.ok and r.tree
            local ty = top and top.attr and top.attr['type'] and top.attr['type'].value
            if top and top.name == 'iq' and not r.parent and not r.bound_by and (ty == 'get' or ty == 'set') then
                stats.requests = stats.requests + 1
                stats.unknown_holes = stats.unknown_holes or {}
                local ctx = { spec = spec, by_id = by_id, holes = {}, n = 0, notes = stats.notes, splice = splice,
                    unknown_holes = stats.unknown_holes, file = f.rel }
                local o = owner(f.rel, r.line)
                if o then stats.owned = stats.owned + 1 end
                -- the child that routes the IQ: its namespace is the registration key
                local kids = children_of(top, r, ctx)
                ctx.branch = nil
                local child = kids[1]
                local uri = child and ((child.el.ns and child.el.ns.uri) or child.inherit)
                local row = { file = f.rel, line = r.line, owner = o and o.id, uri = uri, type = ty, candidates = {} }
                if uri then requested[uri] = true end
                rows[#rows + 1] = row
                local cands = uri and by_uri[uri] or nil
                if not cands then
                    row.verdict = uri and 'no endpoint' or 'no request'
                    stats.no_endpoint = stats.no_endpoint + 1
                    if uri then stats.missing_uri[uri] = (stats.missing_uri[uri] or 0) + 1 end
                else
                    ctx.top = top
                    local cterm = decode(top, r, ctx)
                    -- ★ AN UNDECODABLE REQUEST IS UNREAD, NOT ACCEPTED: its term would be one hole, and a hole
                    -- unifies with every clause of every candidate — the most confident answer from the least
                    -- evidence. (converse always sets xmlns on a top stanza; strophe refuses one without it.)
                    if cterm.k == 'hole' then
                        row.verdict = 'unread'
                        row.why = ctx.holes[cterm.h]
                        stats.unread = (stats.unread or 0) + 1
                        goto next_request
                    end
                    -- several candidate fragments for a hole are ALTERNATIVES: decode every combination (capped)
                    local terms = { cterm }
                    if ctx.branch and next(ctx.branch) then
                        local keys = {}
                        for k in pairs(ctx.branch) do keys[#keys + 1] = k end
                        table.sort(keys)
                        local branch = ctx.branch
                        local combos, total = { {} }, 1
                        for _, k in ipairs(keys) do
                            local nxt = {}
                            for _, cmb in ipairs(combos) do
                                for i = 1, branch[k] do
                                    if #nxt < 16 then
                                        local c2 = {}
                                        for kk, vv in pairs(cmb) do c2[kk] = vv end
                                        c2[k] = i
                                        nxt[#nxt + 1] = c2
                                    end
                                end
                            end
                            combos = nxt
                            total = total * branch[k]
                        end
                        terms = {}
                        for _, cmb in ipairs(combos) do
                            ctx.choice = cmb
                            terms[#terms + 1] = decode(top, r, ctx)
                        end
                        ctx.choice = nil
                        row.alternatives = total
                        if total > 16 then row.alternatives_capped = true; stats.capped = (stats.capped or 0) + 1 end
                    end
                    local any = false
                    local seen_h = {}
                    for _, e in ipairs(cands) do
                      if not seen_h[e.handler] then
                        seen_h[e.handler] = true
                        stats.candidates = stats.candidates + 1
                        local cand = { handler = e.handler, mod = e.mod, fn = e.fn, component = e.component, shadowed = {}, rejected = {} }
                        row.candidates[#row.candidates + 1] = cand
                        local rd = reads(e.handler)
                        for k, h in ipairs(rd and rd.heads or {}) do
                            local ai = request_arg(h)
                            local facts = {}
                            for _, fact in ipairs(h.facts or {}) do if fact.arg == ai then facts[#facts + 1] = fact end end
                            local S = { n = 0, notes = stats.notes }
                            local sterm = ai and pattern(facts, spec, S) or a.hole('S#any')
                            local U, why, at
                            for _, ct in ipairs(terms) do
                                U, why, at = a.unify(a.template(ct), a.template(sterm))
                                if U then cterm = ct; break end
                            end
                            if U then
                                local sh = server[e.handler]
                                if cand.clause then
                                    cand.shadowed[#cand.shadowed + 1] = k
                                    if sh then table.insert(clause_slot(sh, k).shadowed, row) end
                                else
                                    cand.clause = k
                                    if sh then table.insert(clause_slot(sh, k).reached, row) end
                                    cand.binds = {}
                                    for g, t in pairs(U.right or {}) do
                                        if g:sub(1, 2) == 'S:' then
                                            local v = t
                                            -- a server name bound to a client hole reads as the client's expression
                                            if v.k == 'hole' and U.left then
                                                for ch, ct in pairs(U.left) do if ct.k == 'hole' and ct.h == v.h then v = a.hole(ch) end end
                                            end
                                            -- a whole record bound to a name (`#iq{} = IQ`) reads as its record, not its dump
                                            cand.binds[g:sub(3)] = (v.kids and v.k) or show(v, ctx)
                                        end
                                    end
                                end
                            else
                                local where = path_names(cterm, at, spec)
                                cand.rejected[#cand.rejected + 1] = { clause = k, why = why, at = where }
                                if server[e.handler] then
                                    table.insert(clause_slot(server[e.handler], k).rejected, { row = row, why = why, at = where })
                                end
                                local key = (where ~= '' and where or '(top)') .. ': ' .. tostring(why):gsub('"[^"]*"', '"…"')
                                stats.reasons[key] = (stats.reasons[key] or 0) + 1
                            end
                        end
                        if cand.clause then any = true end
                      end
                    end
                    row.verdict = any and 'accepted' or 'rejected'
                    if any then stats.accepted = stats.accepted + 1 else stats.rejected = stats.rejected + 1 end
                end
                ::next_request::
            end
        end
    end
    -- every clause of every registered handler gets a slot, the unreached ones included, with the reason
    for h, rec in pairs(server) do
        local rd = reads(h)
        rec.nclauses = rd and #(rd.heads or {}) or 0
        rec.heads = rd and rd.heads or {}
        local asked = false
        for _, u in ipairs(rec.uris) do if requested[u] then asked = true end end
        rec.asked = asked
        for k = 1, rec.nclauses do
            local c = clause_slot(rec, k)
            if #c.reached > 0 then c.status = 'reached'
            elseif not asked then c.status = 'no request to its namespace'
            elseif #c.shadowed > 0 then c.status = 'shadowed'
            elseif #c.rejected > 0 then c.status = 'every request rejected'
            else c.status = 'not tried' end
        end
    end
    return { rows = rows, stats = stats, server = server }
end

-- exported for the spec
M._decode = function (el, rec, spec, by_id)
    local ctx = { spec = spec, by_id = by_id or {}, holes = {}, n = 0, notes = {} }
    return decode(el, rec, ctx), ctx
end
M._pattern = function (facts, spec) return pattern(facts, spec, { n = 0, notes = {} }) end

return M
