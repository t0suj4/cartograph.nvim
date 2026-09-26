-- lossreport — WHAT DID EXTRACTION SEE AND NOT RECORD? The L2 loss report (CART-0847).
--
--   nvim --headless -u NONE -l tools/lossreport.lua <corpus|dir> [--lang L] [--top N] [--show TYPE]
--
-- ★★ THE QUESTION. Extraction is a set of POSITIVE matchers: a query matches, a fact is minted, and when nothing
-- claims a construct the walk simply does not fire. So nothing computes the complement, and a construct the
-- neutral schema has no slot for vanishes SILENTLY — the `{iq_handler, …}` tuples before CART-0846 read them,
-- proto's message fields, an atom in a position no rule claims. Every later absence is then ambiguous: "the code
-- does not do that" and "the schema had no slot for it" read the same. This computes the complement.
--
-- ★ THE DENOMINATOR IS NOT EVERY NODE (the ticket's rejected design (a), harness error #4: a raw-tree census
-- over a population no claim was made about invents a crisis). The unit is a MAXIMAL DARK SUBTREE: a named node
-- that no recorded fact touches while its parent is touched — "this whole construct left no trace" — counted
-- once at its root, and reported by node TYPE (bounded: a grammar has ~100 named types) and by POSITION
-- (parent type / field). A tuple of atoms is one dark `tuple`, not four dark atoms.
--
-- WHAT COUNTS AS A FACT (a touch), read off the extracted records, never a list of carriers:
--   a definition        its range START (a point: the def is recorded, its interior is examined, not excused),
--                       and its HEADER: a clause node of the language's `fn_types` inside a recorded def has every
--                       child but its `body_field` claimed (the name, the parameters: flow records them)
--   a call site         the whole CALL NODE the language's own `calls` query captures as @call (the record's
--                       argv is its claim on the arguments, and argv carries no positions of its own) — and when
--                       the record's `full` key is QUALIFIED (`lists.foldl/3`), the parent the call is the tail of
--                       (erlang's `remote`: the module is in `full`, positionless)
--   an edge site        each `at` range
--   a flow row          its statement's start, and every NAME LEAF inside its own statement node (stopping at a
--                       nested row) whose text the row records in def/use/rmw — df claims names, not constructs, so a
--                       condition `(a > 0)` is touched through `a` and its `0` stays a dark leaf
-- ★ STAGED, because a fact may be recorded LATER: the post-passes (cartograph.postpass — embedded SQL, the
-- erlang tuple registry, the framework and deployment layers) claim things extraction proper does not. Each
-- row carries two counts, dark after EXTRACTION and dark in the FINAL graph (after the same passes the open path
-- runs, minus the session-bound db link), so a construct a pass picks up reads "claimed later", not "lost".
-- ⚠ A pass that READ something and refused it (a recorded refusal, not a fact) still counts as dark here.
-- ⚠ Only files with a tree-sitter language are walked. A file no grammar parses (.proto is read by a token
-- scanner) is outside this denominator entirely, and the header says how many were skipped.
--
-- LEAF vs STRUCTURE. A dark root with no named children is one token (a literal, a name): a VALUE the graph
-- did not keep. One with named children is a whole CONSTRUCT the graph cannot see. They are listed apart
-- because they mean different things, and structure is the loss the ticket is about.
--
-- ★ IT MUST BE ABLE TO DECLINE (a grouping rule that claims everything is vacuous): the WITNESS line counts the
-- language's @call nodes and how many sit inside a dark root. Calls are what extraction reads first; a report
-- that showed them dark outside a deliberately-skipped context (a -spec) would be measuring its own anchors.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
dofile(here .. 'bench.lua').bootstrap()

local ts = require 'cartograph.providers.treesitter'
local flow = require 'cartograph.flow'
local tsutil = require 'cartograph.spec.tsutil'

local M = {}

local function pos_lt(al, ac, bl, bc) return al < bl or (al == bl and ac < bc) end

