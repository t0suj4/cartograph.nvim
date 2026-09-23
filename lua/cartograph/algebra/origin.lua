-- cartograph.algebra.origin — WHERE THE VENDORED ALGEBRA CAME FROM (CART-0912).
--
-- ★★★ THE VENDORED COPY IS NOT A SECOND AUTHORITY, BECAUSE IT IS STAMPED.
-- The standing objection to vendoring is CART-0746's — A COPIED WALKER IS A
-- COPIED BUG — and `tools/algebradrive.lua` states it as a rule: "a copied
-- algebra would be a second authority that drifts". That objection is about
-- SILENT drift. A copy that records its origin, and a fence that reads the
-- record, cannot drift silently: `tools/vendordrift.lua` reports three states
-- and two of them are findings.
--
-- ★★ THE THREE STATES, AND WHY DIVERGENCE IS NOT AN ERROR. The end goal is that
-- this code is CARTOGRAPH'S OWN (user, 2026-09-13), so a deliberate local edit
-- is the plan, not a fault. What must never happen is not knowing which of the
-- two moved:
--
--     IDENTICAL       the copy still equals the recorded origin content
--     DIVERGED        WE edited the copy — expected once adaptation starts
--     ORIGIN MOVED    the DONOR changed under a stamp that says otherwise
--
-- ⚠ THE DONOR'S ABSENCE IS NOT A FAILURE. This machine has the prototype; a
-- clone of cartograph need not. A missing donor makes the drift check
-- UNAVAILABLE, which is its own answer — never "identical" and never a failure,
-- the same absence/unavailable split the transport layer already draws.
--
-- ★ AND THIS IS THE PROVENANCE SLOT THE ABSORB VERB NEEDS ANYWAY. Any future
-- donor gets a record of this shape; the licence design requires that origin
-- ride WITH the code and survive substitution, and a field that is not written
-- at vendor time cannot be recovered by re-deriving it later.

