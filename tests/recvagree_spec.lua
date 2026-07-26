-- RECEIVER-PATH AGREEMENT: a call `a.b.m()` and a candidate named `b.m` agree on the
-- RECEIVER, which the bare tail `m` says nothing about. Where exactly one admitted
-- candidate agrees, that beats whichever name index happened to answer first.
--
-- The shape is not one language's: MEASURED, all of it previously refused as ambiguous
-- and none of it lost or redirected — go +69 (`h.PathSpec.RelURL()` -> PathSpec.RelURL,
-- the embedded-field idiom where the field is named for its type), v8 +187
-- (`base::OS::Abort()` -> OS::Abort), rust +9
-- (`grep::matcher::LineTerminator::crlf()`), ghost +14
-- (`this.#MemberLinkClickEvent.create()`, `OfferAmount.OfferTrialAmount.create()`).
--
-- WHAT IT DELIBERATELY DOES NOT DO — the reason a bare candidate is NEUTRAL, never
-- agreeing: treating bare `m` as agreeing with `R.m` is the rule that looks obvious and
-- is wrong. It would make a free function outrank a method for every receiver call in
-- every corpus, and deciding `foo.bar()` between a bare `bar` and `Class.bar` needs the
-- receiver's TYPE, not its name ([[cartograph-local-type-inference]]: shipped for zig,
-- measured-low for the dynamic languages). This is the part a NAME can settle, and the
-- negative test below pins the boundary so nobody "improves" it into the unsound rule.

local ts = require 'cartograph.providers.treesitter'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

local function extract(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        local dir = rel:match('^(.*)/[^/]*$')
        vim.fn.mkdir(root .. (dir and '/' .. dir or ''), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    return data
end

local function call_named(data, full)
    for _, c in ipairs(data.calls or {}) do if c.full == full then return c end end
end
local function def_named(data, file, name)
    for _, n in ipairs(data.nodes or {}) do
        if n.file == file and n.name == name then return n.id end
    end
end

test('recv-agree: a call naming the receiver TYPE beats an unrelated same-tail method',
    function ()
    if not ready('go') then skip 'no go parser' end
    local data = extract {
        -- two types define Parse; the call names one of them in its receiver path
        ['a/parser.go'] = 'package a\ntype PathParser struct{}\n'
            .. 'func (p *PathParser) Parse(s string) string { return s }\n',
        ['b/other.go'] = 'package b\ntype UrlParser struct{}\n'
            .. 'func (u *UrlParser) Parse(s string) string { return s }\n',
        ['c/use.go'] = 'package c\nfunc run(w W) string {\n'
            .. '\treturn w.cfg.PathParser.Parse("x")\n}\n',
    }
    local want = def_named(data, 'a/parser.go', 'PathParser.Parse')
    local other = def_named(data, 'b/other.go', 'UrlParser.Parse')
    ok(want and other, 'both Parse methods exist')
    local c = call_named(data, 'w.cfg.PathParser.Parse')
    ok(c, 'the call is recorded')
    eq(want, c.to, 'the receiver path names PathParser, so UrlParser is not a candidate')
end)

-- THE BOUNDARY. A bare candidate carries no receiver, so it can never AGREE — the
-- behaviour here must be whatever the name indexes already decided, not a preference for
-- the free function. If someone makes a bare name count as agreement, this fails.
test('recv-agree: a BARE candidate is neutral, never agreeing', function ()
    if not ready('go') then skip 'no go parser' end
    local data = extract {
        ['a/free.go'] = 'package a\nfunc Handle(s string) string { return s }\n',
        ['b/m.go'] = 'package b\ntype Server struct{}\n'
            .. 'func (s *Server) Handle(x string) string { return x }\n',
        ['c/use.go'] = 'package c\nfunc run(o O) string { return o.thing.Handle("x") }\n',
    }
    local free = def_named(data, 'a/free.go', 'Handle')
    local meth = def_named(data, 'b/m.go', 'Server.Handle')
    ok(free and meth, 'a free function and a method share the tail')
    local c = call_named(data, 'o.thing.Handle')
    ok(c, 'the call is recorded')
    -- `o.thing` names no type, so nothing agrees: the free function must NOT be
    -- promoted over the method by this rule
    ok(c.to ~= free, 'the bare free function is not preferred: ' .. tostring(c.to))
end)

test('recv-agree: TWO agreeing candidates still refuse — uniqueness is the gate',
    function ()
    if not ready('go') then skip 'no go parser' end
    local data = extract {
        -- the SAME type name defined in two packages, both with Init
        ['x/one.go'] = 'package x\ntype Store struct{}\n'
            .. 'func (s *Store) Init() int { return 1 }\n',
        ['y/two.go'] = 'package y\ntype Store struct{}\n'
            .. 'func (s *Store) Init() int { return 2 }\n',
        ['z/use.go'] = 'package z\nfunc run(c C) int { return c.Store.Init() }\n',
    }
    local c = call_named(data, 'c.Store.Init')
    ok(c, 'the call is recorded')
    eq(nil, c.to, 'two agreeing candidates is an honest refusal, not a coin flip')
    ok(c.refused ~= nil, 'and it carries a refusal record')
end)

test('recv-agree: agreement must be at a SEPARATOR boundary, not a substring',
    function ()
    if not ready('go') then skip 'no go parser' end
    -- `Parser.Parse` must not be considered a suffix of `w.MyParser.Parse` at a
    -- boundary — `MyParser` is a different type that merely ends with the same letters
    local data = extract {
        ['a/p.go'] = 'package a\ntype Parser struct{}\n'
            .. 'func (p *Parser) Parse() int { return 1 }\n',
        ['b/q.go'] = 'package b\ntype Other struct{}\n'
            .. 'func (o *Other) Parse() int { return 2 }\n',
        ['c/use.go'] = 'package c\nfunc run(w W) int { return w.MyParser.Parse() }\n',
    }
    local a = def_named(data, 'a/p.go', 'Parser.Parse')
    local c = call_named(data, 'w.MyParser.Parse')
    ok(a and c, 'fixture built')
    ok(c.to ~= a, 'a substring match is not agreement: ' .. tostring(c.to))
end)
