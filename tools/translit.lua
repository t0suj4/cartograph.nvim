-- TRANSLIT — the expression IR's own round-trip oracle: emit lua from the schema, parse
-- it back, and require the two IRs to be IDENTICAL.
--
--   nvim --headless -u NONE -l tools/translit.lua <corpus|dir> [--show=N] [--kinds] [--mem]
--                                                 [--text]
--
-- ── WHY THIS IS A REAL TWO-IMPLEMENTATION CHECK ────────────────────────────────
-- expr.lua's harvest is one direction: tree → schema. This is the other: schema → text →
-- tree → schema. The two share NO code (the emitter here reads only the documented schema
-- fields; the harvest reads only tree nodes), so a disagreement is a real bug on ONE side
-- — the charter bar, applied inside the substrate rather than against lua-ls.
--
-- A FIXPOINT ON THE IR, NOT ON THE TEXT, and that is the whole design. The schema is
-- deliberately lossy about SURFACE: build() unwraps parenthesized_expression
-- (expr.lua:219), comments are not modelled, and `{k='table'}` / `{k='fn'}` are ALLOCATION
-- MARKERS holding no contents at all. Text equality would therefore fail everywhere for
-- reasons that are not defects. What the schema CLAIMS is that it captures an expression's
-- structure, and `IR == reparse(emit(IR))` tests exactly that claim and nothing else.
--
-- ── IT NEEDS NO CALIBRATION, WHICH IS THE POINT ────────────────────────────────
-- Every other census gate in tools/ pins an EXPECTED number and then rots: dfparity's self
-- pin was recalibrated ~30 times before being retired (CART-0024), matrix sits red on main
-- (CART-0232), and a living corpus can never hold a pinned census at all (dfgate/f2gate
-- skip them for exactly that reason). This oracle compares the graph against ITSELF, so
-- there is no baseline to go stale and no corpus it cannot run on — pinned, living, or a
-- bare directory. A green run means something on the day you run it.
--
-- ── --text: AND WHAT DOES THE TEXT LOSE? ───────────────────────────────────────
-- The fixpoint above deliberately says nothing about text, which leaves the obvious
-- question unanswered: when the emitter DOES produce text, what did it drop? `--text`
-- compares each emitted expression against THE SOURCE IT CAME FROM (`.at`, read raw off
-- disk) as token streams — comments counted then dropped, parens dropped from both sides
-- (build() unwraps them and the emitter has no precedence table), whitespace never a
-- token. MEASURED, and the claim "only comments are lost" holds:
--
--   corpus     compared   same tokens   spans w/ a comment   num reformat   UNEXPLAINED
--   self         51499       51471              3                28             0
--   factorio     46198       46172             45                26             0
--   desynced     54916       54636              6               265             0  (+15 CR)
--   wow         604502      602719            164              1631             0  (+152 CR)
--
-- Comments inside an emittable expression are RARE (3 in 51k on our own tree, 164 in 604k
-- on wow), so the claim is true and nearly VACUOUS. Two honesty notes that matter more
-- than the claim: this covers only what EMITTED (79.5% of expressions on self), and the
-- real losses are the REFUSALS above — table contents, closure bodies, loop clauses —
-- which are declared rather than silent. Do not read a green --text as "the IR keeps the
-- program"; read it as "where the IR speaks, it does not quietly change the words".
--
-- WHAT IT FOUND, and this is why comparing against the FILE and not against the IR was
-- worth it: `store.content` read with vim.fn.readfile (STRIPS \r) while extraction read
-- with transport.read (io.open, KEEPS it), so on a CRLF corpus the same file was two
-- different strings and the extract-time IR and the on-demand rebuild disagreed about
-- every multi-line string literal. FIXED in v110 — analysis reads through
-- transport.read_source, one canonical \n text (CART-0238).
--
-- THE CR-ONLY CLASS SURVIVES THAT FIX, and deliberately: this mode still reads the file
-- RAW, so it still sees the CRs the canonical text drops (15 on desynced, 152 on wow).
-- Reading it the same way the IR did would put both sides of this comparison back on ONE
-- reader — the exact blind spot that let the bug live. So the class is now "CRLF
-- normalized for analysis, as lua's own lexer does inside a long string", and it doubles
-- as the guard that the normalization stays deliberate and stays the only one.
--
-- ── A REFUSAL IS NOT A FAILURE ─────────────────────────────────────────────────
-- Where the schema stores no contents the emitter DECLINES rather than inventing, because
-- emitted code that merely looks runnable is the phantom-fact class at its worst
-- ([[cartograph-concern-layering]] rates a manufactured fact above a manufactured absence).
-- So the exit rule counts only the two things that are unambiguously wrong:
--   MISMATCH — the round-trip changed the structure   -> a bug in the harvest or the emitter
--   INVALID  — the emitted text does not parse        -> a bug in the emitter
-- Refusals are reported, partitioned by the schema kind that stopped them, and never fatal.
-- That is what keeps this gate greenable, and a gate nobody can move is not a gate
-- (CART-0192, and the exit rule this deliberately does NOT copy from guards.lua, CART-0229).

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/translit%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local expr = require 'cartograph.expr'

