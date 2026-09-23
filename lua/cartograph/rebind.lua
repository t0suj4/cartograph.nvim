-- rebind.lua — WHICH REFERENCES DID THIS EDIT RE-POINT (CART-1017, CART-1030).
--
-- ── WHY IT EXISTS: A KERNEL RENAME WAS WRONG IN 7 OF 7 MEMBERS AND PARSED IN 7 OF 7 ──
-- Measured 2026-09-23 on the seven fixpoint loops folded to one template: `A.rewrite` of the
-- kernel's `changed` -> `dirty` renamed ONE of each member's three occurrences. The other two
-- sat in hole VALUES, which a template edit carries unchanged, and the declaration sat
-- OUTSIDE the unit. Every member still parsed, so nothing downstream of a parse check
-- could see it. A first-order template is not a scope.
--
-- ── WHAT IT CHECKS: BINDING, BEFORE AGAINST AFTER, OVER THE WHOLE FILE ──────────
-- Both texts are resolved by the algebra's Lua scope graph (through `boundat`, whose
-- offsets come from the lossless reader). Occurrences are paired across the edit: lines
-- outside the diff's hunks pair by column, and inside a hunk by a diff of its TOKENS, with an
-- equal-count changed run paired positionally as a SUBSTITUTION. Then per pair:
--   KEPT (same name, not edited)     its binder must be the same binder after the edit —
--                                    else CAPTURED. Never intended, and invisible to the
--                                    author, because the token they would look at did not change.
--   SUBSTITUTED, local -> unbound    UNBOUND: a name that read a local now reads a global
--                                    or nothing. This is the kernel-rename failure; the
--                                    refusal counts the siblings that kept the old name.
--   SUBSTITUTED, anything else       RETARGETED (reported): `print` -> `log`, `a` -> `b` is
--                                    what an edit is FOR. A substitution that follows its
--                                    renamed declaration is RENAMED, which is consistent.
--   unpaired after the edit          INTRODUCED (reported); a new free name is listed.
--
-- ⚠ WHY THE WHOLE FILE AND NOT THE EDITED UNIT: the unit is not a scope. The binder of
-- `changed` is a line above the loop, and a `local` inserted into a block captures the
-- references AFTER the unit. Both are only visible from the enclosing chunk.
-- ⚠ MOVES NEED ORIGINS. An inline or an extraction relocates text, and a diff cannot pair
-- a token with its moved self. The verb that moved it passes `opts.origins` (see `pair`),
-- and those tokens pair with their source; without origins a move is unchecked text.
-- ⚠ LUA-ONLY, because `boundat` is: another language returns nil and the reason.

local M = {}

local B = require 'cartograph.boundat'

