-- THE ENDPOINT HOLE CENSUS (CART-0841, under CART-0840 "generate a client from
-- server code"). tools/endpointcensus.lua answers, per endpoint: do we have an
-- ADDRESS, a HANDLER, and a PAYLOAD SHAPE — and when we do not, WHICH ANALYSIS
-- OWNS THE GAP.
--
-- ★★★ WHAT THESE SPECS FENCE IS THE POPULATION AND THE DECOMPOSITION, not the
-- numbers. The numbers are measurements of moving corpora. But a census whose
-- POPULATION is wrong is worse than no census, and this one's first version
-- over-counted django-oscar by 47% — 314 "endpoints" of which 149 were .html
-- templates, because the adapter's marker means "this adapter minted it" and the
-- KIND is what separates a route from a template.
--
-- ⚠ AND `EMITTABLE` MUST STAY A CONJUNCTION. Address alone is 66/66 on a
-- declared .proto; payload is 0. A census that headlined the first number would
-- say "we can generate clients", which is the claim CART-0840 exists to test.

local ts = require 'cartograph.providers.treesitter'
local tiers = require 'cartograph.tier'

local function repo(rel)
    return vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h') .. '/' .. rel
end
local function have(lang)
    -- ⚠⚠ `proto` NEEDS NO PARSER, AND ASKING FOR ONE SKIPPED EVERY SPEC HERE.
    -- proto.lua is a TOKEN SCANNER — the first non-treesitter provider
    -- (CART-0824) — so `vim.treesitter.language.add('proto')` fails and a guard
    -- built on it declares the whole file unrunnable while the machinery works
    -- fine. Same defect as CART-0835, where grpcjoin listed `.proto` among
    -- "unread extensions" because it asked the treesitter registry what is
    -- readable. ★ THE READABILITY QUESTION HAS TWO REGISTRIES and one of them
    -- is not treesitter.
    if lang == 'proto' then return true end
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
        and pcall(vim.treesitter.get_string_parser, '', lang)
end

local PROTO = [[
syntax = "proto3";
package fixture;
service Widgets {
    rpc GetWidget(GetWidgetRequest) returns (GetWidgetReply) {}
}
message GetWidgetRequest { string id = 1; }
message GetWidgetReply { string name = 1; }
]]

local URLS = [[
from django.urls import path
from . import views
urlpatterns = [
    path('widgets/', views.index, name='widget-index'),
]
]]

local TEMPLATE = [[
<a href="{% url 'widget-index' %}">widgets</a>
]]

local function mkroot()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/templates', 'p')
    local function w(rel, src)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    w('fixture.proto', PROTO)
    w('urls.py', URLS)
    w('templates/widget.html', TEMPLATE)
    return root
end

local function run(root, extra)
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/endpointcensus.lua'), root }
    if extra then cmd[#cmd + 1] = extra end
    return vim.fn.system(cmd)
end

test('endpointcensus: a declared contract is FULLY addressable and has NO payload', function ()
    if not have('proto') then skip('no proto parser') end
    local root = mkroot()
    local out = run(root)
    -- ★★★ THE HEADLINE FINDING OF CART-0840, in miniature: the strongest
    -- possible starting point — a declared IDL — yields an address and nothing
    -- to send. proto.lua reads a message body for nested NAMES and skips its
    -- FIELDS ("descendable-data is a separate arc"), so we know the request is
    -- called `GetWidgetRequest` and nothing about what is in it.
    local line = out:match('grpc rpc%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)')
    ok(line ~= nil, 'the grpc family reported a row: ' .. out:sub(1, 500))
    local sites, distinct, addr, handler, payload, emit =
        out:match('grpc rpc%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)')
    eq('1', sites, 'one rpc in the fixture')
    eq('1', addr, 'and its wire path is declared')
    eq('0', payload, 'and its payload SHAPE is not recorded anywhere')
    eq('0', emit, 'so it is not emittable — emittable is the CONJUNCTION')
    ok(out:find('message FIELDS', 1, true),
        'and the gap names the owner, not just the absence')
    vim.fn.delete(root, 'rf')
end)

test('endpointcensus: a TEMPLATE is not an endpoint', function ()
    if not (have('proto') and have('python')) then skip('need proto + python') end
    -- ⚠⚠ THE POPULATION BUG THIS FENCES, MEASURED: reading `n.dj` alone counted
    -- 314 endpoints on django-oscar, of which 149 were .html templates the
    -- adapter also marks (`kind = 'module'`, for `{% url %}` references). A
    -- census over the wrong population is worse than no census, and the tell
    -- was an unlabelled `nil` language bucket in the gap-owners table.
    local root = mkroot()
    local out = run(root)
    local sites = out:match('http route%s+(%d+)')
    ok(sites ~= nil, 'the route family reported a row: ' .. out:sub(1, 500))
    eq('1', sites, 'ONE route, not two — the template must not be counted')
    vim.fn.delete(root, 'rf')
end)

test('endpointcensus: a route NAME is not an address, and the census says so', function ()
    if not (have('proto') and have('python')) then skip('need proto + python') end
    -- ★ THE FLATTERING READING REFUSED. django's adapter mints the `reverse()`
    -- name, which addresses the route inside the app; an external client puts a
    -- URL PATTERN in a request line. Counting the name as an address would make
    -- 165 django-oscar routes look client-generable when none of them is.
    local root = mkroot()
    local out = run(root)
    local _, addr = out:match('http route%s+(%d+)%s+%d+%s+(%d+)')
    eq('0', addr, 'a reverse() name is a HALF address and counts as none')
    vim.fn.delete(root, 'rf')
end)

test('endpointcensus: every gap carries a DECLARED absence kind', function ()
    if not have('proto') then skip('no proto parser') end
    -- the census exits 2 on an undeclared kind, the way agent.lua's envelope
    -- check does — a family inventing a kind is a FAULT in the tool, not a
    -- finding about the corpus
    local root = mkroot()
    local out = run(root)
    local kinds = {}
    for k in out:gmatch('%[([%a%-]+)%]') do kinds[k] = true end
    local n = 0
    for k in pairs(kinds) do
        ok(tiers.is_absence(k), k .. ' must be a declared tier.ABSENCE kind')
        n = n + 1
    end
    ok(n > 0, 'the census reported at least one gap kind to check')
    -- ★★ AND THE TWO KINDS MUST NOT COLLAPSE: `unavailable` is a data class we
    -- chose not to extract, `frontier` is a language nothing covers. Different
    -- remedies, and reporting one number would hide both.
    ok(out:find('unavailable', 1, true), 'the proto gap is `unavailable`')
    vim.fn.delete(root, 'rf')
end)

test('endpointcensus: zero endpoints is a FAULT, not a clean result', function ()
    if not have('proto') then skip('no proto parser') end
    -- ⚠ A census pointed at a root with no readable family says NOTHING about
    -- client generability, and "0 emittable" there would read as a finding. It
    -- must refuse instead — the store-headless rule: point a probe that returns
    -- zero at its own detector.
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, 'p')
    local fd = assert(io.open(empty .. '/plain.lua', 'w'))
    fd:write('local M = {}\nreturn M\n'); fd:close()
    local out = run(empty)
    ok(vim.v.shell_error ~= 0, 'the census exits non-zero')
    ok(out:find('ZERO ENDPOINTS IS A FAULT', 1, true), 'and says why: ' .. out:sub(1, 300))
    vim.fn.delete(empty, 'rf')
end)
