# Finding F8 -- GUI froze on cold-load of a full project index -- FIXED

**From:** drag-lint side (joint live-test session on Micronite ORM3)
**To:** Delphi-RAG-Lint-Graph (viewer) designer
**Date:** 2026-06-01
**Branch:** `feat/graph-viewer-real`
**Status:** fixed + regression-tested. Console suite **44/44** (was 41; +3 F8
tests). GUI verified responsive on the real 44k-symbol ORM3 index.

Heads-up: I edited viewer-side source on this branch (the files listed at the
bottom). This note is so the change does not surprise you -- the design is
described in full and is happy to be reworked if you would have done it
differently.

---

## What happened

Launched `drag_lint_graph.exe --db C:\Projects\DB\ORM3\drag-lint.sqlite`
(27 MB, 44,310 symbols, 20,396 loaded nodes after the MaxNodes cap). The window
appeared but pegged a core and never became responsive -- 47 CPU-seconds and
"Not Responding" after ~20 s, had to kill it. The headless suite was 41/41
green the whole time.

## Root cause (three compounding parts)

1. **Load left everything expanded.** `TGraphViewModel.Reload` clears the
   collapsed set, so `NodeIsVisible` was true for nearly every node and
   `Projection` returned ~20k visible nodes.

2. **The layout ran over the entire store, on the UI thread.**
   `TDragLintGraphControl.Relayout` called `FLayout.Step(FVM.Data, ...)` --
   i.e. the whole `TGraphData`, not the visible projection. The force kernel
   (`TGraphLayout.Step`) is all-pairs repulsion, O(N^2) per iteration. Even at
   the 5-step large-graph cap that is 5 x 20,396^2 ~ 2.1 billion ops. The
   comment already flagged "Visible-only relayout is a deferred LOD
   improvement" -- that deferral is what made a real project unusable.

3. **Orphan roots bypassed the top-level cap.** `BuildHierarchy` only adopted
   rootless **units** under `@project`. ORM3 has ~7,200 *non-unit* rootless
   nodes (symbols whose parent unit did not resolve, or children detached when
   their parent row fell outside the MaxNodes cap). Those stayed free top-level
   roots that the cap -- which only governs `@project`'s direct children --
   never bounded. So even after collapsing all containers the visible set was
   7,201, not a handful.

**Why CI was blind:** nothing in `tests/` touched the control or the layout,
and no test asserted the visible-on-load count. `Perf_ORM3Load` measured only
`LoadTopology` (819 ms), never the layout.

## The fix

Visible-subset layout + collapse-to-top-level on load + adopt all orphans.

- **`DragLint.Graph.Layout.pas`** -- added `SetScale(AVisibleCount, W, H)` and
  `StepVisible(AData, AVisibleIdx, AEdgeSrc, AEdgeDst, AIterations)`. Same
  Fruchterman-Reingold math but iterating only the *visible* node indices and
  the projection's aggregated edge endpoint pairs -> O(V^2) in the visible
  count. Decoupled deliberately: it takes plain `TArray<Integer>` index arrays,
  so the layout unit still depends only on `DragLint.Graph.Types` (no
  dependency on the ViewModel/projection types). The old full-graph
  `Init`/`Step` remain but are now unused by the control.

- **`DragLint.Graph.Control.pas`**
  - `EnsureLayout(AForceAll)` builds the visible index + edge arrays from
    `CurrentProjection`, **seeds only nodes not already placed** (a revealed
    child fans out around its already-placed parent), tracks placement in a new
    `FPlaced: TDictionary<Integer,Boolean>`, then `SetScale` + `StepVisible`.
    A node keeps its world position when collapsed and revealed again.
  - `Relayout` = `EnsureLayout(True)` (full settle, re-fits the view).
  - `HandleVMChanged` now calls `EnsureLayout(False)`: an **expand** seeds and
    settles just the newly revealed nodes; a **collapse/select** places nothing
    new and returns cheaply, leaving the user's pan/zoom alone (no re-fit).
  - `FitToWindow` and `AnimTick` now operate on the visible projection, not
    the full `FVM.Data` (FitToWindow was also O(N) over all 20k and its bounds
    were wrong with most nodes unplaced/off-screen).
  - `Bind` (and `HandleVMStoreChanged`) call `FVM.CollapseAll` so the store is
    presented collapsed to its top level. **Deliberately in the View, not the
    ViewModel** -- the VM's "a fresh load is fully expanded" contract is
    relied on by `Test.Graph.ViewModel` and stays intact. (First attempt put
    collapse in `Reload` and broke 5 VM tests; reverted.)

- **`DragLint.Graph.Types.pas`** -- `BuildHierarchy` now adopts **every**
  rootless node under `@project` (was units only). `@project` becomes the
  single forest root, so the existing top-level cap bounds the orphans too.
  `Test_ProjectRootSynthesis` and the perf tests still pass (their roots are
  units).

## Regression coverage (new)

`tests/console/Test.Graph.LayoutF8.pas`, registered in the tests `.dpr`:

- `F8_CollapsedOnLoad_BoundedVisible` -- 200-unit / ~20k-node store collapses
  to **11** visible on load (deterministic).
- `F8_VisibleLayout_FastAndSpreads` -- the visible-subset layout settles in
  ~0 ms and actually separates the nodes (a degenerate engine would stack
  them).
- `F8_ORM3_ProjectionBounded` -- real ORM3 index: visible-on-load **11**
  (soft, SKIPs if the DB is absent).

## Before / after on ORM3 (44,310 symbols, 20,396 loaded nodes)

| | visible on load | cold-load CPU | responsive |
|---|---|---|---|
| before | 20,396 | 47 s+ (climbing) | no -- hung |
| after  | 11     | ~1.5 s          | yes |

## Open questions for you

1. **CollapseAll on `Bind` vs a restore flow.** I call `FVM.CollapseAll` in
   `Bind`. If you have a session-restore path that binds *after* applying a
   saved collapse set, this would clobber it. `RunLoad` is the only current
   `Bind` caller and it is a fresh load, so it is fine today -- flag if you add
   restore-then-bind.
2. **Incremental expand does not re-fit** (keeps the user's view). If you would
   rather a gentle re-fit on expand, it is a one-line change in `EnsureLayout`.
3. **Large single expansion.** Expanding one unit with thousands of direct
   members makes V large for that pass; `EnsureLayout` keeps the same
   >2000-node 5-step cap so it cannot hang, but such a node is itself an
   overwhelming view -- you may want a per-node child cap later.

## Files touched

- `src/control/DragLint.Graph.Layout.pas`  (SetScale + StepVisible)
- `src/control/DragLint.Graph.Control.pas` (EnsureLayout, FPlaced, FitToWindow,
  AnimTick, Bind, HandleVMChanged, HandleVMStoreChanged)
- `src/control/DragLint.Graph.Types.pas`   (BuildHierarchy adopts all rootless)
- `tests/console/Test.Graph.LayoutF8.pas`  (new) + `drag_lint_graph_tests.dpr`

-- drag-lint side, 2026-06-01
