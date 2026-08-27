-- The DOC AUDIT — validate cartograph's OWN user documentation against the
-- code ([[cartograph-shipping-checklist]]: a capability ships → flip the
-- surfaces, and README/help are two of them). doc/cartograph.txt and README.md
-- are hand-authored CLAIMS about a surface that grows every session, and
-- nothing else checks them. The helpdoc drifts fastest because it is the
-- surface nobody re-reads. PROJECT-MANAGEMENT action: the subject is our own
-- documentation, not user code — hence tools/, not a :Cartograph verb. Sibling
-- of tools/specaudit.lua, which does this for our specs.
--
-- The oracles, never conflated (the count was left out of this sentence on
-- purpose: it was 'Three' over six bullets, which is the same class of stale
-- inventory claim this file now fences):
--   REGISTRY (proof) — the commands that actually exist at startup, captured by
--     intercepting nvim_create_user_command while sourcing plugin/. It cannot
--     be wrong: it is the code path a user's nvim runs. (Read back through
--     nvim_get_commands() the desc is LOSSY — nvim escapes byte 0x80, so every
--     em-dash comes back mangled — which is why we intercept instead.)
--   SOURCE SCAN (evidence) — pane-local commands (nvim_buf_create_user_command
--     in a pane buffer) do not exist until that pane is built, so headless
--     startup cannot see them; they are read out of lua/ as text, as are the
--     registration sites. Weaker tier by construction: a rename that keeps the
--     literal string is invisible to it.
--   SPEC ROSTER (proof) — ts.spec's keys, versus the language count and name
--     list each doc sentence claims.
--   CONFIG.KEYS (proof) — the default binding table, versus the field/default
--     table the helpdoc's KEYS section publishes. That section is therefore a
--     MACHINE-CHECKED TABLE: `  <field> <default> <text>` rows, a column header
--     marked with a trailing ~, `(unbound)` for a field defaulting to false.
--     Keep the shape or the audit stops seeing it (and the coverage gate fires).
--     README's key mentions are PROSE and are not checked — they can still rot.
--   CONFIG OPTIONS (evidence) — config.lua scanned as TEXT for `M.<field> =`,
--     versus the option table the CONFIGURATION section publishes. Text and not
--     a require BECAUSE an option defaulting to nil (`M.pins = nil`) creates no
--     table key: a runtime `cfg[f] ~= nil` test calls five real options missing.
--   TARGET SCHEMES (evidence) — the `x://` prefixes init.lua dispatches, versus
--     those the PROVIDERS section offers. Both directions: an accepted target
--     must be documented, and a documented one must still be accepted.
--   AGENT SURFACE (proof) — lua/cartograph/agent.lua's ORDER, which is the table
--     tools/mcpserve.lua iterates to answer tools/list, so it cannot be wrong
--     about what an agent can call. Checked against the verb COUNT and the verb
--     TABLE .claude/skills/cartograph/SKILL.md publishes. That file is an
--     agent-facing claim file of exactly the same class as doc/cartograph.txt and
--     had NO fence at all: it said "21 verbs" while ORDER held 24, and nothing
--     could have caught it — this audit walks :Cartograph* commands, and the
--     agent surface is a different registry in a file it never opened
--     (CART-0595). AUDITED, NEVER EDITED: .claude/ is not this tool's to write,
--     so a finding here is a sentence for a human, not a fix to apply.
--   TAGGED CLAIMS (opt-in proof) — a load-bearing sentence in a module header can
--     carry its own executable check (`@claim` + `check:`; the shape and the
--     measurement that ruled out a general prose fence are in
--     lua/cartograph/claims.lua). Opt-in is the honest limit and the report says
--     so: an UNTAGGED claim is invisible here and is not counted as a finding,
--     because a live claim and a dated record of a past measurement look the same
--     from outside.
--
-- Two tiers of finding, never conflated:
--   CONFIRMED DRIFT — the doc states something FALSE: a :Cartograph name that
--     no longer exists, or a language claim that contradicts its own list or
--     the roster. Always exits non-zero; there is no waiver.
--   UNDOCUMENTED — a real command the helpdoc never names. A coverage gap, not
--     a falsehood, so it rides a RATCHET (FLOOR below): it may shrink, never
--     grow. Lower FLOOR as you document; the audit tells you the new number.
--
-- The helpdoc is the surface held to COMPLETE coverage (it is the reference).
-- README is prose and is checked only for dead names and the roster claim.
--
-- usage:
--   nvim --headless -u NONE -l tools/docaudit.lua
--   ... --emit     print ready-to-paste |cartograph-commands| lines for the gap

