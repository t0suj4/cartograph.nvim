-- invert.lua — INLINE A HELPER BACK INTO THE SITES IT WAS EXTRACTED FROM (CART-1005).
--
-- USER (2026-09-22): "do it" — on the reading of CART-1004 that says our write vocabulary
-- has FIVE ways into an abstraction and none out, so a self-refactoring loop cannot
-- correct itself. This is the first way out, and it is deliberately the RESTRICTED one:
-- not "inline any function" but "undo an extraction this tool performed", which is the
-- version that has a WITNESS.
--
-- ── ★★★ WHY THE RECORD IS THE WHOLE POINT, AND NOT A CONVENIENCE ─────────────
-- A general inliner has to re-derive, from the text, which argument stood for which
-- parameter at which call site. `cloneextract` COMPUTED that correspondence to emit the
-- extraction and then threw it away — the bytes on disk are its shadow, and reading them
-- back means trusting that nobody has touched our own output since. CART-1004 filed the
-- `undo` record for exactly this, and its comment states the constraint this module lives
-- under: *recovering the relation means re-parsing our own output, which is what LATE
-- inversion cannot assume.*
--
-- ⇒ SO THIS READS `e.undo` AND `e.files` AND NOTHING ELSE, the same line `journal.recover`
-- holds. ⚠ NOT `e.plan`: `plan_version` exists precisely because replaying a recorded plan
-- is the fragile path, and an inverse that read `plan.xfile` would be pinned to a schema it
-- does not own. Everything the inverse needs is ON THE RECORD — which is how the record's
-- FIRST CONSUMER discovered it was carrying half of the correspondence (see below).
--
-- ── ★★★ WHAT THE FIRST CONSUMER FOUND, AND IT IS THE ARGUMENT FOR BUILDING ONE ─
-- The record listed the SYNTHETIC parameters only — the `hp*`/`fp*` names the extraction
-- mints. Its reasoning was that the FORWARDED parameters pass through unchanged, and that
-- is true of the TEXT and false of the NAMES: the helper wears side A's parameter names,
-- and side B calls it with its own. MEASURED on the spec's own fixture — helper
-- `fmt_a_extracted(x, hp1)`, called `fmt_a_extracted(a, 'yaml')` at site B — the record
-- described one parameter of two, and the missing one was a RENAMING.
-- ⇒ A DECLARATION NOBODY CONSUMES IS A GUESS ABOUT WHAT A CONSUMER WILL NEED. The
-- correspondence is now positional and total (`#params == the helper's arity`), and the
-- spec pins the arity rather than the count.
--
-- ── ⚠ THIS IS AN INLINE, NOT A RESTORE, AND THE DIFFERENCE IS VISIBLE ────────
-- The helper carries SITE 1's local names. Inlining into site 2 puts site 1's names there:
-- `fmt_b`'s `b, c, d, e` come back as `y, z, w, o`. That is alpha-equivalent and it is not
-- the original bytes. Byte restoration is `journal.rollback`'s job — it has the whole file
-- — and doing it HERE would need the local renaming too, which CART-0996 measured as not
-- even a bijection on 4 of 7 of our own pairs. So the verb is `inline-helper` and `desc`
-- says which of the two it did.
--
-- ── ⚠ AND IT DOES NOT GATE ON THE HELPER BEING UNTOUCHED ─────────────────────
-- The tempting guard is "refuse unless the helper is byte-identical to what we wrote".
-- It would delete the entire point of a LATE inverse: the helper may have been improved
-- since, and inlining is how that improvement reaches the sites. `cloneextract` already
-- settled this shape for the forward verb — *"IT IS A DISCLOSURE, NOT A GATE. Refusing it
-- would throw away a legal refactoring because we cannot yet prove something about it"* —
-- so a drifted helper lands in the REVIEW bucket (`preserves = 'unreviewed'`, with the
-- drift named) rather than in a refusal. `body_hash` on the record is what tells the two
-- apart, and it is a WITNESS, not a copy: the bytes are in the entry's `after`.

local M = {}

