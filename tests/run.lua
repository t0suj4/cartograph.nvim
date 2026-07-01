-- Minimal dependency-free test runner. Run via tests/run.sh (nvim --headless).
-- Specs are tests/*_spec.lua and use the globals defined here: test/eq/ok/skip.

local reg = {}

function _G.test(name, fn) reg[#reg + 1] = { name = name, fn = fn } end

local function fmt(v) return type(v) == 'table' and vim.inspect(v) or tostring(v) end

function _G.eq(expected, got, msg)
    if not vim.deep_equal(expected, got) then
        error(('%s\n       expected: %s\n       got:      %s'):format(msg or 'eq', fmt(expected), fmt(got)), 2)
    end
end

function _G.ok(cond, msg)
    if not cond then error(msg or 'expected truthy value', 2) end
end

-- skip the current test (sentinel table so the runner can tell it apart)
function _G.skip(msg) error({ __skip = true, msg = msg }, 0) end

-- load every spec
for _, f in ipairs(vim.fn.glob('tests/*_spec.lua', false, true)) do
    local chunk, err = loadfile(f)
    if not chunk then error('cannot load ' .. f .. ': ' .. err) end
    chunk()
end

local pass, fail, skipped = 0, 0, 0
print('')
for _, t in ipairs(reg) do
    local good, err = pcall(t.fn)
    if good then
        pass = pass + 1
        print('  ok    ' .. t.name)
    elseif type(err) == 'table' and err.__skip then
        skipped = skipped + 1
        print('  skip  ' .. t.name .. (err.msg and ('  (' .. err.msg .. ')') or ''))
    else
        fail = fail + 1
        print('  FAIL  ' .. t.name)
        print('        ' .. tostring(err):gsub('\n', '\n        '))
    end
end
print(('\n%d passed, %d failed, %d skipped\n'):format(pass, fail, skipped))

if fail > 0 then vim.cmd('cquit 1') else vim.cmd('qall!') end