return {
    -- ★★★ AUTHORITY (user, 2026-09-23): "We can take ownership of algebra and declare our
    -- vendored copy authoritative until we absorb it into cartograph." THE COPY IS THE
    -- SOURCE OF TRUTH from this date: we edit it (DIVERGED is the normal state, not a
    -- finding), and a change in the donor is a PROPOSAL to review and port by hand, never a
    -- correction that overrides ours. `tools/vendordrift.lua` reads this field. The donor
    -- stays read-only to us (it is user-authored); the stamp below still records where the
    -- copy came from, which is provenance, not authority.
    authority       = 'vendored',
    authority_since = '2026-09-23',

    -- the donor, as it was when this copy was taken
    donor_repo   = '~/tools/templates',
    donor_file   = 'algebra.lua',
    donor_rev    = 'ef782cf222937d2cab1438bdb70d052cef04ac9c',  -- tag handoff-2026-09-19
    donor_clean  = true,     -- the donor working tree had no uncommitted changes
    vendored_at  = '2026-09-19',
    vendored_by  = 'CART-0912',

    -- ★★★ THE RE-VENDOR (2026-09-19), 47 donor commits after the first cut. The
    -- donor's own HANDOFF.md (tag handoff-2026-09-19) is written to this session
    -- and states the one breaking change: a `site` from `lua_scope_graph` is a
    -- true tree path now. Nothing in this tree stored one, so it did not bite.
    -- ⚠ THE SPLIT WAS REPLAYED, NOT RE-CUT BY HAND. Each part's old body was
    -- located in the PREVIOUS donor as line ranges, the ranges mapped onto this
    -- one by diff, then three repairs the first cut made by hand and the replay
    -- makes by rule:
    --   1. a region boundary is snapped so every definition a part owned before
    --      it still owns (10 one-line constructors sat in the mapped gaps);
    --   2. a module-level local that lands inside a part but is read by another
    --      part or by core is PULLED BACK to core (7: `cat`, `derived`,
    --      `absence`, `below`, `occurs`, `occurrences`, `prefix_of`) — this is
    --      CART-0924/0925's hazard as a rule instead of a list;
    --   3. a SHARED name is supplied iff luacheck agrees the part reads it.
    -- ⚠ AND TWO SECTIONS CAME HOME. `poslens` and `domains` are back in core,
    -- because the donor now builds templates AT LOAD TIME (`M.RENDER_CALL`,
    -- `M.SQL_UPDATE`) and `M.template` calls `M.sites` and `M.open`. A part is
    -- required at the BOTTOM of core, so a section core itself runs eagerly
    -- cannot be one — the basis is not a section. The acceptance oracle is
    -- unchanged and is the donor's own spec.

    -- sha256 of the bytes as vendored. `vendordrift` compares BOTH sides
    -- against this, which is what separates "we edited it" from "it moved".
    -- ⚠ PROVENANCE, NOT A CHECK OF THE CURRENT FILE: under the vendored authority the
    -- copy is expected to differ from this forever.
    sha256       = 'cb47dd9289987304e80489e147e374024a25007a9df17867c1107166418fc3a5',
    lines        = 9628,

    -- ⚠ ONE LINE OF THE DONOR DOES NOT PORT, AND IT IS DELIBERATELY LEFT IN.
    -- `core.lua:3912` reads
    --     if os.getenv('DERIVE') then require('derive').apply_to(M, ...) end
    -- `derive.lua` is a PROTOTYPE-DEVELOPMENT affordance (re-derive the
    -- operators from the four-arrow basis to check the basis still spans them).
    -- It is env-gated and dead with DERIVE unset, and vendoring it would put a
    -- bare top-level module name `derive` on our package.path. Left verbatim so
    -- the copy stays byte-comparable; if we ever want that check it belongs in
    -- `tools/`, not here.
    --
    -- ★★ TWO MORE UNPORTED KINDS ARRIVED WITH THE RE-VENDOR, AND BOTH COST
    -- EVIDENCE RATHER THAN BEHAVIOUR:
    --   `experiments/` — the donor's measurement fixtures (lua-terms, lua-defs,
    --   key_oracle, key_gen, kv_terms, sqlite_reader, the Kubernetes manifests).
    --   They are the donor's corpus, not the algebra, and they did not come.
    --   43 donor tests name them and PEND; the donor wrote that contract itself
    --   ("a re-vendored spec without experiments/ pends by name") and
    --   tests/algebradonor_spec.lua honours it. ⇒ THE CODE IS OURS BUT PART OF
    --   ITS EVIDENCE IS NOT RE-CHECKABLE HERE — the lossless lua reader, the
    --   scope-graph census and the keyed oracle are the operators affected.
    --   `M.parsers.lua` — ✅ PORTED 2026-09-19 (CART-0961), and deliberately NOT
    --   as a vendored file: `cartograph.algebraread` is ours, the seam installs
    --   it as the last step of `algebra.load()`, and the donor's acceptance test
    --   is ours too (cst_print(read(src)) == src over all 231 files in lua/).
    --   ⇒ IT DID NOT CLOSE THE EVIDENCE GAP: the 43 pending tests want the
    --   FIXTURE FILES, not a parser, and still pend.
    unported     = {
        'core.lua:3912 — optional `require("derive")`, env-gated on DERIVE',
        'experiments/* — the donor fixtures 43 vendored tests pend on',
        -- 'M.parsers.lua' — PORTED, see CART-0961; kept in the comment above so
        -- the record says what was once missing and what closed it
    },

    -- ★★★ THE DONOR'S OWN TESTS CAME TOO (CART-0912). 372 of them over 8270
    -- lines (243 over 5240 at the first cut), vendored BYTE-IDENTICAL to
    -- `tests/vendor/algebra_spec.lua` and run through a harness shim. ⇒ THIS IS WHAT MAKES THE PROOF OURS RATHER THAN
    -- BORROWED: the code was already ours, and a capability whose evidence lives
    -- in someone else's repository is a capability we cannot re-check after we
    -- change it — and we have changed it, six sections' worth.
    -- ⚠ AND IT IS THE ACCEPTANCE ORACLE FOR THE SPLIT: the donor's tests know
    -- nothing about parts, so they pass only if the adaptation preserved
    -- behaviour exactly.
    spec_file    = 'spec/algebra_spec.lua',
    spec_sha256  = 'e9806eb1c77147bb23de257b9488aec8b1d5b597ba9f8e6ecc485d4d1d780725',
    spec_lines   = 8270,
}
