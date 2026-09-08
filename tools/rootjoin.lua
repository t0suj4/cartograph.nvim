-- rootjoin — TWO ROOTS IN ONE PROCESS, JOINED ON A DECLARED RELATION (CART-0821).
--
--   nvim --headless -u NONE -l tools/rootjoin.lua [<left>] [<right>] [--rows]
--
-- ★★★ THE QUESTION NO SINGLE-LANGUAGE SERVER CAN REPRESENT. ejabberd registers
-- XMPP IQ handlers under a namespace URI; converse.js declares the same URIs to
-- Strophe. The two projects share a PROTOCOL and no code. Ask either language's
-- own tooling "who handles urn:xmpp:mam:2" and it can only see its own half.
--
-- ★★ WHY THIS IS A TOOL AND NOT A GRAPH PASS. The join needs BOTH graphs
-- resident at the same instant, and bands cannot do that: only one band is
-- readable at a time (a stashed band is a `store.capture()` snapshot), so
-- CART-0823's N-root hosts give SWITCHABLE roots, not a cross-root query. This
-- sidesteps bands entirely — two `ts.extract` calls, two data tables, join in
-- between. It needs no session work at all, which is why it could ship first.
--
-- ⚠⚠ IT MINTS NOTHING. No edges into either graph, no nodes, nothing cached. A
-- persisted cross-root linkage is CART-0026's federated accessor; this reports.
-- The rows it prints are LINKAGE-SHAPED ({key, left, right, rung, provenance})
-- so that when CART-0026 lands, the shape is a move rather than a rewrite.
--
-- ⚠ NO `expected` COUNTS AND NO GATE. brotardcast is the APPLICATION corpus
-- ([[cartograph-corpus-roster]]) — it MOVES, and reporting false negatives is
-- its declared role. Every number here is a measurement of today's checkout.
--
-- ★★★ AND THE POPULATION IS THE WHOLE ARGUMENT, because four different
-- questions each produce a "namespaces in common" number and they differ by
-- 5.7x. Measured 2026-09-08:
--
--   REGISTERED (a handler exists, via a CALL)   6 by URI ·  4 by name
--   MENTIONED  (the name occurs in the text)   24 by URI · 14 by name
--   VOCABULARY (the protocol library defines)  34 by URI · 16 by name
--   REFUSED    (registered in a shape argv cannot read)  19 namespaces
--
-- Only the first is "this server handles what this client asks for". The last
-- is the one a grep cannot produce at all — see the tuple census below.
-- ⚠ The arc's earlier by-hand figure was 30 by URI / 8 by name. It reproduces as
-- NONE of these today: it sits between MENTIONED and VOCABULARY, on two
-- checkouts that have both moved since, under a by-name rule that was never
-- written down. That is why this tool prints its RULE beside its numbers.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local argv = require 'cartograph.argv'
local prof = require 'cartograph.spec.profile'
local tiers = require 'cartograph.tier'

