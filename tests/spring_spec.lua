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
        'public interface IProductBL extends ISingletonService { void doIt(); void doInline(); }',
    }, '\n'),
    -- the impl is a PLAIN class (no @Service) — the metasfresh style
    ['ProductBL.java'] = table.concat({
        'package svc;',
        'public class ProductBL implements IProductBL {',
        '  public void doIt() {}',
        '  public void doInline() {}',
        '}',
    }, '\n'),
    -- the locator: a real generic signature `<T> T get(Class<T>)`, so the
    -- return-type rounds can bind the return from the call's class literal
    ['Services.java'] = table.concat({
        'package svc;',
        'public class Services {',
        '  public static <T extends ISingletonService> T get(Class<T> c) { return null; }',
        '}',
    }, '\n'),
    ['Consumer.java'] = table.concat({
        'package svc;',
        'public class Consumer {',
        '  private final IProductBL bl = Services.get(IProductBL.class);',
        '  public void go() { bl.doIt(); }',
        '  public void inline() { Services.get(IProductBL.class).doInline(); }',
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

-- the inline-chain form Services.get(IFoo.class).m(): the locator return type
-- (IFoo) types the chained call, which the service-marker gate then redirects.
test('spring: inline Services.get(IFoo.class).m() resolves to the impl', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(SVC)
    local nm = byname(data)
    local c = callof(data, 'IProductBL::doInline')
    ok(c, 'the inline-chain call is present and typed to the interface')
    eq(nm['ProductBL::doInline'].id, c.to) -- locator return-type + marker gate
end)

-- ★★ THE TRANSITIVE CASE — WHICH IS WHY THE MARKER PROPAGATION IS A FIXPOINT AT
-- ALL, AND WAS UNTESTED (CART-0756). The tests above cover ONE hop (IProductBL
-- extends ISingletonService) and zero hops (the negative below); nothing
-- exercised a chain, so the loop that exists to walk one could have been deleted
-- and the suite would have stayed green.
--
-- ★ IT IS ALSO THE ARM THAT MAKES THE PROVENANCE FIX MEANINGFUL. `svc[child]`
-- now records the ORIGIN MARKER rather than `true` or the parent that passed it
-- along — the attribution bug CART-0755 measured on a derivation chain, where
-- after two hops the named step is one that merely INHERITED the property. Two
-- hops is the shortest chain on which origin and parent differ.
local SVCCHAIN = {
    ['ISingletonService.java'] = 'package svc;\npublic interface ISingletonService {}\n',
    -- the MIDDLE link: carries no marker of its own, only an inherited one
    ['IBaseBL.java'] = 'package svc;\npublic interface IBaseBL extends ISingletonService {}\n',
    ['IOrderBL.java'] =
        'package svc;\npublic interface IOrderBL extends IBaseBL { void ship(); }\n',
    ['OrderBL.java'] = table.concat({
        'package svc;',
        'public class OrderBL implements IOrderBL { public void ship() {} }',
    }, '\n'),
    ['Consumer2.java'] = table.concat({
        'package svc;',
        'public class Consumer2 {',
        '  private final IOrderBL bl = null;',
        '  public void go() { bl.ship(); }',
        '}',
    }, '\n'),
}

test('spring: a marker inherited through TWO hops still gates the redirect', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(SVCCHAIN)
    local nm = byname(data)
    ok(not (data.beans or {})['OrderBL'], 'the impl is NOT a @stereotype bean')
    local c = callof(data, 'IOrderBL::ship')
    ok(c, 'the interface-typed call is present')
    -- IOrderBL -> IBaseBL -> ISingletonService: the middle link has no marker of
    -- its own, so only the FIXPOINT can certify IOrderBL
    eq(nm['OrderBL::ship'].id, c.to)
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

-- ── PARAMETERIZED SUPERTYPES (CART-0672) ────────────────────────────────────
-- `extends Base` parses `superclass → type_identifier`; `extends Base<T>` parses
-- `superclass → generic_type → type_identifier`. The two queries named only the
-- first shape, so a GENERIC class had no parent and a GENERIC interface never
-- entered data.implements — the input resolve_interface consumes, which is why
-- this also under-covered the bean redirect above by ~38% on a real repo.
--
-- It hid because a lost super chain DEGRADES TO NAME MATCHING, which succeeds
-- while the method name is unique. Only the conjunction (generic AND ambiguous)
-- loses an edge, so the arms below pair both.
local GENERIC = {
    ['Session.java'] = table.concat({
        'package com.example.app;',
        'class Session { void flush() {} }',
    }, '\n'),
    ['PlainBase.java'] = table.concat({
        'package com.example.app;',
        'class PlainBase { Session getSession() { return null; } }',
    }, '\n'),
    ['GenericBase.java'] = table.concat({
        'package com.example.app;',
        'class GenericBase<T, C> { Session getSession() { return null; } }',
    }, '\n'),
    -- the AMBIGUITY the conjunction needs: two more getSession in the package
    ['Decoy1.java'] = table.concat({
        'package com.example.app;',
        'class Decoy1 { Session getSession() { return null; } }',
    }, '\n'),
    ['Decoy2.java'] = table.concat({
        'package com.example.app;',
        'class Decoy2 { Session getSession() { return null; } }',
    }, '\n'),
    ['PlainChild.java'] = table.concat({
        'package com.example.app;',
        'class PlainChild extends PlainBase { void run() { getSession().flush(); } }',
    }, '\n'),
    ['GenericChild.java'] = table.concat({
        'package com.example.app;',
        'class GenericChild<T> extends GenericBase<T, String> {',
        '  void run() { getSession().flush(); }',
        '}',
    }, '\n'),
    -- iface half: a GENERIC interface with exactly one @Service implementor
    ['TypedValidator.java'] = table.concat({
        'package com.example.app;',
        'interface TypedValidator<T> { boolean check(T t); }',
    }, '\n'),
    ['TypedValidatorImpl.java'] = table.concat({
        'package com.example.app;',
        '@Service class TypedValidatorImpl implements TypedValidator<String> {',
        '  public boolean check(String s) { return true; }',
        '}',
    }, '\n'),
    ['Runner.java'] = table.concat({
        'package com.example.app;',
        'class Runner {',
        '  private TypedValidator<String> typed;',
        '  boolean go(String s) { return this.typed.check(s); }',
        '}',
    }, '\n'),
    -- ⚠ THE GUARD AGAINST OVER-REACH: the parent name becomes VISIBLE here for
    -- the first time, so a resolver keying on the simple name gets a fresh
    -- opportunity to fabricate. `AbstractList` is outside the corpus and must
    -- resolve to NOTHING, not to a same-named local class.
    ['ExternalChild.java'] = table.concat({
        'package com.example.app;',
        'import java.util.AbstractList;',
        'abstract class ExternalChild<T> extends AbstractList<T> {',
        '  void run() { this.size(); }',
        '}',
    }, '\n'),
}

-- data.extends is a LIST of {child, parent, file} rows (build_super folds it
-- into the one-parent map, marking a collision `false`), so read it as one.
local function parent_of(data, child)
    for _, e in ipairs(data.extends or {}) do
        if e.child == child then return e.parent end
    end
end

test('java: a PARAMETERIZED superclass is still a superclass', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(GENERIC)
    eq('PlainBase', parent_of(data, 'PlainChild'), 'the plain form, unchanged')
    eq('GenericBase', parent_of(data, 'GenericChild'),
        'and the parameterized one, ERASED to the same declaration')

    -- the edge the erasure buys: the chain resolves instead of refusing between
    -- the four same-named getSession definitions in the package
    local c = callof(data, 'GenericChild::getSession')
    ok(c and c.to, 'the inherited call resolves')
    eq('super', c.prov, 'and it got there by walking the chain, not by name')
    ok((c.to or ''):find('GenericBase'), 'to the generic parent: ' .. tostring(c.to))
    -- and the CASCADE closes with it: losing the receiver had taken the chained
    -- call down too, which is what made the real site read as two bugs.
    local f
    for _, x in ipairs(data.calls) do
        if x.callee == 'flush' and x.file == 'GenericChild.java' then f = x end
    end
    ok(f and (f.to or ''):find('Session::flush'),
        'the chained call rides the recovered receiver type: ' .. tostring(f and f.to))
end)

test('java: a GENERIC interface enters data.implements and redirects', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(GENERIC)
    local seen = {}
    for _, e in ipairs(data.implements or {}) do seen[e.child .. '->' .. e.iface] = true end
    ok(seen['TypedValidatorImpl->TypedValidator'],
        'implements Foo<T> is the same relation as implements Foo')

    -- the QUIETER failure this closes: before, the call resolved to the abstract
    -- declaration with no absence class marking it — a resolved edge that stops
    -- at the interface reads exactly like a correct answer.
    local nm = byname(data)
    local c = callof(data, 'TypedValidator::check') or callof(data, 'check')
    ok(c, 'the call is present')
    eq(nm['TypedValidatorImpl::check'].id, c.to, 'redirected to the single bean impl')
end)

test('java: an out-of-corpus generic superclass resolves to NOTHING', function ()
    if not ts_ready() then return skip 'no java parser' end
    local data = extract_files(GENERIC)
    eq('AbstractList', parent_of(data, 'ExternalChild'),
        'the name is captured — that is the point of the fix')
    local size
    for _, c in ipairs(data.calls) do if c.callee == 'size' then size = c end end
    ok(size, 'the call is present')
    eq(nil, size.to, 'and it lands on nothing: a visible name is not a resolvable one')
end)
