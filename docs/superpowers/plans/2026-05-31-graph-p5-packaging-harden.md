# P5: Packaging + Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Make the component-first package real and ship-ready: a read-only DB-open hardening fix, dead-code/README/build-script cleanup, and the runtime + DB + design-time BPL split with a `build_all.bat` that builds everything and runs both test gates.

**Architecture:** Three packages — `DragLintGraph.bpl` (runtime core: Types, Source, ViewModel, Style, Layout, Control; VCL, no FireDAC), `DragLintGraphDb.bpl` (Source.Db; requires FireDAC), `DragLintGraphDcl.bpl` (design-time; registers the control). The viewer EXE stays a demo host.

**Tech Stack:** Delphi 13, dproj/dpk packages, `msbuild`/`dcc32`. Strict ASCII/CRLF.

Spec: [`../specs/2026-05-31-graph-viewer-real-and-harden-design.md`](../specs/2026-05-31-graph-viewer-real-and-harden-design.md) §11, §12. Builds on P1-P4.

## Per-task protocol
Same as prior slices: change, verify (console suite `pwsh tests\console\run.ps1` stays green; smoke where relevant), CRLF/ASCII normalize touched `.pas`/`.dpr`/`.dpk`, commit with the given message + `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Branch `feat/graph-viewer-real`.

---

## Task 1: Read-only / immutable DB open (hardening)

**Problem:** P3 opens DBs `ReadWrite + PRAGMA query_only=ON` because WAL DBs reject `OpenMode=ReadOnly`. This (a) can collide with a live indexer ("database is locked"), and (b) creates `-wal`/`-shm` sidecars next to the user's DBs. We must never disturb the user's DBs and must coexist with a live writer for resolve-only access.

**Fix in `src/control/DragLint.Graph.Source.Db.pas` `Connect`:** open with SQLite's read-only + immutable semantics so no sidecar is created and no writer lock is needed. With FireDAC SQLite, set:
```pascal
FConn.Params.Values['Database'] := ADbPath;
FConn.Params.Values['OpenMode'] := 'ReadOnly';
FConn.Params.Values['LockingMode'] := 'Normal';
FConn.Params.Values['SQLiteAdvanced'] := 'immutable=1';  { read-only WAL access w/o -shm; treats file as unchanging }
FConn.LoginPrompt := False;
FConn.Connected := True;
{ no query_only pragma needed under ReadOnly; keep it as belt-and-suspenders if harmless }
```
If FireDAC rejects `SQLiteAdvanced=immutable=1` (older FireDAC), fall back to a file URI: `Database := 'file:' + ADbPath + '?immutable=1'` with `Params.Values['SQLiteAdvanced']:='VFS=...'` — but try the param form first. The goal: opening the 881 MB **locked** library for a single `ResolveName` SELECT must SUCCEED (no "database is locked"), and no `-shm`/`-wal` file should be created next to the DB.

**Verify:**
- Console suite still green (the temp-DB tests build fresh non-WAL DBs; they must still open — `immutable=1` on a rollback-journal DB is fine for reading).
- If `C:\Projects\DB\ORM3\drag-lint.sqlite` and the locked library exist: a focused check that `TDbCatalog.ResolveAcrossStores('TObject')` against the library now SUCCEEDS (or at least does not raise "database is locked"). Update `Test_DbCatalog_LibrarySmoke` so that, when the library is present, a lock error is now a FAIL (not a SKIP) — i.e. tighten the smoke since immutable open should defeat the lock. Keep "file absent -> SKIP".
- Confirm (manually or in the test) that opening ORM3 does NOT create `ORM3\drag-lint.sqlite-shm`/`-wal` (check before/after file listing in the test or note it).

Commit: `fix: open drag-lint DBs read-only + immutable (coexist with live indexer, no sidecars)`

---

## Task 2: Dead-code removal + README + build-script reconcile

- **Remove dead code:** `TGraphLayout.Reset` in `src/control/DragLint.Graph.Layout.pas` is declared+implemented but unused (compiler hint H2219). Remove the declaration and body. Rebuild console suite (green) and re-run the control compile + viewer build to confirm nothing referenced it.
- **README rewrite** (`README.md`): replace the Phase-0 description with the real architecture: pure-VCL canvas (no WebView2 — supersedes the declined drag-lint WebView2 proposal); DB-direct via FireDAC (read-only/immutable); near-MVVM (Model/ViewModel/View) with a dependency-free core; one-graph-per-DB + cross-DB jump; SQL Tier 1; the 4-level hierarchy + collapse/focus; the BPL split (after Task 3); how to build (`build\build_all.bat`) and test (`pwsh tests\console\run.ps1` + `pwsh tests\autotest\run_smoke.ps1`); how to run (`drag_lint_graph.exe --db <path>`). Note deferred items (LOD auto-zoom, search, Barnes-Hut/threaded layout, TStyleManager, SQL Tier 2/3, split-screen). Strict ASCII.
- **Reconcile build scripts:** ensure `build/build_viewer.bat` matches the current dproj; if `build/build_all.bat` does not exist yet, defer its creation to Task 3 (which adds the BPLs) — but update the README references to be accurate for whatever exists after Task 3.

Commit: `chore: remove dead Layout.Reset; rewrite README for DB-direct MVVM architecture`

---

## Task 3: Package split (runtime + DB + design-time BPLs) + build_all

Create three Delphi packages under `src/dclpkg/` (design-time) and `src/pkg/` (runtime), or a single `packages/` dir — follow Delphi conventions. Each needs a `.dpk` (and ideally a `.dproj`).

1. **`DragLintGraph.dpk`** (runtime, `{$IMPLICITBUILD ON}` off; `requires rtl, vcl;`): `contains` Types, Source, ViewModel, Style, Layout, Control. NO FireDAC. Produces `DragLintGraph.bpl`.
2. **`DragLintGraphDb.dpk`** (runtime; `requires rtl, DragLintGraph, FireDAC, FireDACSqliteDriver` — use the actual FireDAC runtime package names, e.g. `FireDAC`, `FireDACCommonDriver`, `FireDACSqliteDriver`, `FireDACCommon`): `contains` Source.Db. Produces `DragLintGraphDb.bpl`.
3. **`DragLintGraphDcl.dpk`** (design-time, `{$DESIGNONLY}`; `requires designide, DragLintGraph;`): `contains` a small `DragLint.Graph.Reg` unit with `Register` calling `RegisterComponents('Delphi-RAG-Lint', [TDragLintGraphControl])` (move the `Register` out of Control.pas into the reg unit if cleaner, or keep Register in Control and just contain it). Produces `DragLintGraphDcl.bpl`.

**`build/build_all.bat`:** calls rsvars then msbuild for: `DragLintGraph.dproj`, `DragLintGraphDb.dproj`, `DragLintGraphDcl.dproj`, `src\viewer\drag_lint_graph.dproj` (Win32 Debug); then runs `pwsh tests\console\run.ps1` and `pwsh tests\autotest\run_smoke.ps1`; non-zero exit on any failure. Echo each command (per project verbose rule).

**Verify:** all three BPLs build (report .bpl paths); the viewer still builds and smoke passes; console suite green. If a FireDAC runtime package name is wrong, find the correct one from the installed packages (`C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\FireDAC*.bpl`) and use it. If design-time registration can't be fully validated without the IDE, at least confirm `DragLintGraphDcl.bpl` compiles and links `designide`.

Commit: `feat: package split - runtime + DB + design-time BPLs; build_all.bat`

---

## Self-Review checklist
- §11 packaging: runtime BPL (no FireDAC), DB BPL (FireDAC), design-time dclpkg registers the control on the 'Delphi-RAG-Lint' page; build_all builds all + runs both gates.
- §12 hardening: read-only/immutable open (no sidecars, coexists with live indexer); dead code removed; README rewritten + accurate build/run/test instructions; ASCII/CRLF.
- Console suite green throughout; viewer launch smoke green.
- If any BPL packaging step is environment-blocked (IDE-only design-time validation), document precisely what was and wasn't verified.
