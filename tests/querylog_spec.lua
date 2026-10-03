-- cartograph.querylog + tools/queryreplay.lua (F20, CART-1387): read queries leave a record, and a replay of the record
-- against this build is one command. The host is driven as a process (tools/mcpserve.lua), the way an agent drives it.
local Q = require 'cartograph.querylog'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end
local repo = vim.fn.getcwd()
local function serve(root, log, requests)
    local lines = { vim.json.encode({ jsonrpc = '2.0', id = 0, method = 'initialize', params = vim.empty_dict() }) }
    for i, r in ipairs(requests) do
        lines[#lines + 1] = vim.json.encode({ jsonrpc = '2.0', id = i, method = 'tools/call', params = { name = r[1], arguments = r[2] or vim.empty_dict() } })
    end
    return vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', repo .. '/tools/mcpserve.lua', root, '--query-log-to', log },
        { stdin = table.concat(lines, '\n') .. '\n', text = true }):wait(300000)
end
local function tree()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.lua', 'w')); fd:write('local function walk(t) return t end\nreturn walk\n'); fd:close()
    return root
end

test('querylog: the ENVELOPE is what an answer claims, and the diff compares claims — never the session counter', function ()
    local a = Q.envelope({ result = {}, absence = 'frontier', absence_why = { premise = 'unparsed-files', why = 'w' }, tier = vim.NIL,
        graph = { generation = 3 } }, 'ok')
    eq({ status = 'ok', absence = 'frontier', premise = 'unparsed-files', why = 'w', rows = 0, generation = 3 }, a)
    local b = vim.deepcopy(a); b.generation = 9; b.why = 'reworded'
    eq({}, Q.diff(a, b), 'generation and the prose of `why` are not claims a replay compares')
    b.absence = 'absent'; b.premise = 'name-not-in-any-index-or-byte'
    eq({ { field = 'absence', before = 'frontier', after = 'absent' }, { field = 'premise', before = 'unparsed-files', after = 'name-not-in-any-index-or-byte' } }, Q.diff(a, b))
    eq('refusal', Q.envelope({ refusal = { rule = 'read-only' } }, 'refusal').status)
end)

test('querylog: mcpserve --query-log records each READ call — request, envelope, commit, roots, host flags; a WRITE is the journal\'s and is not logged', function ()
    if not ready() then skip 'no lua parser' end
    local root, log = tree(), vim.fn.tempname() .. '.jsonl'
    local r = serve(root, log, { { 'mentions', { name = 'nosuchidentifierxyz' } }, { 'txn_undo' }, { 'mentions', { name = 'walk' } } })
    eq(0, r.code, r.stderr)
    local recs = assert(Q.read(log))
    eq({ 'mentions', 'mentions' }, vim.tbl_map(function (x) return x.verb end, recs), 'txn_undo (mutates) is not in the read log')
    eq({ name = 'nosuchidentifierxyz' }, recs[1].args)
    eq('absent', recs[1].answer.absence)
    eq('name-not-in-any-index', recs[1].answer.premise)
    ok(recs[2].answer.rows >= 1, 'walk is mentioned')
    ok(type(recs[1].commit) == 'string' and recs[1].commit ~= '', 'the cartograph commit stamps every record')
    eq({ (vim.fn.fnamemodify(root, ':p'):gsub('/+$', '')) }, recs[1].roots)
    eq({}, recs[1].flags)
end)

test('queryreplay: the logged queries re-asked against this build — the same answers read SAME, a changed one names the field and fails --gate', function ()
    if not ready() then skip 'no lua parser' end
    local root, log = tree(), vim.fn.tempname() .. '.jsonl'
    serve(root, log, { { 'mentions', { name = 'nosuchidentifierxyz' } }, { 'mentions', { name = 'walk' } } })
    local function replay(path)
        return vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', repo .. '/tools/queryreplay.lua', path, '--gate' }, { text = true }):wait(600000)
    end
    local r = replay(log)
    eq(0, r.code, r.stdout .. r.stderr)
    ok(r.stdout:find('2 same, 0 changed, 0 failed', 1, true), r.stdout)
    -- a record whose logged answer differs from today's: the field is named, and the gate fails
    local recs = assert(Q.read(log))
    recs[1].answer.absence = 'frontier'
    local doctored = vim.fn.tempname() .. '.jsonl'
    local fd = assert(io.open(doctored, 'w'))
    for _, x in ipairs(recs) do fd:write(vim.json.encode(x), '\n') end
    fd:close()
    local d = replay(doctored)
    eq(1, d.code, 'a changed answer fails --gate')
    ok(d.stdout:find('absence  frontier -> absent', 1, true), d.stdout)
end)
