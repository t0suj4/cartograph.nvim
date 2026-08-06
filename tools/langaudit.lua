-- The LANGUAGE-ASSUMPTION AUDIT — find the places where a multi-language module
-- hardcodes ONE grammar's vocabulary (CART-0303). Sibling of tools/docaudit.lua
-- and tools/specaudit.lua: the subject is our OWN source, not user code, so it
-- lives in tools/ rather than behind a :Cartograph verb.
--
--   nvim --headless -u NONE -l tools/langaudit.lua [--all]
--
-- WHY IT EXISTS. Four instances in one arc, every one found by reading the code,
-- none by a gate, and one silently UNSOUND:
--   cfg.lua     `c:type() == 'if_statement'` in the early-exit scan → ruby's
--               `return unless p`, the dominant guard clause in the language, was
--               invisible (CART-0298).
--   narrow.lua  mutated_of matched `s.t == 'assignment_statement'` (LUA's name;
--               ruby's is `assignment`) → the reassignment staling that helper
--               EXISTS to provide was entirely absent on ruby. Unsound, and the
--               suite stayed green because the suite is lua-only (CART-0300).
--   narrow.lua  the statement walk matched `c:type() == 'block'` → ruby yielded an
--               EMPTY point list, which reads as "nothing to narrow here".
--   cfg.lua     `block` is also a TYPE-NAME COLLISION — ruby's brace block and
--               lua's statement block share it, so the naive fix would have
--               disabled guards_over for lua instead.
--
-- THE RULE, and it is what separates the defect from the CORRECT pattern. A
-- per-language TABLE holding one grammar's node names is right; that is how cfg and
-- narrow are built. The suspect is a DIRECT COMPARISON against a single node-type
-- literal — `x:type() == 'foo'`, `s.t == 'foo'` — inside a module that serves more
-- than one grammar. Three of the four match that shape exactly.
--
-- ★ BUT THE VERDICT IS NOT DECIDABLE, AND SAYING SO IS THE DESIGN. A deliberate
-- single-grammar branch (python's field-less positional ternary; a helper that only
-- the lua classifier calls) has exactly the same SHAPE as the bug. Whether the other
-- declared languages NEEDED handling is a question about intent, not syntax. So this
-- audit is CALIBRATION-BOUND in the dogfood sense: every hit is a review item, and a
-- deliberate one is WAIVED IN PLACE with `-- @langs-ok <reason>` on the line or the
-- line above. The waiver is the deliverable — all four historical bugs were
-- UNDOCUMENTED single-grammar assumptions, and a comparison someone had to justify
-- in writing is one nobody adds by reflex. A waiver with no reason is itself a
-- finding.
--
-- TWO ORACLES, neither of them a guess:
--   GRAMMAR VOCABULARY (proof) — `vim.treesitter.language.inspect(lang).symbols` is
--     `{ [node_type] = is_named }` for a real installed parser, and `.fields` is the
--     field list. So "is this literal a node type, and in WHICH grammars" is a fact
--     read out of the compiled grammar, not a heuristic name match.
--   DECLARED LANGUAGES (contract) — a module says what it serves with a `@langs`
--     line. Explicit rather than inferred: a module's language set is a design
--     decision, and inferring it from the literals present would make the audit
--     agree with whatever the code already does. Modules with no declaration are
--     REPORTED as undeclared rather than skipped silently, so the audit's own
--     coverage is visible — the same contract docaudit uses for its ratchets.
--
-- Exit 1 on a finding in a declared module.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local ts = require 'cartograph.providers.treesitter'

local ALL = false
for i = 1, #(arg or {}) do if arg[i] == '--all' then ALL = true end end

-- ── oracle 1: the grammar vocabularies ──────────────────────────────────────
-- Every language the repo ships a spec for, when its parser is installed. A
-- missing parser is reported, never silently treated as "this grammar has no such
-- node" — that would turn absence of evidence into evidence of absence.
local langs, missing = {}, {}
for lang in pairs(ts.spec or {}) do
    if pcall(vim.treesitter.language.add, lang) then
        local ok, info = pcall(vim.treesitter.language.inspect, lang)
        if ok and info and info.symbols then
            local named = {}
            for name, is_named in pairs(info.symbols) do
                if is_named then named[name] = true end
            end
            langs[lang] = named
        else
            missing[#missing + 1] = lang
        end
    else
        missing[#missing + 1] = lang
    end
end
table.sort(missing)

-- which installed grammars define `lit` as a NAMED node type
local function grammars_with(lit)
    local out = {}
    for lang, named in pairs(langs) do
        if named[lit] then out[#out + 1] = lang end
    end
    table.sort(out)
    return out
end

-- ── oracle 2: the modules and their declarations ────────────────────────────
local function read(path)
    local fd = io.open(path, 'r'); if not fd then return nil end
    local s = fd:read('*a'); fd:close(); return s
end

-- `-- @langs lua ruby` (or `@langs any`) anywhere in the file's header comment.
-- `any` = deliberately language-agnostic, e.g. a module that only ever sees node
-- types through a spec; it silences the audit and SAYS SO, which is the point.
-- Every word must be an installed grammar (or `any`); the list ends at the first
-- em-dash so a declaration can carry its reason on the same line. An UNKNOWN word is
-- reported rather than ignored — the first version of this function took every word
-- after the marker, swallowed the prose that followed, and cheerfully audited against
-- languages named "spec" and "mapping". A declaration parser that accepts anything
-- makes the audit agree with nothing.
local function declared_langs(src)
    local line = src:match('@langs%s+([^\n]*)')
    if not line then return nil, nil end
    line = line:match('^(.-)%s*[—-][—-]?%s') or line
    local set, n, bad = {}, 0, {}
    for w in line:gmatch('[%w_]+') do
        if w == 'any' then return 'any', nil end
        if langs[w] then set[w] = true; n = n + 1 else bad[#bad + 1] = w end
    end
    if #bad > 0 then return nil, bad end
    return n > 0 and set or nil, nil
end

-- ── the scan: direct comparisons against a string literal ───────────────────
-- Parsed with OUR OWN lua grammar rather than matched with a regex, so `==` inside
-- a comment or a longer expression is structural rather than textual.
assert(pcall(vim.treesitter.language.add, 'lua'), 'the lua parser is required')

-- The other side must be a NODE-TYPE ACCESSOR, not just anything compared to a
-- string. Without this the audit drowns in `type(x) == 'string'`: lua's own type
-- names are node types in most grammars, so every type check would read as a
-- grammar claim. Both real shapes are here — `c:type()` (a live TS node) and `s.t`
-- (flow's recorded statement type, which is where the unsound one hid).
local function is_node_type_accessor(text)
    return text:match(':type%(%)$') ~= nil
        or text:match('^[%w_%.%[%]]-%.t$') ~= nil
        or text:match('_?type$') ~= nil and text:match('[%w_]+_type$') ~= nil
end

-- The outermost `or`-chain a comparison sits in, or the comparison itself. A
-- DISJUNCTION is the other correct multi-grammar pattern besides a table —
-- `t == 'field_definition' or t == 'public_field_definition'` covers js AND ts, and
-- flagging either half alone would be flagging code that already does the right
-- thing. So comparisons are grouped by their or-chain and the group's grammars are
-- UNIONED before anything is reported. (`and` does not merge: a conjunction narrows,
-- it does not offer alternatives.)
local function or_group(n, src)
    local top = n
    local p = n:parent()
    while p and p:type() == 'binary_expression' do
        if vim.treesitter.get_node_text(p:child(1), src) ~= 'or' then break end
        top = p
        p = p:parent()
    end
    return top
end

local function comparisons(src)
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local out = {}
    local function walk(n)
        for c in n:iter_children() do
            if c:named() then
                if c:type() == 'binary_expression' then
                    local op = vim.treesitter.get_node_text(c:child(1), src)
                    if op == '==' or op == '~=' then
                        local l, r = c:named_child(0), c:named_child(1)
                        for _, side in ipairs { { l, r }, { r, l } } do
                            local lit, other = side[1], side[2]
                            if lit and lit:type() == 'string' then
                                local s = vim.treesitter.get_node_text(lit, src)
                                    :match('^["\'](.-)["\']$')
                                local otext = other and vim.treesitter
                                    .get_node_text(other, src):gsub('%s+', ' ') or ''
                                if s and is_node_type_accessor(otext) then
                                    local g = or_group(c, src)
                                    local key = g:id()
                                    local rec = out[key]
                                    if not rec then
                                        rec = { lits = {}, line = g:start() + 1,
                                            text = vim.treesitter.get_node_text(g, src)
                                                :gsub('%s+', ' ') }
                                        out[key] = rec
                                        out[#out + 1] = rec
                                    end
                                    rec.lits[s] = true
                                end
                            end
                        end
                    end
                end
                walk(c)
            end
        end
    end
    walk(root)
    return out
end

-- an inline waiver on the finding's line or the line above: `@langs-ok <reason>`.
-- The reason must be non-empty — a bare marker would let the audit be silenced
-- without anyone having to say what makes the assumption deliberate.
local function waiver(lines, ln)
    for _, i in ipairs { ln, ln - 1, ln - 2 } do
        local l = lines[i]
        local why = l and l:match('@langs%-ok%s*(.*)$')
        if why then return (why:gsub('%s+$', '')) end
    end
    return nil
end

-- ── the audit over one module ───────────────────────────────────────────────
-- Returns (findings, waived) for `src` given its declared language set.
local function audit(src, decl, rel)
    local lines = vim.split(src, '\n', { plain = true })
    local findings, waived = {}, {}
    for _, cmp in ipairs(comparisons(src)) do
        -- the group's grammars are the UNION over its alternatives
        local has, hasset = {}, {}
        for lit in pairs(cmp.lits) do
            for _, lang in ipairs(grammars_with(lit)) do hasset[lang] = true end
        end
        for lang in pairs(hasset) do has[#has + 1] = lang end
        table.sort(has)
        if #has > 0 then
            local lacking = {}
            for lang in pairs(decl) do
                if not hasset[lang] then lacking[#lacking + 1] = lang end
            end
            table.sort(lacking)
            if #lacking > 0 then
                local names = {}
                for lit in pairs(cmp.lits) do names[#names + 1] = lit end
                table.sort(names)
                local rec = { file = rel, line = cmp.line, lit = table.concat(names, '/'),
                    text = cmp.text, lacking = lacking, has = has }
                local why = waiver(lines, cmp.line)
                if why and why ~= '' then
                    rec.why = why
                    waived[#waived + 1] = rec
                elseif why then
                    rec.text = rec.text .. '   [@langs-ok with NO reason]'
                    findings[#findings + 1] = rec
                else
                    findings[#findings + 1] = rec
                end
            end
        end
    end
    return findings, waived
end

-- ── SELFTEST: a zero is meaningless from an audit that cannot fire ──────────
-- Same discipline as tools/pathsat.lua. The planted positive is the HISTORICAL bug
-- verbatim (mutated_of's lua-only `assignment_statement`); the controls are the
-- shapes that must stay silent — the tabled fix that replaced it, and lua's own
-- `type(x) == 'string'`, whose literal IS a node type in most grammars.
local SELFTEST = table.concat({
    '-- @langs lua ruby',
    'local function planted(s)',
    "    if s.t == 'assignment_statement' then return true end",   -- MUST fire
    'end',
    'local ASSIGN = { assignment_statement = true, assignment = true }',
    'local function tabled(s)',
    '    if ASSIGN[s.t] then return true end',                     -- must be silent
    'end',
    'local function typecheck(x)',
    "    if type(x) == 'string' then return true end",             -- must be silent
    'end',
    'local function waived_case(n)',
    "    if n:type() == 'dot_index_expression' then return true end -- @langs-ok lua-only helper",
    'end',
    'local function disjunction(n)',
    -- covers lua AND ruby between its two alternatives: must be silent
    "    if n:type() == 'assignment_statement' or n:type() == 'assignment' then return true end",
    'end',
    'local function half_disjunction(n)',
    -- an or-chain that still misses ruby: MUST fire, so the merge cannot become a
    -- blanket excuse for any expression containing an `or`
    "    if n:type() == 'variable_list' or n:type() == 'expression_list' then return true end",
    'end',
    'return { planted, tabled, typecheck, waived_case, disjunction, half_disjunction }',
}, '\n') .. '\n'

local function selftest()
    local fails = {}
    local f, w = audit(SELFTEST, { lua = true, ruby = true }, 'selftest')
    local hit = {}
    for _, x in ipairs(f) do hit[x.lit] = x end
    if not hit['assignment_statement'] then
        fails[#fails + 1] = "the planted lua-only `s.t == 'assignment_statement'` was NOT found"
    end
    if hit['string'] then
        fails[#fails + 1] = "lua's own `type(x) == 'string'` was reported as a grammar claim"
    end
    if hit['dot_index_expression'] then
        fails[#fails + 1] = 'a waived comparison was still reported as a finding'
    end
    local wl = {}
    for _, x in ipairs(w) do wl[x.lit] = true end
    if not wl['dot_index_expression'] then
        fails[#fails + 1] = 'the waiver was not recognised at all (so waiving is untested)'
    end
    -- the DISJUNCTION pair covers lua+ruby together and must merge to silence…
    for _, x in ipairs(f) do
        if x.lit:find('assignment_statement/assignment', 1, true) then
            fails[#fails + 1] = 'an or-chain covering BOTH declared languages was reported'
        end
    end
    -- …but a half-covering one must still fire, or the merge is a blanket excuse
    if not hit['expression_list/variable_list'] then
        fails[#fails + 1] = 'an or-chain that still misses ruby was NOT reported'
    end
    if #f ~= 2 then
        fails[#fails + 1] = ('expected exactly 2 findings in the fixture, got %d'):format(#f)
    end
    return fails
end

-- ── report ──────────────────────────────────────────────────────────────────
print('langaudit SELFTEST (a zero is meaningless from an audit that cannot fire)')
local sfails = selftest()
for _, m in ipairs(sfails) do print('  FAIL ' .. m) end
if #sfails > 0 then
    print(('langaudit: SELFTEST FAILED (%d) — refusing to report'):format(#sfails))
    os.exit(1)
end
print('  ok — the historical bug and a half-covering or-chain are found; a tabled fix,'
    .. ' a lua type-check, a waiver and a fully-covering or-chain stay silent')
print('')

local files = vim.fn.globpath(repo .. '/lua/cartograph', '**/*.lua', false, true)
table.sort(files)

local findings, waived, declared_n, undeclared, agnostic = {}, {}, 0, {}, 0
local malformed = {}
for _, path in ipairs(files) do
    local src = read(path)
    if src then
        local rel = path:sub(#repo + 2)
        local decl, bad = declared_langs(src)
        if bad then
            malformed[#malformed + 1] = { file = rel, bad = bad }
        elseif decl == 'any' then
            agnostic = agnostic + 1
        elseif not decl then
            -- only worth naming if it actually compares against a node type
            for _, cmp in ipairs(comparisons(src)) do
                local any = false
                for lit in pairs(cmp.lits) do
                    if #grammars_with(lit) > 0 then any = true break end
                end
                if any then undeclared[#undeclared + 1] = rel break end
            end
        else
            declared_n = declared_n + 1
            local f, w = audit(src, decl, rel)
            for _, x in ipairs(f) do findings[#findings + 1] = x end
            for _, x in ipairs(w) do waived[#waived + 1] = x end
        end
    end
end

print(('LANGUAGE-ASSUMPTION AUDIT — %d grammar(s) loaded · %d module(s) declared'
    .. ' · %d language-agnostic'):format(vim.tbl_count(langs), declared_n, agnostic))
if #missing > 0 then
    print(('  parsers NOT installed (their vocabulary is unknown, not empty): %s')
        :format(table.concat(missing, ' ')))
end

print('')
print(('== A DECLARED LANGUAGE WHOSE GRAMMAR LACKS THE COMPARED NODE TYPE'
    .. ' (%d waived) =='):format(#waived))
if #findings == 0 then
    print('  (none)')
else
    for _, f in ipairs(findings) do
        print(('  %s:%d  `%s`'):format(f.file, f.line, f.text))
        print(('      "%s" is a node type in [%s] but NOT in [%s] — which this module declares')
            :format(f.lit, table.concat(f.has, ' '), table.concat(f.lacking, ' ')))
        print('      → put it behind a per-language table, or narrow the @langs claim')
    end
end

if ALL or #undeclared > 0 then
    print('')
    print('== UNDECLARED: compares against a node type, but claims no @langs ==')
    if #undeclared == 0 then
        print('  (none)')
    else
        -- a module without the declaration is not audited; say so rather than
        -- letting a green run imply it was checked
        for _, rel in ipairs(undeclared) do print('  ' .. rel) end
        print(('  (%d module(s) — add `-- @langs <lang>…` or `@langs any` to bring'
            .. ' them under the audit)'):format(#undeclared))
    end
end

if #malformed > 0 then
    print('')
    print('== MALFORMED @langs: not an installed grammar, so the module is NOT audited ==')
    for _, m in ipairs(malformed) do
        print(('  %s  unknown: %s'):format(m.file, table.concat(m.bad, ' ')))
    end
end

print('')
if #findings > 0 or #malformed > 0 then
    print(('langaudit: %d FINDING(S), %d malformed declaration(s)')
        :format(#findings, #malformed))
    os.exit(1)
end
print('langaudit: ok')
