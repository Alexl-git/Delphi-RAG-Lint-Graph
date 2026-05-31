# Unit Uses — what's captured, how to query, what utilities it enables

This document covers the `unit_uses` table that drag-lint v0.40.4 added
to support graphing's interface↔implementation hierarchy view AND
standalone unit-utility tools (circular detection, move-down
suggestions, unused-unit elimination).

It is the companion to `docs/doc-comments.md`. Together they cover the
two parts of "what does an indexed unit look like in the DB."

Accurate to drag-lint v0.40.4-alpha. Storage version: **5**.

---

## 1. Schema

```sql
CREATE TABLE unit_uses (
  id              INTEGER PRIMARY KEY,
  file_id         INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  unit_name       TEXT NOT NULL,        -- verbatim, dotted: 'System.SysUtils'
  unit_name_norm  TEXT NOT NULL,        -- lowercased trailing segment: 'sysutils'
  section         TEXT NOT NULL,        -- 'interface' | 'implementation' | 'program' | 'package'
  in_path         TEXT,                 -- text from `in '...'` clause; NULL if absent
  target_file_id  INTEGER REFERENCES files(id) ON DELETE SET NULL,
  start_line      INTEGER NOT NULL,
  start_col       INTEGER NOT NULL,
  end_line        INTEGER,
  end_col         INTEGER
);

CREATE INDEX idx_unit_uses_file       ON unit_uses(file_id);
CREATE INDEX idx_unit_uses_unit_norm  ON unit_uses(unit_name_norm);
CREATE INDEX idx_unit_uses_section    ON unit_uses(section);
CREATE INDEX idx_unit_uses_target     ON unit_uses(target_file_id)
                                      WHERE target_file_id IS NOT NULL;
```

One row per (file, section, listed unit). `unit_name_norm` is the
lowercased trailing dotted segment — `System.SysUtils` becomes
`sysutils`. Used as the join key against files.

---

## 2. What gets captured

For a `.pas` file shaped like:

```pascal
unit Blueprint4;

interface

uses
  Winapi.Windows, Vcl.Forms,
  Blueprint4.Interfaces;

implementation

uses
  System.UITypes,
  uAppGlobals,
  Blueprint4.ViewModel;
```

we capture eight rows:

| file_id | unit_name             | unit_name_norm  | section        | in_path | start_line |
|---------|-----------------------|-----------------|----------------|---------|-----------:|
| 42      | Winapi.Windows        | windows         | interface      | NULL    |          6 |
| 42      | Vcl.Forms             | forms           | interface      | NULL    |          6 |
| 42      | Blueprint4.Interfaces | interfaces      | interface      | NULL    |          7 |
| 42      | System.UITypes        | uitypes         | implementation | NULL    |         13 |
| 42      | uAppGlobals           | uappglobals     | implementation | NULL    |         14 |
| 42      | Blueprint4.ViewModel  | viewmodel       | implementation | NULL    |         15 |

For `.dpr` and `.dpk` files the section is `program` or `package`,
and the `in '<path>'` text (if present) lands in `in_path`.

Empirically (full Micronite CLIENT folder = 333 files):

- 5,302 rows total
- 4,189 interface
- 569 implementation
- 544 program/package
- 14% have `target_file_id` resolved (rest are RTL/VCL/DevExpress/etc.
  not in the project DB)

---

## 3. How `target_file_id` is resolved

After every full index pass, `ResolveUnitUseTargets` runs once:

1. Read `(id, path)` for every row in `files`.
2. Compute the lowercase stem of each path's basename
   (`C:/.../Foo.pas` → `foo`).
3. Build a `stem → file_id` dictionary.
4. For every `unit_uses` row, look up `unit_name_norm` in the dictionary.
   On hit, UPDATE `target_file_id`.

Resolution is **best-effort, not authoritative**:

- A `unit_name_norm = 'sysutils'` hits whichever `SysUtils.pas` the
  index happens to contain. If two `SysUtils.pas` files exist (e.g.,
  RTL + a renamed copy), the later one wins (deterministic but maybe
  surprising).