local name = arg and arg[1]
if not name then
    print('usage: nvim --headless -u NONE -l tools/translit.lua <corpus|dir>'
        .. ' [--show=N] [--kinds] [--mem]')
    os.exit(2)
end
local show, want_kinds, want_mem, want_text = 0, false, false, false
for i = 2, #(arg or {}) do
    if arg[i]:match('^%-%-show=') then show = tonumber((arg[i]:gsub('^%-%-show=', ''))) or 0 end
    if arg[i] == '--kinds' then want_kinds = true end
    if arg[i] == '--mem' then want_mem = true end
    if arg[i] == '--text' then want_text = true end
end

-- a corpus KEY or a plain directory, so this runs anywhere (see the calibration note above)
local root = name
local okc, corpus = pcall(bench.corpus, name)
if okc and type(corpus) == 'table' and corpus.root then root = corpus.root end
root = vim.fn.expand(root)
if vim.fn.isdirectory(root) ~= 1 then
    print('not a directory and not a known corpus: ' .. tostring(name))
    os.exit(2)
end

-- ── THE EMITTER: schema → lua text, or a refusal naming the kind that stopped it ──
local refused

-- Lua admits only a prefixexp (name / index / call / parenthesized) to the left of
-- `.` `:` `[` `(`. So `('%s'):format(x)` CANNOT shed its parens — `'%s':format(x)` is a
-- syntax error — yet build() unwraps them because they are semantically transparent, and
-- the IR keeps no record. MEASURED: this single case was 782 invalid emissions on the
-- first self run, every one a `<literal>:format(…)`.
-- THE GENERAL OBLIGATION, worth more than the fix: the IR is a SEMANTIC structure, so an
-- emitter owes it the syntax it deliberately discarded.
local NEEDS_NO_PARENS = { name = true, field = true, index = true, call = true,
    un = true, bin = true } -- un/bin already self-parenthesize below

local emit
local function base(x)
    local s = emit(x)
    if not s then return nil end
    return NEEDS_NO_PARENS[x.k] and s or ('(' .. s .. ')')
end

