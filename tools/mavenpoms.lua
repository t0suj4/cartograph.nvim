-- mavenpoms — DOWNLOAD the parent POMs and BOMs a Maven tree needs from Maven Central, as DATA.
--
--   nvim --headless -u NONE -l tools/mavenpoms.lua <repo>… [--rounds N] [--dry]
--
-- ★ NETWORK, EXPLICITLY. This is the one file that reaches Maven Central, and only when run. USER
-- (2026-09-23): "Download the POMs and BOMs" — until the reach barrier (CART-1052) exists, running
-- this tool IS the consent, and its rules are the barrier's first draft:
--   · ONE HOST: https://repo.maven.apache.org/maven2 — a tree's <repositories> is never followed
--     (the tree SELECTS which coordinates; it never says WHERE FROM);
--   · ONE KIND: `.pom` (and its `.sha1`). Never a jar, never a plugin: nothing fetched ever runs;
--   · coordinates are validated (pom.repo_path) before they become a path or a URL;
--   · every file is checked against Central's SHA-1 before it is kept, and written atomically;
--   · every request is appended to the LEDGER (ledger.jsonl next to the files): url, status,
--     bytes, sha1, sha256, time, purpose.
-- WHAT IS MISSING is asked of Maven's own model builder (tools/oracles/maven_effective.py
-- --missing), offline, round after round: a fetched parent names ITS parent, a fetched BOM its
-- imports. `--dry` prints what would be fetched and fetches nothing.

local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
local P = require 'cartograph.pom'
local J = require 'cartograph.oraclejoin'

local CENTRAL = 'https://repo.maven.apache.org/maven2/'
local DEST = P.DEFAULT_REPO
local LEDGER = DEST .. '/ledger.jsonl'
local PURPOSE = 'maven model building: parent POMs and BOMs (CART-1051 oracle and cartograph.pom)'

local repos, rounds, dry = {}, 25, false
local i = 1
while i <= #arg do
    if arg[i] == '--rounds' then rounds = tonumber(arg[i + 1]) or rounds; i = i + 1
    elseif arg[i] == '--dry' then dry = true
    else repos[#repos + 1] = arg[i] end
    i = i + 1
end
if #repos == 0 then print('usage: mavenpoms <repo>… [--rounds N] [--dry]'); os.exit(2) end

local function ledger(rec)
    rec.time = os.date('!%Y-%m-%dT%H:%M:%SZ')
    rec.purpose = PURPOSE
    local fd = assert(io.open(LEDGER, 'a'))
    fd:write(vim.json.encode(rec), '\n')
    fd:close()
end

local function curl(url, out)
    local r = vim.system({ 'curl', '-fsSL', '--proto', '=https', '--proto-redir', '=https', '--max-time', '30',
        '-o', out, url }):wait()
    return r.code == 0, r.code
end

local function readf(p) local fd = io.open(p, 'rb'); if not fd then return nil end; local s = fd:read('*a'); fd:close(); return s end

-- fetch one coordinate; returns 'fetched' | 'absent' | 'bad' and a reason
local function fetch(gav)
    local g, a, v = gav:match('^([^:]+):([^:]+):([^:]+)$')
    local rel, why = P.repo_path(g, a, v)
    if not rel then return 'bad', why end
    local url, path = CENTRAL .. rel, DEST .. '/' .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local tmp, tsha = path .. '.part', path .. '.sha1.part'
    local ok, code = curl(url, tmp)
    if not ok then
        os.remove(tmp)
        ledger({ url = url, status = 'failed', curl = code })
        return 'absent', 'curl exit ' .. code
    end
    local body = readf(tmp) or ''
    local ok2 = curl(url .. '.sha1', tsha)
    local want = ok2 and (readf(tsha) or ''):match('(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)')
    os.remove(tsha)
    local have = vim.fn.system({ 'sha1sum', tmp }):match('^(%x+)')
    if not want or not have or want:lower() ~= have:lower() then
        os.remove(tmp)
        ledger({ url = url, status = 'checksum mismatch', bytes = #body, sha1 = have, expected = want })
        return 'bad', 'checksum mismatch'
    end
    os.rename(tmp, path)
    ledger({ url = url, status = 'ok', bytes = #body, sha1 = have, sha256 = vim.fn.sha256(body) })
    return 'fetched'
end

local function missing()
    local all = {}
    for _, r in ipairs(repos) do
        local dir = r:find('/', 1, true) and vim.fn.expand(r) or vim.fn.expand('~/git/' .. r)
        local paths = {}
        for _, f in ipairs(J.ls_files(dir)) do if f == 'pom.xml' or f:match('/pom%.xml$') then paths[#paths + 1] = dir .. '/' .. f end end
        local res = vim.system({ 'python3', REPO .. '/tools/oracles/maven_effective.py', '--missing' },
            { stdin = table.concat(paths, '\0') .. '\0', text = true }):wait()
        if res.code ~= 0 then print('the model builder failed on ' .. r .. ': ' .. (res.stderr or ''):sub(1, 300)); os.exit(1) end
        for _, gav in ipairs(vim.json.decode(res.stdout)) do all[gav] = true end
    end
    return all
end

vim.fn.mkdir(DEST, 'p')
local tried, counts = {}, { fetched = 0, absent = 0, bad = 0 }
for round = 1, rounds do
    local todo = {}
    for gav in pairs(missing()) do if not tried[gav] then todo[#todo + 1] = gav end end
    table.sort(todo)
    if #todo == 0 then print(('round %d: nothing new is missing'):format(round)); break end
    print(('round %d: %d coordinate(s) missing'):format(round, #todo))
    for _, gav in ipairs(todo) do
        tried[gav] = true
        if dry then print('  would fetch ' .. gav)
        else
            local st, why = fetch(gav)
            counts[st] = counts[st] + 1
            if st ~= 'fetched' then print(('  %s %s: %s'):format(st, gav, why or '')) end
        end
    end
    if dry then break end
end
print(('fetched %d, absent from Central %d, refused %d; files and ledger in %s'):format(counts.fetched, counts.absent, counts.bad, DEST))