local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path

-- The UNDOCUMENTED ratchet: how many registered commands doc/cartograph.txt is
-- still allowed to omit. Lower it as you document; never raise it. At 0 the
-- helpdoc is COMPLETE and stays that way — a new command must be documented in
-- the commit that adds it, or this fence blocks that commit.
local FLOOR = 0
-- The same ratchet for config.keys fields missing from the KEYS table.
local KEYS_FLOOR = 0

local EMIT = false
for _, a in ipairs(arg or {}) do
    if a == '--emit' then EMIT = true
    else print(('docaudit: unknown argument %q'):format(a)); os.exit(2) end
end

-- A language name a doc may use for a spec that ships under another key.
local ALIAS = { js = 'javascript', ts = 'typescript' }
-- Spec keys that are a PARSER VARIANT of a language, not a language of their
-- own: tsx is the typescript spec under the tsx parser, so no doc sentence is
-- expected to count it separately.
local VARIANT = { tsx = 'typescript' }

local NUMWORD = { 'one', 'two', 'three', 'four', 'five', 'six', 'seven',
    'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen',
    'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty',
    'twenty-one', 'twenty-two', 'twenty-three', 'twenty-four', 'twenty-five' }
local WORDNUM = {}
for i, w in ipairs(NUMWORD) do WORDNUM[w] = i end

local function sortedkeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

-- ── 1. REGISTRY (proof): intercept registration while sourcing plugin/ ──────
local reg = {}   -- name -> { desc, nargs, bang, range, panelocal }
do
    local api = vim.api
    local og, ob = api.nvim_create_user_command, api.nvim_buf_create_user_command
    local function note(name, opts, panelocal)
        if type(name) == 'string' and name:match('^Cartograph') and not reg[name] then
            opts = opts or {}
            reg[name] = { desc = opts.desc, nargs = opts.nargs, bang = opts.bang,
                range = opts.range, panelocal = panelocal }
        end
    end
    api.nvim_create_user_command = function (name, fn, opts)
        note(name, opts, false); return og(name, fn, opts)
    end
    api.nvim_buf_create_user_command = function (buf, name, fn, opts)
        note(name, opts, true); return ob(buf, name, fn, opts)
    end
    local ok, err = pcall(vim.cmd, 'source ' .. REPO .. '/plugin/cartograph.lua')
    api.nvim_create_user_command, api.nvim_buf_create_user_command = og, ob
    if not ok then
        print('docaudit: sourcing plugin/ FAILED — ' .. tostring(err))
        os.exit(2)
    end
end