-- ── THE RELATION, DECLARED ──────────────────────────────────────────────────
-- ★ ONE relation, as DATA rather than as control flow, so a second one is a
-- table entry and not a rewrite of this file. It is deliberately NOT a generic
-- join engine: that is a widening with nothing to check it, and one relation
-- with real numbers behind it is worth more than an engine with none.
-- ⚠ THE KEY IS THE URI, AND THE NAMES ARE PER-PROJECT ALIASES. `?NS_MAM_2` on
-- one side and `Strophe.NS.MAM` on the other are the same namespace under two
-- names; `?NS_CLIENT_STATE` is `CSI`. So the URI join and the name join find
-- DIFFERENT SETS, and both are reported — a boundary's identity is the string
-- the boundary itself carries.
local RELATIONS = {
    xmpp_namespace = {
        what = 'an XMPP namespace URI: the server registers an IQ handler under it, the client declares it to Strophe',
        left = {
            root = '~/work/brotardcast/ejabberd/src',
            -- the REGISTERING CALL. ⚠ The bare callee, never
            -- `gen_iq_handler.add_iq_handler`: an erlang remote call's `full` is
            -- ARITY-QUALIFIED (`…/5`), so every qualified spelling misses.
            verb = 'add_iq_handler', slot = 3,
            -- ⚠ THE VALUE RIDES ON A `macro` SLOT AND IS NOT A LITERAL (dec/36).
            -- The source says `?NS_MAM_2` there; a LIBRARY says the URI. So the
            -- URI is provenanced to the distilled vocabulary, not to the file.
            vocab = 'erl-macros',
            -- the second, UNREADABLE registration mechanism, counted not joined
            refused_pattern = '{iq_handler,', refused_exts = { 'erl' },
        },
        right = {
            root = '~/work/brotardcast/converse.js/src',
            verb = 'addNamespace', alias_slot = 1, key_slot = 2,
        },
        -- ★★★ THE HOPS EACH CARRIER PASSES THROUGH, DECLARED (CART-0843). A join
        -- row is a COMPOSED relation, and `tier.floor` takes the weakest hop
        -- rather than letting the strongest mechanism speak for the path.
        -- ⚠ THIS CORRECTS A SHIPPED OVERCLAIM: both carriers asserted a flat
        -- `rung = 'xlang'`, and every URI-keyed row's key comes from
        -- `erl-macros` — a distilled PROFILE ARTIFACT, which the ladder itself
        -- grades `stdlib` ("an active env profile names it"), rank 5 against
        -- xlang's 3. Two rungs of flattery, asserted as a constant where a
        -- computation belonged.
        -- ⚠ A HOP IS LISTED ONLY IF IT MAKES A CLAIM. Parsing the tuple out of
        -- the tree is not a claim — it is the substrate (bytes and sightings),
        -- and grading it would invent a rung for reading a file.
        hops = {
            call = {
                'stdlib',   -- the URI comes from erl-macros, not from the source
                'xlang',    -- and the client's literal is matched as a wire key
            },
            tuple = {
                'stdlib',   -- same vocabulary, same artifact, same stamp
                'xlang',    -- same string-key match on the client side
                -- ⚠⚠ AND ONE HOP THIS LADDER CANNOT GRADE. The tuple's MEANING
                -- comes from an INTERPRETATION derived from a consumer's clause
                -- heads (gen_mod.erl:424-429) — a declared convention, which is
                -- `convention`: a rung tier.lua lists as a BANKED insertion
                -- point that DOES NOT EXIST, because the ladder is full (7
                -- rungs, fold packs 3 bits, an 8th decodes as none). It is
                -- reported as UNGRADED rather than approximated by its nearest
                -- neighbour — the `unbuilt` lesson, one axis over. CART-0848.
                'convention',
            },
        },
        -- ⚠ THE NAME RULE, PRINTED WITH ITS RESULT. An unstated matching rule
        -- makes its own number uncheckable — the arc's earlier "8 by name" can
        -- no longer be reproduced or refuted because nobody wrote the rule down.
        name_rule = { strip = '^NS_', match = 'exact, case-sensitive' },
    },
}

