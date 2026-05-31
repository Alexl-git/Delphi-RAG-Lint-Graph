# Cross-DB symbol resolution — how the graphing tool follows references across stores

This document covers what happens when `X: IList<string>` is in your
project DB but `IList` is in the library DB, and what JSON contract the
graphing tool needs to handle that correctly.

Accurate to drag-lint v0.40.5-alpha.

---

## 1. The model

Each `--db` opens a separate sqlite store with its own
`files / symbols / refs / unit_uses / sql_*` tables. drag-lint does NOT
store cross-DB foreign keys — every `file_id` / `symbol_id` is local to
its store. Resolution across stores is **dynamic, by name**, and happens
at query time inside the LSP server.

That means there is no "link table" you can join across stores. Instead:

- LSP requests iterate `FStores` and merge results
- For each result, the **store index** is the implicit context
- The file URI returned to the IDE is real (resolved against that
  store's `files.path`)

So at the LSP layer cross-DB works transparently. The complication is for
**the graphing tool's exported JSON / CSV** — the consumer can't tell
which store a node came from unless we say so explicitly.

---

## 2. JSON contract — required fields for graph nodes & edges

Both `nodes[]` and `edges[]` carry an explicit `db_index` integer
(0-based, matching the order of `--db` flags). The graphing tool's
click handler maps `db_index` → the file path inside that store.

### Node shape (v0.40.5)

```json
{
  "id":        "Spring.Collections.IList",
  "label":     "IList",
  "kind":      "interface",
  "file":      "C:/.../Spring.Collections.pas",
  "line":      14,
  "col":       3,
  "layer":     "library",
  "db_index":  1
}
```

`db_index` is **mandatory** in v0.40.5 graphs. Tools that consumed the
v0.40.4 JSON without it should treat absent = 0 for backwards compat,
but emitters must always set it.

### Edge shape

```json
{
  "src":      "Foo.TBar.X",
  "dst":      "Spring.Collections.IList",
  "kind":     "type_use",
  "src_db":   0,
  "dst_db":   1,
  "cross_db": true
}
```

`cross_db: true` is the click-handler signal — different `src_db` vs
`dst_db`. The viewer can render cross-DB edges with a distinctive
style (dashed + colored, or with a small DB-icon at the boundary).
Same-DB edges may omit `cross_db` or set it to `false`.

---

## 3. How the graphing tool resolves a click

When the user clicks the `IList` node above:

1. Read `node.db_index` (= 1).
2. Read the corresponding `--db` flag the tool started with (the library DB).
3. Open the file at `node.file:node.line` using the host's open-file
   mechanism:
   - In the IDE plugin: `IOTAActionServices.OpenFile(file)` +
     `IOTAEditPosition.Move(line)`.
   - Standalone EXE: `ShellExecute('open', file)` (Windows default
     editor for `.pas`).

The `file` field is always a fully-qualified, real path — drag-lint
resolves it at export time using `files.path` from the originating
store. There is no "DB-relative" path.

---

## 4. CSV contract (for the uses-report exporter)

The v0.40.4 `uses-report` CSV does not yet expose `db_index` — sources
default to the first DB unless `--all-sources` is passed, and external
units (no `target_file_id`) are flagged via the `external` column.

For v0.40.5, the column shape extends to:

```
source_unit,used_unit,depth,first_section,via_chain,external,src_db,dst_db
```

Where `src_db` and `dst_db` map to `--db` flag positions. Tools that read
the older 6-column shape should detect column count and fall back.

---

## 5. Known limitations carried over

1. **Name collisions across DBs** — if two `IList` interfaces exist in
   different stores (yours + Spring4D), the first store in `--db` flag
   order wins. The IDE plugin's default order is `[project, sibling
   sub-projects, library]`, which keeps project-local definitions
   authoritative. The graphing tool should mirror that order when
   exporting; an interactive viewer may surface "candidates from other
   DBs" as a disambiguation popup.
2. **Generic type parameters not tracked** — `IList<string>` and
   `IList<TFoo>` resolve to the same `IList` symbol. The `<string>`
   part is dropped at index time. For graph rendering this means
   instantiations collapse to the type definition; that's usually what
   you want.
3. **No cross-DB FK** — schema-wise, you can't write a SQL join that
   spans stores. The graphing tool's exporter assembles the merged
   view in memory.

---

## 6. Implications for the IDE plugin

The plugin's `DragLint.Plugin.DbResolver.ResolveActiveIndexDbs`
returns `TArray<string>` of all `--db` paths in priority order. The
graphing tool's exporter can use the same resolver to keep the
DB-flag order identical to what the LSP sees — guaranteeing that
"first-hit wins" matches between hover and graph click.

When emitting JSON / CSV from drag-lint, the source order of
`Args.DbPaths` becomes the `db_index` enumeration.

---

## 7. In-repo file references (drag-lint)

- `src/lsp/DRagLint.LSP.Server.pas` — `FStores` iteration in
  `HandleHover` / `HandleDefinition` / `HandleReferences` (v0.40.3)
- `src/cli/DRagLint.CLI.pas` — `DoUsesReport`'s `Stores: TArray<ISymbolStore>`
  loop with global file index (v0.40.4); v0.40.5 will emit `src_db` /
  `dst_db` columns in the CSV
- `src/delphi-plugin/DragLint.Plugin.DbResolver.pas` —
  `ResolveActiveIndexDbs` (v0.40.3)