- The lookup is by **trailing dotted segment**, not the full dotted
  name. `System.SysUtils` and a hypothetical `Foo.SysUtils` both
  resolve to whatever `sysutils.pas` exists in the index. This is
  almost always what you want in practice (Delphi unit scoping rules
  resolve mostly by basename); when it isn't, fall back to the
  `unit_name` text for disambiguation.
- Library DBs typically have higher resolution coverage; project DBs
  show ~10–20% resolved because most uses target external code.

**Implication for the graphing tool**: when `target_file_id IS NULL`,
treat the unit as "external" — render as a different-colored node,
don't try to recurse into it for in-project navigation. When
`target_file_id IS NOT NULL`, render as a fully clickable in-project
node and use the file's symbols for hover info.

---

## 4. How to query

### A. SQL — full table, expected primary path

#### A1. Every uses entry in a single file

```sql
SELECT section, unit_name, in_path, target_file_id, start_line
FROM   unit_uses
WHERE  file_id = (SELECT id FROM files WHERE path = :path)
ORDER  BY section, start_line, start_col;
```

#### A2. Every file that uses a given unit (forward edges into unit X)

```sql
SELECT f.path, u.section, u.start_line
FROM   unit_uses u
JOIN   files f ON f.id = u.file_id
WHERE  u.unit_name_norm = LOWER(:unit_stem)
ORDER  BY f.path;
```

#### A3. Every unit a given file uses (forward edges out of file X)

```sql
SELECT u.section, u.unit_name, u.in_path, f2.path AS resolved_path
FROM   unit_uses u
LEFT   JOIN files f2 ON f2.id = u.target_file_id
WHERE  u.file_id = (SELECT id FROM files WHERE path = :path)
ORDER  BY u.section, u.start_line;
```

### B. Multi-DB

Same as docs/symbols: iterate stores and merge results. Library DB
resolves most VCL/RTL units; project DB resolves project units; combine
for full graph coverage.

### C. No LSP method yet

LSP textDocument/hover doesn't expose uses data in v0.40.4. The
graphing tool should query SQL directly for unit-graph rendering.
(If LSP integration becomes needed later, a custom `drag-lint/uses`
extension method would be a small add.)

---

## 5. Utilities this powers — query recipes

### 5.1. Circular dependency detection

A → B → A is a circular pair. Detect with a WITH RECURSIVE walk over
resolved edges. The naive approach below stops at depth 6 (configurable)
to bound runtime on large projects.

```sql
WITH RECURSIVE
deps(src_file_id, dst_file_id, path, depth) AS (
    SELECT u.file_id, u.target_file_id,
           f.path || ' -> ' || COALESCE(f2.path, u.unit_name),
           1
    FROM   unit_uses u
    JOIN   files f  ON f.id = u.file_id
    LEFT   JOIN files f2 ON f2.id = u.target_file_id
    WHERE  u.target_file_id IS NOT NULL
  UNION ALL
    SELECT d.src_file_id, u2.target_file_id,
           d.path || ' -> ' || COALESCE(f2.path, u2.unit_name),
           d.depth + 1
    FROM   deps d
    JOIN   unit_uses u2 ON u2.file_id = d.dst_file_id
    LEFT   JOIN files f2 ON f2.id = u2.target_file_id
    WHERE  d.depth < 6
      AND  u2.target_file_id IS NOT NULL
)
SELECT path
FROM   deps
WHERE  src_file_id = dst_file_id
ORDER  BY depth;
```

`src_file_id = dst_file_id` at any depth means a cycle. The `path`
column shows the cycle for the user. In the graphing tool:

- Highlight cycle members with a red border.
- Render the cycle path as an animated tooltip on hover.
- For each cycle, suggest "move N edges down" (see 5.2) as a fix.

### 5.2. Move-down candidates (interface → implementation)

A use is a *move-down candidate* when:

1. It's in the `interface` section of file X.
2. None of file X's **interface-section public symbols** reference any
   symbol from the used unit.