local left_root, right_root, want_rows
do
    local pos = {}
    for i = 1, #arg do
        if arg[i] == '--rows' then want_rows = true else pos[#pos + 1] = arg[i] end
    end
    local R = RELATIONS.xmpp_namespace
    left_root = vim.fn.expand(pos[1] or R.left.root)
    right_root = vim.fn.expand(pos[2] or R.right.root)
end
for _, r in ipairs({ left_root, right_root }) do
    if vim.fn.isdirectory(r) ~= 1 then print('not a directory: ' .. r); os.exit(2) end
end

local R = RELATIONS.xmpp_namespace
print(('rootjoin %s'):format('xmpp_namespace'))
print('  ' .. R.what)
print(('  left  %s'):format(left_root))
print(('  right %s'):format(right_root))

-- ── the vocabulary that values the left key, with its provenance ────────────
-- ★ A PROTOCOL BOUNDARY'S KEY TABLE LIVES IN A LIBRARY BOTH SIDES DEPEND ON.
-- The URIs are in github.com/processone/xmpp, pinned by rebar.config and NOT
-- vendored — in neither endpoint. So it is a distilled artifact, and its STAMP
-- rides on every row whose key came from it.
local vocab, vstamp = {}, nil
do
    local a = prof.load(R.left.vocab)
    vocab = (a and a.values) or {}
    vstamp = a and a.stamp
end
local nvocab = 0
for _ in pairs(vocab) do nvocab = nvocab + 1 end
print(('  vocabulary %s: %d value(s), stamp %s'):format(R.left.vocab, nvocab,
    tostring(vstamp)))
if nvocab == 0 then
    print('  ⚠ FAULT, not a finding: the vocabulary is absent, so no left key can')
    print('    carry a URI and the URI join would report 0 for a reason that has')
    print('    nothing to do with either corpus. Run tools/hrldistill.lua.')
    os.exit(2)
end

-- ── extract both roots, in one process ──────────────────────────────────────
local function extract(root, label)
    local ok, data = pcall(ts.extract, root)
    if not ok then print(('extract failed (%s): %s'):format(label, tostring(data))); os.exit(1) end
    data.root = data.root or root
    print(('  %-5s %d nodes, %d calls'):format(label, #(data.nodes or {}), #(data.calls or {})))
    return data
end
print('')
local dl = extract(left_root, 'left')
local dr = extract(right_root, 'right')

-- ── the RIGHT side: declarations (a call with two literal arguments) ────────
local decl_by_uri, decl_by_alias, ndecl, decl_opaque = {}, {}, 0, 0
for _, c in ipairs(dr.calls or {}) do
    if (c.callee or '') == R.right.verb then
        local al = argv.at(c, R.right.alias_slot)
        local key = argv.at(c, R.right.key_slot)
        ndecl = ndecl + 1
        local rec = { alias = al and al.v, uri = key and key.v, file = c.file, line = c.line }
        -- ⚠ AN ALIAS IS DECLARED WHETHER OR NOT ITS URI IS READABLE, and my
        -- first cut collected both inside one `if key.v` — so a declaration
        -- whose URI slot is not a literal dropped its ALIAS too, and the
        -- name-join population silently shrank (14 -> 10) for a reason that has
        -- nothing to do with names. The two keys have two availabilities and
        -- must be gathered separately.
        if rec.uri then decl_by_uri[rec.uri] = decl_by_uri[rec.uri] or rec
        else decl_opaque = decl_opaque + 1 end
        if rec.alias then decl_by_alias[rec.alias] = decl_by_alias[rec.alias] or rec end
    end
end
local function cnt(t) local k = 0 for _ in pairs(t) do k = k + 1 end return k end

-- ── ★★★ THE SECOND CARRIER (CART-0846), NOW READ. The tuple registry that was
-- counted-but-never-joined below is joinable: `erlreg` reads it against the
-- interpretation gen_mod.erl states in executable code, and the URI it yields
-- is the SAME key this relation already joins on. So the REFUSED population
-- shrinks and the JOINED one grows — and the four namespaces the call form
-- never reaches (urn:xmpp:blocking · carbons:2 · push:0 · time) arrive here.
local erlreg = require 'cartograph.erlreg'
local ers = erlreg.attach(dl)
local tuple_regs = {}
for _, r in ipairs(ers.rows or {}) do
    if r.uri then
        tuple_regs[#tuple_regs + 1] = { k = 'tuple', name = r.key, uri = r.uri,
            file = r.file, line = r.line, arity = r.arity }
    end
end

-- ── the LEFT side: registrations by CALL, and the key's kind per site ───────
local reg, kinds, unvalued = {}, {}, 0
for _, c in ipairs(dl.calls or {}) do
    if (c.callee or '') == R.left.verb then
        local a = argv.at(c, R.left.slot)
        if a then
            kinds[a.k or '?'] = (kinds[a.k or '?'] or 0) + 1
            -- ⚠ THE VALUE IS THE VOCABULARY'S, NOT THE SLOT'S. `a.v` is already
            -- filled by the erlang spec from the same artifact, but reading it
            -- HERE keeps the provenance explicit and survives a spec that stops
            -- filling it.
            local uri = a.name and vocab[a.name] or a.v
            if a.k == 'macro' and a.name and not uri then unvalued = unvalued + 1 end
            reg[#reg + 1] = { k = a.k, name = a.name, uri = uri,
                file = c.file, line = c.line }
        end
    end
end

--- the honest rung for a row of `carrier`, plus how many hops are ungraded
local function rung_of(carrier)
    local floor, ungraded = tiers.floor(R.hops[carrier] or {})
    return floor, ungraded
end

-- ── THE JOIN, both keys ─────────────────────────────────────────────────────
-- ⚠ BOTH CARRIERS, AND THE CARRIER IS RECORDED PER ROW. They are the same
-- relation (CART-0846) so they join identically, but a reader must be able to
-- ask which carrier produced a pair — the call form is argv-read, the tuple form
-- is interpretation-read, and those are different rungs of evidence.
local rows, by_uri, by_name = {}, {}, {}
local joined_by_carrier = { call = 0, tuple = 0 }
for _, s in ipairs(reg) do
    if s.uri and decl_by_uri[s.uri] then
        local d = decl_by_uri[s.uri]
        by_uri[s.uri] = true
        local fl, ung = rung_of('call')
        rows[#rows + 1] = { key = s.uri, kind = 'uri', carrier = 'call',
            left = { root = left_root, file = s.file, line = s.line, via = s.name },
            right = { root = right_root, file = d.file, line = d.line, alias = d.alias },
            rung = fl, ungraded = ung,
            provenance = ('key from %s (%s) · floor over %d hop(s)')
                :format(R.left.vocab, tostring(vstamp), #R.hops.call) }
    end
    if s.name then
        local short = s.name:gsub(R.name_rule.strip, '')
        if decl_by_alias[short] then by_name[short] = true end
    end
end

-- the SAME join, over the second carrier
for _, t in ipairs(tuple_regs) do
    local d = decl_by_uri[t.uri]
    if d then
        by_uri[t.uri] = true
        joined_by_carrier.tuple = joined_by_carrier.tuple + 1
        local fl, ung = rung_of('tuple')
        rows[#rows + 1] = { key = t.uri, kind = 'uri', carrier = 'tuple',
            left = { root = left_root, file = t.file, line = t.line, via = t.name },
            right = { root = right_root, file = d.file, line = d.line, alias = d.alias },
            rung = fl, ungraded = ung,
            provenance = ('key from %s (%s) · carrier: %d-tuple, interpretation from gen_mod')
                :format(R.left.vocab, tostring(vstamp), t.arity) }
    end
    if t.name then
        local short = t.name:gsub(R.name_rule.strip, '')
        if decl_by_alias[short] then by_name[short] = true end
    end
end

print('')
print('  POPULATIONS, and they answer four different questions')
print(('    client DECLARED          %4d site(s)  %d distinct URI, %d distinct alias%s')
    :format(ndecl, cnt(decl_by_uri), cnt(decl_by_alias),
        decl_opaque > 0 and (', %d with a non-literal URI slot — a frontier on THIS side'):format(decl_opaque) or ''))
local kparts = {}
for k, n in pairs(kinds) do kparts[#kparts + 1] = ('%s=%d'):format(k, n) end
table.sort(kparts)
print(('    server REGISTERED (call) %4d site(s)  key slot kinds: %s%s')
    :format(#reg, table.concat(kparts, ' '),
        unvalued > 0 and (', %d unvalued'):format(unvalued) or ''))
print(('    server REGISTERED (tuple) %3d site(s)  %s')
    :format(#tuple_regs, erlreg.summary(ers) or 'no tuple carrier here'))
print('')
print(('  ★ JOINED, by URI:  %d namespace(s)  (%d row(s))'):format(cnt(by_uri), #rows))
print(('    JOINED, by NAME: %d namespace(s)  — rule: strip %s, %s')
    :format(cnt(by_name), R.name_rule.strip, R.name_rule.match))
for _, carrier in ipairs({ 'call', 'tuple' }) do
    local fl, ung = rung_of(carrier)
    print(('    rung(%s) = %s  — the FLOOR over %d declared hop(s) [%s]%s')
        :format(carrier, tostring(fl), #R.hops[carrier],
            table.concat(R.hops[carrier], ' -> '),
            ung > 0 and (', ⚠ %d UNGRADED (no rung on this ladder)'):format(ung) or ''))
end
print('    ⚠ A COMPOSED ROW IS ONLY AS GOOD AS ITS WEAKEST HOP. Both carriers')
print('      were shipped asserting a flat `xlang`; the key rides on a distilled')
print('      profile artifact, which the ladder grades `stdlib` — two rungs down.')
print('    ⚠ THE TWO KEYS FIND DIFFERENT SETS, which is the point: a namespace')
print('      URI is the identity the protocol dispatches on, and each project')
print('      names it whatever it likes (?NS_CLIENT_STATE is CSI).')

-- ── THE REFUSED POPULATION: registered in a shape argv cannot reach ─────────
-- ★★★ THIS IS THE HALF A GREP CANNOT PRODUCE. ejabberd has TWO registration
-- mechanisms and cartograph reads one: a call, and a TUPLE RETURNED FROM A
-- CALLBACK (`{ok, [{iq_handler, ejabberd_local, ?NS_TIME, process_local_iq}]}`).
-- The second is a DECLARED registry — CART-0226's shape — with no call site to
-- scan, so argv reaches none of it. Counting it is what separates "this server
-- does not handle that namespace" from "it does, in a shape we cannot read",
-- and those are opposite claims that otherwise render as the same empty cell.
-- ⚠ A TEXT SCAN, DELIBERATELY, AND MARKED AS ONE. A REPORT axis may use a
-- heuristic where a RESOLVER may not: these rows are counted and never joined,
-- never minted, and carry no rung. Reading them properly needs the tuple shape
-- in the graph, which is its own ticket.
local refused_ns, refused_regs, refused_files = {}, 0, {}
do
    local exts = {}
    for _, e in ipairs(R.left.refused_exts) do exts[e] = true end
    local function walk(dir)
        for name, t in vim.fs.dir(dir) do
            local path = dir .. '/' .. name
            if t == 'directory' then
                if name:sub(1, 1) ~= '.' and not (ts.EXCLUDE_DIRS or {})[name:lower()] then
                    walk(path)
                end
            elseif exts[name:match('%.(%w+)$') or ''] then
                local fd = io.open(path, 'r')
                if fd then
                    local src = fd:read('a'); fd:close()
                    for tup in src:gmatch('{iq_handler,[^}]*}') do
                        refused_regs = refused_regs + 1
                        refused_files[path] = true
                        for nm in tup:gmatch('%?(NS_[%w_]+)') do refused_ns[nm] = true end
                    end
                end
            end
        end
    end
    walk(left_root)
end
-- guard the census: a pattern that silently matches nothing would report a
-- clean residual, which is the strongest possible wrong answer here
print('')
-- ⚠ THIS CENSUS NOW MEASURES A POPULATION THAT IS READ, and saying "argv
-- cannot read it" without saying who DOES would be stale prose describing a
-- solved gap. argv still cannot; `erlreg` reads it by interpretation
-- (CART-0846). The census is KEPT rather than deleted because it is the
-- independent check on the reader: a TEXT SCAN counted 32 and the structural
-- reader claims 26 of 32 with 6 refused by kind, and those two numbers agreeing
-- is what says the reader is not silently dropping a shape.
print(('  THE SECOND CARRIER, censused by TEXT as a check on the reader: %d tagged tuple(s) in %d file(s), %d distinct namespace(s)')
    :format(refused_regs, cnt(refused_files), cnt(refused_ns)))
print(('    structural reader: %d read · %d refused by element kind (%d total) %s')
    :format(#tuple_regs, (ers.notvalue or 0), ers.tuples,
        ers.tuples == refused_regs and '★ COUNTS AGREE'
            or '⚠ COUNTS DISAGREE — the reader or the scan is missing a shape'))
if refused_regs == 0 then
    print('    ⚠ ZERO IS SUSPECT, NOT CLEAN: this is a text scan for a shape known')
    print('      to exist in ejabberd. Zero means the pattern or the walk is')
    print('      wrong far more likely than that the mechanism went away.')
else
    -- ★★★ AND THE COUNT ALONE WOULD MISLEAD: what matters is whether the
    -- unreadable mechanism registers the SAME namespaces as the readable one or
    -- DIFFERENT ones. Equal counts are consistent with both, and they mean
    -- opposite things — a duplicate registry costs the join nothing, a disjoint
    -- one is a whole second set of handlers the join cannot see. A COUNT IS NOT
    -- A CLASS, so the sets are compared and not their sizes.
    local joinable, also_new = {}, {}
    for nm in pairs(refused_ns) do
        local v = vocab[nm]
        if v and decl_by_uri[v] then
            joinable[v] = true
            if not by_uri[v] then also_new[v] = true end
        end
    end
    print(('    ★ %d of them join by URI, and %d of the joined namespaces come')
        :format(cnt(joinable), joined_by_carrier.tuple > 0 and cnt(joinable) or 0))
    print(('      from this carrier — %d join rows out of %d carry carrier=tuple.')
        :format(joined_by_carrier.tuple, #rows))
    -- ★ THE MARGINAL VALUE IS NOW ZERO BY CONSTRUCTION, AND THAT IS THE POINT.
    -- Before erlreg this section reported "reading this shape would take the
    -- join 6 -> 10". It is read, the join IS 10, and the residual's remaining
    -- gain is nil — which is what a closed gap looks like. Keep the line: a
    -- residual that silently stops being reported cannot be seen to have closed.
    print('    ⚠ AND THE REMAINING GAIN IS NOW NIL, BY CONSTRUCTION: before this')
    print('      carrier was read the same census said "6 -> 10". It is read, the')
    print('      join IS 10, and a closed gap should still report itself.')
end

-- ── THE CEILINGS, for reading the join against ──────────────────────────────
local mentioned, mentioned_valued, m_uri, m_name = {}, 0, {}, {}
do
    local function walk(dir)
        for name, t in vim.fs.dir(dir) do
            local path = dir .. '/' .. name
            if t == 'directory' then
                if name:sub(1, 1) ~= '.' and not (ts.EXCLUDE_DIRS or {})[name:lower()] then walk(path) end
            elseif (name:match('%.(%w+)$') or '') == 'erl' or (name:match('%.(%w+)$') or '') == 'hrl' then
                local fd = io.open(path, 'r')
                if fd then
                    local src = fd:read('a'); fd:close()
                    for nm in src:gmatch('%?(NS_[%w_]+)') do mentioned[nm] = true end
                end
            end
        end
    end
    walk(left_root)
    for nm in pairs(mentioned) do
        local v = vocab[nm]
        if v then mentioned_valued = mentioned_valued + 1
            if decl_by_uri[v] then m_uri[v] = true end end
        if decl_by_alias[(nm:gsub(R.name_rule.strip, ''))] then m_name[nm] = true end
    end
end
local v_uri = 0
for _, v in pairs(vocab) do if decl_by_uri[v] then v_uri = v_uri + 1 end end
print('')
print('  CEILINGS — read the join against these, never alone')
print(('    MENTIONED  %3d name(s) in the text, %d valued  ->  %d by URI, %d by name')
    :format(cnt(mentioned), mentioned_valued, cnt(m_uri), cnt(m_name)))
print(('    VOCABULARY %3d value(s) the library defines    ->  %d by URI')
    :format(nvocab, v_uri))
-- ⚠⚠ NAMES AGAINST NAMES. My first version printed "119 names ... only 57
-- reach a call argument" — 119 DISTINCT NAMES against 57 SITES, two different
-- units in one comparison, which makes the ratio meaningless and flattering in
-- an unpredictable direction. The reachable figure is a DISTINCT-NAME count
-- over every argument slot in the corpus, not the registration sites.
local argv_names = {}
for _, c in ipairs(dl.calls or {}) do
    for i = 1, 16 do
        local a = argv.at(c, i)
        if not a then break end
        if a.k == 'macro' and a.name and a.name:match('^NS_') then argv_names[a.name] = true end
    end
end
print(('    ⚠ %d distinct name(s) occur in the text; %d of them reach ANY call')
    :format(cnt(mentioned), cnt(argv_names)))
print(('      argument, and %d reach a REGISTRATION argument. The gap is the tuple')
    :format((function ()
        local seen = {}
        for _, r in ipairs(reg) do if r.name then seen[r.name] = true end end
        return cnt(seen)
    end)()))
print('      form above plus non-argument positions (record fields, guards, heads).')

if want_rows then
    print('')
    print('  LINKAGE ROWS (shaped for CART-0026; nothing is minted today)')
    table.sort(rows, function (a, b) return a.key < b.key end)
    for _, r in ipairs(rows) do
        print(('    %s'):format(r.key))
        print(('      L %s:%s via ?%s'):format(r.left.file, tostring(r.left.line), tostring(r.left.via)))
        print(('      R %s:%s as %s'):format(r.right.file, tostring(r.right.line), tostring(r.right.alias)))
        print(('      rung=%s%s · %s'):format(tostring(r.rung),
            (r.ungraded or 0) > 0 and (' (+%d UNGRADED hop)'):format(r.ungraded) or '',
            r.provenance))
    end
end