-- Cross-check the intercept against the live registry: anything nvim knows
-- about that we did not see would mean a registration path we are blind to.
local unseen = {}
for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match('^Cartograph') and not reg[name] then
        unseen[#unseen + 1] = name
    end
end

-- ── 2. SOURCE SCAN (evidence): sites, and the pane-local commands ──────────
-- Startup cannot reach a pane buffer's commands, so they are read as text.
local site = {}   -- name -> 'file:line'
do
    local files = vim.fn.globpath(REPO .. '/lua', '**/*.lua', false, true)
    vim.list_extend(files, vim.fn.globpath(REPO .. '/plugin', '*.lua', false, true))
    for _, f in ipairs(files) do
        local rel = f:sub(#REPO + 2)
        local lnum = 0
        for _, line in ipairs(vim.fn.readfile(f)) do
            lnum = lnum + 1
            if not line:match('^%s*%-%-')
                and (line:find('create_user_command', 1, true)
                    or line:match('^%s*cmd%(')) then
                for name in line:gmatch("'(Cartograph%a*)'") do
                    site[name] = site[name] or ('%s:%d'):format(rel, lnum)
                    if not reg[name] then
                        reg[name] = { panelocal =
                            line:find('nvim_buf_create_user_command', 1, true) ~= nil }
                    end
                end
            end
        end
    end
end

-- ── 3. the doc surfaces: every :Cartograph name they NAME, with a line ─────
local function surface(path)
    local s = { path = path, lines = vim.fn.readfile(REPO .. '/' .. path), at = {} }
    for i, line in ipairs(s.lines) do
        for name in line:gmatch('Cartograph%a*') do
            s.at[name] = s.at[name] or i
        end
    end
    return s
end
local HELP, READ = surface('doc/cartograph.txt'), surface('README.md')

-- ── 4. the language roster claim, in each surface ───────────────────────────
local ts = require 'cartograph.providers.treesitter'
local roster = {}   -- the languages a doc sentence is expected to list
for key in pairs(ts.spec) do
    if not VARIANT[key] then roster[key] = true end
end
local nroster = #sortedkeys(roster)

-- "Fourteen languages (lua, c, …)" — the sentence wraps, so match over a
-- 3-line window, then map the match back to the line the count word sits on.
local PAT = '([%a%-]+) languages[^(]*%((.-)%)'
local function roster_claim(s)
    for i = 1, #s.lines do
        local win = table.concat({ s.lines[i], s.lines[i + 1] or '',
            s.lines[i + 2] or '' }, '\n')
        local at, _, word, list = win:find(PAT)
        if word and WORDNUM[word:lower()] then
            local names = {}
            for n in list:gmatch('[%w%+#]+') do
                names[#names + 1] = ALIAS[n] or n
            end
            local _, nl = win:sub(1, at - 1):gsub('\n', '')
            return { line = i + nl, word = word,
                claimed = WORDNUM[word:lower()], names = names }
        end
    end
end

-- ── 4b. the TABLES the helpdoc publishes ────────────────────────────────────
-- Rows of `  <field> <value> …` between a tag and the END OF ITS TOPIC. A
-- trailing ~ marks a column header, not a row; continuation lines are indented
-- past the field column and so never match.
local function doc_rows(tag)
    local rows, inside = {}, false
    for i, line in ipairs(HELP.lines) do
        if line:find('*' .. tag .. '*', 1, true) then
            inside = true
        elseif inside and line:match('^====') then
            break
        elseif inside and line:match('%*cartograph%-[%w%-]+%*')
            and not line:find('*' .. tag .. '-', 1, true) then
            -- A NEW TOPIC ends this one. Only a SUBsection (*<tag>-…*, as
            -- cartograph-keys-unbound is to cartograph-keys) still publishes
            -- rows about this table. Before this the region ran on to the next
            -- ==== rule and swallowed any table that happened to sit in
            -- between: |cartograph-lenses| lives in section 4, and its twelve
            -- altitude rows were read as twelve keys.<field> that do not exist.
            break
        elseif inside and not line:match('~%s*$') then
            local field, val = line:match('^  (%a[%w_]*)%s+(%S+)')
            if field and not rows[field] then
                rows[field] = { val = val, line = i }
            end
        end
    end
    return rows
end

local function section_text(tag)
    local out, inside = {}, false
    for _, line in ipairs(HELP.lines) do
        if line:find('*' .. tag .. '*', 1, true) then
            inside = true
        elseif inside and line:match('^====') then
            break
        elseif inside then
            out[#out + 1] = line
        end
    end
    return table.concat(out, '\n')
end

local cfgkeys = require('cartograph.config').keys
local keyclaim = doc_rows('cartograph-keys')
local optclaim = doc_rows('cartograph-config')

-- config.lua is scanned as TEXT, never required, for the option registry: an
-- option whose default is nil (`M.pins = nil`) creates NO table key, so a
-- runtime `cfg[field] ~= nil` test calls five real options missing. The
-- assignment is the registry; the value is not.
local cfgopt, schemes = {}, {}
for _, line in ipairs(vim.fn.readfile(REPO .. '/lua/cartograph/config.lua')) do
    local f = line:match('^M%.([%w_]+)%s*=')
    if f then cfgopt[f] = true end
end
-- The target schemes :Cartograph accepts, from the one file that dispatches
-- them. Evidence tier: a scheme matched anywhere else is invisible here.
for _, line in ipairs(vim.fn.readfile(REPO .. '/lua/cartograph/init.lua')) do
    for s in line:gmatch("target:match%('%^(%a+)://") do schemes[s] = true end
end

-- ── 5. report ──────────────────────────────────────────────────────────────
local confirmed = {}   -- doc states something FALSE
local function drift(fmt, ...) confirmed[#confirmed + 1] = fmt:format(...) end

-- A binding the doc publishes must BE the default. Teaching a key that does
-- nothing (or that another feature owns) is the same class of lie as naming a
-- command that no longer exists.
for _, field in ipairs(sortedkeys(keyclaim)) do
    local c, actual = keyclaim[field], cfgkeys[field]
    if actual == nil then
        drift('doc/cartograph.txt:%d publishes keys.%s — no such setup field',
            c.line, field)
    elseif c.val == '(unbound)' then
        if actual ~= false then
            drift('doc/cartograph.txt:%d calls keys.%s unbound, but it defaults to %s',
                c.line, field, tostring(actual))
        end
    elseif actual == false then
        drift('doc/cartograph.txt:%d teaches keys.%s = %s, but it is UNBOUND by default',
            c.line, field, c.val)
    elseif actual ~= c.val then
        drift('doc/cartograph.txt:%d teaches keys.%s = %s, but the default is %s',
            c.line, field, c.val, tostring(actual))
    end
end
local keygap = {}
for _, field in ipairs(sortedkeys(cfgkeys)) do
    if not keyclaim[field] then keygap[#keygap + 1] = field end
end

-- Every option the CONFIGURATION table publishes must be a real setup field.
-- No coverage gate in this direction: that table is explicitly the subset you
-- are most likely to want, not the full 30-odd.
for _, field in ipairs(sortedkeys(optclaim)) do
    if not cfgopt[field] then
        drift('doc/cartograph.txt:%d publishes setup{ %s = … } — no such config option',
            optclaim[field].line, field)
    end
end

-- Every target scheme :Cartograph accepts must be documented as a provider,
-- and every scheme the PROVIDERS section names must still be accepted.
local provtext = section_text('cartograph-providers')
for _, s in ipairs(sortedkeys(schemes)) do
    if not provtext:find(s .. '://', 1, true) then
        drift('doc/cartograph.txt: |cartograph-providers| never documents the %s:// target',
            s)
    end
end
for s in provtext:gmatch('(%a+)://') do
    if not schemes[s] then
        drift('doc/cartograph.txt: |cartograph-providers| offers %s:// — :Cartograph does not accept it',
            s)
    end
end

-- ── 5b. THE AGENT SURFACE (proof): agent.ORDER versus SKILL.md ─────────────
-- A claim about the tree's own inventory, in the file an agent reads to learn
-- what it may call. Both directions and the count, and a claim that cannot be
-- FOUND is itself drift — a renamed heading must not read as a clean audit.
local claims = require 'cartograph.claims'
local ORDER = require('cartograph.agent').ORDER
local skillinfo
do
    local path = REPO .. '/' .. claims.SKILL
    if vim.fn.filereadable(path) == 0 then
        drift('%s: not readable — the agent-surface check cannot run', claims.SKILL)
    else
        local ds, info = claims.agent_surface(ORDER, vim.fn.readfile(path))
        skillinfo = info
        for _, d in ipairs(ds) do drift('%s', d) end
    end
end

-- ── 5c. TAGGED CLAIMS (opt-in proof): every @claim runs its own check ───────
local tagrows, tagok = {}, 0
for _, t in ipairs(claims.scan(REPO)) do
    local passed, why = claims.verify(t)
    tagrows[#tagrows + 1] = { tag = t, ok = passed, why = why }
    if passed then
        tagok = tagok + 1
    else
        drift('%s:%d @claim %s — %s\n      the sentence: %s',
            t.path, t.line, t.id, why, t.sentence)
    end
end

for _, s in ipairs({ HELP, READ }) do
    for _, name in ipairs(sortedkeys(s.at)) do
        if not reg[name] then
            drift('%s:%d names :%s — no such command is registered',
                s.path, s.at[name], name)
        end
    end
    local c = roster_claim(s)
    if not c then
        drift('%s: no "<N> languages (…)" claim found — the roster check cannot run',
            s.path)
    else
        local listed, dupe = {}, nil
        for _, n in ipairs(c.names) do
            if listed[n] then dupe = n end
            listed[n] = true
        end
        if c.claimed ~= nroster then
            drift('%s:%d says "%s languages" but %d ship — should read "%s"',
                s.path, c.line, c.word, nroster,
                NUMWORD[nroster] or tostring(nroster))
        end
        if #c.names ~= c.claimed then
            drift('%s:%d says "%s languages" but its own list has %d names',
                s.path, c.line, c.word, #c.names)
        end
        local missing, extra = {}, {}
        for _, n in ipairs(sortedkeys(roster)) do
            if not listed[n] then missing[#missing + 1] = n end
        end
        for _, n in ipairs(c.names) do
            if not roster[n] then extra[#extra + 1] = n end
        end
        if #missing > 0 then
            drift('%s:%d omits shipped language(s): %s',
                s.path, c.line, table.concat(missing, ' '))
        end
        if #extra > 0 then
            drift('%s:%d claims language(s) with no spec: %s',
                s.path, c.line, table.concat(extra, ' '))
        end
        if dupe then
            drift('%s:%d lists %s twice', s.path, c.line, dupe)
        end
    end
end

local undoc, nowhere, inread = {}, {}, 0
for _, name in ipairs(sortedkeys(reg)) do
    if READ.at[name] then inread = inread + 1 end
    if not HELP.at[name] then
        undoc[#undoc + 1] = name
        if not READ.at[name] then nowhere[#nowhere + 1] = name end
    end
end

local ncmd = #sortedkeys(reg)
print(('DOC AUDIT — %d commands registered · doc/cartograph.txt names %d · README names %d')
    :format(ncmd, ncmd - #undoc, inread))
print(('  languages shipped: %d (%s)')
    :format(nroster, table.concat(sortedkeys(roster), ' ')))
print('')

print('== CONFIRMED DRIFT: the doc states something false ==')
if #confirmed == 0 then print('  (none)') end
for _, d in ipairs(confirmed) do print('  ' .. d) end

print('')
print(('== UNDOCUMENTED: registered but never named in doc/cartograph.txt (ratchet: %d allowed) =='):format(FLOOR))
if #undoc == 0 then print('  (none)') end
for _, name in ipairs(undoc) do
    local r = reg[name]
    print(('  %-32s %s%s'):format(':' .. name,
        r.panelocal and '[pane-local] ' or '',
        site[name] or '?'))
end

if #nowhere > 0 then
    print('')
    print('== …of those, named in NO surface at all (not even README prose) ==')
    print('  ' .. table.concat(nowhere, ' '))
end

print('')
print(('== KEYS: config.keys fields missing from the |cartograph-keys| table (ratchet: %d) ==')
    :format(KEYS_FLOOR))
if #keygap == 0 then
    print(('  (none — all %d fields published)'):format(#sortedkeys(cfgkeys)))
else
    print('  ' .. table.concat(keygap, ' '))
end

print('')
print(('== AGENT SURFACE: agent.ORDER serves %d verbs (tools/mcpserve.lua iterates it for tools/list) =='):format(#ORDER))
if not skillinfo then
    print('  ' .. claims.SKILL .. ' was not read — see CONFIRMED DRIFT')
else
    local cs = {}
    for _, c in ipairs(skillinfo.counts) do
        cs[#cs + 1] = ('%d@line %d'):format(c.n, c.line)
    end
    print(('  %s: %d count claim(s) [%s] · verb table lists %d name(s)'):format(
        claims.SKILL, #skillinfo.counts,
        #cs > 0 and table.concat(cs, ', ') or 'none found',
        skillinfo.names and #skillinfo.names or 0))
    print('  audited, never edited — .claude/ is not this tool\'s to write')
end

print('')
print(('== TAGGED CLAIMS: %d tagged, %d verified =='):format(#tagrows, tagok))
if #tagrows == 0 then print('  (none)') end
for _, r in ipairs(tagrows) do
    print(('  %-44s %-26s %s'):format(('%s:%d'):format(r.tag.path, r.tag.line),
        r.tag.id, r.ok and 'ok' or 'FAILED — see CONFIRMED DRIFT'))
end
print('  OPT-IN BY CONSTRUCTION. An UNTAGGED claim is invisible here and is NOT a')
print('  finding: 853 header lines match negative-existence phrasing and nearly all')
print('  are legitimate prose about USER code, and a count-shaped line is usually a')
print('  dated record of a past measurement, not a live claim. Tag the load-bearing')
print('  ones; this fence reports what it was given, and never guesses at the rest.')

if #unseen > 0 then
    print('')
    print('== INTERNAL: live commands the intercept did not see (blind path) ==')
    print('  ' .. table.concat(unseen, ' '))
end

-- The gap as helpdoc lines: the name column the existing |cartograph-commands|
-- block uses (2 indent, 28 wide, continuation at 30) wrapped to 'tw=78'. Descs
-- are written for :command completion and run long — this is a scaffold to trim
-- by hand, not finished prose.
if EMIT then
    local NAMEW, TW = 28, 78
    print('')
    print('== ready to paste under |cartograph-commands| (trim the prose) ==')
    for _, name in ipairs(undoc) do
        local r = reg[name]
        local sig = ':' .. name .. (r.bang and '[!]' or '')
        local n = r.nargs
        if n == '1' then sig = sig .. ' {arg}'
        elseif n == '?' then sig = sig .. ' [arg]'
        elseif n == '*' or n == '+' then sig = sig .. ' [args]' end
        if r.range then sig = ":'<,'>" .. sig:sub(2) end
        local d = (r.desc or ''):gsub('^cartograph: ', '')
        if d == '' then
            d = '(pane-local — desc at ' .. (site[name] or '?') .. ')'
        end
        -- first line carries the signature unless the signature fills the column
        local head = ('  %-' .. NAMEW .. 's'):format(sig)
        if #sig > NAMEW then
            print('  ' .. sig)
            head = ('  %' .. NAMEW .. 's'):format('')
        end
        local room = TW - #head
        local line = ''
        for word in d:gmatch('%S+') do
            if line == '' then line = word
            elseif vim.fn.strdisplaywidth(line .. ' ' .. word) <= room then
                line = line .. ' ' .. word
            else
                print(head .. ' ' .. line)
                head = ('  %' .. NAMEW .. 's'):format('')
                line = word
            end
        end
        if line ~= '' then print(head .. ' ' .. line) end
    end
end

print('')
if #confirmed > 0 then
    print(('docaudit: FAIL — %d confirmed drift(s)'):format(#confirmed))
    os.exit(1)
end
if #undoc > FLOOR then
    print(('docaudit: FAIL — %d undocumented commands, ratchet allows %d')
        :format(#undoc, FLOOR))
    os.exit(1)
end
if #keygap > KEYS_FLOOR then
    print(('docaudit: FAIL — %d keys fields unpublished, ratchet allows %d')
        :format(#keygap, KEYS_FLOOR))
    os.exit(1)
end
if #undoc < FLOOR then
    print(('docaudit: ok — and the gap SHRANK to %d; lower FLOOR in this file')
        :format(#undoc))
else
    print('docaudit: ok')
end
