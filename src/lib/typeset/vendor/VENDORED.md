# Vendored from ziglang/zig

Source: `lib/docs/wasm/` in the [ziglang/zig](https://github.com/ziglang/zig) repository.

- Pinned version: **0.16.0** (matches this project's `minimum_zig_version` in
  `build.zig.zon`). Reference snapshot: `references/zig-0.16.0_lib-docs.zip`
  (gitignored, kept locally for diffing against future Zig version bumps).
- License: MIT, per the upstream `LICENSE` file in ziglang/zig. No copyright
  headers were present in the original files; none added here.

## Files

| File | Status |
|---|---|
| `Walk.zig` | Patched (see below) |
| `Decl.zig` | Patched (see below) |
| `markdown.zig` | Unmodified |
| `markdown/Document.zig` | Unmodified |
| `markdown/Parser.zig` | Unmodified |
| `markdown/renderer.zig` | Unmodified |

`html_render.zig` and `main.zig` (the WASM entry point) were intentionally
**not** vendored — they are replaced by `../json_emit.zig`,
`../markdown_typst.zig`, and `../walker.zig` respectively.

## Patches applied

Both `Walk.zig` and `Decl.zig` hardcoded `const gpa = std.heap.wasm_allocator;`.
`wasm_allocator` relies on wasm-specific memory-grow builtins and does not
compile for a native target at all — this is not a matter of behavior, the
build fails outright. Patched to `std.heap.page_allocator` in both files. No
other WASM-host coupling (JS `extern` calls, packed structs for JS marshaling,
etc.) was found in either file — everything else is plain `Ast`/`ArrayList`
manipulation and carries over unmodified.

## Known upstream bug (not patched, worked around instead)

`markdown.zig` re-exports `pub const renderNodeInlineText = @import("markdown/renderer.zig").renderNodeInlineText;`,
but `markdown/renderer.zig` only defines `renderInlineNodeText` (the two
words are transposed). This alias is a dead declaration upstream -- Zig's
lazy analysis never evaluates it unless something references
`markdown.renderNodeInlineText` by that name, which nothing in the vendored
tree does. `../json_emit.zig` needs exactly this function (for `doc_summary`
plain-text rendering) and works around it by importing
`vendor/markdown/renderer.zig` directly and calling `renderInlineNodeText`,
rather than going through the broken `markdown.zig` alias. Not patched here
to keep the vendored diff minimal; worth reporting upstream.

## Re-vendoring checklist

When bumping the pinned Zig version:

1. Diff the new `lib/docs/wasm/{Walk,Decl,markdown*}.zig` against the files
   here (minus the allocator patch) to catch upstream API drift.
2. Re-apply the `wasm_allocator` -> `page_allocator` patch to `Walk.zig` and
   `Decl.zig`.
3. Update the pinned version noted above and re-check `schema.zig` /
   `json_emit.zig` against any changed `Decl`/`Walk.Category` shapes.
