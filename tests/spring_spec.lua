-- F1: interface→impl DI resolution (the linker's first Java kind). A call on a
-- field typed as an interface lands on the interface's abstract method stub;
-- resolve_interface REDIRECTS it to the unique @stereotype bean impl. SET
-- semantics: >1 impl or 0 impls → leave at the interface (honest). Bean-gated:
-- an unannotated implementor is not a candidate. Mirrors examples/spring-di.

local function ts_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'java')
end

-- extract a set of {name=source} java files under one temp root
local function extract_files(files)
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, src in pairs(files) do
        local fd = assert(io.open(root .. '/' .. name, 'w'))
        fd:write(src); fd:close()
    end
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    return data
end

-- one package-private type per file (Java allows ≤1 public top-level type).
local FILES = {
    ['PaymentService.java'] = table.concat({
        'package com.example.app;',
        'interface PaymentService { void charge(); }',
    }, '\n'),
    ['PaymentServiceImpl.java'] = table.concat({
        'package com.example.app;',
        '@Service class PaymentServiceImpl implements PaymentService {',
        '  public void charge() {}',
        '}',
    }, '\n'),
    ['NotificationService.java'] = table.concat({
        'package com.example.app;',
        'interface NotificationService { void send(); }',
    }, '\n'),
    ['EmailNotificationService.java'] = table.concat({
        'package com.example.app;',
        '@Service class EmailNotificationService implements NotificationService {',
        '  public void send() {}',
        '}',
    }, '\n'),
    ['SmsNotificationService.java'] = table.concat({
        'package com.example.app;',
        '@Service class SmsNotificationService implements NotificationService {',
        '  public void send() {}',
        '}',
    }, '\n'),
    ['AuditLog.java'] = table.concat({
        'package com.example.app;',
        'interface AuditLog { void record(); }',
    }, '\n'),
    ['OrderController.java'] = table.concat({
        'package com.example.app;',
        '@Service class OrderController {',
        '  private PaymentService paymentService;',
        '  private NotificationService anyNotifier;',
        '  private AuditLog auditLog;',
        '  public void go() {',
        '    paymentService.charge();',
        '    anyNotifier.send();',
        '    auditLog.record();',
        '  }',
        '}',
    }, '\n'),
    -- a @Qualifier field of the same 2-impl interface: names one impl by bean
    ['Dispatcher.java'] = table.concat({
        'package com.example.app;',
        '@Service class Dispatcher {',
        '  @Qualifier("emailNotificationService") private NotificationService emailNotifier;',
        '  public void go() { emailNotifier.send(); }',
        '}',
    }, '\n'),
}

local function byname(data)
    local m = {}
    for _, n in ipairs(data.nodes) do m[n.name] = n end
    return m
end
local function callof(data, full)
    for _, c in ipairs(data.calls) do if c.full == full then return c end end
end
-- find a call by full AND qualifier (nil = the unqualified one)
local function callof_q(data, full, qual)
    for _, c in ipairs(data.calls) do
        if c.full == full and c.qualifier == qual then return c end
    end
end

test('spring: implements/extends captured to data.implements', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(FILES)
    local seen = {}
    for _, e in ipairs(data.implements or {}) do
        seen[e.child .. '->' .. e.iface] = true
    end
    ok(seen['PaymentServiceImpl->PaymentService'], 'impl edge present')
    ok(seen['EmailNotificationService->NotificationService'], 'email impl edge')
    ok(seen['SmsNotificationService->NotificationService'], 'sms impl edge')
end)

-- bean detection is scoped to IMPLEMENTERS (the only place resolve_interface
-- needs it) — an @stereotype implementer is a candidate; the annotation gates
-- membership. (A bean that implements nothing is never a candidate, so it need
-- not be tracked; the negative test below covers the exclusion side.)
test('spring: @stereotype implementer captured as a bean', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(FILES)
    ok((data.beans or {})['PaymentServiceImpl'], 'annotated impl is a bean')
    ok((data.beans or {})['EmailNotificationService'], 'annotated impl is a bean')
end)

test('spring: unique bean impl — I::m redirects to C::m', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(FILES)
    local nm = byname(data)
    ok(nm['PaymentServiceImpl::charge'], 'impl method node exists')
    local c = callof(data, 'PaymentService::charge')
    ok(c, 'the interface-typed call is present')
    eq(nm['PaymentServiceImpl::charge'].id, c.to) -- redirected to the impl
    ok(c.inferred, 'marked inferred (~), a DI-inferred resolution')
end)

test('spring: ambiguous (>1 impl) stays at the interface — no guess', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(FILES)
    local nm = byname(data)
    local c = callof_q(data, 'NotificationService::send', nil) -- unqualified
    ok(c, 'the unqualified ambiguous call is present')
    -- two bean impls → NOT redirected to either; left at the interface stub
    eq(nm['NotificationService::send'].id, c.to)
end)

-- @Qualifier: the receiver field's bean name picks one impl of an otherwise
-- ambiguous interface. Default bean name = decapitalized class name, so
-- @Qualifier("emailNotificationService") → EmailNotificationService.
test('spring: @Qualifier narrows an ambiguous interface to the named bean', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(FILES)
    local nm = byname(data)
    local c = callof_q(data, 'NotificationService::send', 'emailNotificationService')
    ok(c, 'the qualified call is present with its qualifier recorded')
    eq(nm['EmailNotificationService::send'].id, c.to) -- narrowed to the named impl
    ok(c.inferred, 'inferred (~)')
end)