--- anchors by file: { [file] = { {sl, sc, el, ec, point = bool}… } } from the extracted records.
--- `callcover[file]` maps a call's @name start `line:char` to its @call node range (see calls_of).
function M.anchors(data, callcover, files)
    local A, D, R = {}, {}, {} -- anchors, def ranges, row names by `line:col:type` (0-based)
    local function add(file, sl, sc, el, ec, point)
        if not file then return end
        local l = A[file]; if not l then l = {}; A[file] = l end
        l[#l + 1] = { sl, sc, el, ec, point = point }
    end
    local function rng(r) return r and r.start and r['end'] and r or nil end
    for _, n in ipairs(data.nodes or {}) do
        local r = rng(n.range)
        if r and n.kind ~= 'module' then add(n.file, r.start.line, r.start.char, r.start.line, r.start.char, true) end
        if (n.kind == 'function' or n.kind == 'method') and r and n.file then
            local d = D[n.file]; if not d then d = {}; D[n.file] = d end
            d[#d + 1] = { r.start.line, r.start.char, r['end'].line, r['end'].char }
        end
        if n.kind == 'function' or n.kind == 'method' then
            local ok, rec = pcall(flow.record, n)
            if ok and rec then
                for _, s in ipairs(rec.stmts or {}) do
                    -- `l` and `c` are both 1-based
                    if s.l and s.c then
                        add(n.file, s.l - 1, s.c - 1, s.l - 1, s.c - 1, true)
                        if s.t then
                            local rk = R[n.file]; if not rk then rk = {}; R[n.file] = rk end
                            local names = rk[(s.l - 1) .. ':' .. (s.c - 1) .. ':' .. s.t] or {}
                            for _, list in ipairs({ s.def, s.use, s.rmw }) do
                                for _, nm in ipairs(list or {}) do names[nm] = true end
                            end
                            rk[(s.l - 1) .. ':' .. (s.c - 1) .. ':' .. s.t] = names
                        end
                    end
                end
            end
        end
    end
    for _, c in ipairs(data.calls or {}) do
        local r = rng(c.at)
        if r then
            local cc = callcover and callcover[c.file] and callcover[c.file][r.start.line .. ':' .. r.start.char]
            if cc and cc.tail and c.full and c.full:find('.', 1, true) then cc = cc.tail end
            if cc then add(c.file, cc[1], cc[2], cc[3], cc[4], false)
            else add(c.file, r.start.line, r.start.char, r['end'].line, r['end'].char, false) end
        end
    end
    for _, e in ipairs(data.edges or {}) do
        local file = e.file or (e.from and e.from:match('^([^:]+)::')) or nil
        local ats = e.at
        if ats and ats.start then ats = { ats } end
        for _, r in ipairs(ats or {}) do
            if rng(r) then add(e.file or file, r.start.line, r.start.char, r['end'].line, r['end'].char, false) end
        end
    end
    -- the name leaves each row records, found in its own statement node (a nested row claims its own)
    for _, f in ipairs(files or {}) do
        local rk = R[f.rel]
        if rk then
            local ids = flow.leaf_ids(ts.spec[f.lang] and ts.spec[f.lang].df_ids)
            local function key(nd) local a, b = nd:start(); return a .. ':' .. b .. ':' .. nd:type() end
            local function mark(nd, names)
                for c in nd:iter_children() do
                    if c:named() and not rk[key(c)] then
                        if ids[c:type()] and names[vim.treesitter.get_node_text(c, f.src)] then
                            local a, b, cc, d = c:range()
                            add(f.rel, a, b, cc, d, false)
                        end
                        mark(c, names)
                    end
                end
            end
            local function walk(nd)
                local names = rk[key(nd)]
                if names then mark(nd, names) end
                for c in nd:iter_children() do if c:named() then walk(c) end end
            end
            walk(f.root)
        end
    end
    -- a per-line index: every anchor listed on each line it spans
    local idx = {}
    for file, l in pairs(A) do
        local byline = {}
        for _, a in ipairs(l) do
            for ln = a[1], a[3] do
                local b = byline[ln]; if not b then b = {}; byline[ln] = b end
                b[#b + 1] = a
            end
        end
        idx[file] = byline
    end
    return idx, D
end

-- is [sl,sc)-(el,ec) inside one of the file's recorded def ranges?
local function in_def(defs, sl, sc, el, ec)
    for _, d in ipairs(defs or {}) do
        if not pos_lt(sl, sc, d[1], d[2]) and not pos_lt(d[3], d[4], el, ec) then return true end
    end
    return false
end

-- does any anchor touch [sl,sc)–(el,ec)? a point touches when it sits inside (or at the start of) the node; a
-- range when it overlaps
local function touched(byline, sl, sc, el, ec)
    if not byline then return false end
    for ln = sl, el do
        for _, a in ipairs(byline[ln] or {}) do
            local s_lt_end = pos_lt(a[1], a[2], el, ec) or (a[1] == sl and a[2] == sc)
            local e_after = a.point and not pos_lt(a[3], a[4], sl, sc) or pos_lt(sl, sc, a[3], a[4])
            if s_lt_end and e_after then return true end
        end
    end
    return false
end

-- the language's @call nodes in one tree, keyed by their @name start, from the spec's own `calls` query
local qcache = {}
local function calls_of(lang, troot, src)
    local spec = ts.spec[lang]
    if not (spec and spec.calls) then return {}, {} end
    local q = qcache[lang]
    if q == nil then
        local ok, parsed = pcall(vim.treesitter.query.parse, lang, spec.calls)
        q = ok and parsed or false
        qcache[lang] = q
    end
    if not q then return {}, {} end
    local cover, nodes = {}, {}
    for _, match in q:iter_matches(troot, src, 0, -1, { all = true }) do
        local call, name
        for id, ns in pairs(match) do
            local cap = q.captures[id]
            local nd = type(ns) == 'table' and ns[#ns] or ns
            if cap == 'call' then call = nd elseif cap == 'name' then name = nd end
        end
        if call then
            nodes[#nodes + 1] = call
            if name then
                local nl, nc = name:start()
                local a, b, c, d = call:range()
                local p = call:parent()
                local pa, pb, pc, pd
                if p then pa, pb, pc, pd = p:range() end
                -- the parent this call is the TAIL of (same end, earlier start): used only for a qualified record
                local tail = p and pc == c and pd == d and (pa < a or (pa == a and pb < b)) and { pa, pb, pc, pd } or nil
                cover[nl .. ':' .. nc] = { a, b, c, d, tail = tail }
            end
        end
    end
    return cover, nodes
end

--- the report. Returns { files, skipped, rows = { [key] = row }, witness = {calls, dark}, torn }
--- row = { type, leaf, pos = { [parent/field] = n }, ext = n (dark after extraction), fin = n (dark in the
--- final graph), ex = { "file:line text" } }
function M.run(root, opts)
    opts = opts or {}
    local data = ts.extract(root)
    -- parse every walked file ONCE (both stages walk the same trees)
    local files, skipped = {}, 0
    local callcover = {}
    for _, rel in ipairs(ts.list_files(root)) do
        local lang = ts.lang_of(rel)
        if not lang then skipped = skipped + 1
        elseif not opts.lang or lang == opts.lang then
            local fh = io.open(root .. '/' .. rel, 'r')
            local src = fh and fh:read('a'); if fh then fh:close() end
            -- ⚠ PARSE WITH THE FILE'S GRAMMAR, NOT ITS LANGUAGE FAMILY: lang_of says `javascript` for a .ts file
            -- (the spec family), parse_lang says `typescript`. Parsing a .d.ts with the js grammar tore 600+
            -- statements into ERROR nodes and put 2624 calls inside them — the first converse run's whole witness.
            local plang = ts.parse_lang(rel) or lang
            if src and pcall(vim.treesitter.language.add, plang) then
                local okp, parser = pcall(vim.treesitter.get_string_parser, src, plang)
                local tree = okp and parser and parser:parse()[1]
                if tree then
                    local cover, cnodes = calls_of(ts.spec[plang] and plang or lang, tree:root(), src)
                    callcover[rel] = cover
                    files[#files + 1] = { rel = rel, lang = ts.spec[plang] and plang or lang, src = src,
                        root = tree:root(), calls = cnodes, parser = parser }
                end
            end
        end
    end
    local rows, torn = {}, 0
    local extdark = {} -- node id -> row key of a dark root after EXTRACTION, to see which the final graph touches
    local function darkroots(idx, defs, stage, witness)
        local seen = {}
        for _, f in ipairs(files) do
            local byline = idx[f.rel]
            local fnt = ts.fn_types(f.lang) or {}
            local bodyf = ts.spec[f.lang] and ts.spec[f.lang].body_field or 'body'
            local function walk(node, ptype, header)
                for c, fld in node:iter_children() do
                  -- a recorded def's header part (anything but the body field of a fn_types clause) is claimed
                  if c:named() and not (header and fld ~= bodyf) then
                    local t = c:type()
                    if t == 'ERROR' then torn = torn + (stage == 'fin' and 1 or 0) end
                    if not tsutil.is_comment(c) then
                        local sl, sc, el, ec = c:range()
                        if not (sl == el and sc == ec) then
                            if touched(byline, sl, sc, el, ec) then
                                -- dark after extraction, touched now: a post-pass claimed it (whole or in part)
                                local ek = stage == 'fin' and extdark[c:id()]
                                if ek then rows[ek].later = (rows[ek].later or 0) + 1 end
                                local sr = { c:range() }
                                walk(c, t, fnt[t] and in_def(defs[f.rel], sr[1], sr[2], sr[3], sr[4]) or false)
                            else
                                local leaf = c:named_child_count() == 0
                                local key = (leaf and 'leaf ' or '') .. t
                                local r = rows[key]
                                if not r then r = { type = t, leaf = leaf, pos = {}, ext = 0, fin = 0, ex = {} }; rows[key] = r end
                                r[stage] = r[stage] + 1
                                if stage == 'fin' then
                                    local pk = ptype .. (fld and ('.' .. fld) or '')
                                    r.pos[pk] = (r.pos[pk] or 0) + 1
                                    if #r.ex < 3 then
                                        local txt = vim.treesitter.get_node_text(c, f.src):gsub('%s+', ' '):sub(1, 70)
                                        r.ex[#r.ex + 1] = ('%s:%d  %s'):format(f.rel, sl + 1, txt)
                                    end
                                end
                                seen[c:id()] = true
                                if stage == 'ext' then extdark[c:id()] = key end
                            end
                        end
                    end
                  end
                end
            end
            walk(f.root, f.root:type())
            if witness then
                local skip = ts.spec[f.lang] and ts.spec[f.lang].skip_call
                for _, cn in ipairs(f.calls) do
                    witness.calls = witness.calls + 1
                    local a = cn
                    while a do
                        if seen[a:id()] then
                            witness.dark = witness.dark + 1
                            -- a call the SPEC deliberately does not extract (erlang: a type in a -spec) is dark by
                            -- decision; any other dark call means the anchors missed something extraction read
                            local torn_ = false
                            local up = cn:parent()
                            while up do if up:type() == 'ERROR' then torn_ = true; break end up = up:parent() end
                            if skip and skip(cn, f.src) then witness.skipped = witness.skipped + 1
                            elseif torn_ then witness.torn = witness.torn + 1 -- a torn parse: extraction could not read it either
                            elseif #witness.ex < 5 then
                                witness.ex[#witness.ex + 1] = ('%s:%d'):format(f.rel, (cn:start()) + 1)
                            end
                            break
                        end
                        a = a:parent()
                    end
                end
            end
        end
    end
    local i1, d1 = M.anchors(data, callcover, files)
    darkroots(i1, d1, 'ext')
    require('cartograph.postpass').run(data, { skip = { dblink = true } })
    local witness = { calls = 0, dark = 0, skipped = 0, torn = 0, ex = {} }
    local i2, d2 = M.anchors(data, callcover, files)
    darkroots(i2, d2, 'fin', witness)
    return { files = #files, skipped = skipped, rows = rows, witness = witness, torn = torn }
end

local function main()
    local a = _G.arg or {}
    local target, lang, top, show = a[1], nil, 25, nil
    for i = 2, #a do
        if a[i] == '--lang' then lang = a[i + 1]
        elseif a[i] == '--top' then top = tonumber(a[i + 1]) or top
        elseif a[i] == '--show' then show = a[i + 1] end
    end
    if not target then
        io.write('usage: lossreport.lua <corpus|dir> [--lang L] [--top N] [--show TYPE]\n'); os.exit(2)
    end
    local root = target
    if vim.fn.isdirectory(root) ~= 1 then
        local c = dofile(here .. 'bench.lua').corpus(target)
        root = c and c.root or target
    end
    local R = M.run(root, { lang = lang })
    io.write(('%s  files=%d (skipped %d with no tree-sitter language)%s\n'):format(root, R.files, R.skipped,
        lang and ('  [lang=' .. lang .. ']') or ''))
    local W = R.witness
    io.write(('WITNESS: %d @call nodes, %d inside a dark root: %d where the spec skips calls by decision, %d in a'
        .. ' torn parse (ERROR), %d neither%s\n')
        :format(W.calls, W.dark, W.skipped, W.torn, W.dark - W.skipped - W.torn,
            #W.ex > 0 and ('  e.g. ' .. table.concat(W.ex, ' ')) or ''))
    local list = {}
    for k, r in pairs(R.rows) do r.key = k; list[#list + 1] = r end
    table.sort(list, function (x, y) if x.fin ~= y.fin then return x.fin > y.fin end return x.key < y.key end)
    for _, leafpass in ipairs({ false, true }) do
        io.write(leafpass and '\n── LEAF (one token the graph did not keep) ──\n'
            or '── STRUCTURE (a whole construct no fact touches) ──\n')
        io.write(('  %7s %7s  %s\n'):format('final', 'extract', 'type   top positions'))
        local k = 0
        for _, r in ipairs(list) do
            if r.leaf == leafpass and r.fin > 0 and k < top then
                k = k + 1
                local ps = {}
                for p, n in pairs(r.pos) do ps[#ps + 1] = { p, n } end
                table.sort(ps, function (x, y) return x[2] > y[2] end)
                local pt = {}
                for i = 1, math.min(3, #ps) do pt[#pt + 1] = ps[i][1] .. '=' .. ps[i][2] end
                io.write(('  %7d %7d  %s   %s\n'):format(r.fin, r.ext, r.type, table.concat(pt, ' ')))
            end
        end
    end
    local later, lt = 0, {}
    for _, r in ipairs(list) do
        if r.later then later = later + r.later; lt[#lt + 1] = r.key .. '=' .. r.later end
    end
    io.write(('\nclaimed LATER by a post-pass (a dark root after extraction that the final graph touches): %d%s\n')
        :format(later, #lt > 0 and ('  ' .. table.concat(lt, ' ')) or ''))
    io.write('(counts are MAXIMAL dark roots per stage: a pass that touches one tuple in a list turns the one dark\n'
        .. ' list into its dark siblings, so a final count can exceed the extraction count)\n')
    if show then
        for _, r in ipairs(list) do
            if r.type == show then
                io.write(('\n%s%s: %d final / %d extraction\n'):format(r.leaf and 'leaf ' or '', r.type, r.fin, r.ext))
                for _, e in ipairs(r.ex) do io.write('    ', e, '\n') end
            end
        end
    end
end

if _G.arg and _G.arg[0] and _G.arg[0]:match('lossreport%.lua$') then main() end
return M
