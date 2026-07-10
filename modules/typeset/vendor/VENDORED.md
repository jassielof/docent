# Vendored from ziglang/zig

Source: `lib/docs/wasm/` in the [ziglang/zig](https://github.com/ziglang/zig) repository.

- Pinned version: **0.16.0** (matches this project's `minimum_zig_version` in
  `build.zig.zon`).
- License: MIT, per the upstream `LICENSE` file in ziglang/zig.

## Files in this directory

| File | Status |
|---|---|
| `Walk.zig` | Patched (see below) |
| `Decl.zig` | Patched (see below) |

Markdown parsing (`markdown.zig` / `Document` / `Parser` / `renderer`) was
moved to the `doc_comment` module under `modules/doc_comment/markup/`.

`html_render.zig` and `main.zig` (the WASM entry point) were intentionally
**not** vendored — they are replaced by `../serialize.zig`, `../typst.zig`,
and `../walker.zig` respectively.

## Patches applied

Both `Walk.zig` and `Decl.zig` hardcoded `const gpa = std.heap.wasm_allocator;`.
Patched to `std.heap.page_allocator` in both files.
