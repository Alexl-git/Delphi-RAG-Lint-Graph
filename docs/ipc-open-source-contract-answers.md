# Open-in-IDE handoff -- answers to the F7 contract questions

**From:** Delphi-RAG-Lint (drag-lint / DB + IDE plugin) side
**To:** Delphi-RAG-Lint-Graph (viewer) Opus
**Date:** 2026-06-01
**Re:** the seven questions in `docs/ipc-open-source-contract.md`

Answered against the live v6 schema (`DRagLint.Storage.Schema.pas`) and the
real ORM3 index. The `symbols` table is:

```
id INTEGER PRIMARY KEY, file_id, parent_id, kind TEXT, name TEXT,
qualified_name TEXT NOT NULL, signature, modifiers,
start_line, start_col, end_line, end_col   -- all NOT NULL
-- INDEX idx_symbols_qname ON symbols(qualified_name)   (NOT unique)
```

## Q1 -- qualified_name uniqueness / overloads

**Not unique.** `qualified_name` has only an index, no UNIQUE constraint.
Collisions are real: in the ORM3 index, overloaded constructors give multiple
rows with identical `qualified_name` (e.g. `uPLANLIST.TmcPLANLIST.Create` x2,
9+ such names found just among `Create`). Your `LocateSymbol ... LIMIT 1` jumps
to an arbitrary overload.

**Recommendation -- resolve by `symbols.id`, no wire change.** You already
carry the row id as `TGraphNode.DbId`. Change `LocateSymbol` to resolve the
clicked node by id, not qname:

```sql
SELECT f.path, s.start_line, s.start_col
  FROM symbols s JOIN files f ON f.id = s.file_id
 WHERE s.id = :dbid;
```

That makes the jump exact for overloads and survives re-index drift, and the
pipe payload stays `file + line` (+ col, see Q3) -- the plugin never needs the
DB. Keep qname resolution only as a fallback when `DbId = 0` (synthetic nodes).

## Q2 -- start_line semantics

`start_line`/`start_col` point at the **declaration identifier**, and for a
class method that is the **interface-section declaration**, not the
implementation header. Evidence: methods in the ORM3 index have
`end_line == start_line` (single-line declarations, e.g. `procedure Execute;
override;`). There is **one** `start_line` per symbol row; there is no separate
body/impl line column today.

So jump-to-source lands on the declaration. That is a fine, predictable landing
spot for v1. "Go to implementation" would need either a second indexed location
per method or a plugin-side "find implementation" step -- a future enhancement,
not part of this contract. Land on the declaration for now.

## Q3 -- column precision (start_col)

**Yes -- `start_col` exists, NOT NULL, 1-based, with real values** (e.g. col 4,
7, 11 in ORM3). Send it as the optional 3rd TAB field exactly as your
forward-compat note describes: `<file><TAB><line><TAB><col><LF>`. The plugin
will place the caret on the identifier (`GotoLine` + column) and ignore the
field if absent. Please add it -- caret-on-identifier is worth it.

## Q4 -- SQL symbols

SQL-tier symbols live in their own tables (`fb_relations`, `fb_columns`,
`fb_datasets`, ...), **not** in `symbols`, and have no `.pas`/`.sql` file path
in the graph today. So for a `sql_table` / `sql_column` node: **gate on node
kind and do not emit an open-source request** -- show a status hint instead
("SQL symbol -- no source file"). If/when we add a DDL `files.path` for these,
we will tell you and you can open it like any other node. For now: no-op + hint.

## Q5 -- DFM form nodes

`file_path` is the `.dfm`. We want the **code**, not the form designer:
**map `.dfm` -> `.pas` on the viewer side** before sending (same base name,
`.pas` extension) and send the `.pas` path. If the `.pas` is missing, fall back
to the `.dfm`. The plugin will just open whatever path it receives.

## Q6 -- library / RTL symbols not on disk

**Attempt the open, fall back, hint.** The plugin will try
`IOTAActionServices.OpenFile`; if the path is not on disk it fails quietly and
the viewer's `ShellExecute` fallback (which will also fail) leaves a status
note. Cleaner: when a node is `IsExternal` / resolves only in the library
store, you may suppress the pipe send and show "external symbol -- source not
on disk" directly. Either is fine; do not block the main flow on it.

## Q7 -- schema stability

These columns are **contract-stable** and safe to depend on across v5 -> v6 ->
v7: `symbols.id`, `symbols.file_id`, `symbols.name`, `symbols.qualified_name`,
`symbols.kind`, `symbols.start_line`, `symbols.start_col`, `symbols.end_line`,
`symbols.end_col`, and `files.path`. v6 added new *tables* (`symbol_docs`,
`fb_*`, `orm_links`) but did not change these `symbols` columns. Your
`schema_version >= 5` guard is fine -- no need to chase the bump.

## Net effect on the wire contract

Unchanged framing, one optional field added:

```
<file><TAB><line><TAB><col><LF>        (UTF-8, no BOM, single LF)
```

and the viewer resolves the clicked node by `symbols.id` (Q1) so `<file>`,
`<line>`, `<col>` are exact. The plugin server side (pipe + OTAPI
`OpenFile`/`GotoLine`/column) is drag-lint's next task.

-- drag-lint side, 2026-06-01
