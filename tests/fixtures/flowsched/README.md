# flowsched — an answer that moved when an unrelated file was added (CART-1621)

Driven by `tests/flowtype_spec.lua` through `ts.extract` and `flowtype.solve`.

`ark/schema/shared/{errors,traversal}.ts` are a delta-debugged reduction of arktype
(github.com/arktypeio/arktype at bc1419f, 2026-10-08): first by file (393 files to these 2),
then by line (774 lines to 151), keeping one property — under the old LIFO worklist, adding a
comment-only file beside them changes a flow answer here. Adding a file shifts every port and
object number, and LIFO's order followed those numbers through `pairs` over integer-keyed sets.
Lines are deleted, not rewritten, so the files do not compile; tree-sitter parses them anyway.

The test checks both sides: the default schedule (a heap over a stable order) moves nothing, and
`order = 'lifo'` still moves something — so the fixture is live.

arktype is MIT licensed:

    Copyright 2025 ArkType

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software
    and associated documentation files (the "Software"), to deal in the Software without
    restriction, including without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or
    substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
    BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
    DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
