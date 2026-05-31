# P4: Style + View (VCL) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Give the viewer its visual layer: a pure `DragLint.Graph.Style` (kind/edge visuals + legend — headless-testable) and a `TDragLintGraphControl` rewired into a **passive View** that renders the ViewModel's projection and forwards input to VM commands, plus the demo host wired to the real DB. Validated by headless Style tests + a GUI launch smoke.

**Architecture:** The control no longer reads `TGraphData` directly — it binds an `IGraphViewModel`, paints `VM.Projection` through `Style`, and routes mouse/keyboard to VM commands, repainting on the VM's `OnChanged`. Layout: the control runs the existing full-graph `TGraphLayout` once on (re)load and draws only the visible projection nodes (a deliberate simplification; visible-only relayout is deferred to LOD). `Style` is pure (no VCL): colors as `Cardinal` `$00RRGGBB`, shapes/dashes as enums — so it unit-tests headlessly.

**Tech Stack:** Delphi 13, VCL (`Vcl.Graphics`/`Vcl.Controls`) in the View only, `dcc32`. Strict ASCII/CRLF.

Spec: [`../specs/2026-05-31-graph-viewer-real-and-harden-design.md`](../specs/2026-05-31-graph-viewer-real-and-harden-design.md) §8, §9. Builds on P1-P3.

## Per-task protocol
Same as P2/P3: RED first, implement, GREEN (`pwsh tests\console\run.ps1`), CRLF/ASCII normalize every touched `.pas`/`.dpr` (`bareLF=0 nonAscii=0`), commit with the given message + `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Branch `feat/graph-viewer-real`. `Style` is pure (no VCL/FireDAC). The View links VCL (not FireDAC). The viewer EXE links VCL + the DB unit (FireDAC).

---

## File Structure

| File | Responsibility |
|------|----------------|
| Create `src/control/DragLint.Graph.Style.pas` | Pure node/edge visual tables + legend. Headless-tested. |
| Create `tests/console/Test.Graph.Style.pas` | Headless Style tests. |
| Modify `tests/console/drag_lint_graph_tests.dpr` | Register the Style test unit. |
| Rewrite `src/control/DragLint.Graph.Control.pas` | Passive View bound to `IGraphViewModel`; paints projection via Style; input -> VM. |
| Rewrite `src/viewer/MainForm.pas` | Build `IDbCatalog` from `--db` args; wire VM + control + detail pane. |
| Modify `tests/autotest/run_smoke.ps1` | Build viewer + launch against a DB (or SKIP); assert stays alive. |

---

## Task 1: DragLint.Graph.Style (pure, headless-tested)

- [ ] **Step 1: Create the unit** `src/control/DragLint.Graph.Style.pas`:

```pascal
unit DragLint.Graph.Style;

{ Pure visual mapping for the graph View. No VCL: colors are Cardinal
  $00RRGGBB (assignable straight to TColor), shapes/dashes are enums.
  This keeps styling headlessly unit-testable. }

interface

uses
  DragLint.Graph.Types;

type
  TNodeShape = (nsEllipse, nsBox, nsRoundBox, nsDiamond, nsHexagon,
                nsCylinder, nsTag, nsTriangle);
  TEdgeDash  = (edSolid, edDash, edBold);

  TNodeStyle = record
    Fill:  Cardinal;       { $00RRGGBB }
    Shape: TNodeShape;
  end;

  TEdgeStyle = record
    Color: Cardinal;
    Width: Integer;
    Dash:  TEdgeDash;
    Arrow: Boolean;
  end;

const
  CL_PROJECT  = Cardinal($00808080);
  CL_UNIT     = Cardinal($00C4A484);
  CL_TYPE     = Cardinal($0066D9EF);
  CL_MEMBER   = Cardinal($00A6E22E);
  CL_SQL      = Cardinal($00B5651D);   { steel/earth for SQL kinds }
  CL_OTHER    = Cardinal($00909090);
  CL_EDGE     = Cardinal($00606060);
  CL_EDGE_USES= Cardinal($007090C0);
  CL_EDGE_CALL= Cardinal($0080C080);
  CL_EDGE_TYPE= Cardinal($00C0A060);
  CL_EDGE_XDB = Cardinal($000080FF);   { cross-DB accent }

function NodeStyleFor(AKind: TGraphNodeKind): TNodeStyle;
function EdgeStyleFor(AKind: TGraphEdgeKind; const ASection: string;
  AAggregated, ACrossDb: Boolean): TEdgeStyle;

implementation

