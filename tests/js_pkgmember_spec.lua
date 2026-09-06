-- A DESTRUCTURED IMPORT BINDS EACH NAME TO A PACKAGE MEMBER (CART-0804).
-- `const {expect} = require('chai')` binds a name that is thereafter called BARE,
-- so nothing in the call connects it to the package. v183's pkgbind covers only
-- the whole-namespace form, because its `@bind` capture is a single identifier and
-- a destructuring pattern is not one.
--
-- The hook is tested DIRECTLY rather than through extraction, because the rewrite
-- it feeds is gated on an environment profile confirming the member — and a test
-- that needed a distilled npm surface to run would be a test of the network.

local jsspec = require 'cartograph.spec.javascript'
local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'javascript')
end

--- run import_members over the first string literal in `src`
local function members(src)
    local parser = vim.treesitter.get_string_parser(src, 'javascript')
    local root = parser:parse()[1]:root()
    local found
    local function walk(n)
        if found then return end
        if n:type() == 'string' then found = n; return end
        for ch in n:iter_children() do if ch:named() then walk(ch) end end
    end
    walk(root)
    if not found then return nil end
    return jsspec.import_members(found, src, function (node, s)
        return vim.treesitter.get_node_text(node, s)
    end)
end

test('pkgmember: a destructured require binds each name to its member', function ()
    if not ready() then skip 'no javascript parser' end
    eq({ expect = 'expect' }, members("const {expect} = require('chai');"))
    eq({ a = 'a', b = 'b' }, members("const {a, b} = require('pkg');"))
end)

test('pkgmember: a RENAME maps the local to the MEMBER, not to itself', function ()
    if not ready() then skip 'no javascript parser' end
    -- the member is what a profile can confirm; the local is what the call says
    eq({ e = 'expect' }, members("const {expect: e} = require('chai');"))
    eq({ s = 'stub' }, members("import {stub as s} from 'sinon';"))
end)

test('pkgmember: ESM named imports bind too', function ()
    if not ready() then skip 'no javascript parser' end
    eq({ html = 'html', css = 'css' }, members("import {html, css} from 'lit';"))
end)

test('pkgmember: a plain binding is NOT a destructuring and yields nothing', function ()
    if not ready() then skip 'no javascript parser' end
    -- v183's pkgbind already owns this form; two mechanisms claiming one site is
    -- how the `full` rewrite would fight itself
    eq(nil, members("const sinon = require('sinon');"))
    eq(nil, members("import sinon from 'sinon';"))
end)

test('pkgmember: bare_package answers the PACKAGE, and refuses a path', function ()
    eq('lodash', ts.bare_package("'lodash/fp'"))
    eq('@scope/pkg', ts.bare_package('"@scope/pkg/sub"'))
    eq('chai', ts.bare_package("'chai'"))
    -- a path is not a package: the rule that keeps a relative import from
    -- binding a local name to a nonexistent registry entry
    eq(nil, ts.bare_package("'./local'"))
    eq(nil, ts.bare_package("'../up'"))
    eq(nil, ts.bare_package("'/abs'"))
    eq(nil, ts.bare_package("'node:fs'"))
end)