test('spring: interface with 0 impls stays a frontier', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(FILES)
    local nm = byname(data)
    local c = callof(data, 'AuditLog::record')
    ok(c, 'the no-impl call is present')
    eq(nm['AuditLog::record'].id, c.to) -- unchanged
end)

-- bean gating: an unannotated implementor must NOT count as a candidate, so a
-- lone bean impl stays UNIQUE (the negative/spring-di StorePlain guard).
local GATED = {
    ['Store.java'] = table.concat({
        'package com.example.ann;',
        'interface Store { void put(); }',
    }, '\n'),
    ['StoreBean.java'] = table.concat({
        'package com.example.ann;',
        '@Service class StoreBean implements Store { public void put() {} }',
    }, '\n'),
    ['StorePlain.java'] = table.concat({
        'package com.example.ann;',
        'class StorePlain implements Store { public void put() {} }', -- NOT a bean
    }, '\n'),
    ['StoreConsumer.java'] = table.concat({
        'package com.example.ann;',
        '@Service class StoreConsumer {',
        '  private Store store;',
        '  public void go() { store.put(); }',
        '}',
    }, '\n'),
}

test('spring: unannotated implementor excluded — resolution stays unique', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(GATED)
    local nm = byname(data)
    ok(not (data.beans or {})['StorePlain'], 'plain impl is not a bean')
    local c = callof(data, 'Store::put')
    ok(c, 'the call is present')
    -- StorePlain excluded → {StoreBean} is the sole candidate → redirect
    eq(nm['StoreBean::put'].id, c.to)
    ok(c.inferred, 'inferred (~)')
end)

-- explicit @Service("name"): the qualifier matches the DECLARED bean name, not
-- the decapitalized class name (which would be "repoA" and miss).
local EXPL = {
    ['Repo.java'] = table.concat({
        'package com.example.expl;',
        'interface Repo { void save(); }',
    }, '\n'),
    ['RepoA.java'] = table.concat({
        'package com.example.expl;',
        '@Service("customRepo") class RepoA implements Repo { public void save() {} }',
    }, '\n'),
    ['RepoB.java'] = table.concat({
        'package com.example.expl;',
        '@Service class RepoB implements Repo { public void save() {} }',
    }, '\n'),
    ['RepoConsumer.java'] = table.concat({
        'package com.example.expl;',
        '@Service class RepoConsumer {',
        '  @Qualifier("customRepo") private Repo repo;',
        '  public void go() { repo.save(); }',
        '}',
    }, '\n'),
}

test('spring: @Qualifier matches an explicit @Service("name")', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(EXPL)
    local nm = byname(data)
    eq('customRepo', (data.beans or {})['RepoA']) -- explicit name captured
    local c = callof_q(data, 'Repo::save', 'customRepo')
    ok(c, 'the qualified call is present')
    eq(nm['RepoA::save'].id, c.to) -- narrowed by explicit bean name
end)

-- SERVICE-MARKER gate (metasfresh Services.get(IFoo.class) idiom): a receiver
-- typed as an interface that extends a service marker (ISingletonService) is
-- resolved to its UNIQUE implementer even though the impl is NOT a @stereotype
-- bean — the marker certifies a fat single-impl service. The bean gate alone
-- (F1) misses these; this is the metasfresh-native kind.
local SVC = {
    ['ISingletonService.java'] = table.concat({
        'package svc;',
        'public interface ISingletonService {}',
    }, '\n'),
    ['IProductBL.java'] = table.concat({
        'package svc;',
        'public interface IProductBL extends ISingletonService { void doIt(); }',
    }, '\n'),
    -- the impl is a PLAIN class (no @Service) — the metasfresh style
    ['ProductBL.java'] = table.concat({
        'package svc;',
        'public class ProductBL implements IProductBL { public void doIt() {} }',
    }, '\n'),
    ['Consumer.java'] = table.concat({
        'package svc;',
        'public class Consumer {',
        '  private final IProductBL bl = Services.get(IProductBL.class);',
        '  public void go() { bl.doIt(); }',
        '}',
    }, '\n'),
}

test('spring: service-marker interface resolves to its unique impl (non-bean)', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(SVC)
    local nm = byname(data)
    ok(not (data.beans or {})['ProductBL'], 'the impl is NOT a @stereotype bean')
    local c = callof(data, 'IProductBL::doIt')
    ok(c, 'the interface-typed call is present')
    eq(nm['ProductBL::doIt'].id, c.to) -- service-gate redirect, not bean-gated
    ok(c.inferred, 'inferred (~)')
end)

-- the marker IS the gate: the same shape WITHOUT the service marker (and no
-- @stereotype) must NOT redirect — counting all impls unconditionally would be
-- the unsound generalization the gates exist to prevent.
local NOMARKER = {
    ['IFoo.java'] = table.concat({
        'package nm;',
        'public interface IFoo { void doIt(); }', -- no marker extends
    }, '\n'),
    ['FooImpl.java'] = table.concat({
        'package nm;',
        'public class FooImpl implements IFoo { public void doIt() {} }', -- not a bean
    }, '\n'),
    ['C.java'] = table.concat({
        'package nm;',
        'public class C { private IFoo f; public void go() { f.doIt(); } }',
    }, '\n'),
}

test('spring: no marker + no stereotype → stays at the interface (sound)', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(NOMARKER)
    local nm = byname(data)
    local c = callof(data, 'IFoo::doIt')
    ok(c, 'the call is present')
    eq(nm['IFoo::doIt'].id, c.to) -- unchanged: neither gate fires
end)
