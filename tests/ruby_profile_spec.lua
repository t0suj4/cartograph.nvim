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
    -- canonical owners: RBS ground truth for CORE methods (ruby-core.mpack), hand-
    -- authored for Rails methods core RBS can't see ([[cartograph-stdlib-profile]])
    eq('Module#attr_reader', p.canon['attr_reader']) -- RBS-corrected (was hand Kernel#)
    eq('Object#dup', p.canon['dup'])                 -- RBS-corrected (BasicObject/Object)
    eq('ActiveRecord::Base.belongs_to', p.canon['belongs_to']) -- Rails owner preserved
    -- nav-time enrichment payload: RBS signatures + a source-root hint ride along
    ok(p.sigs and type(p.sigs['Object#dup']) == 'table' and p.sigs['Object#dup'].sig,
        'the profile carries the RBS signature for Object#dup')
    ok(p.sig_root, 'the profile carries an RBS source-root hint')
end)

test('ruby-rails profile: LSP hover shows the RBS signature of a minted symbol', function ()
    if not ready() then skip 'no ruby parser' end
    local store = require 'cartograph.store'
    local lsp = require 'cartograph.lsp'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'config/application.rb', { 'module Demo; end' })
    write(root, 'app/models/widget.rb', {
        'class Widget < ApplicationRecord',
        '  def pick(arr)',
        '    arr.values_at(0, 1)',   -- values_at → minted Array#values_at (core, sig'd);
        '  end',                     -- not in base stdlib_names, so it reaches prof_ext → stdlib → mint
        'end',
    })
    local data = ts.extract(root)
    store.ingest(data)
    -- the `values_at` call, resolved to the minted core node carrying an RBS sig
    local c
    for _, cc in ipairs(data.calls or {}) do
        if cc.callee == 'values_at' and cc.to == 'ruby-rails::Array#values_at' then c = cc; break end
    end
    ok(c, 'values_at resolved to the minted Array#values_at node')
    -- cursor inside the `values_at` occurrence on line 2 (`    arr.values_at(0, 1)`)
    local params = {
        textDocument = { uri = vim.uri_from_fname(root .. '/' .. c.file) },
        position = { line = 2, character = 10 },
    }
    local h = lsp.handlers['textDocument/hover'](store, params)
    local val = h and h.contents and h.contents.value or ''
    ok(val:find('RBS', 1, true), 'hover carries the RBS provenance')
    ok(val:find('->', 1, true), 'hover shows the declared signature (has a -> return)')
    -- go-to-def jumps into the .rbs source (the local rbs checkout exists here)
    local defs = lsp.handlers['textDocument/definition'](store, params)
    ok(type(defs) == 'table' and defs[1] and defs[1].uri:find('%.rbs$'),
        'go-to-def resolves the minted symbol into its RBS source file')
end)

test('ruby-rails profile: a Rails root activates it; framework calls → minted stdlib nodes', function ()
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
        '  def names',
        '    parts.map { |p| p }',   -- map: a base-ruby stdlib_names VOCAB word
        '  end',
        'end',
    })
    local data = ts.extract(root)
    eq('ruby-rails', data.profile) -- the profile activated via the rails shape

    -- the RESOLUTION face (profile.mint): the disposition is promoted to a real
    -- resolution — a minted OWNER-PRECISE `ruby-rails::Owner#member` node at the
    -- stdlib tier (present? → Object#present?; belongs_to → the AR::Base class macro)
    local c1 = call_to(data, 'present?')
    ok(c1 and c1.to == 'ruby-rails::Object#present?', 'present? → Object#present? minted node')
    local c2 = call_to(data, 'belongs_to')
    ok(c2 and c2.to == 'ruby-rails::ActiveRecord::Base.belongs_to',
        'belongs_to → the AR::Base class-macro node (dot sep)')
    -- a stdlib_names VOCAB method (map) is now minted too (routed through minting),
    -- owner-precise via the profile canon (map → Enumerable#map)
    local c3 = call_to(data, 'map')
    ok(c3 and c3.to == 'ruby-rails::Enumerable#map', 'vocab `map` → Enumerable#map minted node')
    -- the minted node exists, is external, and lives in the runtime's synthetic file
    local byid = {}; for _, n in ipairs(data.nodes) do byid[n.id] = n end
    local nd = byid['ruby-rails::Object#present?']
    ok(nd and nd.kind == 'external' and nd.file == 'ruby-rails', 'minted node is external @ ruby-rails')
    -- the ref edge carries the stdlib tier flag
    local stdlib_edge = false
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.to == 'ruby-rails::Object#present?' and e.stdlib then stdlib_edge = true end
    end
    ok(stdlib_edge, 'the ref edge is stamped the stdlib tier')
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
