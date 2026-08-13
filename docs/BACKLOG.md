# Delphi-RAG-Lint-Graph -- Resume Doc / Backlog

Canonical cold-start pointer for this repo. Last updated: 2026-08-13.

Pure-VCL interactive graph viewer + reusable `TDragLintGraphControl` over drag-lint's
SQLite index. No WebView2/HTML/JS. Sibling repo `C:\Projects\Delphi-RAG-lint` produces
the DBs this reads.

---

## Status

- **Branch:** `feat/manifest-dbselect`.
- **Manifest-driven DB selection: CODE DONE, and now VERIFIED end-to-end.**
  [src/viewer/MainForm.pas](../src/viewer/MainForm.pas) `ResolveDbsFromEngine` shells
  out to `drag-lint.exe resolve-dbs --json [--platform <p>]` when the viewer is
  launched with no `--db`, parses the returned JSON array and populates `FDbPaths`
  (v0.45 Task 10). Arg parsing handles `--db` (repeatable) and `--platform win32|win64`.
- **Build-target work: settled** (see the platform decision below).
- **Recent shipped features** (committed on this branch):
  - `efbc126` "Where Used" = precise caller *list* in the panel (not a hairball)
  - `99c8df4` viewer publishes its HWND to the registry for editor-sync discovery
  - `8825d5c` class-level flow aggregation (trace flow from a class)
  - `1134bb7` "Where Used (focus)" leaves the drill scope so callers show
  - `daaf9bc` word-wrap flow boxes + `--flow` / `--selftest` self-diagnostics

## Package platform decision (the question this branch left open -- now RESOLVED)

The open question was whether all three BPL packages should default to Win64.
Resolution, backed by an actual build probe:

| Package | Targets | Default | Why |
|---------|---------|---------|-----|
| `DragLintGraph` (runtime core) | Win32 + Win64 | Win64 | lets 64-bit hosts consume the control |
| `DragLintGraphDb` (runtime DB) | Win32 + Win64 | Win64 | same |
| `DragLintGraphDcl` (design-time) | **Win32 only** | Win32 | `{$DESIGNONLY}`; the 32-bit IDE is its only consumer |

The Dcl flip was **reverted**. The reason is *not* that a Win64 Dcl build fails --
it was probed and it **succeeds** (exit 0). That is precisely the trap: it produces a
design-time BPL the 32-bit IDE silently cannot load, with no build error to warn you.
Reverting keeps a bare `msbuild DragLintGraphDcl.dproj` producing the IDE-loadable
Win32 BPL.

Residual (mild) footgun, accepted: a bare `msbuild DragLintGraph.dproj` now defaults to
Win64, so the Win32 `DragLintGraph.bpl`/`.dcp` that the Win32 Dcl BPL *requires* can go
stale. `build_all.bat` always passes an explicit `/p:Platform`, so the scripted path is
safe; only ad-hoc bare msbuild invocations are exposed.

## Verification performed (2026-07-29)

All green, on this working tree:

- `build\build_all.bat`: 3 packages Win32 + viewer Win64, **console suite 64/64 GREEN**,
  **GUI smoke 4/4 pass**. Only diagnostic is hint H2164 (unused `Sect` in
  `TfrmMain.TreeExpanding`, [src/viewer/MainForm.pas:934](../src/viewer/MainForm.pas#L934)).
- Runtime packages built **Win64** cleanly -> `bin\Win64\DragLintGraph.{bpl,dcp}`,
  `DragLintGraphDb.{bpl,dcp}`. `bin\Win32` artefacts untouched (separate output dirs).
- `resolve-dbs --json` contract checked: **stdout is pure JSON**, the
  `(loaded defaults from ...)` note goes to **stderr** -- so the viewer's
  `ParseJSONValue` gets clean input. Manifest currently yields 8 DBs.
- Headless viewer matrix via `--flow <sym> --selftest <log>` (exits itself), symbol
  `AssignGroups.TfrmAssignGroups.FormCreate`:

  | Case | Args | Result |
  |------|------|--------|
  | A | *no* `--db` (manifest path) | `flow boxes=5` -- DBs came from the manifest |
  | C | explicit `--db ...ORM3\drag-lint.sqlite` | `flow boxes=5` -- identical to A |
  | D | `--platform win64`, no `--db` | `flow boxes=5` -- platform forwarded OK |
  | E | negative control, bogus symbol | `flow boxes=1` -- diag is data-dependent |

  Case E matters: it proves the diagnostic can fail, so A's `boxes=5` is real evidence
  of a loaded manifest DB and not a constant the viewer prints regardless.
- `--platform` discrimination confirmed at the CLI: win32 -> `library-Win32.sqlite`,
  win64 -> `library-Win64.sqlite` (all other 7 DBs identical).

## GOTCHAS (cold-start traps)

- **Design-time BPL is Win32.** See the decision table above. Never "helpfully" flip it
  to Win64 -- it builds fine and then fails to load, which is much harder to diagnose.
- **Win32 vs Win64 storage.** The plugin (Win32 BPL) spawns
  `third_party\dll-win64\drag-lint.exe`. The Win32 `sqlite3.dll` is older SQLite -- **no
  FTS5**. Build/deploy BOTH platforms after any storage change.
- **Index lock on reindex.** `reindex ... used by another process` happens when an
  orphaned `drag_lint_graph.exe` still holds the DB after the IDE closes -- kill it first.
- **`call <script>.bat` by bare name fails here.** The environment does not resolve
  scripts from the current directory (`'build_all.bat' is not recognized`), even after
  `cd /d` into its folder. Always `call` build scripts by **absolute path**;
  `build_all.bat` uses `%~dp0` internally so it is location-independent.
- **Build recipe.** Use the `delphi-build` skill: wrapper `.bat` (rsvars -> msbuild) run
  from PowerShell `Start-Process -Wait` with output redirected to a log; then read the
  log for `BUILD_EXITCODE=0` and no `[dcc] Error`. Never the MCP build tool; never
  `cmd /c` from the Bash tool.

## Not done yet / backlog ideas

### High Priority (2026-08-13 planning)

**Side-effect badges on Code Flow View** (SPEC: `docs/superpowers/specs/2026-08-11-side-effect-badges-design.md`)
- **Phase 1 (next action):** Render transaction/resource badges on each flow step box
  - `TSideEffects = set of TSideEffect` (1 byte/node, 7 badge types: TX-start/commit/rollback, file/registry/network, var-out)
  - Query: LEFT JOIN `symbol_facts` on `s.id` (indexed on v21, unindexed on v19)
  - Parse touches+mutates_params into set at load
  - Render as badge strip (position TBD: header line or corner cluster?)
  - Fetch raw text lazily on hover for the one node under cursor
  - Support v19 (no index, still performant with node cap) and pre-v18 (no column, graceful no-badge degradation)
- Phase 2 (future): same badges on UML class box member rows
- **Why:** Code Flow View cannot show where transactions open/close or var parameters mutate -- badges make these boundaries visible without reading bodies

**CodeLens cache memory leak** — sent to drag-lint team as INBOX (delphi-plugin team owns)
- INBOX filed: `C:\Projects\Delphi-RAG-lint\docs\INBOX-codelens-cache-has-no-eviction.md`
- `FByFile: TDictionary<string,TDictionary<Integer,string>>` grows monotonically with no eviction
- Impact: 32-bit in-process DLL, IDE address space is already tight
- Suggested fixes: per-file removal on editor close OR LRU cap on FByFile

### Lower Priority

- Deferred viewer features (from README): LOD / semantic auto-zoom (progressive detail
  on zoom in). See README "Deferred (not yet implemented)".
- Optional cleanup: the H2164 unused-variable hint in `TfrmMain.TreeExpanding`.
- Consider a console test that covers `ResolveDbsFromEngine`'s JSON parsing directly
  (currently only exercised end-to-end by the headless viewer matrix above).
- Sibling linter backlog (separate repo): `C:\Projects\Delphi-RAG-lint\docs\lint\BACKLOG.md`
  section 3+.

## Reference

- IPC / open-source contract: [docs/ipc-open-source-contract.md](ipc-open-source-contract.md)
- Test findings: `docs/test-findings-*.md`
- Auto-memory: `graph-viewer-state.md` (RESUME line points back here).