local txn = require 'cartograph.txn'
local ba = require 'cartograph.boundat'
local expr = require 'cartograph.expr'

--- the definition named `name` in `file`, or nil. ⚠ TAIL-MATCHED, because a cross-file
--- helper is `M.foo` in the graph and `foo` on the record — the same name under two
--- qualifications, which is the registration relation's oldest lesson.
local function find_def(store, file, name)
    local short = tostring(name):match('[%w_]+$') or name
    for _, n in ipairs(store.data.nodes or {}) do
        if n.file == file and n.name and (n.name:match('[%w_]+$') or n.name) == short
            and (n.kind == 'function' or n.kind == 'method') then
            return n
        end
    end
end

--- body span + parameter list of a definition, through the accessors that own them:
--- `expr.of` for the flow facts, `cloneextract.body_span` for the line arithmetic.
--- @return table|nil shape  { params, sig, open, close }
--- @return string|nil why
local function shape_of(store, node)
    local ok, eo = pcall(expr.of, store, node.id)
    if not ok or not (eo and eo.fl) then
        return nil, ('`%s` has no analyzable body'):format(tostring(node.name))
    end
    local lines = {}
    for _, s in ipairs(eo.fl.stmts or {}) do lines[#lines + 1] = s.l end
    local sig, open, close = require('cartograph.cloneextract').body_span(store, node.id, lines)
    if not sig then
        return nil, ('`%s` is not a clean multi-line block'):format(tostring(node.name))
    end
    return { params = eo.fl.params or {}, sig = sig, open = open, close = close }
end

--- 0-based line -> byte offset of its first character, for a split source.
local function line_offsets(src)
    local offs, pos = { 0 }, 0
    for _, l in ipairs(vim.split(src, '\n', { plain = true })) do
        pos = pos + #l + 1
        offs[#offs + 1] = pos
    end
    return offs
end

--- The identifier names occurring FREE in an argument expression.
--- ⚠ NOT A PATTERN SCAN. `'json'` contains the letters of a name and is not a reference;
--- `t.x` mentions `x` and does not read a variable called `x`. The scope graph is the only
--- thing that knows the difference, so the expression is wrapped into the smallest chunk
--- that makes it readable and its REFERENCES are the answer.
local function free_names(argtext)
    local h = ba.of(('local __cg_arg = (%s)\n'):format(argtext), '?arg')
    if not h then return nil end
    local out = {}
    for _, p in ipairs(h.points or {}) do
        if p.kind == 'ref' and p.name then out[p.name] = true end
    end
    return out
end

--- ★★★ BUILD THE INVERSE PLAN FROM A JOURNAL ENTRY, or (nil, why).
---
--- Every refusal below is the forward verb's own precondition read backwards, which is the
--- design CART-1004 landed on: *the forward verb's refusals are the reverse verb's
--- preconditions.* They are named individually on purpose — "cannot invert" is the answer
--- that sends someone to read this file instead of their tree.
--- @return table|nil plan
--- @return string|nil why
function M.of(store, entry)
    if type(entry) ~= 'table' then return nil, 'not a journal entry' end
    local rec = entry.undo
    if not rec then
        return nil, ('entry %s carries no undo record — it was written before the verb'
            .. ' declared one, or the verb declares none'):format(tostring(entry.id))
    end
    if rec.kind ~= 'relation' then
        return nil, ('this undo record is a `%s`, not a relation — a destructive verb\'s'
            .. ' inverse is `journal.recover`, which resolves spans against the before-text')
            :format(tostring(rec.kind))
    end
    if entry.status ~= 'applied' then
        return nil, ('entry %s is `%s`, not applied — there is no extraction in the tree to'
            .. ' invert'):format(tostring(entry.id), tostring(entry.status))
    end
    if not rec.file or not rec.params or not rec.sites then
        return nil, ('this record predates the full correspondence (CART-1005): it names no'
            .. ' helper file, so the inverse would have to re-derive it from the plan')
    end

    local root = store.data.root
    -- ⚠ ONE FILE, THIS RUNG. A cross-file extraction's inverse must also drop the require
    -- line and prove the helper's free names still resolve at a site in a DIFFERENT module
    -- — the same "does the text reach what it reads" question CART-1000 measured
    -- `destinations` refusing on. Naming it is the honest answer; doing it here would be
    -- inlining text into a scope nobody checked.
    for _, s in ipairs(rec.sites) do
        if s.file ~= rec.file then
            return nil, ('`%s` lives in %s and the site `%s` is in %s — inverting a'
                .. ' cross-file extraction must also remove the import and re-check that the'
                .. ' body\'s free names resolve in the destination, which this verb does not'
                .. ' do'):format(tostring(rec.helper), tostring(rec.file),
                tostring(s.name), tostring(s.file))
        end
    end
    if (rec.nfparams or 0) > 0 then
        return nil, ('`%s` takes %d function parameter(s); inverting one is a'
            .. ' beta-reduction — the lambda\'s body must be substituted for its'
            .. ' applications with the dependencies remapped, not spliced at a name')
            :format(tostring(rec.helper), rec.nfparams)
    end

    local hnode = find_def(store, rec.file, rec.helper)
    if not hnode then
        return nil, ('`%s` is no longer defined in %s — it was renamed, moved, or already'
            .. ' inlined'):format(tostring(rec.helper), tostring(rec.file))
    end
    local hs, hwhy = shape_of(store, hnode)
    if not hs then return nil, hwhy end
    -- ★ THE ARITY IS THE CORRESPONDENCE'S OWN INVARIANT, and it is also what refuses a
    -- record written before the forwarded half was recorded: those describe strictly fewer
    -- parameters than the helper has, so they land here with a sentence that says so.
    if #hs.params ~= #rec.params then
        return nil, ('`%s` takes %d parameter(s) and the record describes %d — either the'
            .. ' signature changed since, or the record predates the full correspondence'
            .. ' (CART-1005), and either way the positional match is not established')
            :format(tostring(rec.helper), #hs.params, #rec.params)
    end

    local src = txn.read_file(root, rec.file)
    if not src then return nil, ('cannot read %s'):format(rec.file) end
    local lines = vim.split(src, '\n', { plain = true })
    local offs = line_offsets(src)

    local h, bwhy = ba.of(src, rec.file)
    if not h then
        return nil, ('no scope graph for %s (%s) — a substitution without one would be a'
            .. ' text replacement, and `x` occurs inside `max`'):format(rec.file, tostring(bwhy))
    end
    local hpath = ba.fn_path(h, hs.sig)
    if not hpath then
        return nil, ('cannot locate `%s` in the scope graph of %s'):format(rec.helper, rec.file)
    end

    -- ── the helper's BODY BINDERS: what a substituted argument may not name ──
    -- ⚠ PARAMETERS EXCLUDED. A parameter is what we are substituting FOR; a `local` of the
    -- same name inside the body is the thing that would capture.
    local binders, rebound = {}, {}
    local pset = {}
    for _, p in ipairs(hs.params) do pset[p] = true end
    for _, d in ipairs(h.decls or {}) do
        if d.name and ba.under(hpath, d.site) then
            if d.kind == 'parameter' and pset[d.name] then
                -- the helper's own signature; not a body binder
            else
                binders[d.name] = d.kind or 'local'
                if pset[d.name] then rebound[d.name] = d.kind or 'local' end
            end
        end
    end
    -- ⚠ MEASURED AGAINST THE CAPTURE CHECK BELOW, WHICH MOSTLY SUBSUMES IT. The donor's
    -- argument for a forwarded parameter is ALWAYS that parameter's own name, so a rebound
    -- parameter trips the capture guard at the donor site every time — reverting this one
    -- leaves the suite green except for the SENTENCE, which then describes a collision
    -- rather than a shadowing. It is kept for two reasons and the first is not cosmetic:
    --   · IT IS INDEPENDENT ONCE THE HELPER IS EDITED. Rename the helper's parameter after
    --     the extraction and the recorded argument no longer shares its name, so nothing
    --     collides and the substitution would silently rewrite the shadow's references.
    --   · a reader sent to `local x = prep(x)` by "rewrite the wrong one" finds the defect;
    --     one sent there by "would capture" looks for the wrong thing.
    for _, p in ipairs(hs.params) do
        if rebound[p] then
            return nil, ('`%s` is rebound as a %s inside `%s` — after that line the name'
                .. ' does not mean the parameter, so substituting the argument at every'
                .. ' occurrence would rewrite the wrong one')
                :format(p, tostring(rebound[p]), tostring(rec.helper))
        end
    end

    -- ── the body's byte range, and every occurrence of every parameter in it ──
    local body_from = offs[hs.open + 1]
    local body_to = offs[hs.close + 2] and (offs[hs.close + 2] - 1) or #src
    local subs = {}        -- { off, len, param_index }
    for i, p in ipairs(hs.params) do
        for _, u in ipairs(ba.uses(h, hpath, p)) do
            if u.off >= body_from and u.off < body_to then
                subs[#subs + 1] = { off = u.off, len = #p, i = i }
            end
        end
    end
    table.sort(subs, function (x, y) return x.off < y.off end) -- emitted left to right

    local hbody = src:sub(body_from + 1, body_to)
    local hind = (lines[hs.open + 1] or ''):match('^%s*') or ''

    -- ── per site: check it still delegates, then splice ──────────────────────
    local ops, refspecs, site_ids, nsubs = {}, {}, {}, 0
    local origins = {}      -- per op: where each byte of its new text was copied from
    for _, s in ipairs(rec.sites) do
        -- ⚠ IDENTITY FIRST, NAME ONLY AS A FALLBACK. A tail-name match returns whichever
        -- node the list yields first, and a file may hold `local function tidy` beside
        -- `function M.tidy`. The record carries each site's `id`; a record written before
        -- it did gets the name match and a note-worthy chance of being wrong.
        local snode = (s.id and store.node(s.id)) or find_def(store, s.file, s.name)
        if not snode then
            return nil, ('the site `%s` is no longer defined in %s'):format(
                tostring(s.name), tostring(s.file))
        end
        local ss, swhy = shape_of(store, snode)
        if not ss then return nil, swhy end
        if #s.args ~= #rec.params then
            return nil, ('the site `%s` records %d argument(s) for %d parameter(s)')
                :format(tostring(s.name), #s.args, #rec.params)
        end
        -- ★★★ THE RECORDED ARGUMENTS ARE A WITNESS, AND THIS IS WHERE THEY EARN IT. The
        -- delegating call is REGENERATED from the record and compared to what is on disk.
        -- If they match, the record describes the tree; if they do not, the record is
        -- describing something that is no longer there, and inlining it would put back a
        -- body nobody asked for. ⚠ COMPARED TRIMMED: indentation is not the claim.
        local want = ('%s(%s)'):format(rec.call, table.concat(s.args, ', '))
        local have = table.concat({ unpack and unpack(lines, ss.open + 1, ss.close + 1)
            or table.unpack(lines, ss.open + 1, ss.close + 1) }, '\n')
        local trimmed = have:gsub('^%s+', ''):gsub('%s+$', '')
        if not (ss.close == ss.open and trimmed:find(want, 1, true)) then
            return nil, ('`%s` no longer delegates to `%s` — its body is not the single call'
                .. ' the record describes (`%s`), so the recorded arguments no longer'
                .. ' witness what is there'):format(tostring(s.name), tostring(rec.helper), want)
        end
        -- ── capture: a free name of an argument that the helper's body binds ──
        for i, a in ipairs(s.args) do
            local fr = free_names(a)
            if not fr then
                return nil, ('cannot read the recorded argument `%s` of `%s` as an'
                    .. ' expression'):format(tostring(a), tostring(s.name))
            end
            for n in pairs(fr) do
                if binders[n] then
                    return nil, ('inlining `%s` would capture: the argument `%s` reads `%s`,'
                        .. ' and `%s` declares a %s of that name — after the splice the'
                        .. ' argument would read the helper\'s own binding')
                        :format(tostring(s.name), tostring(a), n, tostring(rec.helper),
                        tostring(binders[n]))
                end
            end
            local _ = i
        end

        -- ★★ THE SPLICE RECORDS ITS ORIGINS AS IT GOES (CART-1038). Every byte of the new
        -- body is either a verbatim copy of the helper's body, a verbatim copy of a recorded
        -- argument at the call, or re-indentation. The `bindings-preserved` guard resolves
        -- the file before and after and pairs each copied name with its SOURCE, so a helper
        -- name that means something else at the site (a local declared between them, a
        -- site-local shadowing an upvalue) or an argument the body captures is refused on
        -- the result — the one thing a diff cannot pair, because the text MOVED.
        local wpos = have:find(want, 1, true)
        local argoff, ao = {}, offs[ss.open + 1] + wpos - 1 + #rec.call + 1
        for i, a in ipairs(s.args) do argoff[i] = ao; ao = ao + #a + 2 end
        local sind = (lines[ss.open + 1] or ''):match('^%s*') or ''
        local out, segs, olen = {}, {}, 0
        local function emit(str, from)
            if str == '' then return end
            out[#out + 1] = str
            if from then segs[#segs + 1] = { off = olen, len = #str, from = from } end
            olen = olen + #str
        end
        local blines = vim.split(hbody, '\n', { plain = true })
        local lo, k = body_from, 1
        for li, l in ipairs(blines) do
            -- reindent from the helper's body indent to the site's
            local pos = 0
            if hind ~= '' and hind ~= sind and l:sub(1, #hind) == hind then
                emit(sind, nil); pos = #hind
            end
            while subs[k] and subs[k].off < lo + #l do
                local sub = subs[k]
                local rel = sub.off - lo
                emit(l:sub(pos + 1, rel), lo + pos)
                emit(s.args[sub.i], argoff[sub.i])
                nsubs = nsubs + 1
                pos, k = rel + sub.len, k + 1
            end
            emit(l:sub(pos + 1), lo + pos)
            if li < #blines then emit('\n', lo + #l) end
            lo = lo + #l + 1
        end
        local new = vim.split(table.concat(out), '\n', { plain = true })
        origins[#origins + 1] = { op = #ops + 1, segs = segs }
        ops[#ops + 1] = { from0b = ss.open, to0b = ss.close, new = new }
        refspecs[#refspecs + 1] = { id = snode.id, name = snode.name,
            ref = store.ref_of(snode.id), what = 'site' }
        site_ids[snode.id] = true
    end

    -- ── the helper itself: removed only if nothing else calls it ─────────────
    local outside = {}
    local okt, band = pcall(store.topo)
    if okt and band then
        for _, from in ipairs(band:callers(hnode.id) or {}) do
            if not site_ids[from] then
                local fn = store.node(from)
                outside[#outside + 1] = (fn and fn.name) or tostring(from)
            end
        end
    end
    local removed = nil
    if #outside == 0 then
        -- swallow one trailing blank line, the same courtesy `txn.edit_file` extends to a
        -- deletion — the extraction emitted one after the helper
        local last = hs.close + 1
        if lines[last + 2] == '' then last = last + 1 end
        ops[#ops + 1] = { from0b = hs.sig, to0b = last, new = {} }
        removed = { { file = rec.file, name = rec.helper, s = hs.sig, e = last } }
    end

    local plan = {
        verb = 'inline-helper', generation = store.generation,
        guards = { 'parses', 'bindings-preserved' },
        origins = { [rec.file] = origins },
        helper = rec.helper, from_entry = entry.id, lang = 'lua',
        files = { [rec.file] = { ops = ops } },
        touched = { rec.file },
        refspecs = refspecs,
        nsites = #rec.sites, nsubs = nsubs, removed_helper = removed ~= nil,
        kept_because = (#outside > 0) and outside or nil,
    }
    plan.stamps = { [rec.file] = txn.disk_stamp(root, rec.file) }
    -- ★ THE INVERSE'S OWN INVERSE. Removing the helper is DESTRUCTIVE, so its undo is the
    -- other shape — spans into the journal's before-text, which `journal.recover` already
    -- resolves. Symmetry, and it is free: the entry keeps the bytes regardless.
    if removed then plan.undo = { kind = 'removed', spans = removed } end

    -- ── the claim, and the one thing that DOWNGRADES it ──────────────────────
    local cur = require('cartograph.journal').hash(hbody)
    local drifted = rec.body_hash ~= nil and cur ~= rec.body_hash
    if drifted then
        plan.preserves = 'unreviewed'
        plan.preserves_why = ('`%s` is not the text this extraction wrote — it has been'
            .. ' edited since, so what comes back to the %d site(s) is the CURRENT helper'
            .. ' and not what was taken from them. That is usually the point of a late'
            .. ' inline and it is not something this verb can certify')
            :format(tostring(rec.helper), #rec.sites)
    else
        -- ★★★ IT INHERITS THE FORWARD CLAIM, AND THE SENTENCE MUST SAY WHOSE IT IS.
        -- `plan_family` claims `unreviewed` because `family_admissibility` carries no
        -- per-hole purity — so a FAMILY fold's inverse reports `unreviewed` even when the
        -- helper is untouched and every site still delegates. ⚠ THAT IS NOT A DOUBT ABOUT
        -- THE INVERSE. The checks above establish that the splice restores the relation;
        -- what nobody established is whether the ORIGINAL fold changed behaviour, and the
        -- inverse of an unestablished step is equally unestablished. Claiming `all` here
        -- would say more than was shown, so the claim stays and the REASON is attributed.
        plan.preserves = rec.preserves or 'unreviewed'
        plan.preserves_why = (rec.preserves == 'all')
            and ('the helper is byte-identical to what the extraction wrote and each site\'s'
                .. ' arguments still match the recorded call, so the splice restores the'
                .. ' relation the fold removed; the forward fold established `all`')
            or ('the splice itself is established — the helper is byte-identical to what the'
                .. ' extraction wrote and each site still delegates with the recorded'
                .. ' arguments — but the FORWARD fold claimed `%s` (it could not establish'
                .. ' its own behavioural radius), and the inverse of an unestablished step'
                .. ' is unestablished. This names the FOLD\'s gap, not a doubt about the'
                .. ' inline'):format(tostring(rec.preserves or 'unreviewed'))
    end

    plan.desc = {
        helper = rec.helper, file = rec.file, entry = entry.id,
        sites = #rec.sites, substitutions = nsubs,
        removed_helper = removed ~= nil, kept_because = plan.kept_because,
        drifted = drifted or nil,
        -- ⚠ SAID IN THE JOURNAL, NOT ONLY IN THIS FILE'S HEADER. The bodies come back in
        -- the HELPER's local names, which are the donor site's. Anyone reading the entry
        -- later should not have to diff to discover that.
        note = 'inline, not restore: each body returns in the helper\'s local names',
    }
    plan.precheck = function (st)
        if next(st.moveset or {}) then
            return 'a move-set is staged — apply or clear it first'
        end
    end
    return txn.protocol(plan, require('cartograph.cloneextract').edits_for)
end

--- Preview and apply, through the generic driver — this verb adds no shape of its own.
function M.preview(store, plan) return txn.dryrun(store, plan) end
function M.apply(store, plan) return txn.apply(store, plan) end

--- The inverse of the LAST invertible entry in this root, or (nil, why) naming the entry
--- it looked at. ⚠ IT DOES NOT SEARCH BACKWARDS FOR ONE THAT WORKS: "the last extraction"
--- is a question with one answer, and silently skipping to an older one would invert
--- something the caller did not ask about.
function M.of_last(store)
    local journal = require 'cartograph.journal'
    local entries = journal.list(store.data.root) or {}
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.undo and e.undo.kind == 'relation' then return M.of(store, e) end
    end
    return nil, 'no entry in this project\'s journal declares a relation to invert'
end

return M
