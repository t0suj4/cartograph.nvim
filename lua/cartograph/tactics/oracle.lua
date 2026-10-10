-- ORACLE (discovery, CART-1645): score an analysis against an INDEPENDENT implementation — a scorer script joins our
-- answers to an oracle's (the TypeScript checker's, Go's type checker's) and prints count rows `  N  <label>`. Promoted
-- from the flowtype scorers run by hand after every walker change on 2026-10-10 (tools/experiments/flowtype_oracle:
-- score.lua for Go, ts/score.lua for TS). The scorer runs in its own process with `repo` on the runtimepath, so the
-- code under test can be a mutated copy (`mutant`).
-- params: scorer (a script path, relative to repo), root (the tree), oracle (the oracle's TSV), args (a list: more
-- positional arguments for the scorer), repo (default this cartograph), wrong / right (Lua patterns over a row's label;
-- default `WRONG` or `MISSES` / `RIGHT`), floor (the fewest RIGHT answers acceptable — a regression gate), timeout.
-- CLAIM: no WRONG row, some RIGHT one (a scorer that matched nothing is dead), and at least `floor` RIGHT.
local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local function measure(_, p)
    local repo = p.repo or repo_of_toolbelt()
    local scorer = p.scorer:sub(1, 1) == '/' and p.scorer or (repo .. '/' .. p.scorer)
    if vim.fn.filereadable(scorer) == 0 then return { error = 'oracle: no scorer ' .. scorer } end
    local argv = { vim.v.progpath, '--headless', '-u', 'NONE', '--cmd', 'set rtp^=' .. repo, '-l', scorer, p.root, p.oracle }
    for _, a in ipairs(p.args or {}) do argv[#argv + 1] = tostring(a) end
    local r = vim.system(argv, { text = true, cwd = repo, timeout = tonumber(p.timeout or 3000) * 1000 }):wait()
    local out = (r.stdout or '') .. (r.stderr or '')
    if r.code ~= 0 then return { error = ('oracle: the scorer failed (%s): %s'):format(tostring(r.code), out:sub(-400)) } end
    local wrong, right = p.wrong or 'WRONG', p.right or 'RIGHT'
    local v = { rows = {}, wrong = 0, right = 0, floor = tonumber(p.floor) }
    for ln in out:gmatch('[^\n]+') do
        local n, label = ln:match('^%s+(%d+)%s+(%S.*)$')
        if n then
            n = tonumber(n)
            v.rows[#v.rows + 1] = { n = n, label = label }
            if label:match(wrong) or (not p.wrong and label:match('MISSES')) then v.wrong = v.wrong + n
            elseif label:match(right) then v.right = v.right + n end
        end
    end
    return v
end

local SCORER = [[
-- a toy scorer: answers in a file, the oracle in another, one `key value` per line
local mine, truth = {}, {}
for ln in io.lines(arg[1] .. '/answers.txt') do local k, val = ln:match('^(%S+) (%S+)$'); mine[k] = val end
for ln in io.lines(arg[2]) do local k, val = ln:match('^(%S+) (%S+)$'); truth[k] = val end
local right, wrong = 0, 0
for k, val in pairs(truth) do if mine[k] == val then right = right + 1 elseif mine[k] then wrong = wrong + 1 end end
print(('  %d  calls EXACT-RIGHT'):format(right))
print(('  %d  calls EXACT-WRONG'):format(wrong))
]]

return {
    name = 'oracle',
    kind = 'discovery',
    tags = { 'gate', 'measure' },
    summary = 'score an analysis against an independent oracle: scorer = a script printing `  N  <label>` rows, run on root + the oracle TSV in its own process (repo on the runtimepath); claim: no WRONG / MISSES row, some RIGHT, at least floor RIGHT',
    params = { scorer = 'string', root = 'string', oracle = 'string', args = 'list?', repo = 'string?', wrong = 'string?',
        right = 'string?', floor = 'string?', timeout = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local parts = {}
        for _, r in ipairs(v.rows) do parts[#parts + 1] = r.n .. ' ' .. r.label end
        local head = table.concat(parts, '; ')
        if v.wrong > 0 then return false, ('%d WRONG — %s'):format(v.wrong, head) end
        if v.right == 0 then return false, 'nothing RIGHT: the scorer matched nothing, so it shows nothing — ' .. head end
        if v.floor and v.right < v.floor then return false, ('%d RIGHT, below the floor %d — %s'):format(v.right, v.floor, head) end
        return true, ('%d RIGHT, 0 wrong — %s'):format(v.right, head)
    end,
    examples = {
        {
            name = 'every answer the oracle holds agrees: the claim holds',
            files = { ['answers.txt'] = 'a 1\nb 2\nc 3\n', ['truth.tsv'] = 'a 1\nb 2\n', ['score.lua'] = SCORER },
            params = function (store) local r = store.data.root
                return { scorer = r .. '/score.lua', root = r, oracle = r .. '/truth.tsv', repo = r } end,
            expect = { holds = true, check = function (v) return v.right == 2 and v.wrong == 0, vim.inspect(v.rows) end },
        },
        {
            name = 'one answer the oracle contradicts: WRONG, the claim fails',
            files = { ['answers.txt'] = 'a 1\nb 9\n', ['truth.tsv'] = 'a 1\nb 2\n', ['score.lua'] = SCORER },
            params = function (store) local r = store.data.root
                return { scorer = r .. '/score.lua', root = r, oracle = r .. '/truth.tsv', repo = r } end,
            expect = { holds = false },
        },
        {
            name = 'right answers below the floor: a regression, refused',
            files = { ['answers.txt'] = 'a 1\n', ['truth.tsv'] = 'a 1\nb 2\n', ['score.lua'] = SCORER },
            params = function (store) local r = store.data.root
                return { scorer = r .. '/score.lua', root = r, oracle = r .. '/truth.tsv', repo = r, floor = '2' } end,
            expect = { holds = false },
        },
        {
            name = 'a scorer that matches nothing: refused — it could not have failed',
            files = { ['answers.txt'] = 'x 1\n', ['truth.tsv'] = 'a 1\n', ['score.lua'] = SCORER },
            params = function (store) local r = store.data.root
                return { scorer = r .. '/score.lua', root = r, oracle = r .. '/truth.tsv', repo = r } end,
            expect = { holds = false },
        },
    },
}
