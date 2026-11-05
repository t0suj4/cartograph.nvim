-- tools/claude-guard.py, the Claude Code PreToolUse half of the commit fence (CART-1921): driven here with the JSON
-- event Claude Code sends, through the real script. Only the rules that need no tk tree or transcript live here; the
-- per-session reference rules were measured by replaying a session (CART-1921's notes).

local GUARD = vim.fn.getcwd() .. '/tools/claude-guard.py'

local function decide(ev)
    local r = vim.system({ 'python3', GUARD }, { stdin = vim.json.encode(ev), text = true }):wait()
    if r.code ~= 0 then return nil, 'exit ' .. r.code .. ': ' .. tostring(r.stderr) end
    if (r.stdout or '') == '' then return 'allow' end
    local d = vim.json.decode(r.stdout).hookSpecificOutput
    return d.permissionDecision, d.permissionDecisionReason
end

local function ready() return vim.fn.executable('python3') == 1 end

test('claude-guard: Edit / Write on a HARD-LINKED file is denied, with the command that breaks the link', function ()
    if not ready() then skip 'no python3' end
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local f, twin = d .. '/f.lua', d .. '/twin.lua'
    vim.fn.writefile({ 'return 1' }, f)
    assert(vim.uv.fs_link(f, twin))
    for _, tool in ipairs({ 'Edit', 'Write' }) do
        local verdict, why = decide({ tool_name = tool, session_id = 'x',
            tool_input = { file_path = f, old_string = 'return 1', new_string = 'return 2', content = 'return 2' } })
        eq('deny', verdict, tool .. ': ' .. tostring(why))
        ok(tostring(why):find('2 hard links', 1, true) and tostring(why):find('cp -p', 1, true), tostring(why))
    end
    eq({ 'return 1' }, vim.fn.readfile(twin), 'and nothing was written to either copy')
    -- the link broken, the same edit passes; a NEW file has no other copy
    os.remove(twin)
    eq('allow', (decide({ tool_name = 'Edit', session_id = 'x',
        tool_input = { file_path = f, old_string = 'return 1', new_string = 'return 2' } })))
    eq('allow', (decide({ tool_name = 'Write', session_id = 'x',
        tool_input = { file_path = d .. '/new.lua', content = 'return 3' } })))
    vim.fn.delete(d, 'rf')
end)

test('claude-guard: an agent\'s `git commit --no-verify` in cartograph is denied', function ()
    if not ready() then skip 'no python3' end
    local verdict, why = decide({ tool_name = 'Bash', session_id = 'x',
        tool_input = { command = 'cd /srv/cartograph.nvim && git commit -q --amend --no-verify -m wip' } }) -- (any path naming cartograph)
    eq('deny', verdict, tostring(why))
    eq('allow', (decide({ tool_name = 'Bash', session_id = 'x',
        tool_input = { command = 'git -C "$r" cat-file -e abc1234^{commit}' } })), 'a ^{commit} rev is not a commit')
end)
