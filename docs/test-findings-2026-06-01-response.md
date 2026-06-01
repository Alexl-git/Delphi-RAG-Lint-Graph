# Response to findings #2 -- F6 / F7 implemented -- 2026-06-01

Addresses every item in `docs/test-findings-2026-06-01.md`. Branch
`feat/graph-viewer-real`. Both gates green after the change:
console **41/41** (was 36; +5 new open-source tests), GUI smoke **4/4**,
all 3 BPLs + viewer build clean.

## F6 -- single-click drills into a container

`TDragLintGraphControl.MouseDown` now, on a plain left-click:

- **container node** (has children -- Project / Unit / Class / Record):
  `FVM.ToggleCollapse` -> the unit expands to show its classes/methods, or
  collapses again. No more inert graph for first-time users.
- **leaf node** (method / field / property / sql_column): raises
  `OnOpenSource` (see F7).

Gated by a new published property `ExpandOnSingleClick` (default **True**); set
False to restore select-only behaviour. Double-click is repurposed to the
deeper "navigate into" gesture (`FVM.NavigateTo` -- expand ancestors + select);
because `NavigateTo` force-expands rather than toggles, it never flip-flops
against the single-click toggle.

## F7 -- single-click opens source (plain click, named pipe to the IDE)

- The `Ctrl` gate is **dropped**: a plain left-click on a leaf now fires
  `OnOpenSource`. `Ctrl`+click is retained as a power override that opens
  source on *any* node (including containers).
- New unit `DragLint.Graph.OpenSourceClient.pas` is the IPC client. The host
  (`MainForm.GraphOpenSource`) resolves the node to `(file, line)` via
  `LocateSymbol`, then calls `SendOpenSource`, which writes
  `<file><TAB><line><LF>` (UTF-8) to `\\.\pipe\drag-lint-open-source`.
  - **Pipe answered** -> status: `Opened in IDE: <file>:<line>`.
  - **No plugin listening** (standalone) -> fast fallback to
    `ShellExecute('open', file)`; status notes no IDE plugin was listening.
- The full wire contract + the plugin's required server/OTAPI side is written
  up for the drag-lint team in **`docs/ipc-open-source-contract.md`**, along
  with seven database questions (Q1 overload disambiguation / id-vs-qname
  payload, Q2 start_line semantics, Q3 caret column, Q4 SQL symbols, Q5 DFM
  forms, Q6 off-disk RTL symbols, Q7 schema stability).

This is option **2** (named pipe) from your findings doc, which you said you
preferred and would wire on the plugin side. The viewer holds up its half now;
we need a plugin BPL with the pipe listener to test the live handoff.

## Smaller items

- **Esc closes the loop.** `KeyDown(VK_ESCAPE)` now unwinds one level at a
  time: clear an active focus first; otherwise, if the top-level cap was
  expanded via "Show all units", collapse back to the high-level view. The
  "Show all units (N hidden)" button still flips to "Show top N units" as the
  explicit return affordance, so there are now two ways back.
- **Status-bar hint updated** to describe the real behaviour:
  `Click a unit/class to expand - click a method to open source - Shift+click
  to focus - double-click to drill in - Backspace = back`. (The old hint that
  promised an unwired behaviour is gone.)
- **Shift+click = focus** the clicked node's 1-hop neighborhood (the modifier
  you reserved for "isolate / focus").

## New tests

`tests/console/Test.Graph.OpenSource.pas` (5 tests, all green):
byte-exact framing, path-with-spaces framing, no-server fast-fail, empty-path
rejection, and a **live round-trip** against a mock byte-mode pipe server
thread (defensive timeouts so it can never hang the suite).

## Files touched

- new `src/control/DragLint.Graph.OpenSourceClient.pas`
- `src/control/DragLint.Graph.Control.pas` (F6/F7 interaction, Esc, Shift)
- `src/viewer/MainForm.pas` (pipe handoff + fallback, status hint)
- `src/pkg/DragLintGraph.dpk` + `.dproj`, `src/viewer/drag_lint_graph.dpr` +
  `.dproj` (register the new unit)
- new `tests/console/Test.Graph.OpenSource.pas` + tests `.dpr`
- new `docs/ipc-open-source-contract.md`

-- viewer side, 2026-06-01
