# Test findings #2 -- 2026-06-01

Second-round retest of `feat/graph-viewer-real` after the F1-F5 fixes
from the 2026-05-31 doc. User ran the recipe:

```
build\build_all.bat
bin\Win32\drag_lint_graph.exe ^
  --db C:\Projects\DB\ORM3\drag-lint.sqlite ^
  --db C:\Projects\DB\SQL\drag-lint-sql.sqlite ^
  --db C:\Projects\Delphi-RAG-lint\third_party\dll-win32\drag-lint-library.sqlite
```

User verdict: **"looks promising, needs more work to be useful"**.

## What now works (confirmed against findings #1)

- F1 (hover-flicker) -- mouse-move is calm.
- F2 (click hang) -- cross-DB jump returns in seconds, not minutes; memory
  stays bounded.
- F3 (no zoom UI) -- zoom slider + Fit button visible on the right.
- F4 (no labels) -- clicking a node labels it.
- F5 (window off-screen) -- viewer comes up centered and focused.

So the priority-1 fixes from round 1 all landed. Thank you.

## What's blocking actual use

### F6 -- Single-click on a unit does not drill in

User expectation: "click a unit, see its classes/methods" -- i.e. single
click should expand the unit and reveal its children.

Current behaviour at
`src/control/DragLint.Graph.Control.pas:879-890`: `DblClick` calls
`FVM.ToggleCollapse` for nodes with children, and `FVM.NavigateTo` for
leaves. Single click only selects.

That means a first-time user, who doesn't know to double-click, sees an
inert graph. The right discoverability move is to make **single click**
on a container node (Project / Unit / Class / Record) toggle expand. Double
click can keep its current role as a deeper "navigate into".

**Suggested fix.** In `MouseDown` at `Graph.Control.pas:698-732`, after the
`FOnSelectionChange` call, if the node has children call
`FVM.ToggleCollapse(N.Id)` instead of only selecting it. Or expose a
property `ExpandOnSingleClick: Boolean` (default True) so the host can
choose. The current `DblClick` handler can stay as a fast collapse-toggle
for users who learn it.

### F7 -- single-click does not open source in the running Delphi IDE

User preference (2026-06-01 retest): **plain single-click**, not
Ctrl+click. The Ctrl modifier is an extra step that breaks the flow when
exploring -- the viewer's whole point is that you point at things and
they open. Reserve modifiers for less common actions (Shift+click =
isolate / focus, Alt+click = open in new IDE tab, etc.) if needed later.

The control already wires the source-open chain -- `MouseDown` at
`Graph.Control.pas:721-722` fires `FOnOpenSource(Self, N.Id)`, but
gated behind `ssCtrl in Shift`. Two changes needed there:
- Drop the Ctrl gate; fire `FOnOpenSource` on plain left-click for leaf
  nodes (methods, fields, properties, sql_columns). Container nodes
  (Project, Unit, Class, Record) should expand on click instead -- see
  F6 below.
- **The viewer host
  (`src/viewer/MainForm.pas` -- the only assignment site in the EXE) never
  sets `FGraph.OnOpenSource`.** Even with the gate dropped, nothing
  happens because no handler is attached.

Even when the host assigns it, there's a second problem: the viewer is a
standalone EXE in its own process. Opening the file in the **running**
Delphi IDE (rather than spawning a second instance of bds.exe) needs an
IPC mechanism. Options, lightest-first:

1. **`ShellExecuteW(0, 'open', '<file>', nil, nil, SW_SHOW)`** -- relies on
   Windows file association for `.pas`. If RAD Studio is associated and
   running, its registered DDE topic (`bds.OpenFile`) routes the file to
   the existing instance. If not, a second IDE starts -- bad UX.
2. **Named pipe to drag-lint plugin BPL.** The plugin lives inside the IDE
   process and has full OTAPI access (`IOTAActionServices.OpenFile` +
   `IOTAEditView.Position.GotoLine`). The viewer writes
   `{filepath, line}` to `\\.\pipe\drag-lint-open-source`. The plugin's
   server thread reads, marshals to the main thread, opens the file. This
   is the cleanest and what we (drag-lint side) are happy to implement on
   our end. It also gives line-precision navigation, which option 1 does
   not.
3. **Shared-file polling.** Viewer writes `%LOCALAPPDATA%\Temp\drag-lint-open.txt`
   with `filepath:line`; plugin's file-change notifier picks it up. Works
   but feels brittle.

We strongly prefer **option 2** -- happy to wire the plugin side. All we
need from the viewer is the host EXE to:

- Assign `FGraph.OnOpenSource := HandleOpenSource;` in MainForm.
- In `HandleOpenSource(Sender, NodeId)`, resolve `NodeId` to
  `(file_path, line)` via the node's source store (the same store the
  graph already reads), then write
  `<file>\t<line>\n` to `\\.\pipe\drag-lint-open-source`.

Plugin side -- our work, not yours:

- Spawn a server thread on plugin load that creates the pipe and accepts.
- On each line received, `TThread.Queue` to main thread:
  `ActSvc.OpenFile(File); EdSvc.TopView.Position.GotoLine(N)`.
- Tear the thread down on plugin Uninstall, same defensive pattern we just
  did for the hover popup.

## Smaller things noticed

- **Discoverability.** Status bar says "Click node to select | single-click
  to open source" -- but with F7 unwired the hint promises a behaviour
  that doesn't happen. Update the hint once F7 lands.
- **Empty-state on "Show all".** When the high-level view is collapsed to
  ten units, "Show all" is a great affordance. After clicking it the user
  loses the small set as a return path. A "Back to high-level" button (or
  Esc) would close the loop.

## Suggested priority

1. **F7** (single-click -> source) -- the headline feature for code
   exploration; if this works, the viewer is genuinely useful even without
   F6.
2. **F6** (single-click drill-in) -- discoverability fix, cheap.
3. The "Back to high-level" / Esc affordance.

## Re-test recipe (for round 3)

Same as before plus -- once F7 lands -- a second console with the
Delphi IDE open and the plugin BPL loaded, so the named-pipe handoff has
a listener. We'll send a separate plugin BPL when our side of the pipe
is ready.

-- drag-lint side, 2026-06-01
