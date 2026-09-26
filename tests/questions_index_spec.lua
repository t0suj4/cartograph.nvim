-- THE QUESTION INDEX IS FENCED (.claude/skills/cartograph/references/questions.md). User, 2026-09-26: "finding what
-- cartograph can do for us should be a standing rule, we'll need to document the discoveries about its capabilities,
-- so we don't do things by hand the next morning". The previous inventory (a memory file with a same-session update
-- rule) stopped being updated for a month; a rule alone decays, so this one is a test.

local INDEX = '.claude/skills/cartograph/references/questions.md'

local function read(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end

test('question index: every tools/*.lua appears in it', function ()
    local text = read(INDEX)
    ok(text, 'the index exists')
    local tools = vim.fn.glob('tools/*.lua', false, true)
    ok(#tools > 100, 'the glob saw the tools (' .. #tools .. ')')
    local missing = {}
    for _, t in ipairs(tools) do
        if not text:find(t, 1, true) then missing[#missing + 1] = t end
    end
    eq({}, missing, 'add each to a question section (or, for now, the Backlog) of ' .. INDEX)
end)

test('question index: every tool it names exists (no stale entry)', function ()
    local text = read(INDEX)
    local stale = {}
    for t in text:gmatch('`(tools/[%w_]+%.lua)') do
        if vim.fn.filereadable(t) ~= 1 then stale[#stale + 1] = t end
    end
    eq({}, stale)
end)
