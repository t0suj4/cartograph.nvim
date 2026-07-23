-- The RUBY-RAILS L2 profile ([[cartograph-stdlib-profile]]): a Rails root
-- (config/application.rb) activates the ruby-rails profile via the rails shape,
-- and framework method calls with no project def get the `stdlib` disposition
-- (prof_ext, at the no-def fallback — never shadowing a real def). Gate-protects
-- the profile CONTENT + the shape→active_profile_for→eff_spec wiring end-to-end.

local ts = require 'cartograph.providers.treesitter'
local profmod = require 'cartograph.spec.profile'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'ruby')
end
local function write(root, name, lines)
    local dir = vim.fn.fnamemodify(root .. '/' .. name, ':h')
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
end
-- the first call with this callee, from the extracted graph
local function call_to(data, callee)
    for _, c in ipairs(data.calls or {}) do
        if c.callee == callee then return c end
    end
end

test('ruby-rails profile: loads with the framework surface in `free`', function ()
    local p = profmod.load('ruby-rails')
    ok(p and p.schema == 1, 'profile loads, schema 1')
    eq('ruby', p.lang)
    for _, n in ipairs({ 'present?', 'blank?', 'belongs_to', 'has_many',
        'validates', 'scope', 'save', 'where', 'puts', 'raise' }) do
        ok(p.free[n], 'free blesses ' .. n)
    end
    ok(p.nsset['Rails'] and p.nsset['ActiveRecord'], 'namespaces cover Rails/ActiveRecord')
end)

test('ruby-rails profile: a Rails root activates it; framework calls → stdlib', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- the shape marker: config/application.rb makes this a Rails root
    write(root, 'config/application.rb', {
        'module Demo', '  class Application < Rails::Application', '  end', 'end',
    })
    write(root, 'app/models/widget.rb', {
        'class Widget < ApplicationRecord',
        '  belongs_to :account',
        '  def ready?',
        '    title.present? && subtitle.blank?',
        '  end',
        'end',
    })
    local data = ts.extract(root)
    eq('ruby-rails', data.profile) -- the profile activated via the rails shape

    local c1 = call_to(data, 'present?')
    ok(c1 and not c1.to and type(c1.ext) == 'table' and c1.ext.why == 'stdlib',
        'present? (no project def) → stdlib disposition')
    local c2 = call_to(data, 'belongs_to')
    ok(c2 and not c2.to and type(c2.ext) == 'table' and c2.ext.why == 'stdlib',
        'belongs_to class-macro → stdlib disposition')
end)

test('ruby-rails profile: a PROJECT def is not stolen by the profile (sound)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'config/application.rb', { 'module Demo; end' })
    -- `helper` IS in the profile free set (ActionView), but here it is a real
    -- project method — resolution must win over the profile (prof_ext is nodef-only)
    write(root, 'app/models/widget.rb', {
        'class Widget < ApplicationRecord',
        '  def compute',
        '    helper',
        '  end',
        '  def helper',
        '  end',
        'end',
    })
    local data = ts.extract(root)
    eq('ruby-rails', data.profile)
    local c = call_to(data, 'helper')
    ok(c and c.to and c.to:match('Widget#helper'), 'helper resolves to the project def, not stdlib')
    ok(not (type(c.ext) == 'table' and c.ext.why == 'stdlib'), 'not disposed stdlib')
end)
