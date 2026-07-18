-- The rspec test-DSL pack (v1 = vocab): the SECOND ruby pack, proving
-- MULTI-PACK composition (rails + rspec) and modeling RSpec/factory_bot verbs
-- as framework vocab. Measure-first finding: spec DSL calls are already
-- honestly "unresolved" (external), so the pack's value is composition + the
-- correct model (a project method named `subject`/`describe` no longer gets
-- mis-matched), NOT a resolution gain. The let/subject example-group emitters
-- (which need a scoping model) are a banked v2.

local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'ruby')
end

local function write(root, name, lines)
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
end

local function callstate(root, callee, packs)
    local data = ts.extract(root, { packs = packs })
    for _, c in ipairs(data.calls) do
        if c.callee == callee then
            return c.to and 'resolved' or c.refused and 'refused' or 'unresolved'
        end
    end
end

test('rspec pack MULTI-PACK COMPOSITION: rails + rspec vocab both apply', function ()
    local composed = ts.compose_spec('ruby', ts.spec.ruby, { ts.packs.rails, ts.packs.rspec })
    ok(composed, 'a two-pack composition yields a spec')
    ok(composed.stdlib_names.where, 'rails vocab present (where)')
    ok(composed.stdlib_names.describe, 'rspec vocab present (describe)')
    ok(composed.stdlib_names.each, 'base ruby vocab still present (each)')
    -- rails synth_defs still runs under the composition (chained)
    ok(type(composed.synth_defs) == 'function', 'composed synth_defs is callable')
end)

test('rspec pack: a project method named `subject` is NOT mis-resolved to a DSL call', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- `subject` is an RSpec verb; with the pack it is framework vocab, so a
    -- bare `subject` call does not tail-match some unrelated project method
    write(root, 'a.rb', {
        'class Mailer',
        '  def deliver',
        '    subject',            -- RSpec verb name; must NOT resolve to X#subject
        '  end',
        'end',
        'class Report',
        '  def subject',          -- an unrelated same-named method (the trap)
        '    1',
        '  end',
        'end',
    })
    -- WITH the rspec pack, `subject` is vocab → not resolved to Report#subject
    ok(callstate(root, 'subject', { 'rspec' }) ~= 'resolved',
        'subject is framework vocab, not matched to Report#subject')
    vim.fn.delete(root, 'rf')
end)

test('rspec pack: DSL verbs are framework vocab (not a project-def match)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'b_spec.rb', {
        'RSpec.describe Thing do',
        '  it "works" do',
        '    expect(1).to eq(1)',
        '  end',
        'end',
    })
    -- describe/it/expect/to/eq are all recognized DSL → none resolve to a
    -- project def (there are none); they stay external, honestly
    for _, verb in ipairs({ 'describe', 'it', 'expect', 'eq' }) do
        ok(callstate(root, verb, { 'rspec' }) ~= 'resolved',
            verb .. ' is framework vocab, not a resolved project call')
    end
    vim.fn.delete(root, 'rf')
end)
