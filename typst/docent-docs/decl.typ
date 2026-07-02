// Per-DeclNode rendering, split out of lib.typ so nesting/signature changes
// stay contained here without touching the top-level render-docs entry
// point.
//
// Each argument is a dictionary matching the shape produced by
// src/lib/typeset/schema.zig's DeclNode, as parsed from docs.json.

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

/// Renders a decl (heading, signature, params/fields tables, doc comment)
/// and recurses into `decls` for containers, incrementing the heading level
/// each time -- this is the only nesting-aware piece of the template; the
/// docs.json shape it walks was already fully populated in v0.1.
///
/// The heading carries `#label(decl.id)`, directly adjacent with no
/// whitespace so Typst attaches it to the heading itself. This is the
/// target `json_emit.zig`'s cross-reference resolution (v0.3) links to via
/// `#link(label("..."))` baked into `doc` markup -- see markdown_typst.zig.
/// Only public decls get a label, since only public decls are ever emitted
/// into a `decls` array in the first place (see json_emit.zig's
/// `emitChildren`), so every link target this template could receive is
/// guaranteed to resolve.
#let render-decl(decl, depth: 2) = [
  #heading(level: depth)[
    #raw(decl.name, lang: "zig")
    #text(size: 0.7em, style: "italic")[(#decl.kind#if decl.container_kind != none [ #decl.container_kind])]
  ]#label(decl.id)

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

  #if decl.decls != none [
    #for child in decl.decls [
      #render-decl(child, depth: depth + 1)
    ]
  ]
]