--- Every lexical occurrence in `src` with its binder.
--- A binder is `{ local = <decl offset> }`, `{ lib = name }`, `{ free = name }` or
--- `{ ambiguous = name }`. Field references (`t.x`) are not names and are left out.
--- @return table|nil idx { occ = { {off, name, kind='ref'|'decl', binder} } ascending }, string|nil why
function M.index(src, file)
    local h, why = B.of(src, file)
    if not h then return nil, why end
    local G, A = h.G, h.A
    local occ = {}
    for id, r in pairs(G.refs or {}) do
        local off = h.ref_off[id]
        if off and r.kind ~= 'field' and r.kind ~= 'module' then
            local R = A.resolve(G, id)
            local binder
            if R.absent then binder = { free = r.name }
            elseif R.ambiguous then binder = { ambiguous = r.name }
            else
                local did = R.entries[1].decl
                local d = G.decls[did]
                local doff = h.decl_off[did]
                if doff then binder = { ['local'] = doff }
                else binder = { lib = d and d.name or r.name } end
            end
            occ[#occ + 1] = { off = off, name = r.name, kind = 'ref', binder = binder }
        end
    end
    for id, d in pairs(G.decls or {}) do
        local off = h.decl_off[id]
        if off then occ[#occ + 1] = { off = off, name = d.name, kind = 'decl' } end
    end
    table.sort(occ, function (x, y)
        if x.off ~= y.off then return x.off < y.off end
        return x.kind < y.kind
    end)
    return { occ = occ, src = src }
end

-- ── the pairing ───────────────────────────────────────────────────────────────
local function line_starts(s)
    local st = { 0 }
    for i = 1, #s do if s:byte(i) == 10 then st[#st + 1] = i end end
    return st
end
local function line_of(st, off)
    local lo, hi = 1, #st
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if st[mid] <= off then lo = mid else hi = mid - 1 end
    end
    return lo -- 1-based
end

-- ⚠ INSIDE A HUNK THE PAIRING IS A TOKEN DIFF, NOT A MATCH ON NAMES. The first cut paired
-- same-named occurrences by ORDER (an LCS on names), and two different locals called `x` on
-- one edited line were paired crosswise: deleting the inner `print(x)` of
-- `do local x = 2 print(x) end print(x)` matched the surviving OUTER `x` with the deleted
-- inner one and reported a capture. Diffing the TOKENS keeps each occurrence at its own
-- position: an unchanged token pairs with its counterpart, and only the changed runs pair
-- positionally (equal counts: a substitution; unequal: nothing is paired there).
local function tokens(s, base)
    local out, i = {}, 1
    while i <= #s do
        local x, y = s:find('^[%a_][%w_]*', i)
        if not x then x, y = s:find('^%s+', i) end
        if not x then x, y = i, i end
        out[#out + 1] = { off = base + x - 1, text = s:sub(x, y) }
        i = y + 1
    end
    return out
end
local function as_lines(toks)
    local t = {}
    for k, tk in ipairs(toks) do t[k] = (tk.text:gsub('\n', '\1')) end
    return table.concat(t, '\n') .. '\n'
end

-- pair the occurrences of one line hunk: before text [a0, a1), after [b0, b1) (byte offsets)
local function pair_hunk(A, Bx, a0, a1, b0, b1, at_a, at_b, out)
    local ta = tokens(A.src:sub(a0 + 1, a1), a0)
    local tb = tokens(Bx.src:sub(b0 + 1, b1), b0)
    if #ta == 0 or #tb == 0 then return end -- a pure insertion or deletion pairs nothing
    -- ⚠ AN OFFSET HOLDS A LIST: `function M.f` puts the declaration of `f` and the reference
    -- `M` at one byte (1526 of 164880 occurrences here). Keyed by offset alone the ref was
    -- dropped, and a capture of `M` on an edited line went unseen. Pairs match by KIND.
    local function occ_in(at, toks, i, j) -- occurrences starting at tokens i..j, in order
        local r = {}
        for k = i, j do
            for _, o in ipairs(at[toks[k].off] or {}) do
                if not (o.moved or o.origin_paired) then r[#r + 1] = o end
            end
        end
        return r
    end
    local function kept(i, j)
        local la, lb = at_a[ta[i].off] or {}, at_b[tb[j].off] or {}
        for _, oa in ipairs(la) do
            for _, ob in ipairs(lb) do
                if oa.kind == ob.kind and not (oa.moved or ob.origin_paired) then
                    out[#out + 1] = { a = oa, b = ob }; break
                end
            end
        end
    end
    local hunks = vim.diff(as_lines(ta), as_lines(tb), { result_type = 'indices' }) or {}
    local i, j = 1, 1
    for _, hk in ipairs(hunks) do
        local x0, xc, y0, yc = hk[1], hk[2], hk[3], hk[4]
        local xf = xc == 0 and x0 + 1 or x0
        local yf = yc == 0 and y0 + 1 or y0
        while i < xf do kept(i, j); i, j = i + 1, j + 1 end
        local xs, ys = occ_in(at_a, ta, xf, xf + xc - 1), occ_in(at_b, tb, yf, yf + yc - 1)
        if #xs == #ys then
            for k = 1, #xs do
                if xs[k].kind == ys[k].kind then
                    out[#out + 1] = { a = xs[k], b = ys[k], subst = xs[k].name ~= ys[k].name or nil }
                end
            end
        end
        i, j = xf + xc, yf + yc
    end
    while i <= #ta and j <= #tb do kept(i, j); i, j = i + 1, j + 1 end
end

local function pair(A, Bx, origins, known_hunks)
    local sa, sb = line_starts(A.src), line_starts(Bx.src)
    local by_line_a, by_line_b, at_a, at_b = {}, {}, {}, {}
    for _, o in ipairs(A.occ) do
        local l = line_of(sa, o.off); o.line = l
        by_line_a[l] = by_line_a[l] or {}; table.insert(by_line_a[l], o)
        at_a[o.off] = at_a[o.off] or {}; table.insert(at_a[o.off], o)
    end
    for _, o in ipairs(Bx.occ) do
        local l = line_of(sb, o.off); o.line = l
        by_line_b[l] = by_line_b[l] or {}; table.insert(by_line_b[l], o)
        at_b[o.off] = at_b[o.off] or {}; table.insert(at_b[o.off], o)
    end
    -- ★★ ORIGINS FIRST. A MOVE (an inline, an extraction) relocates text, and a diff cannot
    -- pair a token with its moved self. The verb that moved it KNOWS where each piece came
    -- from, so it says so: `{ off, len, from, group }` = these `len` bytes of the result are
    -- a verbatim copy of the bytes at `from` in the before-text. Occurrences inside pair with
    -- their source by relative offset; `group` is one copy (one inlined site), because a
    -- helper-local copied into two sites is two declarations, each owning its own uses.
    local pairs_ = {}
    local segs = {}
    for _, sg in ipairs(origins or {}) do segs[#segs + 1] = sg end
    table.sort(segs, function (x, y) return x.off < y.off end)
    local si = 1
    for _, ob in ipairs(Bx.occ) do -- ascending offset
        while segs[si] and segs[si].off + segs[si].len <= ob.off do si = si + 1 end
        local sg = segs[si]
        if sg and ob.off >= sg.off then
            for _, oa in ipairs(at_a[sg.from + (ob.off - sg.off)] or {}) do
                if oa.kind == ob.kind and oa.name == ob.name then
                    pairs_[#pairs_ + 1] = { a = oa, b = ob, origin = sg.group or true }
                    ob.origin_paired, oa.moved = true, true
                    break
                end
            end
        end
    end
    local function start(st, src, l) return st[l] or #src end
    -- ⚠ A GUESSED DIFF CAN ALIGN A MOVED COPY WITH ITS SOURCE: an inlined body is often
    -- byte-identical to the helper body it replaced, and xdiff happily keeps the helper's
    -- lines "unchanged" against the site's new ones — which unpairs the site's own
    -- declarations. A plan KNOWS which lines it replaced, so it may pass `hunks` (in
    -- vim.diff's `indices` form) and nothing is guessed.
    local hunks = known_hunks or vim.diff(A.src, Bx.src, { result_type = 'indices' }) or {}
    local la, lb = 1, 1
    local function same_lines(upto_a)
        while la < upto_a do
            local xa, xb = by_line_a[la] or {}, by_line_b[lb] or {}
            -- an unchanged line: its occurrences pair one to one, in order
            for k = 1, math.min(#xa, #xb) do
                -- a copy the diff aligned with its source line is already paired by origin
                if not xb[k].origin_paired then pairs_[#pairs_ + 1] = { a = xa[k], b = xb[k] } end
            end
            la, lb = la + 1, lb + 1
        end
    end
    for _, hk in ipairs(hunks) do
        local a0, ac, b0, bc = hk[1], hk[2], hk[3], hk[4]
        -- xdiff reports a pure insertion as starting AFTER line a0, a pure deletion after b0
        local afirst = ac == 0 and a0 + 1 or a0
        local bfirst = bc == 0 and b0 + 1 or b0
        same_lines(afirst)
        pair_hunk(A, Bx, start(sa, A.src, afirst), start(sa, A.src, afirst + ac),
            start(sb, Bx.src, bfirst), start(sb, Bx.src, bfirst + bc), at_a, at_b, pairs_)
        la, lb = afirst + ac, bfirst + bc
    end
    same_lines(#sa + 1)
    return pairs_
end

-- ── the verdict ───────────────────────────────────────────────────────────────
local function show(b, I)
    if not b then return 'nothing' end
    if b['local'] then
        local d = I and I.decl_at and I.decl_at[b['local']]
        if d then return ('the local `%s` of line %d'):format(d.name, d.line) end
        return 'a local at byte ' .. b['local']
    end
    if b.lib then return 'library `' .. b.lib .. '`' end
    if b.free then return 'free `' .. b.free .. '`' end
    return 'ambiguous `' .. tostring(b.ambiguous) .. '`'
end
local function unbound(b) return b and (b.free or b.lib) end

--- Check that an edit re-points no reference it did not mean to.
--- @param before string  the file's text before the edit
--- @param after string   after
--- @param opts table|nil { file = name, allow_unbound = bool, origins = { {off, len, from, group} },
---                        hunks = { {a0, ac, b0, bc} } — the line hunks when the editor knows them }
--- @return table|nil verdict { ok, refusals = {...}, reports = {...}, counts }, string|nil why
function M.check(before, after, opts)
    opts = opts or {}
    local file = opts.file or '?'
    if opts.lang and opts.lang ~= 'lua' then
        return nil, ('rebind is Lua-only (the scope graph is Lua\'s mapping), not `%s`'):format(opts.lang)
    end
    local IA, wa = M.index(before, file)
    if not IA then return nil, 'before the edit: ' .. tostring(wa) end
    local IB, wb = M.index(after, file)
    if not IB then return nil, 'after the edit: ' .. tostring(wb) end
    local P = pair(IA, IB, opts.origins, opts.hunks)
    for _, I in ipairs { IA, IB } do
        I.decl_at = {}
        for _, o in ipairs(I.occ) do if o.kind == 'decl' then I.decl_at[o.off] = o end end
    end
    -- declaration correspondence: before-offset -> after-offset; a COPY's declarations
    -- correspond within their own copy (origin group) first
    local decl_to, decl_copy, paired_a, paired_b = {}, {}, {}, {}
    for _, p in ipairs(P) do
        paired_a[p.a], paired_b[p.b] = true, true
        if p.a.kind == 'decl' then
            if p.origin then
                decl_copy[p.origin] = decl_copy[p.origin] or {}
                decl_copy[p.origin][p.a.off] = p.b.off
            else
                decl_to[p.a.off] = p.b.off
            end
        end
    end
    local function expected(ba, p)
        if ba['local'] then
            local t = p and p.origin and decl_copy[p.origin] and decl_copy[p.origin][ba['local']]
            t = t or decl_to[ba['local']]
            return t and { ['local'] = t }
        end
        return ba
    end
    local function same(x, y)
        if not x or not y then return false end
        return x['local'] == y['local'] and x.lib == y.lib and x.free == y.free and x.ambiguous == y.ambiguous
    end
    local refusals, reports = {}, {}
    local counts = { kept = 0, substituted = 0, introduced = 0, removed = 0 }
    -- siblings: every before-ref of a local binder, and where it ended up
    local fate = {}
    for _, p in ipairs(P) do
        if p.a.kind == 'ref' and p.a.binder['local'] then
            local k = p.a.binder['local']
            fate[k] = fate[k] or { kept = 0, moved = 0 }
            if same(p.b.binder, expected(p.a.binder, p)) then fate[k].kept = fate[k].kept + 1 else fate[k].moved = fate[k].moved + 1 end
        end
    end
    for _, p in ipairs(P) do
        if p.a.kind == 'ref' then
            local want, got = expected(p.a.binder, p), p.b.binder
            if not p.subst then
                counts.kept = counts.kept + 1
                if not same(got, want) then
                    refusals[#refusals + 1] = { kind = 'captured', name = p.a.name, line = p.b.line, before_line = p.a.line,
                        moved = p.origin and true or nil, was = show(p.a.binder, IA), now = show(got, IB),
                        why = p.origin
                            and ('`%s` at line %d, moved there from line %d, no longer reads what it read there: %s before, %s after')
                                :format(p.a.name, p.b.line, p.a.line, show(p.a.binder, IA), show(got, IB))
                            or ('`%s` at line %d was not edited, and it no longer reads what it read: %s before, %s after')
                                :format(p.a.name, p.b.line, show(p.a.binder, IA), show(got, IB)) }
                end
            else
                counts.substituted = counts.substituted + 1
                if same(got, want) then
                    reports[#reports + 1] = { kind = 'renamed', from = p.a.name, to = p.b.name, line = p.b.line }
                elseif p.a.binder['local'] and unbound(got) and not opts.allow_unbound then
                    local f = fate[p.a.binder['local']] or { kept = 0 }
                    refusals[#refusals + 1] = { kind = 'unbound', name = p.a.name, to = p.b.name, line = p.b.line,
                        siblings_kept = f.kept, was = show(p.a.binder, IA), now = show(got, IB),
                        why = ('`%s` -> `%s` at line %d: it read %s and now reads %s; %s — rename the declaration and every use, or none (or pass allow_unbound if the global is what you mean)')
                            :format(p.a.name, p.b.name, p.b.line, show(p.a.binder, IA), show(got, IB),
                                f.kept > 0 and ('%d other use(s) of that local keep the old name'):format(f.kept)
                                    or 'the declaration keeps the old name') }
                else
                    reports[#reports + 1] = { kind = 'retargeted', from = p.a.name, to = p.b.name, line = p.b.line, was = show(p.a.binder, IA), now = show(got, IB) }
                end
            end
        end
    end
    for _, o in ipairs(IB.occ) do
        if not paired_b[o] and o.kind == 'ref' then
            counts.introduced = counts.introduced + 1
            reports[#reports + 1] = { kind = 'introduced', name = o.name, line = o.line, now = show(o.binder, IB), free = o.binder.free ~= nil }
        end
    end
    -- ⚠ COUNTED, NOT SUBTRACTED: a source copied into two sites is paired twice
    for _, o in ipairs(IA.occ) do if o.kind == 'ref' and not paired_a[o] then counts.removed = counts.removed + 1 end end
    return { ok = #refusals == 0, refusals = refusals, reports = reports, counts = counts }
end

--- The member form: `src` with bytes (sb, eb] replaced by `text` (a template edit unfolds to
--- one of these per member). Checks the WHOLE file, for the reason in the header.
function M.check_splice(src, sb, eb, text, opts)
    return M.check(src, src:sub(1, sb) .. text .. src:sub(eb + 1), opts)
end

return M