function NodeStyleFor(AKind: TGraphNodeKind): TNodeStyle;
begin
  case AKind of
    nkProject:
      begin Result.Fill := CL_PROJECT; Result.Shape := nsRoundBox; end;
    nkUnit:
      begin Result.Fill := CL_UNIT; Result.Shape := nsBox; end;
    nkClass, nkInterface, nkRecord, nkType:
      begin Result.Fill := CL_TYPE; Result.Shape := nsEllipse; end;
    nkMethod, nkProcedure, nkFunction, nkProperty, nkField, nkConst, nkVar:
      begin Result.Fill := CL_MEMBER; Result.Shape := nsEllipse; end;
    nkSqlTable, nkSqlView:
      begin Result.Fill := CL_SQL; Result.Shape := nsBox; end;
    nkSqlColumn, nkSqlDomain:
      begin Result.Fill := CL_SQL; Result.Shape := nsTag; end;
    nkSqlIndex:
      begin Result.Fill := CL_SQL; Result.Shape := nsDiamond; end;
    nkSqlTrigger:
      begin Result.Fill := CL_SQL; Result.Shape := nsHexagon; end;
    nkSqlGenerator:
      begin Result.Fill := CL_SQL; Result.Shape := nsCylinder; end;
    nkSqlProcedure:
      begin Result.Fill := CL_SQL; Result.Shape := nsRoundBox; end;
    nkSqlException:
      begin Result.Fill := CL_SQL; Result.Shape := nsTriangle; end;
    nkDfmForm:
      begin Result.Fill := CL_TYPE; Result.Shape := nsBox; end;
  else
    begin Result.Fill := CL_OTHER; Result.Shape := nsEllipse; end;
  end;
end;

function EdgeStyleFor(AKind: TGraphEdgeKind; const ASection: string;
  AAggregated, ACrossDb: Boolean): TEdgeStyle;
begin
  Result.Arrow := True;
  Result.Width := 1;
  case AKind of
    ekUses:
      begin
        Result.Color := CL_EDGE_USES;
        if SameText(ASection, 'interface') then
          Result.Dash := edSolid
        else if SameText(ASection, 'implementation') then
          Result.Dash := edDash
        else if (ASection <> '') then        { program | package }
          Result.Dash := edBold
        else
          Result.Dash := edSolid;
      end;
    ekCalls:
      begin Result.Color := CL_EDGE_CALL; Result.Dash := edSolid; end;
    ekTypeRef, ekInherits, ekImplements:
      begin Result.Color := CL_EDGE_TYPE; Result.Dash := edSolid; end;
    ekSqlTableRef:
      begin Result.Color := CL_SQL; Result.Dash := edSolid; end;
  else
    begin Result.Color := CL_EDGE; Result.Dash := edSolid; end;
  end;
  if AAggregated then
  begin
    Result.Width := 2;
    Result.Color := CL_EDGE;            { neutral for mixed/aggregated }
  end;
  if ACrossDb then
  begin
    Result.Color := CL_EDGE_XDB;
    Result.Dash := edDash;
  end;
end;

end.
```

- [ ] **Step 2: Tests** `tests/console/Test.Graph.Style.pas`:

```pascal
unit Test.Graph.Style;

interface

implementation

uses
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Style;

procedure Test_NodeStyleShapes;
begin
  Check(NodeStyleFor(nkSqlTable).Shape = nsBox, 'sql_table is a box');
  Check(NodeStyleFor(nkSqlTrigger).Shape = nsHexagon, 'sql_trigger is a hexagon');
  Check(NodeStyleFor(nkProject).Shape = nsRoundBox, 'project is a round box');
  Check(NodeStyleFor(nkMethod).Shape = nsEllipse, 'method is an ellipse');
  Check(NodeStyleFor(nkSqlTable).Fill = CL_SQL, 'sql kinds use SQL fill');
end;

procedure Test_EdgeStyleSection;
var
  S: TEdgeStyle;
begin
  S := EdgeStyleFor(ekUses, 'interface', False, False);
  Check(S.Dash = edSolid, 'interface uses = solid');
  S := EdgeStyleFor(ekUses, 'implementation', False, False);
  Check(S.Dash = edDash, 'implementation uses = dashed');
  S := EdgeStyleFor(ekUses, 'program', False, False);
  Check(S.Dash = edBold, 'program uses = bold');
  S := EdgeStyleFor(ekCalls, '', False, False);
  Check(S.Color = CL_EDGE_CALL, 'call edge has call color');
end;

procedure Test_EdgeStyleAggregatedAndCrossDb;
var
  S: TEdgeStyle;
begin
  S := EdgeStyleFor(ekCalls, '', True, False);
  Check(S.Aggregated_Width2(S), 'aggregated widens');  { see note }
  S := EdgeStyleFor(ekUses, 'interface', False, True);
  Check(S.Color = CL_EDGE_XDB, 'cross-db edge uses xdb accent');
  Check(S.Dash = edDash, 'cross-db edge dashed');
