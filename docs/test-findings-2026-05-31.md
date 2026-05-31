# Test findings — 2026-05-31

drag-lint side report from a joint live test of `feat/graph-viewer-real` with
the user driving in the Delphi 13 IDE on Micronite. Viewer launched as:

```
drag_lint_graph.exe ^
  --db C:\Projects\DB\ORM3\drag-lint.sqlite ^
  --db C:\Projects\DB\SQL\drag-lint-sql.sqlite ^
  --db C:\Projects\Delphi-RAG-lint\third_party\dll-win32\drag-lint-library.sqlite
```

ORM3 DB ≈ 26 MB / ~16 k symbols, SQL DB ≈ 16 MB (Tier 1+2+3, fb-snapshot,
orm-links), library DB ≈ 840 MB / 1.35 M syms / 2.5 M refs. All three schema
v6.

## What worked

- All three DBs opened without schema or lock errors.
- Initial render produced a populated canvas (~10–15 k visible nodes) with the
  expected colour scheme: blue Unit cluster in the centre, green
  Method/Procedure/Function/Field/Property ring, gray Other/Project outer
  ring, yellow Class/Interface scattered.
- Legend (top-left) and status-bar hint string ("Pan: drag empty area | Zoom:
  mouse wheel | Click node to select | Ctrl+click to open source") are both
  visible and accurate.
- F-R layout converged: `TAnimTick` properly disables the timer when
  `Layout.Step` returns True. No infinite animation loop.

## Findings

### F1 — Hover-on-mouse-move triggers Invalidate, blocks interaction
Severity: **high** — makes the viewer effectively unusable on graphs this size.

`TDragLintGraphControl.MouseMove` calls `HitTestProjNode(X, Y, Proj)` every
WM_MOUSEMOVE and `Invalidate`s whenever `NewId <> FHoverId`. With ~10 k
visible nodes packed tightly, the hovered ID changes on almost every pixel
of motion, so the canvas repaints continuously while the mouse moves. The
user reported it was impossible to land a click — by the time they pressed
the button the next paint was already in flight.

`src/control/DragLint.Graph.Control.pas:754–793` — every mouse-move emits
`OnNodeHover` and `Invalidate` whenever the hovered node changes.

**Suggested fix.** Either
- debounce hover updates with a TTimer (fire only after 80–120 ms of mouse
  stillness), or
- gate `Invalidate` on a meaningful visual delta — only repaint if the new
  hover node is going to be drawn distinctly (e.g. the hover effect is
  off-screen at the current zoom). At zoomed-out scale the per-pixel hover
  change isn't visible anyway, so the paint is pure cost.

### F2 — Click on node hangs UI thread for minutes, memory grows 16×
Severity: **high** — single click made the viewer non-responsive.

After convergence the user clicked one node. The cursor changed to the SQL
busy cursor and stayed. Process probe after several minutes:

| Metric | Reading |
|---|---|
| `Process.Responding` | False |
| Threads | 7 (1 Running, 6 EventPairLow waits) |
| TID 33712 CPU | 350.5 s, still Running |
| Memory (private) | 1126 MB (was 72 MB before the click — 16× growth) |

Click handler at `src/control/DragLint.Graph.Control.pas:698–732` calls
`FVM.SelectNode(N.Id)` and then `FOnSelectionChange(Self)`. The most likely
culprit is an unbounded query firing into the library DB
(840 MB / 2.5 M refs) on the UI thread — possibly resolving all callers /
refs for the clicked symbol without a `LIMIT`. The growth from 72 MB to
1.1 GB strongly suggests a large SQLite result set is being materialised
into a TList/TArray.

**Suggested fixes.**
- Wrap every cross-DB resolve in a `LIMIT` (e.g. 500 rows) and surface a
  "showing first N of M" indicator if truncated.
- Move the resolve off the UI thread (TTask / TThread) and post a
  `TThread.Queue` back when results are ready, so the click registers and
  the form stays responsive.
- Add a cancel button or auto-cancel if the user clicks another node before
  the query finishes.

### F3 — No zoom UI; wheel zoom is insufficient at scale
Severity: **medium** — usability blocker for inspection workflows.

With the entire Micronite + SQL graph laid out, the wheel-zoom alone can't
get the user close enough to read individual node labels (which only render
above some font-size threshold inside `Paint`). The user explicitly asked
for "a zoom slider" and noted the view was "too far away and no details are
visible." There's no fit-to-selection either, so after panning across the
canvas there is no fast way to recover the overall view.

**Suggested additions.**
- Zoom slider on a side-panel (1 % … 800 %, log scale).
- Buttons / shortcuts: Fit-to-Window (already implemented as
  `FitToWindow` — just expose it), Fit-to-Selection,
  Zoom-to-Cursor (uses current mouse position as the zoom anchor instead
  of view centre — much nicer for spelunking).
- Persist last zoom level on close, restore on reopen.

### F4 — No labels at zoomed-out scale (LOD)
Severity: **medium** — known, README lists "LOD / semantic auto-zoom" under
Deferred. Calling it out anyway because it's a hard limit on testing
everything else: without labels the user can't tell which node they're
about to click, which compounds F1 and F2.

If a quick win is possible: render labels for **selected** + **hovered**
nodes only (no LOD logic needed), independent of zoom. Lets the user
explore by hover-and-read without waiting for full LOD.

### F5 — Window opens off-screen / not focused
Severity: **low** — workaround possible from PowerShell.

After launch the main form's `Visible` returned False until we forced
ShowWindow(SW_SHOWNORMAL) + SetForegroundWindow from outside. Probably an
order-of-operations issue between `FormCreate` (where DBs are opened —
likely synchronous and slow) and the WM_SHOWWINDOW the VCL would otherwise
post. Worth checking whether DB open / first layout pass is happening on
the main thread before `Application.Run` reaches its first idle.

## Suggested fix priority

1. **F1** (hover-debounce) — one-line + one timer, restores clickability.
2. **F2** (off-thread cross-DB resolve + LIMIT) — biggest UX win and the
   thing that made the user stop the test.
3. **F3** (zoom slider + fit + zoom-to-cursor) — quick to add, dramatically
   improves inspection.
4. **F4** (selected/hovered always labelled) — lightweight precursor to
   real LOD.
5. **F5** — only worth fixing if F1+F2 don't already shake it loose.

## Schema confirmation

Reader's "≥ v5" guard is fine — all three DBs in this test are v6. No
changes needed on the drag-lint side for schema; current `schema_meta` row
is `('schema_version', '6')` from
`src/storage/DRagLint.Storage.Schema.pas:6` and
`src/storage/DRagLint.Storage.SQLite.pas:305–306`.

## Re-test recipe (once fixes land)

```
build\build_all.bat
bin\Win32\drag_lint_graph.exe ^
  --db C:\Projects\DB\ORM3\drag-lint.sqlite ^
  --db C:\Projects\DB\SQL\drag-lint-sql.sqlite ^
  --db C:\Projects\Delphi-RAG-lint\third_party\dll-win32\drag-lint-library.sqlite
```

Test plan to re-run from step 1: README sections "Status" + "Run" sequence,
with the test plan items 1–6 (first-impression / hierarchy / pan-zoom /
click-collapse / cross-DB jump / SQL Tier 1 node verification).

— drag-lint side, 2026-05-31
