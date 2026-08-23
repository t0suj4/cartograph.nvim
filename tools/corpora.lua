-- The corpus registry: every named corpus the benchmarks and gates run
-- against. A corpus's IDENTITY is its content — repo URL + commit — not the
-- local path (that's just where it happens to live). `expected` baselines are
-- only meaningful at the pinned `rev`: the gate refuses to apply them when
-- the checkout has moved (that would report corpus drift as extractor drift).
--
-- PINNED (repo + rev + expected): stable read-only dogfood targets. If the
-- checkout moves, either restore the rev or recalibrate (`gate <name> --save`
-- on the new rev + update rev/expected here).
-- UNPINNED (no rev): living corpora — their truth is a saved snapshot whose
-- meta records the corpus rev at save time; the gate surfaces rev drift as
-- context instead of failing.
--
-- Use from a headless driver (a pure data table — dofile and index by name):
--   local corpora = dofile('tools/corpora.lua')
--   local c = corpora.server            -- or corpora[name], nil if unknown
--   -- c.root  = local checkout path (where it happens to live)
--   -- c.repo/c.rev = the corpus IDENTITY (baselines hold only at this rev)
--   -- c.expected = { refs, nodes } gate baseline (PINNED corpora only)
--   for name, c in pairs(corpora) do ... end   -- iterate the registry

local HOME = vim.env.HOME or os.getenv('HOME')

return {
    server = {
        root = HOME .. '/git/elasticsearch/server/src/main/java',
        budget_mb = 3000, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://github.com/elastic/elasticsearch',
        rev = '4743238408a4',
        lang = 'java',
        expected = { refs = 80269, nodes = 93446 }, -- recalib 2026-08-22 (v132 A JAVA LAMBDA IS A FUNCTION AND NOW HAS A NODE, CART-0406 — GATED HERE LATE, CART-0502): +6545 nodes / +1640 refs. THIS PIN WAS RED ON CLEAN MAIN, which is the whole reason CART-0502 exists: v132 landed on 08-14 recalibrated on `libs` and NOT here, so for eight days every server diff was a mixture that read as attributable. ATTRIBUTED BY MEASUREMENT, not by date: 6359 of the +6545 nodes (97.1%) carry `#cb` in their id — the `<callee>#cb` name v132 mints for an anonymous lambda in argument position — and `libs`, the corpus that DID get the v132 recalib, gives 1538 of its recorded +1579 (97.4%). The same ratio on a corpus whose delta is known is what makes this an attribution and not a coincidence; the ~3% residual is the lambda-assigned-to-a-named-variable share, which takes the declarator's name instead. ★ v134 (.h PARSED AS C, the era libs' own comment names) IS RULED OUT, not merely unlikely: `server/src/main/java` holds 4843 .java files and ZERO non-java files, so a C++-header fix cannot reach it. libs is java WITH a native tail (28 .cc, 6 .h) and server is the same repo without one — the property does not travel between subtrees, and reading libs' comment as if it did is how v134 got suspected in the first place. Prior: 78629/86901 -- recalib 2026-08-07 (v119 FIVE LANGUAGES HAD NO ENCLOSING FUNCTION, CART-0306): -340 nodes / -1496 edges / +137 edges, Δrefs 0. `in_function` read `spec.fn_types or DEFAULT` and the default names function_definition/function_declaration — neither of which exists in java, so it returned nil for EVERY node and could not reject a declaration made inside a function. What went: the same java anonymous-class fields as libs, at scale. The +137 edges are re-pointing, not growth — refs is unchanged at 78629, so references that had matched a fabricated module variable now match a real target. Δrefs 0 is the tell: these nodes were fabricated MODULE variables that nothing correctly referenced, so removing them moved no reference. Only java and rust moved, and the predicate is sharp — a language changes iff its `vars` query is UNROOTED AND its in_function was blind; everyone else roots at source_file/program and never needed the predicate. Prior: nodes 87241 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +1502 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. java's `region@0` owns STATIC FIELD INITIALIZERS — the load-time code of a class (TransportVersion.java's constants calling loadConstant/collectFromResources). Prior: 77127 -- +18 @ honesty pass v46 (stale baseline caught up on prior Java refused→resolved)
        notes = 'THE parity gate corpus (5x scale, 4843 files, ~55s extract)',
    },
    libs = {
        root = HOME .. '/git/elasticsearch/libs',
        repo = 'https://github.com/elastic/elasticsearch',
        rev = '4743238408a4',
        lang = 'java',
        expected = { refs = 11649, nodes = 15419 }, -- recalib 2026-08-14 (v134 .h PARSED AS C, CART-0410): +267 refs / -22 nodes. libs is java with a small native tail (28 .cc, 6 .h); the tree holds C++ source so its headers now parse as C++ too. Small because the corpus is mostly java — which is the point of keeping a mixed corpus pinned: a change aimed at C++ should move it a little and not at all elsewhere. Prior: 11382/15441 -- recalib @ CART-0406: +1579 nodes / +394 refs = A JAVA LAMBDA IS A FUNCTION AND NOW HAS A NODE. flow stops at `lambda_expression` on the documented promise that a node is MINTED to hold the rows; an anonymous CLASS kept it (its `run` was always in the graph) and a lambda did not, so 1670 lambda bodies here had NO ROWS IN NO NODE. The +1579 are named js's way — the declarator's name, or `<callee>#cb` in argument position (map#cb, filter#cb, forEach#cb) — because js solved this for arrows and a second convention would BE the drift. +394 refs = calls inside those bodies finally have an OWNER. The gap between 1670 lambdas and 1579 nodes is deliberate: a lambda in RETURN position has no name and no enclosing call, and `fn#cb` in a name-keyed graph carries no information. EVERY number rose and none fell, which is the review question answered by the shape of the delta. Found by the combinatorial grid (CART-0405) the day an `inlambda` SHELL existed. Prior: refs 10988, nodes 13862 -- recalib 2026-08-07 (v119 FIVE LANGUAGES HAD NO ENCLOSING FUNCTION, CART-0306): -24 nodes / -65 edges, Δrefs 0. `in_function` read `spec.fn_types or DEFAULT` and the default names function_definition/function_declaration — neither of which exists in java, so it returned nil for EVERY node and could not reject a declaration made inside a function. What went: fields of ANONYMOUS CLASSES declared inside methods — ReleasableIterator.java's `private T value` lives in a `new ReleasableIterator<>() { … }` inside a static method, and was published as a file-level variable named `value`. Δrefs 0 is the tell: these nodes were fabricated MODULE variables that nothing correctly referenced, so removing them moved no reference. Only java and rust moved, and the predicate is sharp — a language changes iff its `vars` query is UNROOTED AND its in_function was blind; everyone else roots at source_file/program and never needed the predicate. Prior: nodes 13886 -- recalib 2026-08-06 (v117 A COMMENT IS NOT A STATEMENT IN JAVA/RUST, CART-0304): -2 nodes. flow + the extractor skipped only the node name `comment`, which java and rust do not use (`line_comment`/`block_comment`, + rust `doc_comment`), so every comment was a STATEMENT. The node delta is almost entirely a RE-KEY, not a loss: a file's module-level `region@0` becomes `region@<first real line>` because the license header no longer opens the statement run (ArrowUtils.java region@0 -> region@9). The net -2 are two files whose only statement-run content WAS comments, so they now correctly have no module-level region at all. Δrefs 0 in both — a comment carries no identifier, which is exactly why this hid: it moved statement PARTITION and nothing else. Found by tools/langaudit.lua, not by a test; the suite is lua-only and lua calls its comments `comment`. Prior: nodes 13888 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +166 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. In java the region is `region@0` and what it owns is STATIC FIELD INITIALIZERS — java's load-time code, structurally the same thing as a lua module body (Terminal.java's DEFAULT = defaultTerminal()). Prior: 10822 -- +1 @ generic Class<T> return (getLibrary(VectorLibrary.class))
        notes = 'the small/fast java corpus (943 files, ~10s) — quick iteration',
    },
    -- ── per-language quick tier (libs-sized: seconds, calibrated, pinned) ──
    php = {
        root = HOME .. '/git/mantisbt/core',
        repo = 'https://github.com/mantisbt/mantisbt',
        rev = '821ce4ac9dab',
        expected = { refs = 6384, nodes = 2538 }, -- recalib 2026-08-23 (v146 A DEFINITION-SIDE MEMBER KEY IS NOT A REFERENCE, CART-0529): -1 ref, nodes unchanged, and the one edge is nameable: BugFilterQuery.class.php:231 does `$this->db_result = null;` -- an INSTANCE PROPERTY being cleared -- and the graph claimed BugFilterQuery::build_query references the GLOBAL function db_result() in database_api.php, on nothing but a spelling collision. It was the edge's only occurrence, so the whole edge was fabricated. Prior: 6385 -- recalib 2026-08-22 (v145 CALL POSITION IS A PER-LANGUAGE FACT, CART-0499): -7 refs / -20 edges, nodes unchanged. php's three call spellings (function_call_expression / member_call_expression / scoped_call_expression) were absent from the provider's inline four-name list, so a call-position identifier was never marked a callee and fell through to the fn-REFERENCE branch. TWO KINDS OF WRONG EDGE WENT, and every one is nameable: (a) the -7 refs are all `$this->html_end()` in core/classes/Issue*TimelineEvent.class.php bound to the GLOBAL function html_end() in html_api.php purely because the bare name is corpus-unique -- a method call fabricated into a call on an unrelated global; (b) 13 `reg` edges ("kept alive by top-level DATA") that are really top-level CALLS -- datetimepicker_api.php -> require_js, session_api.php -> php_mode, six files -> config_get_global. THE SCALE IS NOT HERE: this corpus is mantis's core/ only and holds 25 of the full repo's 2681 reg occurrences (CART-0506), which is why the fix was verified by hand on ~/git/mantisbt -- 751 reg edges -> 27, and of 724 removed (file -> target) pairs ZERO lost their last edge, because own_module_calls has recorded resolved module-level calls from their REGION since v107. Prior: 6392 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +16 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. mantis's *_api.php files do load-time config_get_global/require_js/require_css at file scope. Prior: 6376 -- calibrated @ 098c537
        lang = 'php',
        notes = 'php quick tier (150 files); mantis events adapter banked',
    },
    sylius = {
        root = HOME .. '/git/sylius/src',
        budget_mb = 1400, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://github.com/sylius/sylius',
        rev = '9b6799e2b884',
        expected = { refs = 5606, nodes = 32213 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +1 ref (nodes unchanged) = a top-level call now owned by its statement-run REGION. The smallest lift in the grid, and it is the right answer: symfony php is class bodies with no file-scope statements, so the single edge is in a .js asset (statistics_chart.js::region@108 -> renderChart). Prior: 5605 -- recalib 2026-07-19: +53 nodes/+10 refs = JS/TS pivot (index.js webpack configs class-keyed SyliusShop._prepareWebpackConfig) + anon-fn #cb restructuring + 1 php fn-value honesty; php side stable
        lang = 'php',
        notes = 'php SCALE tier (4636 files) — symfony adapter territory',
    },
    grocy = {
        root = HOME .. '/git/grocy',
        repo = 'https://github.com/grocy/grocy',
        rev = '297cc5724441', -- PRE-FIX of #2259 (c415e2f) — the taint keystone
        expected = { refs = 2367, nodes = 2403 }, -- recalib 2026-08-08 (v123 A TEMPLATE THAT REUSES ITS HOST'S EXTENSION IS NOT THAT LANGUAGE, CART-0347): -192 nodes, Δrefs 0. `x.blade.php` ends in `.php`, so lang_for claimed 96 Laravel templates as php — and the grammar does NOT error on them: a blade file has no `<?php` tag, so the whole file parses as inline text (has_error=false, one named child). Valid php, semantically empty. What came out was a module + a region PER FILE, 192 nodes named after template directives (`region @extends('layout.default')`), and ZERO of the 1296 `$__t(…)` calls those templates actually contain (`grep -roE '\$__t\s*\(' views --include='*.blade.php' | wc -l`, at the pinned rev 297cc5724441 — this said 1608 until 2026-08-16, a figure NOBODY COULD REPRODUCE from any scope or pattern: $__t( is 1296 everywhere in the repo, `__t(` is 1653 whole-repo with ~337 of those in the .js frontend and 20 in non-view php, and no combination reaches 1608. AN ACCEPTANCE NUMBER WITHOUT ITS COMMAND IS NOT A MEASUREMENT — this one was the whole reason reading blade looked worth building, and it was 24% high. The command travels with the number now, CART-0424). Δrefs 0 is the tell, the same one the java/rust entries below use: nothing referenced these nodes, because they were never real. NOTE the 2026-07-19 line further down says "php side STABLE at 878 nodes" — that number always included these 192; the honest php figure was 686 the whole time. php.exts now carries ext_disclaim={'blade.php'} and the file is skipped, which is the honest answer: we have no blade grammar, and parsing a template as its host invents structure rather than finding it. Prior: 2595 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +129 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. THE TAINT KEYSTONE IS UNAFFECTED (rung-2 fires on the same GetProductStockLocations; these are load-time bootstraps — app.php's ConfigurationValidator/WebhookRunner and migrations/*.php calling GetDbConnection). Prior: 2238 -- recalib 2026-07-26: v104 js member-target function literals (+997 refs/+98 nodes defs): `X.y = function(){}` now mints, so pre-class exports are definitions. MEASURED per-item vs a HEAD baseline: the cleanest case — recovered 1230, +12 out of a refusal, 0 redirected, 0 LOST: its frontend is `Grocy.Api.Post = function(){}` all the way down. Prior: refs 1241 / nodes 2497 -- recalib 2026-07-19: +1180 nodes = JS/TS pivot + anon-fn (public/viewjs/*.js: 1615 js nodes incl 1123 #cb callbacks); php side STABLE at 878 nodes (taint keystone unaffected — validated via reduced fixture in sinkflow_spec, not live corpus counts)
        lang = 'php',
        notes = 'the TAINT keystone (Slim/PSR-7 + LessQL): both poles ground-'
            .. 'truth-validated — rung-2 fires on GetProductStockLocations (the '
            .. 'real SQLi), silent on the int-typed sibling; [[cartograph-taint-analysis]]',
    },
    -- ★ MODERN C++, because the 7kaa row below CANNOT GATE THREE FORMS (CART-0385). Measured
    -- with tools/ctrlcensus.lua --coverage, 7kaa has ZERO for_range_loop, try_statement and
    -- catch_clause -- it is C-style C++ -- so the range-for support shipped in CART-0363 and
    -- cpp exception flow had no corpus behind them at all. colobot-base covers 10 of 10 forms
    -- the grammar has (259 range-for, 38 try, 39 catch) and its checkout is clean, which
    -- azerothcore's is not (it writes .log files into the tree, and a dirty pin is no pin).
    -- Kept ALONGSIDE 7kaa rather than replacing it: 7kaa is the calibrated quick tier, and a
    -- corpus that lacks a form is still a fine witness for the forms it has.
    cppmodern = {
        root = HOME .. '/git/colobot/colobot-base/src',
        repo = 'https://github.com/colobot/colobot',
        rev = '018af35',
        expected = { refs = 7161, nodes = 6215 }, -- recalib 2026-08-14 (v134 .h PARSED AS C, CART-0410): -1859 nodes / +1555 refs, same mechanism as cpp — colobot is 259 .h against 208 .cpp, so the majority of its headers were misparsed. The expression census is the sharper witness: binder:ERROR 686→0 and extra:ERROR 20→0, i.e. the rows whose node type was literally ERROR — the C parser's wreckage of a C++ class — no longer exist to disagree about; missing:declaration 1400→8. Prior: 5606/8074 -- calibrated 2026-08-11 @ colobot 018af35 (CART-0385, on arrival)
        lang = 'cpp',
        notes = 'modern C++ (208 files): range-for, try/catch, the forms 7kaa has none of',
    },
    cpp = {
        root = HOME .. '/git/7kaa',
        repo = 'https://git.code.sf.net/p/skfans/7kaa',
        rev = '9e5cde1bc1d7',
        expected = { refs = 9229, nodes = 9024 }, -- recalib 2026-08-14 (v134 A C++ HEADER NAMED .h WAS PARSED AS C, CART-0410): -3120 nodes / +1189 refs. 7kaa names every header .h, and spec/c.lua claims that extension, so all 189 headers were parsed with the C grammar — where `class Foo { … }` is not an error but reads as type + declarator plus a compound_statement. The whole class became ONE function_definition and every method prototype inside it resolved to that node, minting a free-floating `function` per prototype: 3752 of them, plus 403 vars. THE NODE DROP IS FABRICATION LEAVING, and the REF RISE is the soundness signal — removing 3120 definitions could only lose references if they had been real targets; instead 1189 MORE calls resolve, because a method attributed to its class is findable and a fake free function never was (550 `method` nodes + ctors/dtors appear). Unconditional .h→cpp was measured and REJECTED (it costs real decls on real C headers); this is a repo-shape rule, so a pure-C tree pays nothing. Prior: 8040/12144 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +23 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. cpp's share is small because code lives in functions; what is left is file-scope initializers (src/OUNITA.cpp::region@536) + the repo's packaging/*.sh. Prior: 8017 -- +1 @ v48 short-name honesty (same-file sq)
        lang = 'cpp',
        notes = 'cpp quick tier (~325 cpp + 189 h); openmw is DIRTY — never pin it',
    },
    ghost = {
        root = HOME .. '/git/ghost/ghost/core',
        budget_mb = 1600, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://github.com/TryGhost/Ghost',
        rev = 'f7d7df8f9816',
        expected = { refs = 30967, nodes = 40863 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +2647 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. js anon callbacks ALREADY had owners (`#cb` nodes, @adef), so these are true module bodies: bin/*.js CLI scripts and config files whose whole point is load-time work. Prior: 28320 -- recalib 2026-07-26: +14 refs (nodes unchanged) = v106 RECEIVER-PATH AGREEMENT — a candidate whose own qualified name is a segment-suffix of the call's wins when unique. +14 calls, EVERY ONE previously an ambiguous refusal; 0 lost, 0 redirected. e.g. `this.#MemberLinkClickEvent.create()` and `OfferAmount.OfferTrialAmount.create()`. Prior: 28306
        lang = 'javascript',
        notes = 'js SCALE tier (2134 files) — a real node webapp: express'
            .. ' routes + handlebars themes (parametric-files territory)',
    },
    v8 = {
        root = HOME .. '/git/v8/src',
        budget_mb = 7500, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://chromium.googlesource.com/v8/v8',
        rev = '0646faaada71',
        expected = { refs = 110587, nodes = 171079 }, -- recalib 2026-08-19 (v142 A MACRO BETWEEN `class` AND ITS NAME DISSOLVED THE CLASS, CART-0439): -12151 nodes / -7623 refs, and the SIGN IS THE POINT. A class whose name is preceded by an export macro parsed as a `function_definition`: the MACRO became the class name, the real name went into an ERROR node, the base class became the declarator and the class BODY became a function body — so every constructor and inline method came out as a FREE FUNCTION named after its class, and every prototype as another free function. VERIFIED PAIRWISE, not blessed: `ApiRuntimeCallStatsScope@413` (free function) became `ApiRuntimeCallStatsScope::ApiRuntimeCallStatsScope@413` (its constructor) on the SAME LINE; 8341 such reclassifications. The remaining ~12k are prototypes, which inside a REAL class are `field_declaration`s and mint nothing — the same node loss CART-0410 produced on 7kaa, for the same reason. ★ The refs fall with them because a fabricated free function carried real ref edges. ★★ AND BOTH CALIBRATED cpp CORPORA ARE ZERO-DIFF: neither colobot nor 7kaa uses an export macro, so a defect that deletes 483 files' worth of containers on the SCALE corpus is INVISIBLE to both corpora that gate C++ (TSGAP-0007). Prior: 118210 -- recalib 2026-08-19 (v141 A MISPARSED QUALIFIED NAME + CONSTRAINED CTORS, CART-0434/0435): +390 refs, nodes UNCHANGED, and 57272 node IDENTITIES shifted with no change in count — bare names became correctly QUALIFIED ones. VERIFIED against source rather than blessed: `Initialize@212` was really `PropertyCallbackArguments::Initialize`, and the added `FunctionCallbackArguments::Initialize@102` sits under a `requires` clause, i.e. CART-0435's own shape. ★★ THE DRIFT WAS OWED BY THE TWO COMMITS BEFORE THIS ONE AND I DID NOT GATE THEM HERE: both changed C++ node NAMES, I ran zig/cpp/cppmodern struct and NOT v8 because v8 is the heavy tier — and v8 is where the names lived (76 glued ones by my own count). Attributed by stashing: the drift is byte-identical at plain HEAD, so none of it belongs to the param fix landing beside it. A NAME CHANGE MUST BE GATED ON THE CORPUS THAT HAS THE NAMES, and cheapness is what decides which corpus gets skipped. Prior: 117820 -- recalib 2026-08-14 (v134 .h PARSED AS C, CART-0410): +17393 nodes / +42677 refs (+57%), the largest move of the change and the reason this corpus is pinned at all — v8 is 1813 .h against 1267 .cc, i.e. MORE HEADER THAN SOURCE, so the misparse covered most of it. ★ NOTE THE SIGN IS OPPOSITE TO 7kaa, which LOST 3120 nodes on the same fix: 7kaa's headers are class declarations whose method prototypes stopped being minted as definitions, while v8's carry INLINE METHOD DEFINITIONS that the class-as-one-function_definition had swallowed whole. Same bug, opposite node delta, and either sign alone would have been easy to misread as the fix working or failing — the refs rise is the direction that agrees across both. Prior: 75143/165837 -- recalib 2026-08-07 (v119 FIVE LANGUAGES HAD NO ENCLOSING FUNCTION, CART-0306): -22 nodes / -256 edges, Δrefs 0. cpp gained `lambda_expression` to its fn_types — a lambda is a function SCOPE that never reaches the `functions` query (it has no name), so declarations inside lambda bodies were being published as MODULE-level variables of the file. The small `cpp` corpus does not move; v8 is 1267 .cc + 1813 .h of lambda-dense engine code, which is why the SCALE tier is the one that shows it — a control chosen for being small can be too small to falsify anything. Prior: nodes 165859 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +549 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. In v8's headers `region@4` owns file-scope MACRO-LIST expansions (STDLIB_MATH_FUNCTION_LIST, EXPORT_TEMPLATE_DECLARE, RCS_SCOPE) — an X-macro invocation is genuinely code at file scope. Prior: 74594 -- recalib 2026-07-26: +174 refs (nodes unchanged) = v106 RECEIVER-PATH AGREEMENT — a candidate whose own qualified name is a segment-suffix of the call's wins when unique. +187 calls, EVERY ONE previously an ambiguous refusal; 0 lost, 0 redirected. e.g. `base::OS::Abort()` -> OS::Abort, `internal::HandleScope::ZapRange()` -> HandleScope::ZapRange. Prior: 74420
        lang = 'cpp',
        notes = 'cpp SCALE tier (1267 cc + 1813 h) — preprocessor-heavy,'
            .. ' the TU-walk torture target; .tq (torque) not spec\'d',
    },
    scheme = {
        root = HOME .. '/git/guile/module',
        repo = 'https://github.com/cky/guile',
        rev = '89ce9fb31b00',
        expected = { refs = 5744, nodes = 3288 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +2143 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 edges removed. +60%, expected: in scheme essentially EVERYTHING is a top-level form. THE TWO CHANGES IN v107 ARE COUPLED — this recalib also removes 707 spurious call RECORDS, because a `define-module` declaration list (`#:export`/`#:re-export`/`#:use-module`) was being read as calls, and several of those had RESOLVED to the very function the list exports (control.scm:22 `prompt` -> call-with-prompt@64; buffered-input.scm:20 `port` -> make-buffered-input-port@35). Pre-v107 they were harmless — resolved but unowned, so the edge was dropped. WITHOUT the DECL_FORM scoping in spec/scheme.lua, v107 would have promoted all 707 into fabricated "this module calls what it exports" edges. Scoping is to DECL_FORM only: a keyword-VALUED call elsewhere is still a call (guile's `#:on-error (repl-option-ref repl 'on-error)`, which the first blanket rule lost). Prior: 3601 -- +5 @ v48 short-name honesty (scheme's ??/>>/vv culture)
        lang = 'scheme',
        notes = 'scheme quick tier (280 files)',
    },
    ruby = {
        root = HOME .. '/git/rails/activesupport/lib',
        repo = 'https://github.com/rails/rails',
        rev = 'ed0f92c5e779',
        expected = { refs = 1594, nodes = 2791 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +4 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. Only 4 because activesupport/lib is framework SOURCE — class bodies, not statement runs (ForkTracker.hook! at file scope is the shape). Prior: 1590 -- recalibrated @ R5b-ivar (v78)
        lang = 'ruby',
        packs = {}, -- EXPLICIT packless (S2 belt+braces, [[cartograph-repo-shapes]]):
                    -- activesupport/lib is framework SOURCE, not an app — it detects
                    -- packless anyway (no config/application.rb ancestor), but the
                    -- explicit {} guarantees no shape-defaulting ever activates a pack
        notes = 'ruby quick tier (305 files) — BASE ruby, no framework pack (explicit packless)',
    },
    rails = {
        root = HOME .. '/git/discourse/app/models',
        repo = 'https://github.com/discourse/discourse',
        rev = '28b003a38d82',
        expected = { refs = 7499, nodes = 5201 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +20 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. All 20 are `require` at the top of an app/models/*.rb — modest here because a rails model file is a class body, not a statement run (contrast rspec, +2122). Prior: 7479 -- recalib @ UP-direction profile activation (v99): +4837 refs/+285 nodes = the ruby-rails profile now activates via ancestor-probing (config/application.rb 2 levels up in discourse/) → framework surface MINTS (ActiveRecord/ActiveSupport/ActionView), 0 edges removed, 0 project defs stolen (find yields to 5 project defs). Prior 2642 @ R5b-more (v98, pack-only, profile not activated on the subdir root)
        lang = 'ruby',
        packs = { 'rails' }, -- the rails overlay pack (assoc/delegate emitters
                             -- + ActiveRecord vocab); the ruby-rails PROFILE also
                             -- activates via UP-probing (discourse/config/application.rb)
        notes = 'rails overlay pack + UP-activated ruby-rails profile (discourse app/models, 369 files)',
    },
    rspec = {
        root = HOME .. '/git/discourse/spec/models',
        repo = 'https://github.com/discourse/discourse',
        rev = '28b003a38d82',
        expected = { refs = 2273, nodes = 689 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +2122 refs (nodes unchanged), a 15x lift and the largest in the grid. Δrefs == edges added, 0 removed. WHY IT IS THIS BIG, and it is a real gap not an invention: a ruby BLOCK is not a node — `@adef` (anonymous-fn capture) is defined by spec/javascript.lua and by NO other language spec — so in a spec file, where every call lives inside `RSpec.describe do … it "…" do … end end`, NOTHING had an enclosing function and the whole corpus's evidence was being dropped. It now attributes to the file-level region. That owner is lexically true but COARSE (an `it` body is deferred, not load-time), and the coarseness is the same one accepted for `return function() … end`. Minting ruby blocks as `#cb`-style nodes is the follow-up that would sharpen it. Prior: 151 -- recalib @ UP-direction profile activation (v99): +138 refs/+174 nodes = ruby-rails profile UP-activates here too (also under discourse/). Prior 13/515 @ pack-only. DSL verbs still framework-refused; the lift is framework method minting
        lang = 'ruby',
        packs = { 'rails', 'rspec' }, -- MULTI-PACK composition (the de-risker):
                                      -- rails + the rspec/factory_bot test-DSL
                                      -- + UP-activated ruby-rails profile
        notes = 'rspec test-DSL pack + multi-pack composition + UP-activated '
            .. 'ruby-rails profile (discourse spec/models, 196 files) — DSL is '
            .. 'framework-refused; framework methods now mint via the profile',
    },
    go = {
        root = HOME .. '/git/hugo',
        repo = 'https://github.com/gohugoio/hugo',
        rev = '5a5f4a549522',
        expected = { refs = 9754, nodes = 11769 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +96 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. go's share is package-level `var x = f()` initializers (config/allconfig/alldecoders.go::region@13 dominates) + check.sh. Prior: 9658 -- recalib 2026-07-26: +65 refs (nodes unchanged) = v106 RECEIVER-PATH AGREEMENT — a candidate whose own qualified name is a segment-suffix of the call's wins when unique. +69 calls, EVERY ONE previously an ambiguous refusal; 0 lost, 0 redirected. e.g. `h.PathSpec.RelURL()` -> PathSpec.RelURL (go's embedded-field idiom names the type in the receiver path). Prior: 9593
        lang = 'go',
        notes = 'go quick tier (901 files)',
    },
    rust = {
        root = HOME .. '/git/ripgrep',
        repo = 'https://github.com/burntsushi/ripgrep',
        rev = '48b0c795f4fe',
        expected = { refs = 2612, nodes = 3238 }, -- recalib 2026-08-07 (v119 FIVE LANGUAGES HAD NO ENCLOSING FUNCTION, CART-0306): -26 nodes / -25 edges, Δrefs 0. `in_function` read `spec.fn_types or DEFAULT` and the default names function_definition/function_declaration — neither of which exists in rust, so it returned nil for EVERY node and could not reject a declaration made inside a function. What went: function-local `static`/`const` declarations — ripgrep's `static RE` inside parse_excludes_file, `const ARGS_GZIP` inside default_decompression_commands. Rust is the case because its `vars` query is UNROOTED (`(const_item …)` matches anywhere) where go's is rooted at `source_file`. Δrefs 0 is the tell: these nodes were fabricated MODULE variables that nothing correctly referenced, so removing them moved no reference. Only java and rust moved, and the predicate is sharp — a language changes iff its `vars` query is UNROOTED AND its in_function was blind; everyone else roots at source_file/program and never needed the predicate. Prior: nodes 3264 -- recalib 2026-08-06 (v117 A COMMENT IS NOT A STATEMENT IN JAVA/RUST, CART-0304): -96 nodes, Δrefs 0. flow + the extractor skipped only the node name `comment`, which rust does not use (`line_comment`/`block_comment`/`doc_comment`), so every comment was a STATEMENT. Rust moves MORE than java (-96 vs -2) because rustdoc culture puts a `///` block above almost every item, so a module-level region routinely began at a doc comment; the nodes are re-keyed (`region@0` -> `region@<first real line>`) or, where a run was ALL comments, correctly gone. Δrefs 0 is the tell: a comment carries no identifier, so this moved statement PARTITION and nothing else — which is exactly why it survived. Found by tools/langaudit.lua, not by a test; the suite is lua-only and lua calls its comments `comment`. Prior: nodes 3360 -- recalib 2026-08-02 (v111 SCOPE-AWARE chain_lookup, CART-0241): +3 refs (nodes unchanged), EVERY ONE previously `refused (ambiguous)`; 0 lost, 0 redirected. ripgrep vendors the SAME class name in two crates — crates/regex and crates/pcre2 each define `RegexMatcherBuilder::build_many` — so chain_lookup gave up on the corpus-wide duplicate and refused `self.build_many(&[pattern])` in both. The same-file tier now picks the copy in the calling file, which is the only sound answer (read both: crates/regex/src/matcher.rs:46 calls the build_many at :53 of its own file). Prior: 2609 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +9 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. Mostly `rgtest!` macro invocations at module scope in tests/ + two hyperlink/aliases.rs file-scope calls. Prior: 2600 -- recalib 2026-07-26: +7 refs (nodes unchanged) = v106 RECEIVER-PATH AGREEMENT — a candidate whose own qualified name is a segment-suffix of the call's wins when unique. +9 calls, EVERY ONE previously an ambiguous refusal; 0 lost, 0 redirected. e.g. `grep::matcher::LineTerminator::crlf()` -> LineTerminator::crlf. Prior: 2593
        lang = 'rust',
        notes = 'rust quick tier (100 files)',
    },
    zig = {
        root = HOME .. '/git/zig/src',
        budget_mb = 3800, -- ~2x inline peak: the compiler files are enormous
        repo = 'https://github.com/ziglang/zig',
        rev = 'd5181a9c9bac',
        expected = { refs = 24645, nodes = 9768 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +476 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. zig's container scope IS the idiom: `const X = std.ArrayList(T)` / `std.MultiArrayList` / `std.debug.assert` at file scope, all resolving into the zig-std profile. Prior: 24169 -- recalib 2026-07-26: +35 refs (nodes unchanged) = v105, the two name indexes are not alternatives: resolve_module_alias/field_chain could not see a module's own BARE export once any file defined `<x>.m`. +47 calls resolved (module_alias 1054 -> 1096, field_chain +5), 0 lost, 0 redirected. Prior: 24134/9768
        lang = 'zig',
        notes = 'zig + R5 receiver typing + @import module binding + value-recv '
            .. 'dual-key + multi-level chain type + instance-chain field typing '
            .. '(the self-hosted compiler, 171 files) — procedural+struct+method '
            .. 'family; `recv.method()` keyed Type.method from the pointer '
            .. 'receiver\'s type, `const Foo=@import("f.zig")` binds Foo.member() '
            .. 'to f.zig, a value-receiver method gains a Foo.m dual key, a chain '
            .. '`root.Type.method()` resolves via its PascalCase penultimate type, '
            .. 'and an instance chain `root.field.method()` resolves via struct '
            .. 'field types (file-bound), and a local `const x=param.field; '
            .. 'x.method()` resolves via one hop of local type inference (41.8% '
            .. 'resolved). Remaining: deeper local typing (call-return chains) + '
            .. 'generic field types',
    },
    odin = {
        root = HOME .. '/git/odin/core',
        budget_mb = 2000, -- ~2x inline peak
        repo = 'https://github.com/odin-lang/Odin',
        rev = '967c6046a624',
        expected = { refs = 20770, nodes = 36223 }, -- recalib 2026-08-06 (v117 A COMMENT IS NOT A STATEMENT, CART-0304): -898 nodes, Δrefs 0. ODIN IS THE THIRD LANGUAGE THE COMMENT FIX MOVED, and I missed it in the first control sweep by misreading the audit: it reported `comment` as a node type in odin, which is TRUE and INCOMPLETE — odin has BOTH `comment` and `block_comment` (as does scheme), so its `/* */` blocks were still statements after the java/rust fix landed. The lesson is the same shape as the bug: "grammar X has this node" does not mean "grammar X has ONLY this node". Same re-key signature as libs/rust — a module-level `region@0` becomes `region@<first real line>` — and Δrefs 0, because a comment carries no identifier. Prior: nodes 37121 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +1244 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. +6%: like zig, odin puts procedure-valued declarations at package/container scope (bufio/reader.odin::region@337 wiring reader_read/reader_destroy into an io vtable). Prior: 19526 -- recalibrated @ odin node-local tearing (v88)
        lang = 'odin',
        notes = 'odin v1 + R1 package-qualified + node-local tearing (the core '
            .. 'stdlib, 1279 files) — C/procedural family, no methods; a proc in '
            .. '`package P` gains a P.proc key (dual-key, bare kept), `pkg.proc()` '
            .. 'calls resolve via the import alias/name, and torn_by_node keys '
            .. 'clean-subtree defs after a parse error (the Odin grammar errors in '
            .. 'fmt/io big files) → 20.6% (+7214 vs v1; core IS the corpus so std '
            .. 'resolves). Remaining: package-path→dir (last-seg≠pkg for 141 dirs, '
            .. 'mostly non-core) + UFCS + the grammar parse errors themselves',
    },
    python = {
        root = HOME .. '/git/django-oscar/src',
        repo = 'https://github.com/django-oscar/django-oscar',
        rev = 'c0608e0d167e',
        expected = { refs = 1827, nodes = 3883 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +244 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. +15%, the largest share of any non-ruby corpus: django's whole loading idiom is module-level (`get_model`/`get_class`/`is_model_registered` at the top of every models.py/admin.py). Prior: 1583 -- recalib 2026-07-26: v104 js member-target function literals (+12 refs/+11 nodes defs): `X.y = function(){}` now mints, so pre-class exports are definitions. MEASURED per-item vs a HEAD baseline: recovered 10, +3 out of a refusal, 0 redirected, 0 LOST — every added node is a .js file (a mixed repo, not a python change). Prior: refs 1571 / nodes 3872 -- +enclosing-chain captured-callable wins @ v51
        lang = 'python',
        notes = 'python quick tier (483 files) — the django adapter\'s home turf',
    },
    haskell = {
        root = HOME .. '/git/ghc/libraries/base',
        repo = 'https://github.com/ghc/ghc',
        rev = '8585f8cb561e',
        expected = { refs = 1588, nodes = 2805 }, -- recalib 2026-08-22 (v145 CALL POSITION IS A PER-LANGUAGE FACT, CART-0499): +7 refs, nodes unchanged -- and this one is a GAIN, from the half of the defect the ticket did not know about. The old rule marked a callee when `nt == 'list'` (a SEXP HEAD, for scheme) and that comparison was global, so haskell's LIST LITERAL -- the same node-type name, the opposite meaning -- had its first element marked a callee and its reference dropped. `chars = [backspace,tab,space,…]` in tests/unicode001.hs recorded every element EXCEPT backspace; `tyFixed = mkDataType "…" [conMkFixed]` in src/Data/Fixed.hs recorded nothing at all. All 7 new edges are a first-list-element reference. Same hazard CART-0466 names for the descent tables: one node-type name, two grammar shapes, and a global table cannot say which. (haskell's own `apply` was IN the old list but tested against the `function`/`name` fields, and its callee is an unnamed child 0 -- so haskell marked no callees either way.) Prior: 1581, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +10 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. This was the 10-edge case that caught the parallel-vs-inline split (a worker's slice-local resolution is PROVISIONAL — attribution must run only where resolution is final). Prior: 1571 -- +11 @ v48 short-name honesty (ghc test snippets' 1-char fns)
        lang = 'haskell',
        notes = 'haskell quick tier (515 files); ghc = the Track B reference repo',
    },
    jquery = {
        root = HOME .. '/git/jquery/src',
        repo = 'https://github.com/jquery/jquery',
        rev = 'b043db95042b',
        expected = { refs = 1124, nodes = 852 }, -- recalib 2026-07-26: v104 js member-target function literals (+95 refs/+41 nodes defs): `X.y = function(){}` now mints, so pre-class exports are definitions. MEASURED per-item vs a HEAD baseline: recovered 36, +11 out of a refusal, 20 redirected (10 CORRECT — `find.error`/`find.matchesSelector` calls that had been landing on core.js's bare `error` and selector-native's `matchesSelector`; 2 WRONG — `jQuery.error(…)` now hits `find.error`, a tail collision the `tail or exact` bug at treesitter.lua:5381 keeps resolve_module_alias from correcting), 0 LOST. Prior: refs 1029 / nodes 811 -- +anon callback fns @ v51 (df-strangler B; +257 #cb nodes)
        lang = 'javascript',
        notes = 'js quick tier (115 ESM files); selector/event-name strings'
            .. ' = typed-string territory',
    },
    mootools = {
        root = HOME .. '/git/mootools-core/Source',
        repo = 'https://github.com/mootools/mootools-core',
        rev = '187a16bae2d7',
        expected = { refs = 495, nodes = 563 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +52 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. Biggest relative lift of the js corpora (+12%) and it fits the culture: in prototype-extension code the module BODY is the program (Core.js::region@22 calling Function.overloadSetter). Prior: 443 -- recalib 2026-07-26: v104 js member-target function literals (+44 refs/+18 nodes defs): `X.y = function(){}` now mints, so pre-class exports are definitions. MEASURED per-item vs a HEAD baseline: recovered 4, +16 out of a refusal, 35 redirected — all `ua.match(/…/)`, i.e. String.prototype.match, where the old and new targets are both wrong (~-tier noise, not a regression), 0 LOST. Prior: refs 399 / nodes 545 -- +9/+3 @ v63 B4 prototype methods (Function.prototype.overloadSetter/String.prototype.contains)
        lang = 'javascript',
        notes = 'js archaeology tier (29 files, frozen 2017) — prototype-'
            .. 'extension culture, string-keyed dispatch',
    },
    bash = {
        root = HOME .. '/git/testssl.sh',
        repo = 'https://github.com/testssl/testssl.sh',
        rev = 'deda4c762768',
        expected = { refs = 942, nodes = 618 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +120 refs (nodes unchanged) = a RESOLVED top-level call now yields an edge owned by its statement-run REGION instead of being dropped for want of an enclosing function. Δrefs == edges added exactly, 0 edges removed, 0 nodes minted. testssl.sh is one giant script: region@15023 alone owns 120 calls into its own functions. Prior: 822 -- recalibrated @ torn-by-node + literal names
        lang = 'bash',
        notes = 'bash quick tier (~20 files, one giant sophisticated script)',
    },
    blesh = {
        root = HOME .. '/git/ble.sh',
        repo = 'https://github.com/akinomyoga/ble.sh.git',
        rev = '5d39ebe6db67',
        expected = { refs = 6040, nodes = 5081 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +780 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. bash's plugin-loading idiom is entirely load-time: contrib/airline/*.bash bodies call `ble-import`, cmap files call `ble-bind`. Prior: 5260 -- recalib 2026-07-19: +3 nodes = anon-fn #cb + region in a .js helper (make/color.sample.gogh.js: forEach#cb, region) shipped since v48 but never re-gated; refs stable. VERIFIED independent of P0/P1 (count-neutral). Prior: 5078 @ v48 short-name honesty
        lang = 'bash',
        notes = 'bash SCALE tier (~420 files; a line editor written in bash —'
            .. ' eval-heavy, the aperture design\'s first real workout)',
    },

    -- ── stack languages (token provider — no tree-sitter substrate) ──
    postscript = {
        root = HOME .. '/git/postscript-examples',
        repo = 'https://github.com/jwaite/postscript-examples',
        rev = 'b6c8be09c600',
        expected = { refs = 0, nodes = 159 }, -- recalibrated @ ps depth fix (348 counted proc-local false defs)
        provider = 'tokens',
        lang = 'postscript',
        notes = 'postscript quick tier (43 files); inline only (no parallel'
            .. ' pipeline for the token provider)',
    },
    bwipp = {
        root = HOME .. '/git/postscriptbarcode',
        repo = 'https://github.com/bwipp/postscriptbarcode',
        rev = 'b22ce8fe921d',
        provider = 'tokens',
        lang = 'postscript',
        expected = { refs = 11, nodes = 1234 }, -- calibrated @ token-provider v1
        notes = 'postscript REAL tier (130 .ps.src encoders + examples) —'
            .. ' declared --REQUIRES manifests = declared-vs-derived bait;'
            .. ' findresource dispatch; inline only',
    },
    gforth = {
        root = HOME .. '/git/gforth',
        repo = 'https://git.savannah.gnu.org/git/gforth.git',
        rev = '0235f65b468a',
        expected = { refs = 33195, nodes = 21165 }, -- recalibrated @ dup-id fix (aliased edges split honest)
        provider = 'tokens',
        lang = 'forth',
        notes = 'forth mid tier (555 files) — the language\'s own kernel;'
            .. ' [IF] dup defs = candidate sets; inline only',
    },
    openfirmware = {
        root = HOME .. '/git/openfirmware',
        budget_mb = 1200, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://github.com/openbios/openfirmware',
        rev = 'd1681c6293f6',
        expected = { refs = 67997, nodes = 48349 }, -- recalibrated @ dup-id fix; walk +52 only (fload paths ${BP}-templated, banked)
        provider = 'tokens',
        lang = 'forth',
        notes = 'forth SCALE tier (1804 .fth, 1.77M tokens) — the volume'
            .. ' discipline proof; inline only',
    },

    -- ── SYNTHETIC corpora (tools/gen.lua) ───────────────────────────────
    -- Identity = (GEN_VERSION, lang, seed, files) — deterministic, byte-
    -- reproducible, no checkout to pin. The root path EMBEDS g<genversion>-
    -- s<seed>: a generator change bumps GEN_VERSION → new paths here + a
    -- recalibration, the same discipline as expected counts. bench.corpus
    -- MATERIALIZES a missing root by running the generator — so these
    -- gates run on any machine, no ~/git checkouts required.
    synlua = {
        root = HOME .. '/.cache/cartograph-tools/syn/lua-g6-s1',
        synthetic = { lang = 'lua', seed = 1, files = 8 },
        lang = 'lua',
        expected = { refs = 117, nodes = 203 }, -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +15 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. The generator already plants module-level require/registry calls, so this is the synthetic answer-key exercising the new owner (m1.lua::region@147 -> usec1). Prior: 102 -- recalibrated @ gen v5 (+registry idiom + RNG shift)
        notes = 'synthetic lua (gen.lua g2 seed 1): the resolution-ladder'
            .. ' bestiary — fwd-decls, fn-values, higher-order, shadows,'
            .. ' smt classes, requires, goto',
    },
    synjava = {
        root = HOME .. '/.cache/cartograph-tools/syn/java-g6-s1',
        synthetic = { lang = 'java', seed = 1, files = 8 },
        lang = 'java',
        expected = { refs = 55, nodes = 99 }, -- recalib @ gen v6 (CART-0377): +12 nodes / +8 refs = Ctrl.java, the CONTROL BESTIARY. synjava covered 2 of java's 13 control forms (only if/for), so the java gate could never have failed on java switches opening NOTHING — now 13/13. The eight numbered modules are byte-identical to v5, verified by diff. Prior: refs 47, nodes 87 -- calibrated @ gen v3, byte-identical @ v4
        notes = 'synthetic java (gen.lua g2 seed 1): @Service impls = the'
            .. ' ONLY locally-testable F1 bean redirects; unique Builder<k>'
            .. ' chains = the positive rt-rounds path; enums, overloads,'
            .. ' method refs, cross-file',
    },

    synjs = {
        root = HOME .. '/.cache/cartograph-tools/syn/js-g6-s1',
        synthetic = { lang = 'js', seed = 1, files = 8 },
        lang = 'javascript',
        expected = { refs = 167, nodes = 291 }, -- recalib @ gen v6 (CART-0377): +8 nodes / +5 refs = ctrl.js, the CONTROL BESTIARY. synjs covered 3 of js's 10 control forms and held NO `for_in_statement` — the exact form whose loop-variable def/use bug shipped (CART-0363) — so the js gate could not have caught it. Now 10/10, for-of AND for-in. The eight numbered modules + min.js are byte-identical to v5, verified by diff. Prior: refs 162, nodes 283 -- recalib 2026-07-31 (v107 MODULE-LEVEL OWNER): +8 refs (nodes unchanged) = top-level calls now owned by their statement-run REGION. Δrefs == edges added, 0 removed. ESM module bodies calling across files (m6.js::region@1 -> m1.js::fa1). Prior: 154 -- +6 @ v64 V2 ctor-typing (obj=new C → obj.calc→C.calc); +6 @ v62 B3 this.getv
        notes = 'synthetic js (gen.lua g6 seed 1): hoisted fwd calls,'
            .. ' fn-value consts, let/var regimes, arrows, classes, ESM +'
            .. ' one CommonJS module, and min.js — a one-line minified'
            .. ' module (the (l,c) column-spill exercise), + ctrl.js: every'
            .. ' control form the grammar has, nested, with keyed call sites inside',
    },

    self = {
        root = HOME .. '/git/cartograph.nvim',
        repo = 'git@github.com:t0suj4/cartograph.nvim.git',
        lang = 'lua',
        notes = 'cartograph on cartograph — LIVING corpus, NOT GATED: the corpus'
            .. ' is this repo, so every commit invalidates a snapshot baseline by'
            .. ' construction (red by drift, greenable only by blessing unread'
            .. ' change). Self-analysis is gated by tools/dogfood.lua ratchets'
            .. ' instead. Name it explicitly for measurement — it is a good'
            .. ' polyglot-free lua corpus, it just cannot hold a fixed baseline',
    },
    bnw = {
        root = HOME .. '/git/bravest-new-world',
        repo = 'https://github.com/t0suj4/bravest-new-world',
        lang = 'lua',
        notes = 'READ-ONLY dogfood target with UNCOMMITTED WIP (never checkout,'
            .. ' never pin); dynamic-lua gate for scope-model step 3',
    },
    wow = {
        root = HOME .. '/work/wow_addons',
        lang = 'lua', -- not a git repo: path-only identity, snapshot meta is the stamp
        budget_mb = 8200, -- ~2x MEASURED inline extract peak (4077 MB, 130s wall)
        -- THE LARGEST CORPUS IN THIS REGISTRY BY SOURCE BYTES (81 MB, ahead of v8's 65)
        -- and it carried NO budget until measured, which cost twice over: matrix's
        -- admission control weights an UNDECLARED corpus at a flat 500 MB (`weight()`),
        -- so this one was scheduled as ~1/8th of its own extract, and its `mem` column
        -- read `--` instead of gating. It stayed latent rather than live only because the
        -- default roster is `if v.expected then` and this corpus pins no counts.
        -- CAUTION — WHY A BUDGET ALONE IS NOT ENOUGH: this, like every budget in this
        -- file, is an EXTRACT peak. A tool that extracts and then SWEEPS every function
        -- pays a further multi-GB transient that nothing here describes — on desynced the
        -- graph is 290 MB while sweeping it costs 2.5-4.5 GB. So a sweep can sit inside
        -- its declared budget throughout extraction and still OOM, with `mem` reporting
        -- OK. See tools/bench.lua's sweep_gc for the measurement and the mitigation.
        notes = '353 addons / 2.27M lines — SCALE corpus; .toc load-order'
            .. ' adapter banked, whole-tree extract is a stress test not a gate',
    },
    desynced = {
        root = HOME .. '/work/desynced',
        lang = 'lua', -- not a git repo
        notes = 'game-script corpus; adapter gap banked',
    },
    nio = {
        -- THE ANNOTATED-LUA CORPUS (CART-0240 step zero). Every lua corpus we gate
        -- on is effectively UNANNOTATED — wow_addons carries 3 annotation lines in
        -- 2.27M, factorio-mods none — so anything reading annotations would ship
        -- untested by construction. This one is 1851 type tags in 6982 lines (the
        -- densest on the machine), DECLARES 432 @class + 67 @alias, and 88 of its
        -- 148 def-attached @return tags name a class it declares itself: the shape
        -- an answer-key or receiver-typing measurement needs.
        -- A lazy.nvim plugin checkout, so it is a real git repo and PINNABLE — the
        -- reason to prefer ONE plugin over the whole 25k-annotation lazy/ tree,
        -- which is 34 independent package roots and could never hold a baseline.
        root = HOME .. '/.local/share/nvim/lazy/nvim-nio',
        repo = 'https://github.com/nvim-neotest/nvim-nio',
        rev = '21f5324bfac1',
        lang = 'lua',
        expected = { refs = 273, nodes = 376 }, -- calibrated 2026-08-03 @ 21f5324
        notes = 'annotated-lua tier (24 files): the annotation reader/lint gate'
            .. ' (CART-0240); tools/annotcensus.lua is its census',
    },
    factorio = {
        root = HOME .. '/work/factorio-mods',
        lang = 'lua', -- symlink-assembled multi-mod root (SE + postprocess
        -- + scripts + bravest-new-world) — the CROSS-PROJECT corpus:
        -- __modname__ requires resolve by info.json identity across mods
        notes = 'factorio multi-mod: cross-mod imports (scripts->SE x9),'
            .. ' mod dirs = scope boundaries, per-phase entry cones',
    },
    se = {
        root = HOME .. '/work/space-exploration_0.7.57',
        lang = 'lua', -- version-pinned mod dir, not a git repo
        notes = 'Space Exploration 0.7.57 — the FACTORIO reference corpus:'
            .. ' 5 phase entries (control/data/updates/final-fixes/settings),'
            .. ' phase cones separate via imports (2 shared files), unreached'
            .. ' = conditional compat requires + menu-simulations engine'
            .. ' entries; the factorio sharing-model cut lands here',
    },
}