The first condition is direct SQL. The second is a join through `refs`
and `symbols`. The query below approximates it by checking whether the
file's interface-section symbols (where `s.start_line` falls before the
implementation keyword line) have any references whose target lives in
the used unit:

```sql
-- Candidates: interface uses whose used unit appears NOWHERE in this
-- file's interface section.
WITH iface_uses AS (
    SELECT id, file_id, unit_name, target_file_id, start_line
    FROM   unit_uses
    WHERE  section = 'interface'
),
iface_refs_per_file AS (
    -- All refs from interface-section symbols in each file
    SELECT s.file_id, ref_target_sym.file_id AS used_file_id
    FROM   symbols s
    JOIN   refs r ON r.file_id = s.file_id
                  AND r.start_line BETWEEN s.start_line AND s.end_line
    JOIN   symbols ref_target_sym
                ON LOWER(ref_target_sym.name) = LOWER(r.name_text)
    WHERE  s.kind IN ('class','interface','record','procedure','function',
                      'property','field','const','var')
)
SELECT  f.path           AS in_file,
        iu.unit_name     AS use_to_move_down,
        iu.start_line    AS line
FROM    iface_uses iu
JOIN    files f ON f.id = iu.file_id
WHERE   iu.target_file_id IS NOT NULL
  AND   NOT EXISTS (
            SELECT 1
            FROM   iface_refs_per_file rpf
            WHERE  rpf.file_id      = iu.file_id
              AND  rpf.used_file_id = iu.target_file_id
        )
ORDER BY f.path, iu.start_line;
```

Caveats — the move-down query is HEURISTIC, not provably correct:

- It misses cases where the used unit contributes only **type
  arguments to a generic** in the interface (refs table doesn't track
  every type instantiation).
- It misses cases where a published `class` field's TYPE comes from
  the unit but the unit is only used by name (not as a symbol ref).
- It can produce false positives on units that re-export types via
  `uses` (e.g., `System.Generics.Collections` is often used in the
  interface "just because" the implementation uses `TList<T>` which
  Delphi resolves via the published API).

For the graphing tool, **render move-down suggestions as
informational hints, not as automated rewrites**. A user clicks the
suggestion → drag-lint opens the file at the use line and the user
decides whether to move it. Wire to a future
`drag-lint refactor move-uses --file X --unit Y` command (not in
v0.40.4).

### 5.3. Unused-unit candidates

A use is a *unused candidate* when no symbol in the file references
any symbol from the used unit, in EITHER section. Same heuristic as
above, extended across sections. Same caveats apply, more so —
unused-unit elimination is the most error-prone of the three utilities
because of the generic-instantiation and re-export issues.

```sql
SELECT  f.path        AS in_file,
        u.section,
        u.unit_name   AS unused_candidate,
        u.start_line  AS line
FROM    unit_uses u
JOIN    files f ON f.id = u.file_id
WHERE   u.target_file_id IS NOT NULL
  AND   NOT EXISTS (
            SELECT 1
            FROM   refs r
            JOIN   symbols rs ON rs.id = r.symbol_id
            WHERE  r.file_id  = u.file_id
              AND  rs.file_id = u.target_file_id
        )
ORDER BY f.path, u.section, u.start_line;
```

Same render-as-hint, never-auto-apply guidance applies.

### 5.4. Forward dependency graph (for graphing)

```sql
-- Edges: every file -> every used file it references that's also in the DB
SELECT u.file_id            AS src,
       u.target_file_id     AS dst,
       u.section            AS edge_kind,
       COUNT(*)             AS multiplicity
FROM   unit_uses u
WHERE  u.target_file_id IS NOT NULL
  AND  u.file_id <> u.target_file_id        -- ignore unit referring to itself
GROUP  BY u.file_id, u.target_file_id, u.section;
```

`multiplicity` here is always 1 for well-formed code (one section can
list a unit once), but groups handle the same unit in both interface
and implementation sections as **two** edges with different
`edge_kind`. The graphing tool should:

- Render interface edges as solid lines
- Render implementation edges as dashed lines
- Render program/package edges as bold lines
- Group multiple edges between the same two nodes into one visual
  edge with a tooltip listing each section

### 5.5. Coverage (for "% resolved" panel)

```sql
SELECT COUNT(*)                                   AS total,
       SUM(CASE WHEN target_file_id IS NULL
                THEN 0 ELSE 1 END)                AS resolved,
       SUM(CASE WHEN target_file_id IS NULL
                THEN 1 ELSE 0 END)                AS external
FROM   unit_uses;
```

---

## 6. Known limitations

- **Conditional sections (`{$IFDEF}`)** are processed permissively;
  the grammar accepts uses-clauses interleaved with `pp` and
  `pp_block` tokens but the indexer doesn't track which `IFDEF`
  branch a given entry came from. The result: a use that ONLY
  exists inside an `{$IFDEF POSIX}` branch shows up identically to
  an unconditional use. Bear this in mind when reporting "unused".
- **`uses` clauses inside `program` blocks** are captured under
  `section = 'program'`. We don't distinguish the implicit
  Application-creating `.dpr` shape from a normal program.
- **Renames of used units** between index passes don't propagate
  automatically. The stale row stays until the next index of the
  using file. For correctness, run `drag-lint index` against the
  whole project after a unit rename.
- **`target_file_id` resolution is by bare name only.** A code base
  with `Foo.SysUtils` and `System.SysUtils` and a project-local
  `SysUtils.pas` will pick one — the indexer dictionary picks the
  LAST file seen. Workaround: use full `unit_name` for
  disambiguation when this matters.
- **In `.dproj` projects with explicit `<DCCReference>`s and
  search-path resolution**, drag-lint's resolution doesn't model
  Delphi's exact dotted-vs-unscoped precedence. For the
  `unit-not-in-dpr` lint rule, drag-lint reparses the .dpr directly
  rather than using this table.

---

## 7. The Pascal record (for in-process consumers)

```pascal
type
  TUnitUseSection = (
    uusInterface,        // `interface uses ...`
    uusImplementation,   // `implementation uses ...`
    uusProgram,          // top-level uses in a .dpr
    uusPackage           // top-level uses in a .dpk
  );

  TUnitUse = record
    FileId:    Int64;          // owning file
    UnitName:  string;         // verbatim, with dots
    Section:   TUnitUseSection;
    InPath:    string;         // text from `in '...'`; '' when absent
    StartLine: Integer;        // 1-based
    StartCol:  Integer;
    EndLine:   Integer;
    EndCol:    Integer;
  end;
```

`ISymbolStore` API additions (for embedded VCL consumers):

```pascal
procedure UpsertUnitUse(const AToken: TFileTxToken; const AUse: TUnitUse);
procedure DeleteUnitUsesForFile(AFileId: Int64);
function  GetUnitUsesForFile(AFileId: Int64): TArray<TUnitUse>;
function  FindUsersOfUnit(const AUnitNameNorm: string): TArray<TUnitUse>;
procedure ResolveUnitUseTargets;   { run once after a full index pass }
```

---

## 8. In-repo file references

- Schema: `src/storage/DRagLint.Storage.Schema.pas` — version bumped to 5
- Pascal record: `src/core/DRagLint.Core.Model.pas` — `TUnitUse`, `TUnitUseSection`
- Parser: `src/parser/DRagLint.Parser.Delphi13.pas` — `WalkUsesClause`, `WalkSection`
- Storage impl: `src/storage/DRagLint.Storage.SQLite.pas` — `UpsertUnitUse`, `GetUnitUsesForFile`, `ResolveUnitUseTargets`
- Indexer hook: `src/core/DRagLint.Core.Indexer.pas` — wipe-and-rewrite per file inside the file transaction
- CLI post-pass: `src/cli/DRagLint.CLI.pas` — `Store.ResolveUnitUseTargets` after every full pass

When the indexer learns to resolve dotted/scoped names properly,
this doc should be updated to drop the "by bare name" caveat in §6.
