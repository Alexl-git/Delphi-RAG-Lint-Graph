# P3: DB Source (FireDAC) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Implement the real `IGraphSource` / `IDbCatalog` over the drag-lint SQLite DB via FireDAC — topology (containment, `unit_uses` edges with section, `refs` edges with enclosing-symbol resolution, SQL Tier 1), lazy docs, cref + cross-store resolution, schema-version guard — proven by deterministic temp-DB tests plus a real-DB integration smoke.

**Architecture:** `DragLint.Graph.Source.Db` is the ONLY unit that links FireDAC. It mirrors the proven connection setup in drag-lint's `DRagLint.Storage.SQLite.pas` (reference: `C:\Projects\Delphi-RAG-lint\src\storage\DRagLint.Storage.SQLite.pas`) but opens **read-only** (we must never modify the user's DBs). The headless tests build a temp DB from the exact v5 DDL and assert; a soft integration smoke opens the real ORM3 + library DBs.

**Tech Stack:** Delphi 13, FireDAC SQLite (dynamic, `sqlite3.dll` — proven present since drag-lint's own console tests use it), `dcc32` Win32. Strict ASCII/CRLF.

Spec: [`../specs/2026-05-31-graph-viewer-real-and-harden-design.md`](../specs/2026-05-31-graph-viewer-real-and-harden-design.md) §3, §4. Builds on P1 (`Types`, `Source`) and is consumed by P2's `IGraphViewModel`.

## Proven FireDAC connection (mirror this; open READ-ONLY)

From drag-lint's working reader:
```pascal
FConn := TFDConnection.Create(nil);
FConn.DriverName := 'SQLite';
FConn.Params.Values['Database'] := ADbPath;
FConn.Params.Values['OpenMode'] := 'ReadOnly';   { we only read; never mutate user DBs }
FConn.Params.Values['LockingMode'] := 'Normal';
FConn.LoginPrompt := False;
FConn.Connected := True;
```
Unit `uses` for the DB unit: `System.SysUtils, System.Classes, System.Generics.Collections, Data.DB, FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.Stan.Async, FireDAC.Phys.SQLite, FireDAC.Stan.Param, FireDAC.DApt, DragLint.Graph.Types, DragLint.Graph.Source`.
The console test program (`drag_lint_graph_tests.dpr`) must add `FireDAC.ConsoleUI.Wait` to its uses (console wait-cursor provider) if a FireDAC wait-cursor runtime error appears.

## Test data
- **Deterministic:** a temp DB built from the v5 DDL (copy `SCHEMA_DDL` text — see reference `C:\Projects\Delphi-RAG-lint\src\storage\DRagLint.Storage.Schema.pas`) with a handful of inserted rows. Created fresh in `%TEMP%` per test run; deleted after.
- **Integration smoke (soft):** open real DBs read-only. Project: `C:\Projects\DB\ORM3\drag-lint.sqlite` (27 MB — full `LoadTopology` OK). Library: `C:\Projects\Delphi-RAG-lint\third_party\dll-win32\drag-lint-library.sqlite` (881 MB — **never** `LoadTopology`; targeted resolve/doc queries only). If a real DB path is absent at run time, the smoke logs SKIP and passes (so the suite stays green on machines without them).

## Per-task protocol
Same as P2's: failing test first (RED), implement, GREEN (`pwsh tests\console\run.ps1` exit 0), then MANDATORY CRLF/ASCII normalization of every touched `.pas`/`.dpr` (`bareLF=0 nonAscii=0`), then commit with the given message + `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Branch `feat/graph-viewer-real`. The DB unit links FireDAC; all P1/P2 units stay FireDAC-free.

## Scope note (record in code comments)
`LoadTopology` loads an entire store's graph. This is impractical for very large stores (e.g. the 881 MB library) — the real product resolves/jumps into such stores rather than rendering them whole. Scoped/lazy loading for huge stores is the deferred LOD concern; P3 implements straightforward full-store load (fine for project-sized DBs).

---

## File Structure

| File | Responsibility |
|------|----------------|
| Create `src/control/DragLint.Graph.Source.Db.pas` | `TDbGraphSource` (IGraphSource) + `TDbCatalog` (IDbCatalog). Only FireDAC-linking unit. |
| Create `tests/console/Test.Db.Fixtures.pas` | Build a temp v5 SQLite DB with known rows; return its path; cleanup helper. |
| Create `tests/console/Test.Graph.Source.Db.pas` | Deterministic temp-DB tests + soft real-DB smoke. |
| Modify `tests/console/drag_lint_graph_tests.dpr` | Register units; add `FireDAC.ConsoleUI.Wait`. |
| Modify `tests/console/run.ps1` only if needed | Add FireDAC unit search/namespaces if dcc32 cannot resolve them. |

---

## Task 1: Connection + schema guard + symbols->nodes (containment + flags)

**Create `src/control/DragLint.Graph.Source.Db.pas`** with `TDbGraphSource`:
- `constructor Create(const ADbPath: string; AStoreIndex: Integer)`; opens read-only (above), verifies `schema_meta.schema_version` (SELECT value FROM schema_meta WHERE key='schema_version'); if missing or `< 5`, raise `EDbSchemaMismatch` with a clear message. Destructor frees the connection.
- `StoreIndex` returns the stored index.
- `LoadTopology(AData)`: clear, then:
  - **symbols -> nodes:** `SELECT id, file_id, parent_id, kind, name, qualified_name, signature, start_line, start_col FROM symbols`. Map each: `Id := qualified_name`, `Label_ := name`, `Kind := KindTextToNodeKind(kind)`, `DbId := id`, `Signature := signature`, `Line := start_line`, `Col := start_col`. Resolve `FilePath` via a `file_id -> path` map loaded once from `SELECT id, path FROM files`. Set `ParentId` to the parent symbol's qualified_name (build an `id -> qualified_name` map first, then `ParentId := map[parent_id]` when parent_id not null, else '').
  - **doc/deprecated flags:** `Documented`/`Deprecated` from a `LEFT JOIN symbol_docs` (one pass: `SELECT symbol_id, deprecated FROM symbol_docs` into a set/dict; mark nodes whose DbId is present).
  - call `AData.BuildHierarchy`.
- `KindTextToNodeKind`: map 'unit'->nkUnit, 'class'->nkClass, 'interface'->nkInterface, 'record'->nkRecord, 'method'->nkMethod, 'procedure'->nkProcedure, 'function'->nkFunction, 'property'->nkProperty, 'field'->nkField, 'const'->nkConst, 'var'->nkVar, 'type'->nkType, 'sql_table'->nkSqlTable, 'sql_column'->nkSqlColumn, 'sql_index'->nkSqlIndex, 'sql_trigger'->nkSqlTrigger, 'sql_generator'->nkSqlGenerator, 'sql_view'->nkSqlView, 'sql_procedure'->nkSqlProcedure, 'sql_exception'->nkSqlException, 'sql_domain'->nkSqlDomain, else nkOther. (Stub `GetDoc`/`ResolveCref`/`LocateSymbol` to empty results in this task; real impl in Task 4.)

**`tests/console/Test.Db.Fixtures.pas`**: a function `CreateTempV5Db: string` that creates a temp file path, opens a FireDAC SQLite connection (read-write), runs the v5 `SCHEMA_DDL` statements (copy them into this unit from the reference Schema.pas), inserts `schema_meta` version 5, and inserts known rows: one `files` row; symbols: a unit `U` (kind 'unit'), class `U.TFoo` (parent = U), method `U.TFoo.Bar` (parent = TFoo) with start/end line ranges; returns the path. Add `DeleteTempDb(path)`.

**Test 1 (`Test.Graph.Source.Db.pas`)**: build temp DB, `TDbGraphSource.Create(path, 0)`, `LoadTopology` into a `TGraphData`; assert: node count = 4 (3 symbols + synthetic project? No — symbols include `unit U`; BuildHierarchy adds `@project` over `U`, so 3 symbols + 1 project = 4); `FindNodeIndex('U.TFoo.Bar') >= 0`; `ParentIndexOf` of Bar = index of TFoo; the unit's `Documented` flag true if a symbol_docs row was inserted for it (insert one to test). Delete temp DB.

**Smoke 1 (soft):** if `C:\Projects\DB\ORM3\drag-lint.sqlite` exists, open it, `LoadTopology`, assert `NodeCount > 100`; else print SKIP. (Wrap in try/except; a failure here is a real FAIL, but a missing file is SKIP.)

Commit: `feat: FireDAC DB source - connection, schema guard, symbols->nodes`

---

## Task 2: unit_uses -> ekUses edges (section + external targets)

Extend `LoadTopology` (after symbols, before BuildHierarchy or after — edges don't need hierarchy, but `BuildHierarchy` must run after all nodes incl. external nodes are added, so add uses edges/external nodes BEFORE BuildHierarchy):
- Load a `unit_name_norm/path-stem -> unit-symbol-node` resolution: the source unit of a `unit_uses` row is the `kind='unit'` symbol whose `file_id` matches `unit_uses.file_id`. Build `file_id -> unit qualified_name` from symbols where kind='unit'.
- `SELECT file_id, unit_name, section, target_file_id FROM unit_uses`:
  - Source node id = the unit qualified_name for `file_id` (skip row if none).
  - Target: if `target_file_id` not null, the unit qualified_name for that file (in-store). If null OR no unit symbol, create/lookup a synthetic **external** node: id = `'@ext:' + unit_name`, `Kind := nkUnit`, `IsExternal := True`, added once (dedupe via a dictionary).
  - Add `TGraphEdge`: SourceId, TargetId, `Kind := ekUses`, `Label_ := section`, `Weight := 1.0`. (Section is carried in `Label_` for now; the View reads it for solid/dashed/bold styling.)

**Test 2:** in the temp DB add a second file/unit `V` and a `unit_uses` row (file of U, unit_name 'V', section 'interface', target_file_id = V's file) and one external (unit_name 'System.SysUtils', target_file_id null). `LoadTopology`; assert an `ekUses` edge U->V with `Label_='interface'` exists, and an external node `@ext:System.SysUtils` with `IsExternal=True` exists with a U->that edge.

Commit: `feat: DB source unit_uses -> uses edges with section + external nodes`

---

## Task 3: refs -> call/type_use/dfm/sql_table_ref edges (enclosing-symbol resolution)

The hard part. `refs` stores `symbol_id` (target), `file_id`, `kind`, `name_text`, `start_line`, `start_col` (the ref SITE) — but NOT the source symbol. Resolve the source = the innermost symbol whose `[start_line..end_line]` range in the same `file_id` contains the ref's `start_line`.

Algorithm (in-memory, efficient): when loading symbols, also keep per-`file_id` a list of `(start_line, end_line, node_index)`. For each `refs` row, find candidate symbols in that file where `start_line <= ref.start_line <= end_line`; pick the one with the greatest `start_line` (innermost). That node is the source.
- `SELECT symbol_id, file_id, kind, name_text, start_line FROM refs`:
  - Map `kind`: 'call'->ekCalls, 'type_use'->ekTypeRef, 'event-binding'->ekDfmBinds, 'sql_table_ref'->ekSqlTableRef, else skip (or ekOther).
  - Target: if `symbol_id` not null -> that symbol's qualified_name; else skip (unresolved refs do not create edges in this task — they could be external nodes later, but keep P3 focused: skip null-target refs).
  - Source: enclosing symbol via the resolution above; skip if none.
  - Add edge Source->Target with the mapped kind, Weight 1.0. Skip self-edges (source=target).

**Test 3:** in temp DB, add a `refs` row of kind 'call' located inside Bar's line range, with `symbol_id` = MB (add a second class/method `U.TBaz.MB` to be the call target). `LoadTopology`; assert an `ekCalls` edge `U.TFoo.Bar -> U.TBaz.MB` exists (source resolved by enclosing range). Add a `type_use` ref to assert `ekTypeRef`.

Commit: `feat: DB source refs -> call/typeref/dfm/sqltableref via enclosing-symbol resolution`

---

## Task 4: docs (GetDoc) + cref resolution (ResolveCref) + LocateSymbol

- `GetDoc(AQName)`: `SELECT d.* FROM symbols s LEFT JOIN symbol_docs d ON d.symbol_id = s.id WHERE s.qualified_name = :q LIMIT 1`. If no `symbol_docs` row (`d.format` null), `HasDoc := False`. Else fill `TGraphDoc` (HasDoc True; Format, Summary, Remarks, ReturnsText, ExampleText, SinceText, Deprecated). Parse `params_json`/`exceptions_json`/`seealso_json` (TEXT JSON arrays) with `System.JSON` into the arrays (client-side parse — robust across Win32/Win64). Guard malformed JSON (empty on parse failure).
- `LocateSymbol(AQName; out AFile; out ALine)`: `SELECT f.path, s.start_line FROM symbols s JOIN files f ON f.id=s.file_id WHERE s.qualified_name=:q LIMIT 1`. Return False if none.
- `ResolveCref(AText)`: implement the algorithm — if starts with 'http://'/'https://' -> crkUrl. Else exact `qualified_name` match (LIMIT 1) -> crkResolved (TargetId=qname, StoreIndex). Else bare `name` match (`SELECT qualified_name FROM symbols WHERE name=:n ORDER BY CASE kind WHEN 'class' THEN 0 WHEN 'method' THEN 1 WHEN 'property' THEN 2 ELSE 3 END LIMIT 5`): if exactly 1 -> crkResolved; if >1 -> crkAmbiguous (Candidates := qnames); if 0 -> crkUnresolved.

**Test 4:** temp DB: insert a `symbol_docs` row for `U.TFoo.Bar` (format 'xmldoc', summary 'Hi', seealso_json '["U.TFoo","https://x"]', deprecated 0). Assert `GetDoc('U.TFoo.Bar').HasDoc` and Summary='Hi' and SeeAlso length 2. `GetDoc('U')` HasDoc False (no doc row). `ResolveCref('U.TFoo')` = crkResolved/TargetId 'U.TFoo'. `ResolveCref('https://x')` = crkUrl. `ResolveCref('Nope')` = crkUnresolved. `LocateSymbol('U.TFoo.Bar', f, l)` True with f<>'' .
**Smoke (soft):** on ORM3, pick any symbol via `SELECT qualified_name FROM symbols WHERE kind='method' LIMIT 1` and assert `LocateSymbol` returns a non-empty path.

Commit: `feat: DB source docs + cref resolution + locate-symbol`

---

## Task 5: TDbCatalog (ordered stores, cross-store resolve) + integration smoke

- `TDbCatalog`: `constructor Create(const APaths: TArray<string>)`. `StoreCount`, `StorePath(i)`. `SourceForStore(i)`: lazily create + cache a `TDbGraphSource(path_i, i)` (store the interface in an array so it lives as long as the catalog). `ResolveAcrossStores(AName)`: for i := 0 to StoreCount-1, open/get source i, try exact qname then bare name (a lightweight query — add a `function ExistsQName/FindBareName` to `TDbGraphSource`, or reuse `ResolveCref`'s exact/bare logic via a new `function ResolveName(const AName): Boolean + out qname`). First store with a hit -> `TCrossDbResolution(Found:=True, StoreIndex:=i, TargetId:=qname)`. None -> Found False.
  - **Performance:** `ResolveAcrossStores` must NOT `LoadTopology`; it runs a single indexed `SELECT ... WHERE qualified_name=:q LIMIT 1` (then bare-name) per store. This keeps it fast even against the 881 MB library.
- Add to `IGraphSource` (P1) a method `function ResolveName(const AName: string; out AQName: string): Boolean;`? — NO, do not change the P1 interface this late. Instead implement cross-store resolution inside `TDbCatalog` by calling the concrete `TDbGraphSource` (the catalog creates them, so it can hold them as the concrete class or add the method to the interface). DECISION: add `ResolveName` to `IGraphSource` in P1's `DragLint.Graph.Source.pas` (small, additive; update the P1 fakes to implement it returning False, and `TFakeGraphSource`/`TPreloadedSource`/`TStoreSource` accordingly). This keeps the catalog interface-clean. Re-run the full suite to confirm the fakes still satisfy the interface.

**Test 5 (deterministic):** build TWO temp DBs (store0 has unit 'A', store1 has unit 'B'), `TDbCatalog.Create([p0,p1])`; `ResolveAcrossStores('B')` -> Found, StoreIndex 1, TargetId 'B'; `ResolveAcrossStores('A')` -> store 0; `ResolveAcrossStores('Zed')` -> not Found. `SourceForStore(0).LoadTopology` works.
**Integration smoke (soft):** if both real DBs exist, `TDbCatalog.Create([ORM3, library])`; `LoadTopology` store 0 (ORM3) asserts NodeCount>100 and at least one `ekUses` edge with a section label; `ResolveAcrossStores` of a known RTL/Spring name resolves in store 1 (library) WITHOUT loading it; else SKIP.

Commit: `feat: DB catalog (multi-store cross-DB resolve) + real-DB integration smoke`

---

## Self-Review checklist (run after Task 5)
- §3 coverage: schema guard; symbols->nodes + containment + flags + signature (T1); unit_uses->uses+section+external (T2); refs->call/typeref/dfm/sqltableref + enclosing-symbol resolution (T3); SQL Tier 1 kinds mapped (T1 KindText map); docs lazy + crefs render-time + locate (T4); multi-store catalog + cross-store first-hit resolve, no-merge (T5).
- Read-only opens (never mutate user DBs). FireDAC isolated to this one unit. Real-DB smokes are soft (SKIP if absent).
- `ResolveName` interface addition propagated to all fakes; full suite green; node/edge counts asserted.
- ASCII/CRLF on every file.