end;

initialization
  RegisterTest('NodeStyleShapes', Test_NodeStyleShapes);
  RegisterTest('EdgeStyleSection', Test_EdgeStyleSection);
  RegisterTest('EdgeStyleAggregatedAndCrossDb', Test_EdgeStyleAggregatedAndCrossDb);
end.
```

NOTE: there is no `Aggregated_Width2` helper — replace that line with a direct width check: `Check(S.Width = 2, 'aggregated widens to 2');` (the snippet above intentionally flags it; implement the direct check).

- [ ] **Step 3:** Register `Test.Graph.Style` and `DragLint.Graph.Style` in `drag_lint_graph_tests.dpr` uses. RED -> implement -> GREEN. Expected: 31 tests, 0 failed (28 + 3). Normalize `src/control/DragLint.Graph.Style.pas`, `tests/console/Test.Graph.Style.pas`, `drag_lint_graph_tests.dpr`.

Commit: `feat: pure graph Style (node/edge visuals, section dashes, cross-db) + tests`

---

## Task 2: Control -> passive View bound to IGraphViewModel

**Read the current `src/control/DragLint.Graph.Control.pas`** (Phase 0). Keep its proven pan/zoom transforms (`WorldToScreen`/`ScreenToWorld`), `TTimer`, and mouse-wheel zoom. **Transform it** as follows:

- Replace the data model: remove `FData`/`FOwnsData`/`LoadData(TGraphData)`. Add `FVM: IGraphViewModel;` and `procedure Bind(const AVM: IGraphViewModel);`. Keep `FLayout: TGraphLayout`.
- `Bind`: store VM; subscribe `FVM.SetOnChanged(HandleVMChanged)` and `FVM.SetOnStoreChanged(HandleVMChanged)`; call `Relayout`; `Invalidate`.
- `Relayout`: if VM and VM.Data have nodes, `FLayout.Init(VM.Data, Width*2, Height*2); FLayout.Step(VM.Data, 200); FitToWindow;`. (Lays out the whole store once; only visible projection nodes are drawn. Document the simplification.)
- `HandleVMChanged(Sender)`: set a `FNeedsRelayout` flag when topology may have changed (store change) — simplest: on store change call Relayout; on plain change just Invalidate. For P4, call `Relayout` only from `Bind` and `OnStoreChanged`; `OnChanged` just `Invalidate` (collapse/focus don't move nodes).
- **Paint** reads `FVM.Projection` (a `TGraphProjection`):
  - Build a quick `NodeIdx -> screen point` using `VM.Data.NodeAt(idx)^.X/.Y` through `WorldToScreen`.
  - **Edges first:** for each `TProjEdge`, get screen points of Source/TargetIdx; `Sty := EdgeStyleFor(E.Kind, <section from the edge>, E.Aggregated, <crossdb>)`. Section: the projection edge does not carry section text directly — for P4, read it from the node/edge? The VM aggregates edges and drops the raw `Label_`. SIMPLIFICATION: add a `Section: string` and `CrossDb: Boolean` field to `TProjEdge` in the ViewModel and populate them during aggregation (Section from the first underlying `ekUses` edge's `Label_`; CrossDb left False in P4 since one graph = one store). This is a small additive ViewModel change — make it in this task and add a ViewModel test asserting a collapsed uses edge carries its section. Map `TEdgeDash` -> `Canvas.Pen.Style`/width (`edSolid`->psSolid w1, `edDash`->psDash w1, `edBold`->psSolid w3). Draw line; draw arrowhead if `Sty.Arrow`.
  - **Nodes:** for each visible `TProjNode`, `NS := NodeStyleFor(VM.Data.NodeAt(idx)^.Kind)`. Brush color := TColor(NS.Fill) unless Selected/Hovered (use existing highlight colors). Draw the shape per `NS.Shape` (implement `nsEllipse`/`nsBox`/`nsRoundBox` properly; for `nsDiamond`/`nsHexagon`/`nsCylinder`/`nsTag`/`nsTriangle` a polygon/approx is fine — a labelled box fallback is acceptable for P4, but ellipse/box/roundbox must be distinct). Border: 2px accent if Selected; cyan if Hovered; red if `Deprecated`; gray-dashed if `IsExternal`; thin if undocumented (skip). If `PN.Collapsed`, draw a `+N` badge (N = `VM.Data.DescendantCount(idx)`). If `PN.Dimmed`, draw with a lightened/blended fill (e.g. average with background) to convey de-emphasis.
  - **Labels** at sufficient zoom (keep the existing zoom>=0.6 gate). For a collapsed node show `label (+N)`.
  - **Legend:** a small panel (top-left) listing the node kinds present in the current projection with a swatch + name (toggle with a published `ShowLegend: Boolean = True`).
- **Hit-testing** now runs over the projection's visible nodes (not all FData). Add edge hit-testing (distance from click to the edge segment < ~4px) returning the underlying projection edge.
- **Input -> VM commands** (replace the Phase-0 handlers):
  - left-click node -> `FVM.SelectNode(id)`; raise `OnNodeClick` for the host (keep the event for Ctrl+click open-source).
  - double-click node: if collapsible (`VM.Data.ChildrenOf(idx)` non-empty) -> `FVM.ToggleCollapse(id)`; else -> `FVM.NavigateTo(id)`.
  - click on an edge line whose kind is `ekUses` and target `IsExternal`/cross-db -> `FVM.NavigateTo(targetId)` (in-store) or raise `OnCrossDbJump(targetName)` for the host (P4: in-store NavigateTo; external target -> raise the host event).
  - `F` -> `FVM.SetFocus(SelectedId, 1)`; `Esc` -> `FVM.ClearFocus`; `Backspace` -> `if FVM.CanGoBack then FVM.Back`.
  - Ctrl+click -> raise an `OnOpenSource(id)` event (host calls `FVM.OpenSource`/ShellExecute).
  - pan/zoom unchanged.
- Keep published props (Align/Anchors/etc.); add `ShowLegend`. Add events `OnNodeClick`, `OnOpenSource`, `OnCrossDbJump`.

Validated by building the viewer in Task 3 (no headless unit test for Canvas). Add the small ViewModel `TProjEdge.Section`/`CrossDb` change + 1 headless test (`Test_VMProjEdgeSection`: collapse uA, assert the uA->uB uses edge's `Section='interface'`). Update `Fake`/builder so the uses edge in `BuildTwoUnitGraph` has `Label_:='interface'`.

Commit: `feat: control as passive View over VM projection + Style; input drives VM`

---

## Task 3: Viewer wiring + launch smoke

**Rewrite `src/viewer/MainForm.pas`:**
- Parse `--db <path>` (repeatable) into an ordered `TArray<string>`. Build `TDbCatalog.Create(paths)` (from `DragLint.Graph.Source.Db`). Create `TGraphViewModel`, `VM.SetCatalog(cat)`, `VM.OpenStore(0)`. `FGraph.Bind(VM)`.
- If no `--db` given or store 0 has zero nodes, show a friendly message in the status bar ("pass --db <drag-lint.sqlite>") and bind an empty VM (no crash).
- Detail pane (reuse the status bar + optionally a side `TMemo`): on `OnSelectionChange`/`OnNodeClick`, show `VM.SelectedDoc.Summary` and, if `HasDoc`, a one-line cref hint; wire `OnOpenSource` -> `VM.OpenSource(id)` (which uses a host opener: `ShellExecute(0,'open',PChar(file),...)` after `VM.LocateSymbol`). Wire `OnCrossDbJump(name)` -> `VM.JumpToCrossDb(name)` (in-place; the active graph swaps — this exercises the host-policy seam in its simplest form).
- Keep it a thin host; no business logic.

**Update `tests/autotest/run_smoke.ps1`:** build the viewer EXE (msbuild the dproj or dcc32 the dpr — mirror `build/build_viewer.bat`), then launch it with `--db C:\Projects\DB\ORM3\drag-lint.sqlite` if that file exists (else launch with no args). Assert the process stays alive ~3s without exiting (crash = fail), then kill it. Keep exit 0 = pass. (This is the GUI gate; the headless console suite remains the logic gate.)

Build the viewer; run `pwsh tests\autotest\run_smoke.ps1` and confirm it passes (viewer launches, renders the ORM3 graph or the no-db message, stays alive). Also re-run `pwsh tests\console\run.ps1` (still 31+ tests green).

Commit: `feat: viewer host wired to DB catalog + ViewModel; launch smoke`

---

## Self-Review checklist
- §8/§9 coverage: Style node/edge visuals incl SQL shapes + section dashes + cross-db + aggregated (T1); passive View renders projection via Style with legend, collapsed +N, dimmed, borders (T2); input -> VM commands incl collapse/navigate/focus/back/open-source (T2); host wires catalog + VM + detail pane + in-place cross-db jump (T3).
- Headless tests stay green (Style + the small ViewModel section addition); GUI validated by launch smoke (SKIP-safe if ORM3 absent).
- Pure/dep rules: Style no VCL/FireDAC; Control VCL-only; viewer links the DB unit. ASCII/CRLF everywhere.
- Simplifications documented: full-store layout on load (visible-only relayout deferred to LOD); cross-db edges not drawn within a single-store graph (jump affordance via external-node click).
