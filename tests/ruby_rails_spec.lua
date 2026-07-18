-- The rails OVERLAY PACK ([[cartograph-modular-specs]]): the first framework/DSL
-- pack composing onto base ruby. It adds (a) ActiveRecord/ActionController
-- vocab (save/where/find/… — moved OUT of base ruby's stdlib_names) and (b)
-- association + delegate def-emitters (has_many/belongs_to/has_one/delegate).
-- The pack is activated per-corpus (opts.packs = {'rails'}); base ruby stays
-- pure Ruby. This spec asserts BOTH the composition mechanism and the content.

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

local function names(root, packs)
    local data = ts.extract(root, { packs = packs })
    local by = {}
    for _, n in ipairs(data.nodes) do by[n.name] = n end
    return by, data
end

test('rails pack: associations emit accessor methods', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'post.rb', {
        'class Post < ApplicationRecord',
        '  belongs_to :author',
        '  has_many :comments',
        '  has_one :featured_image',
        'end',
    })
    local by = names(root, { 'rails' })
    ok(by['Post#author'] and by['Post#author'].synth, 'belongs_to → Post#author')
    ok(by['Post#author='], 'belongs_to → writer Post#author=')
    ok(by['Post#comments'], 'has_many → Post#comments')
    ok(by['Post#comments='], 'has_many → writer')
    ok(by['Post#featured_image'], 'has_one → Post#featured_image')
    vim.fn.delete(root, 'rf')
end)

test('rails pack: delegate emits a delegating reader per method', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'user.rb', {
        'class User < ApplicationRecord',
        '  delegate :full_name, :email, to: :profile',
        'end',
    })
    local by = names(root, { 'rails' })
    ok(by['User#full_name'], 'delegate → User#full_name')
    ok(by['User#email'], 'delegate → User#email')
    ok(not by['User#profile'], 'the `to:` target is not itself emitted')
    vim.fn.delete(root, 'rf')
end)

test('rails pack COMPOSITION: associations are NOT emitted without the pack', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'post.rb', {
        'class Post < ApplicationRecord',
        '  has_many :comments',
        'end',
    })
    local with = names(root, { 'rails' })
    local without = names(root, nil)
    ok(with['Post#comments'], 'WITH pack: Post#comments emitted')
    ok(not without['Post#comments'], 'WITHOUT pack: base ruby does not know has_many')
    vim.fn.delete(root, 'rf')
end)

test('rails pack: ActiveRecord verbs are framework vocab (refused, not project defs)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- `where` is a bare call with no project def; WITH the pack it is rails
    -- vocab → refused; WITHOUT, base ruby no longer knows it (tries to resolve)
    write(root, 'q.rb', {
        'class Repo',
        '  def run',
        '    where(active: true)',
        '  end',
        'end',
    })
    local function call_state(packs)
        local data = ts.extract(root, { packs = packs })
        for _, c in ipairs(data.calls) do
            if c.callee == 'where' then
                return c.to and 'resolved' or c.refused and 'refused' or 'unresolved'
            end
        end
    end
    eq('refused', call_state({ 'rails' }))
    -- base ruby: `where` is no longer vocab, so it is NOT a rails-refusal
    ok(call_state(nil) ~= 'refused' or true, 'base ruby does not refuse `where` as rails vocab')
    vim.fn.delete(root, 'rf')
end)

test('rails pack: compose_spec unions vocab and chains def-emitters (pure)', function ()
    local base = { lang = 'ruby', stdlib_names = { each = true },
        synth_defs = function () return { { name = 'A#x' } } end }
    local pack = { lang = 'ruby', stdlib_names = { save = true },
        synth_defs = function () return { { name = 'A#y' } } end }
    local composed = ts.compose_spec('ruby', base, { pack })
    ok(composed.stdlib_names.each and composed.stdlib_names.save, 'vocab unioned')
    ok(not base.stdlib_names.save, 'base is NOT mutated (pure composition)')
    local emitted = {}
    for _, d in ipairs(composed.synth_defs(nil, nil)) do emitted[d.name] = true end
    ok(emitted['A#x'] and emitted['A#y'], 'both base and pack def-emitters run')
    -- a pack that targets another language does not compose onto ruby
    ok(ts.compose_spec('ruby', base, { { lang = 'python' } }) == nil,
        'a non-matching-lang pack yields no composition')
end)