function emit(e)
    if type(e) ~= 'table' or not e.k then refused = 'malformed'; return nil end
    local k = e.k
    if k == 'lit' then
        if e.ty == 'str' then return e.v end -- raw source text, quotes included
        if e.ty == 'nil' then return 'nil' end
        if e.ty == 'bool' then return tostring(e.v) end
        -- NUMBERS MUST ROUND-TRIP EXACTLY, and `tostring` does not: it formats with %.14g,
        -- so a literal carrying more precision returns as a DIFFERENT double. MEASURED on
        -- wow: 3 mismatches, every one this shape — LibGraph's 0.707106781186548 (1/sqrt2)
        -- and DrDamage's 1.7038716888919. They PRINT identically while comparing unequal,
        -- which is exactly how the bug hides. Short form first so ordinary numbers stay
        -- readable, else %.17g, which is round-trip-exact for IEEE doubles. A
        -- transliterator that silently alters a numeric constant is worse than one that
        -- refuses to emit at all.
        if e.ty == 'num' then
            local short = ('%.14g'):format(e.v)
            if tonumber(short) == e.v then return short end
            return ('%.17g'):format(e.v)
        end
        refused = 'lit:' .. tostring(e.ty); return nil
    end
    if k == 'name' then return e.n end
    if k == 'vararg' then return '...' end
    if k == 'field' then
        local b = base(e.b); if not b then return nil end
        return b .. (e.method and ':' or '.') .. e.n
    end
    if k == 'index' then
        local b, i = base(e.b), emit(e.i)
        if not (b and i) then return nil end
        return b .. '[' .. i .. ']'
    end
    if k == 'call' then
        local f = base(e.f); if not f then return nil end
        local parts = {}
        for _, a in ipairs(e.a or {}) do
            local s = emit(a); if not s then return nil end
            parts[#parts + 1] = s
        end
        return f .. '(' .. table.concat(parts, ', ') .. ')'
    end
    if k == 'un' then
        local x = emit(e.e); if not x then return nil end
        -- a word operator needs a space, and `-` must not glue into `--` (a COMMENT,
        -- which would silently swallow the rest of the line)
        return '(' .. e.op .. (e.op:match('^%a') and ' ' or '') .. x .. ')'
    end
    if k == 'bin' then
        local l, r = emit(e.l), emit(e.r)
        if not (l and r) then return nil end
        -- ALWAYS parenthesize: the IR carries no precedence, and build() unwraps parens,
        -- so this is structure-preserving in both directions with no precedence table
        return '(' .. l .. ' ' .. e.op .. ' ' .. r .. ')'
    end
    if k == 'pair' then
        local key = emit(e.key); if not key then return nil end
        local val = e.val and emit(e.val) or nil
        if e.val and not val then return nil end
        -- ONE SHAPE, TWO CONVENTIONS, and they are distinguishable: a bare identifier key
        -- stores `v` UNQUOTED (expr.lua:303) while any other string lit keeps its quotes
        -- (expr.lua:229). The quote is the signal for whether the key needs brackets.
        local lhs = key:match('^["\']') and ('[' .. key .. ']') or key
        return val and (lhs .. ' = ' .. val) or lhs
    end
    -- CONTENTS ABSENT BY DESIGN — decline, never invent
    if k == 'table' then refused = 'table (allocation marker: no contents in IR)'; return nil end
    if k == 'fn' then refused = 'fn (closure body never descended)'; return nil end
    if k == '?' then refused = '? ' .. tostring(e.t); return nil end
    refused = 'unhandled:' .. k
    return nil
end

-- ── structural equality over the closed schema ────────────────────────────────
local SCALARS = { 'k', 'ty', 'v', 'n', 'op', 'method', 't' }
local KIDS = { 'b', 'i', 'f', 'e', 'l', 'r', 'key', 'val' }
local function eq(a, b, path)
    if type(a) ~= 'table' or type(b) ~= 'table' then return a == b, path end
    for _, f in ipairs(SCALARS) do
        local x, y = a[f], b[f]
        if x == expr.NIL then x = '<nil>' end -- the sentinel compares by identity
        if y == expr.NIL then y = '<nil>' end
        if x ~= y then
            return false, ('%s.%s: %s vs %s'):format(path, f, tostring(x), tostring(y))
        end
    end
    for _, f in ipairs(KIDS) do
        if (a[f] ~= nil) ~= (b[f] ~= nil) then return false, path .. '.' .. f .. ' presence' end
        if a[f] ~= nil then
            local ok, why = eq(a[f], b[f], path .. '.' .. f)
            if not ok then return false, why end
        end
    end
    local na, nb = #(a.a or {}), #(b.a or {})
    if na ~= nb then return false, ('%s.a arity %d vs %d'):format(path, na, nb) end
    for i = 1, na do
        local ok, why = eq(a.a[i], b.a[i], path .. '.a[' .. i .. ']')
        if not ok then return false, why end
    end
    return true, nil
end

-- ── ATTRIBUTING A NON-PARSE: emitter fault, or source the grammar rejects? ─────
-- A `str` lit is emitted VERBATIM (its `v` IS the raw source text, quotes included), so
-- when the only questionable content is such a literal the emitter changed NOTHING and
-- cannot be at fault. MEASURED on wow: 9 non-parses, every one a string carrying a
-- LUA 5.1 ESCAPE that 5.2+ and the tree-sitter grammar reject — `\%`, `\|`, `\]`, `\m`
-- (WoW's runtime is 5.1, so this is real code, not corruption).
-- WHY BOTHER SEPARATING THEM: charging these to the emitter would leave this gate
-- permanently red on the largest lua corpus for something that is not a defect — the
-- "a gate nobody can move is not a gate" failure this tool's own header warns about
-- (CART-0192/0229/0232). So they are counted, named, and kept OUT of the exit rule.
-- Valid escapes in 5.2+: a b f n r t v z \ " ' newline, \x<hex>, \<ddd>, \u{...}.
local VALID_ESC = { a=1, b=1, f=1, n=1, r=1, t=1, v=1, z=1, x=1, u=1,
    ['\\']=1, ['"']=1, ["'"]=1, ['\n']=1 }
local function legacy_escape(text)
    local i = 1
    while true do
        local a = text:find('\\', i, true)
        if not a then return nil end
        local c = text:sub(a + 1, a + 1)
        if not (VALID_ESC[c] or c:match('%d')) then return '\\' .. c end
        i = a + 2
    end
end

-- ── the reverse leg: emitted text → schema, through the REAL harvest ───────────
local VALUE_Q = '(variable_declaration (assignment_statement (expression_list value: (_) @v)))'

-- token stream of one expression's parse tree: every LEAF under the value node, with
-- comments COUNTED rather than recorded and parens dropped from the list. Shared by both
-- sides of the --text comparison so neither side can tokenize by its own rules.
local PAREN = { ['('] = true, [')'] = true }
local function leaf_toks(vnode, src)
    local out, ncom = {}, 0
    local function walk(n)
        if n:type() == 'comment' then ncom = ncom + 1; return end
        if n:child_count() == 0 then
            local t = vim.treesitter.get_node_text(n, src)
            if not PAREN[t] then out[#out + 1] = t end
            return
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(vnode)
    return out, ncom
end

-- (ir, why, toks): the token list is the emitted side's, taken from THIS parse rather
-- than from a second one — --text would otherwise parse the same text twice.
local function reparse(text, want_toks)
    local src = 'local __rt = ' .. text
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not okp then return nil, 'no parser' end
    local tree = (parser:parse() or {})[1]
    if not tree then return nil, 'no tree' end
    if tree:root():has_error() then return nil, 'PARSE ERROR' end
    local q = vim.treesitter.query.parse('lua', VALUE_Q)
    for _, node in q:iter_captures(tree:root(), src) do
        local ir, why = expr.build(node, src)
        return ir, why, want_toks and (leaf_toks(node, src)) or nil
    end
    return nil, 'no value node'
end

-- ── --text: WHAT DOES THE TEXT LOSE? (the source-comparison mode) ─────────────
-- The round trip above is a fixpoint on the IR and says nothing about the TEXT. This mode
-- asks the other question directly: emit an expression, and compare it against the SOURCE
-- IT CAME FROM (every expr node carries `.at`, its byte range). The claim under test is
-- "the only thing that goes missing is comments".
--
-- COMPARED AS TOKEN STREAMS, not as strings, and the exclusions are the point:
--   comments   COUNTED, then dropped — they are what the claim is about.
--   parens     dropped from BOTH sides. build() unwraps parenthesized_expression, so the
--              IR cannot know they were there, and the emitter parenthesizes every un/bin
--              because it carries no precedence table. This is a SECOND deliberate loss
--              and it would otherwise drown out everything else.
--   whitespace not a token — a multi-line expression collapsing to one line is not a loss.
-- Anything left is a real difference in what the text SAYS, and the classes below name it.
local atmod = require 'cartograph.at'
local FLINES = {}
local function file_lines(f)
    local l = FLINES[f]
    if l == nil then
        l = false
        local h = io.open(root .. '/' .. f)
        if h then l = {}; for x in h:lines() do l[#l + 1] = x end; h:close() end
        FLINES[f] = l
    end
    return l or nil
end
local function slice(lines, r)
    local sl, sc, el, ec = atmod.sl(r), atmod.sc(r), atmod.el(r), atmod.ec(r)
    if not (lines[sl + 1] and lines[el + 1]) then return nil end
    if sl == el then return lines[sl + 1]:sub(sc + 1, ec) end
    local parts = { lines[sl + 1]:sub(sc + 1) }
    for i = sl + 1, el - 1 do parts[#parts + 1] = lines[i + 1] end
    parts[#parts + 1] = lines[el + 1]:sub(1, ec)
    return table.concat(parts, '\n')
end

-- the SOURCE side: parse the slice off disk and tokenize it the same way
local function toks(text)
    local src = 'local __rt = ' .. text
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not okp then return nil, 'no parser' end
    local tree = (parser:parse() or {})[1]
    if not tree or tree:root():has_error() then return nil, 'PARSE ERROR' end
    local q = vim.treesitter.query.parse('lua', VALUE_Q)
    for _, node in q:iter_captures(tree:root(), src) do
        local out, ncom = leaf_toks(node, src)
        return out, nil, ncom
    end
    return nil, 'no value node'
end

-- both sides tokenized: same tokens, or the first place they part company
local function tokdiff(a, b)
    if #a ~= #b then
        return ('token count %d vs %d'):format(#a, #b), math.min(#a, #b) + 1
    end
    for i = 1, #a do
        if a[i] ~= b[i] then return ('%q vs %q'):format(a[i], b[i]), i end
    end
    return nil
end

-- ── sweep ─────────────────────────────────────────────────────────────────────
-- STAGED PEAK REPORTING (--mem). A whole-corpus sweep is a memory instrument whether
-- or not it means to be: the first wow run was OOM-killed ~20 min in, long past the
-- 130s / 4.1 GB extract, so the growth was in the SWEEP and not the corpus. Attributing
-- that needs stage figures, not a single total — measure where it goes before bounding it.
local function stage(label)
    if not want_mem then return end
    local m = bench.rss_mb()
    print(('  [mem] %-28s %s MB'):format(label, m and ('%.0f'):format(m) or '?'))
end

stage('start')
local data = ts.extract(root)
data.root = data.root or root
stage('after extract')
store.ingest(data)
stage('after store.ingest')

local stat = { exprs = 0, emitted = 0, ok = 0, mismatch = 0, invalid = 0,
    legacy_esc = 0, fns = 0,
    -- --text mode
    tchecked = 0, tsame = 0, tcomment = 0, tncom = 0, tnum = 0, tcr = 0, tdiff = 0,
    tnospan = 0, tsrcfail = 0 }
local refusals, mismatches, kinds = {}, {}, {}
local tclasses, tsamples = {}, {}
local function note(t, k) t[k] = (t[k] or 0) + 1 end

local function count_kinds(e)
    if type(e) ~= 'table' or not e.k then return end
    note(kinds, e.k)
    for _, f in ipairs(KIDS) do if e[f] then count_kinds(e[f]) end end
    for _, a in ipairs(e.a or {}) do count_kinds(a) end
end

local fns = {}
local nfile = {} -- fn id -> file, for the --text source slice
for _, n in ipairs(data.nodes) do
    if (n.kind == 'function' or n.kind == 'method')
        and n.file and n.file:match('%.lua$') then
        fns[#fns + 1] = n.id
        nfile[n.id] = n.file
    end
end
table.sort(fns) -- deterministic report order
stat.fns = #fns

local EVERY = 500
for fi, id in ipairs(fns) do
    if want_mem and fi % EVERY == 0 then
        stage(('after %d/%d fns'):format(fi, #fns))
    end
    -- -39% peak for +0.3% wall; see bench.sweep_gc for the measurement
    bench.sweep_gc(fi)
    local okx, res = pcall(expr.of, store, id)
    if okx and res and res.fl and res.fl.stmts then
        for _, st in ipairs(res.fl.stmts) do
            local row = st.expr
            if row then
                local list = {}
                for _, e in ipairs(row.lhs or {}) do list[#list + 1] = e end
                for _, e in ipairs(row.rhs or {}) do list[#list + 1] = e end
                if row.cond then list[#list + 1] = row.cond end
                for _, e in ipairs(list) do
                    stat.exprs = stat.exprs + 1
                    count_kinds(e)
                    refused = nil
                    local text = emit(e)
                    if not text then
                        note(refusals, refused or 'unknown')
                    else
                        stat.emitted = stat.emitted + 1
                        local back, why, etoks = reparse(text, want_text)
                        if not back then
                            -- attribute before blaming: a verbatim str lit carrying a
                            -- pre-5.2 escape is the SOURCE's, not the emitter's
                            local esc = legacy_escape(text)
                            if esc then
                                stat.legacy_esc = stat.legacy_esc + 1
                                note(refusals, ('source escape %s (lua 5.1) — not an emitter fault'):format(esc))
                            else
                                stat.invalid = stat.invalid + 1
                                note(refusals, 'INVALID(' .. tostring(why) .. ')')
                                if #mismatches < 40 then
                                    mismatches[#mismatches + 1] = { text = text,
                                        why = 'does not parse: ' .. tostring(why), id = id }
                                end
                            end
                        else
                            -- WHAT THE TEXT LOST, for an expression that round-trips
                            if want_text then
                                if not e.at then stat.tnospan = stat.tnospan + 1
                                else
                                    local lines = file_lines(nfile[id] or '')
                                    local orig = lines and slice(lines, e.at)
                                    -- `orig and toks(orig)` would truncate the multiple
                                    -- return to its first value and lose the comment count
                                    local stoks, serr, ncom
                                    if orig then stoks, serr, ncom = toks(orig) end
                                    if not stoks or not etoks then
                                        stat.tsrcfail = stat.tsrcfail + 1
                                        note(tclasses, 'source span did not tokenize: '
                                            .. tostring(serr or 'emit side'))
                                    else
                                        stat.tchecked = stat.tchecked + 1
                                        local tdw, at1 = tokdiff(stoks, etoks)
                                        if not tdw then
                                            stat.tsame = stat.tsame + 1
                                            if ncom > 0 then
                                                stat.tcomment = stat.tcomment + 1
                                                stat.tncom = stat.tncom + ncom
                                            end
                                        else
                                            -- value-preserving number reformat is not a
                                            -- loss of what the text SAYS: %.17g only ever
                                            -- appears where %.14g would change the double
                                            local numonly = #stoks == #etoks
                                            for i = 1, #stoks do
                                                if stoks[i] ~= etoks[i] then
                                                    local a, b = tonumber(stoks[i]), tonumber(etoks[i])
                                                    if not (a and b and a == b) then
                                                        numonly = false break
                                                    end
                                                end
                                            end
                                            -- CR-ONLY: byte-identical once the source
                                            -- side's \r are removed. NOT a loss — the
                                            -- canonical analysis text normalizes \r\n,
                                            -- exactly as lua's own lexer does inside a
                                            -- long string (transport.read_source). THIS
                                            -- SIDE STAYS RAW ON PURPOSE: reading the file
                                            -- the same way the IR did would put both
                                            -- sides of this check back on one reader,
                                            -- which is the blind spot that hid CART-0238.
                                            local cronly = #stoks == #etoks
                                            for i = 1, #stoks do
                                                if stoks[i] ~= etoks[i] then
                                                    if stoks[i]:gsub('\r', '') ~= etoks[i]
                                                        or not stoks[i]:find('\r') then
                                                        cronly = false break
                                                    end
                                                end
                                            end
                                            if numonly then
                                                stat.tnum = stat.tnum + 1
                                                note(tclasses, 'number reformatted, value identical')
                                            elseif cronly then
                                                stat.tcr = stat.tcr + 1
                                                note(tclasses, 'CRLF normalized by'
                                                    .. ' read_source (as lua does in a long string)')
                                            else
                                                stat.tdiff = stat.tdiff + 1
                                                note(tclasses, 'UNEXPLAINED at token '
                                                    .. tostring(at1) .. ': ' .. tdw)
                                                if #tsamples < 40 then
                                                    tsamples[#tsamples + 1] = { src = orig,
                                                        emit = text, why = tdw, id = id }
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            local same, diff = eq(e, back, 'e')
                            if same then stat.ok = stat.ok + 1
                            else
                                stat.mismatch = stat.mismatch + 1
                                if #mismatches < 40 then
                                    mismatches[#mismatches + 1] =
                                        { text = text, why = diff, id = id }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function pct(a, b) return b > 0 and (a / b * 100) or 0 end
print(('translit %s — %d lua functions'):format(name, stat.fns))
print(('expressions visited     %7d'):format(stat.exprs))
print(('  emitted               %7d  (%.1f%%)'):format(stat.emitted, pct(stat.emitted, stat.exprs)))
print(('    round-tripped OK    %7d  (%.1f%% of emitted)'):format(stat.ok, pct(stat.ok, stat.emitted)))
print(('    IR MISMATCH         %7d'):format(stat.mismatch))
print(('    INVALID (no parse)  %7d  <- emitter fault'):format(stat.invalid))
if stat.legacy_esc > 0 then
    print(('    pre-5.2 str escape  %7d  <- SOURCE the grammar rejects, not gated')
        :format(stat.legacy_esc))
end
print(('  refused (frontier)    %7d  (%.1f%%)'):format(stat.exprs - stat.emitted,
    pct(stat.exprs - stat.emitted, stat.exprs)))

if want_text then
    print('\nTEXT vs SOURCE (tokens; comments counted, parens and whitespace excluded):')
    print(('  compared              %7d'):format(stat.tchecked))
    print(('    same tokens         %7d  (%.1f%%)'):format(stat.tsame, pct(stat.tsame, stat.tchecked)))
    print(('      of those, spans carrying a comment %d (%d comments dropped)')
        :format(stat.tcomment, stat.tncom))
    print(('    number reformatted  %7d  <- value identical, text differs'):format(stat.tnum))
    print(('    CR-only            %7d  <- CRLF normalized for analysis, not a loss')
        :format(stat.tcr))
    print(('    UNEXPLAINED         %7d  <- something other than a comment went missing')
        :format(stat.tdiff))
    if stat.tnospan > 0 then
        print(('  no source span       %7d  (built from no TS node)'):format(stat.tnospan))
    end
    if stat.tsrcfail > 0 then
        print(('  span did not tokenize %6d'):format(stat.tsrcfail))
    end
    local cl = {}
    for k, v in pairs(tclasses) do cl[#cl + 1] = { k, v } end
    table.sort(cl, function (a, b) return a[2] > b[2] end)
    if #cl > 0 then
        print('  classes:')
        for i = 1, math.min(12, #cl) do print(('    %7d  %s'):format(cl[i][2], cl[i][1])) end
    end
    if show > 0 and #tsamples > 0 then
        print('  samples (source | emitted):')
        for i = 1, math.min(show, #tsamples) do
            print(('    %s\n    %s\n      %s  in %s'):format(
                (tsamples[i].src or ''):gsub('\n', ' '):sub(1, 110),
                (tsamples[i].emit or ''):sub(1, 110), tsamples[i].why, tsamples[i].id))
        end
    end
end

if want_kinds then
    local kl, ktot = {}, 0
    for k, v in pairs(kinds) do kl[#kl + 1] = { k, v }; ktot = ktot + v end
    table.sort(kl, function (a, b) return a[2] > b[2] end)
    print('\nschema kinds (every node, not just roots):')
    for _, x in ipairs(kl) do
        print(('  %-10s %8d  (%.1f%%)'):format(x[1], x[2], pct(x[2], ktot)))
    end
end

local rl = {}
for k, v in pairs(refusals) do rl[#rl + 1] = { k, v } end
table.sort(rl, function (a, b) return a[2] > b[2] end)
if #rl > 0 then
    print('\nrefusals by cause:')
    for i = 1, math.min(18, #rl) do print(('  %7d  %s'):format(rl[i][2], rl[i][1])) end
end

if show > 0 and #mismatches > 0 then
    print('\nsamples:')
    for i = 1, math.min(show, #mismatches) do
        print(('  %s\n      %s\n      in %s'):format(mismatches[i].text:sub(1, 100),
            mismatches[i].why, mismatches[i].id))
    end
end

-- ONLY the unambiguous bugs gate; a refusal is a frontier (see the header). Under --text
-- an UNEXPLAINED token difference joins them: the deliberate losses (comments, parens,
-- whitespace, a value-preserving number reformat, the CR reader disagreement) are each
-- named and counted, so anything left is text the IR changed without saying so. Measured 0
-- on self / factorio / desynced, which is what makes it a gate somebody can move.
if stat.mismatch > 0 or stat.invalid > 0 or stat.tdiff > 0 then
    print(('\nTRANSLIT: FAIL — %d mismatch, %d invalid%s'):format(
        stat.mismatch, stat.invalid,
        stat.tdiff > 0 and (', %d unexplained text difference'):format(stat.tdiff) or ''))
    os.exit(1)
end
print('\nTRANSLIT: PASS')
