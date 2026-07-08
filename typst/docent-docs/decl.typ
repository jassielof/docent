// Per-DeclNode rendering, split into two tiers so the document stays
// bounded regardless of how deeply the real Zig code nests:
//
// - Namespace sections: only structs and module roots can hold further
//   sub-decls (see json_emit.zig's `is_namespace_kind`), so this is the
//   only kind that ever recurses. Always headed by its full absolute path
//   (e.g. `docent.scan.reach`), since a namespace can appear at any true
//   nesting depth and still needs to be unambiguous on its own -- and
//   always at the *same fixed level* (2), regardless of true depth. This is
//   what keeps heading depth bounded no matter how deep the source nests.
// - Member entries: everything else (fn/const/var/error_set/type_alias, and
//   enums/unions/opaques treated as leaves). Headed by just its short name
//   -- the enclosing namespace's heading, immediately above it in document
//   order, already supplies the path prefix, so repeating the full id on
//   every member (as earlier versions of this template did) was pure
//   redundancy that got worse the more members a namespace had. Unlike
//   namespaces, a member's level is its *parent's* level + 1: a module's own
//   direct functions/constants sit at level 2 (alongside that module's own
//   namespace sections, since both are equally "module contents"), while a
//   namespace's own members sit at level 3. This avoids ever emitting a
//   level-3 heading with no level-2 heading before it in the same section,
//   which otherwise makes Typst's automatic numbering show a stray "1.0.1".
//
// A namespace nested inside another namespace is *not* rendered one level
// deeper -- it gets its own level-2 section, flat, right where it falls in
// traversal order.
//
// Each argument is a dictionary matching the shape produced by
// src/lib/typeset/schema.zig's DeclNode, as parsed from docs.json.

#let is-namespace(decl) = decl.decls != none

#let render-params-table(params) = table(
  columns: (auto, auto, 1fr),
  table.header([*Name*], [*Type*], [*Doc*]),
  ..params
    .map(p => (
      raw(p.name, lang: "zig"),
      raw(p.type, lang: "zig"),
      if p.doc != none { eval(p.doc, mode: "markup") } else { [] },
    ))
    .flatten()
)

#let render-fields-table(fields) = table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Name*], [*Type*], [*Value*], [*Doc*]),
  ..fields
    .map(f => (
      raw(f.name, lang: "zig"),
      if f.type != none { raw(f.type, lang: "zig") } else { [] },
      if f.value != none { raw(f.value, lang: "zig") } else { [] },
      if f.doc != none { eval(f.doc, mode: "markup") } else { [] },
    ))
    .flatten()
)

#let kind-label(decl) = text(size: 0.7em, style: "italic")[(#decl.kind#if decl.container_kind != none [ #decl.container_kind])]

// Shared body: signature, params/fields tables, doc comment. Identical for
// namespaces and members -- only the heading (level + text) differs.
#let render-body(decl) = [
  #if decl.signature != none [
    #raw(decl.signature, lang: "zig", block: true)
  ]

  #if decl.params != none and decl.params.len() > 0 [
    #render-params-table(decl.params)
  ]

  #if decl.fields != none and decl.fields.len() > 0 [
    #render-fields-table(decl.fields)
  ]

  #if decl.doc != none [
    #eval(decl.doc, mode: "markup")
  ]
]

/// A leaf entry at `level` (parent's level + 1 -- see the module doc
/// comment), headed by just its short name.
///
/// The heading carries `#label(decl.id)`, directly adjacent with no
/// whitespace so Typst attaches it to the heading itself -- this is the
/// target `markdown_typst.zig`'s cross-reference resolution links to via
/// `#link(label("..."))` baked into `doc` markup. Only public decls (or, with
/// `--include-private`, all included decls) ever reach this function via
/// `emitChildren`, so every link target this template could receive is
/// guaranteed to resolve.
#let render-member(decl, level: 3) = [
  #heading(level: level)[
    #raw(decl.name, lang: "zig")
    #kind-label(decl)
  ]#label(decl.id)

  #render-body(decl)
]

/// A namespace section: heading with the full absolute path, recursing into
/// `decls` -- promoting nested namespaces to their own (still level-2,
/// regardless of `level`) sections rather than nesting deeper, and demoting
/// non-namespace children to `level + 1` members.
///
/// `level` defaults to 2 (an ordinary namespace section); `lib.typ` passes
/// `level: 1` for each top-level module itself, reusing this same function
/// so the module heading and its own doc/fields render identically to any
/// other namespace.
#let render-namespace(decl, level: 2) = [
  #heading(level: level)[
    #raw(decl.id, lang: "zig")
    #kind-label(decl)
  ]#label(decl.id)

  #render-body(decl)

  #if decl.decls != none [
    #for child in decl.decls [
      #if is-namespace(child) [ #render-namespace(child) ] else [ #render-member(child, level: level + 1) ]
    ]
  ]
]
