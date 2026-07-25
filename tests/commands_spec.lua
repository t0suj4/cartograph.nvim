-- The command REGISTRY: 69 global commands now come from nine group modules,
-- and the dispatch list inside cartograph.commands is the only thing wiring them
-- together. Drop a require there and a whole group vanishes SILENTLY — nothing
-- errors, the commands simply stop existing. These guard that seam.
--
-- Registration is intercepted rather than performed: a spec should not leave 69
-- real user commands behind in the test process.

local ENTRY = 'lua/cartograph/commands.lua'
local GROUP_DIR = 'lua/cartograph/commands'

-- run register() with nvim_create_user_command stubbed, and report what it asked for
local function intercept()
    local api = vim.api
    local orig = api.nvim_create_user_command
    local orig_del = api.nvim_del_user_command
    local seen = {}
    api.nvim_create_user_command = function (name) seen[#seen + 1] = name end
    api.nvim_del_user_command = function () end
    -- `done`, not `ok`: a local named ok would shadow the harness's assertion
    local done, err = pcall(function ()
        package.loaded['cartograph.commands'] = nil
        require('cartograph.commands').register()
    end)
    api.nvim_create_user_command, api.nvim_del_user_command = orig, orig_del
    ok(done, 'register() ran: ' .. tostring(err))
    return seen
end

test('commands: register() asks for the whole surface, with no duplicates', function ()
    local seen = intercept()
    local dupes, byname = {}, {}
    for _, n in ipairs(seen) do
        if byname[n] then dupes[#dupes + 1] = n end
        byname[n] = true
    end
    eq({}, dupes, 'no command is registered twice')
    -- The expectation is DERIVED from the group files, not hardcoded: adding a
    -- verb then needs no edit here, while an unwired group still fails loudly —
    -- its file keeps its cmd() calls, so the files claim more than register()
    -- delivers. (A hardcoded count also caught it, but churned on every verb.)
    local claimed = 0
    for _, f in ipairs(vim.fn.globpath(GROUP_DIR, '*.lua', false, true)) do
        claimed = claimed + select(2, table.concat(vim.fn.readfile(f), '\n')
            :gsub("cmd%('Cartograph", ''))
    end
    ok(claimed > 60, 'the group files were actually read (' .. claimed .. ')')
    eq(claimed, #seen, 'every command the group files define is registered')
    for _, must in ipairs({ 'CartographLint', 'CartographApply', 'CartographTrace',
        'CartographCanvasStop', 'CartographIndexOnly', 'CartographClones',
        'CartographNeutralityCheck', 'CartographJournal', 'CartographTerritory' }) do
        ok(byname[must], must .. ' came from its group')
    end
end)

test('commands: every group file on disk is wired into the dispatch', function ()
    local entry = table.concat(vim.fn.readfile(ENTRY), '\n')
    local files = vim.fn.globpath(GROUP_DIR, '*.lua', false, true)
    ok(#files > 0, 'the group directory is populated')
    local missing = {}
    for _, f in ipairs(files) do
        local name = vim.fn.fnamemodify(f, ':t:r')
        if not entry:find("require 'cartograph.commands." .. name .. "'", 1, true) then
            missing[#missing + 1] = name
        end
    end
    eq({}, missing, 'a group file exists but nothing requires it — its commands are dead')
end)

test('commands: each group module exposes register(H) and contributes commands', function ()
    local files = vim.fn.globpath(GROUP_DIR, '*.lua', false, true)
    local empty = {}
    for _, f in ipairs(files) do
        local name = vim.fn.fnamemodify(f, ':t:r')
        local mod = require('cartograph.commands.' .. name)
        eq('function', type(mod.register), name .. ' exposes register()')
        local body = table.concat(vim.fn.readfile(f), '\n')
        local n = select(2, body:gsub("cmd%('Cartograph", ''))
        if n == 0 then empty[#empty + 1] = name end
    end
    eq({}, empty, 'a group with no commands in it should not exist')
end)
