# P2: ViewModel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Implement `TGraphViewModel` (`IGraphViewModel`) — the pure, headless-testable heart of the viewer: a derived projection (collapse + edge aggregation + neighborhood focus), selection, lazy doc, a navigation back-stack, and cross-DB jump — all over the `IGraphSource`/`IDbCatalog` gateways from P1, driven by fakes.

**Architecture:** Near-MVVM. The ViewModel owns a `TGraphData`, loads it through `IGraphSource`, and computes a `TGraphProjection` (visible nodes + aggregated edges) on demand. No VCL, no FireDAC, no Spring4D — events are plain method-pointers (single-cast `TGraphVMNotify`), which keeps the console harness dependency-free. (Deviation from spec §7's `IEvent`: documented here; can swap to Spring4D multicast later if multiple subscribers are needed — the View only needs one.)

**Tech Stack:** Delphi 13, `dcc32` Win32, `System.Generics.Collections`. Strict ASCII/CRLF.

Spec: [`../specs/2026-05-31-graph-viewer-real-and-harden-design.md`](../specs/2026-05-31-graph-viewer-real-and-harden-design.md) §6, §7. Builds on P1 (`DragLint.Graph.Types`, `DragLint.Graph.Source`).

---

## Per-task protocol (applies to EVERY task)

1. Write the failing test(s) first; run `pwsh tests\console\run.ps1` and confirm RED (compile error or failing assertion) — except where a task note says the test passes on first compile.
2. Implement the minimal code.
3. Run `pwsh tests\console\run.ps1`; confirm GREEN (exit 0). Do not fake a pass; if the toolchain is unavailable report BLOCKED with output.
4. **CRLF/ASCII normalization (MANDATORY — Write/Edit emit LF):** for every `.pas`/`.dpr` created or modified this task, run:
```powershell
foreach($f in @(<FILES>)){
  $t=[IO.File]::ReadAllText($f); $t=($t -replace "`r`n","`n") -replace "`n","`r`n"
  [IO.File]::WriteAllText($f,$t,[Text.Encoding]::ASCII)
  $b=[IO.File]::ReadAllBytes($f);$bare=0;$na=0;for($i=0;$i -lt $b.Length;$i++){if($b[$i]-eq10 -and -not($i-gt0 -and $b[$i-1]-eq13)){$bare++};if($b[$i]-gt127){$na++}}
  Write-Host ("{0}: bareLF={1} nonAscii={2}" -f $f,$bare,$na)}
```
All files must show `bareLF=0 nonAscii=0` (replace any `?` that displaced an em-dash with `--`). Re-run the suite after normalizing to confirm still GREEN.
5. Commit with the message given in the task plus trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

All work on branch `feat/graph-viewer-real`, from `c:\Projects\Delphi-RAG-Lint-Graph`. New units are pure: `uses` only `System.*`, `DragLint.Graph.Types`, `DragLint.Graph.Source` (and the test framework in test units). NO Vcl/FireDAC/Spring.

---

## File Structure

| File | Responsibility |
|------|----------------|
| Create `src/control/DragLint.Graph.ViewModel.pas` | `TGraphProjection` types, `IGraphViewModel`, `TGraphViewModel`. |
| Create `tests/console/Test.Graph.Builders.pas` | Shared topology builders for tests (`BuildNode`, `BuildTwoUnitGraph`). |
| Create `tests/console/Fake.DbCatalog.pas` | Fake `IDbCatalog` over two in-memory stores (for Task 5). |
| Create `tests/console/Test.Graph.ViewModel.pas` | ViewModel tests (grows each task). |
| Modify `tests/console/drag_lint_graph_tests.dpr` | Register new test units. |

---

## Task 1: ViewModel skeleton — load, selection, flat projection

**Files:** Create `src/control/DragLint.Graph.ViewModel.pas`, `tests/console/Test.Graph.Builders.pas`, `tests/console/Test.Graph.ViewModel.pas`; modify `tests/console/drag_lint_graph_tests.dpr`.

- [ ] **Step 1: Shared builders** — Create `tests/console/Test.Graph.Builders.pas`:

```pascal
unit Test.Graph.Builders;

interface

uses
  DragLint.Graph.Types;

function BuildNode(const AId: string; AKind: TGraphNodeKind;
  const AParentId: string): TGraphNode;
{ Two units (uA, uB), each a class with one method; plus a call edge
  MA->MB and an interface uses edge uA->uB. Containment via ParentId.
  Caller owns the returned TGraphData and must call BuildHierarchy. }
function BuildTwoUnitGraph: TGraphData;

implementation

uses
  System.SysUtils;

function BuildNode(const AId: string; AKind: TGraphNodeKind;
  const AParentId: string): TGraphNode;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Id := AId;
  Result.Label_ := AId;
  Result.Kind := AKind;
  Result.ParentId := AParentId;
  Result.ParentIdx := -1;
  Result.Radius := 12;
end;

function BuildTwoUnitGraph: TGraphData;
var
  E: TGraphEdge;
begin
  Result := TGraphData.Create;
  Result.AddNode(BuildNode('uA', nkUnit, ''));
  Result.AddNode(BuildNode('uA.TA', nkClass, 'uA'));
  Result.AddNode(BuildNode('uA.TA.MA', nkMethod, 'uA.TA'));
  Result.AddNode(BuildNode('uB', nkUnit, ''));
  Result.AddNode(BuildNode('uB.TB', nkClass, 'uB'));
  Result.AddNode(BuildNode('uB.TB.MB', nkMethod, 'uB.TB'));

  FillChar(E, SizeOf(E), 0);
  E.SourceId := 'uA.TA.MA'; E.TargetId := 'uB.TB.MB'; E.Kind := ekCalls; E.Weight := 1.0;
  Result.AddEdge(E);
  FillChar(E, SizeOf(E), 0);
  E.SourceId := 'uA'; E.TargetId := 'uB'; E.Kind := ekUses; E.Weight := 1.0;
  Result.AddEdge(E);

  Result.BuildHierarchy;  { adds synthetic @project root over uA, uB }
end;

end.
```

- [ ] **Step 2: ViewModel unit** — Create `src/control/DragLint.Graph.ViewModel.pas`:

```pascal
unit DragLint.Graph.ViewModel;

{ Pure ViewModel: owns a TGraphData, loads it through IGraphSource, and derives
  a TGraphProjection. No VCL/FireDAC/Spring. Events are single-cast method
  pointers (the View is the sole subscriber). }

interface

uses
  System.SysUtils, System.Generics.Collections,
  DragLint.Graph.Types,
  DragLint.Graph.Source;

type
  TProjNode = record
    NodeIdx:   Integer;     { index into Data }
    Collapsed: Boolean;     { collapsed and has children (drawn with +N badge) }
    Dimmed:    Boolean;     { focus active and node outside neighborhood }
  end;

  TProjEdge = record
    SourceIdx:  Integer;    { representative visible node index }
    TargetIdx:  Integer;
    Kind:       TGraphEdgeKind;
    Count:      Integer;    { underlying edges merged into this one }
    Weight:     Double;
    Aggregated: Boolean;    { Count>1 or mixed kinds }
    Dimmed:     Boolean;
  end;

  TGraphProjection = record
    Nodes: TArray<TProjNode>;
    Edges: TArray<TProjEdge>;
  end;

  TGraphVMNotify = procedure(Sender: TObject) of object;

  IGraphViewModel = interface
    ['{B1C2D3E4-F5A6-4B7C-8D9E-0A1B2C3D4E5F}']
    procedure SetSource(const ASource: IGraphSource);
    procedure SetCatalog(const ACatalog: IDbCatalog);
    procedure OpenStore(AStoreIndex: Integer);
    function  ActiveStoreIndex: Integer;
    function  Data: TGraphData;
    function  Projection: TGraphProjection;
    procedure SelectNode(const AId: string);
    function  SelectedId: string;
    function  SelectedNodeIndex: Integer;
    function  SelectedDoc: TGraphDoc;
    procedure SetOnChanged(AValue: TGraphVMNotify);
    procedure SetOnSelectionChanged(AValue: TGraphVMNotify);
  end;

  TGraphViewModel = class(TInterfacedObject, IGraphViewModel)
  strict private
    FData:        TGraphData;
    FSource:      IGraphSource;
    FCatalog:     IDbCatalog;
    FActiveStore: Integer;
    FSelectedId:  string;
    FOnChanged:   TGraphVMNotify;
    FOnSelectionChanged: TGraphVMNotify;
    procedure DoChanged;
    procedure DoSelectionChanged;
    procedure Reload;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetSource(const ASource: IGraphSource);
    procedure SetCatalog(const ACatalog: IDbCatalog);
    procedure OpenStore(AStoreIndex: Integer);
    function  ActiveStoreIndex: Integer;
    function  Data: TGraphData;
    function  Projection: TGraphProjection;
    procedure SelectNode(const AId: string);
    function  SelectedId: string;
    function  SelectedNodeIndex: Integer;
    function  SelectedDoc: TGraphDoc;
    procedure SetOnChanged(AValue: TGraphVMNotify);
    procedure SetOnSelectionChanged(AValue: TGraphVMNotify);
  end;

implementation

constructor TGraphViewModel.Create;
begin
  inherited Create;
  FData := TGraphData.Create;
  FActiveStore := -1;
  FSelectedId := '';
end;

destructor TGraphViewModel.Destroy;
begin
  FData.Free;
  inherited;
end;

procedure TGraphViewModel.DoChanged;
begin
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

procedure TGraphViewModel.DoSelectionChanged;
begin
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
end;

procedure TGraphViewModel.Reload;
begin
  FSelectedId := '';
  FData.Clear;
  if FSource <> nil then
    FSource.LoadTopology(FData);
  DoChanged;
end;

procedure TGraphViewModel.SetSource(const ASource: IGraphSource);
begin
  FSource := ASource;
  if FSource <> nil then
    FActiveStore := FSource.StoreIndex
  else
    FActiveStore := -1;
  Reload;
end;

procedure TGraphViewModel.SetCatalog(const ACatalog: IDbCatalog);
begin
  FCatalog := ACatalog;
end;

procedure TGraphViewModel.OpenStore(AStoreIndex: Integer);
begin
  if FCatalog = nil then Exit;
  FActiveStore := AStoreIndex;
  FSource := FCatalog.SourceForStore(AStoreIndex);
  Reload;
end;

function TGraphViewModel.ActiveStoreIndex: Integer;
begin
  Result := FActiveStore;
end;

function TGraphViewModel.Data: TGraphData;
begin
  Result := FData;
end;

function TGraphViewModel.Projection: TGraphProjection;
var
  Nodes: TList<TProjNode>;
  Edges: TList<TProjEdge>;
  I, SI, TI: Integer;
  PN: TProjNode;
  PE: TProjEdge;
  E: TGraphEdge;
begin
  Nodes := TList<TProjNode>.Create;
  Edges := TList<TProjEdge>.Create;
  try
    for I := 0 to FData.NodeCount - 1 do
    begin
      PN.NodeIdx := I;
      PN.Collapsed := False;
      PN.Dimmed := False;
      Nodes.Add(PN);
    end;
    for I := 0 to FData.EdgeCount - 1 do
    begin
      E := FData.EdgeAt(I);
      if E.Kind = ekContains then Continue;
      SI := FData.FindNodeIndex(E.SourceId);
      TI := FData.FindNodeIndex(E.TargetId);
      if (SI < 0) or (TI < 0) or (SI = TI) then Continue;
      PE.SourceIdx := SI;
      PE.TargetIdx := TI;
      PE.Kind := E.Kind;
      PE.Count := 1;
      PE.Weight := E.Weight;
      PE.Aggregated := False;
      PE.Dimmed := False;
      Edges.Add(PE);
    end;
    Result.Nodes := Nodes.ToArray;
    Result.Edges := Edges.ToArray;
  finally
    Nodes.Free;
    Edges.Free;
  end;
end;

procedure TGraphViewModel.SelectNode(const AId: string);
begin
  FSelectedId := AId;
  DoSelectionChanged;
end;

function TGraphViewModel.SelectedId: string;
begin
  Result := FSelectedId;
end;

function TGraphViewModel.SelectedNodeIndex: Integer;
begin
  if FSelectedId = '' then
    Result := -1
  else
    Result := FData.FindNodeIndex(FSelectedId);
end;

function TGraphViewModel.SelectedDoc: TGraphDoc;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (FSource <> nil) and (FSelectedId <> '') then
    Result := FSource.GetDoc(FSelectedId);
end;

procedure TGraphViewModel.SetOnChanged(AValue: TGraphVMNotify);
begin
  FOnChanged := AValue;
end;

procedure TGraphViewModel.SetOnSelectionChanged(AValue: TGraphVMNotify);
begin
  FOnSelectionChanged := AValue;
end;

end.
```

- [ ] **Step 3: Tests** — Create `tests/console/Test.Graph.ViewModel.pas`:

```pascal
unit Test.Graph.ViewModel;

interface

implementation

uses
  System.SysUtils,
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  DragLint.Graph.ViewModel,
  Test.Graph.Builders,
  Fake.GraphSource;

var
  GChangeCount: Integer;
  GSelectCount: Integer;

type
  TEventSink = class
    procedure OnChanged(Sender: TObject);
    procedure OnSelection(Sender: TObject);
  end;

procedure TEventSink.OnChanged(Sender: TObject);
begin
  Inc(GChangeCount);
end;

procedure TEventSink.OnSelection(Sender: TObject);
begin
  Inc(GSelectCount);
end;

procedure Test_VMLoadsViaSource;
var
  VM: IGraphViewModel;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TFakeGraphSource.Create);
  CheckEqualsInt(4, VM.Data.NodeCount, '3 fixture nodes + project');
  CheckEqualsInt(0, VM.ActiveStoreIndex, 'active store from source');
end;

procedure Test_VMSelectionFiresEvent;
var
  VM: IGraphViewModel;
  Sink: TEventSink;
begin
  Sink := TEventSink.Create;
  try
    GSelectCount := 0;
    VM := TGraphViewModel.Create;
    VM.SetOnSelectionChanged(Sink.OnSelection);
    VM.SetSource(TFakeGraphSource.Create);
    VM.SelectNode('U.TFoo');
    CheckEqualsStr('U.TFoo', VM.SelectedId, 'selected id stored');
    Check(VM.SelectedNodeIndex >= 0, 'selected index resolved');
    CheckEqualsInt(1, GSelectCount, 'selection event fired once');
  finally
    Sink.Free;
  end;
end;

procedure Test_VMFlatProjection;
var
  VM: IGraphViewModel;
  Data: TGraphData;
  Proj: TGraphProjection;
begin
  { Use the richer two-unit graph via a source that returns it. }
  Data := BuildTwoUnitGraph;  { 6 + project = 7 nodes; 2 non-contains edges }
  VM := TGraphViewModel.Create;
  try
    VM.SetSource(TPreloadedSource.Create(Data)); { Data ownership transfers to source }
    Proj := VM.Projection;
    CheckEqualsInt(7, Length(Proj.Nodes), 'all nodes visible when nothing collapsed');
    CheckEqualsInt(2, Length(Proj.Edges), 'two non-containment edges (call + uses)');
  finally
    { VM frees its own internal Data; TPreloadedSource frees the graph it built into. }
  end;
end;

initialization
  RegisterTest('VMLoadsViaSource', Test_VMLoadsViaSource);
  RegisterTest('VMSelectionFiresEvent', Test_VMSelectionFiresEvent);
  RegisterTest('VMFlatProjection', Test_VMFlatProjection);
end.
```

Note: `Test_VMFlatProjection` needs a source that loads a *specific* prebuilt graph. Add a tiny `TPreloadedSource` to `Fake.GraphSource.pas` (Step 4) that copies a prebuilt `TGraphData` into the VM's `TGraphData` on `LoadTopology`.

- [ ] **Step 4: Preloaded source** — In `tests/console/Fake.GraphSource.pas`, add a second class. Append to the `interface` `type` section:

```pascal
  { Loads a caller-supplied topology (built by Test.Graph.Builders) into the
    VM's TGraphData by copying nodes + edges, then rebuilding the hierarchy.
    Owns and frees the template graph. }
  TPreloadedSource = class(TInterfacedObject, IGraphSource)
  strict private
    FTemplate: TGraphData;
  public
    constructor Create(ATemplate: TGraphData);
    destructor Destroy; override;
    function StoreIndex: Integer;
    function LoadTopology(AData: TGraphData): Boolean;
    function GetDoc(const AQName: string): TGraphDoc;
    function ResolveCref(const AText: string): TCrefResolution;
    function LocateSymbol(const AQName: string; out AFile: string;
      out ALine: Integer): Boolean;
  end;
```

Add to the `implementation`:

```pascal
constructor TPreloadedSource.Create(ATemplate: TGraphData);
begin
  inherited Create;
  FTemplate := ATemplate;
end;

destructor TPreloadedSource.Destroy;
begin
  FTemplate.Free;
  inherited;
end;

function TPreloadedSource.StoreIndex: Integer;
begin
  Result := 0;
end;

function TPreloadedSource.LoadTopology(AData: TGraphData): Boolean;
var
  I: Integer;
  N: TGraphNode;
begin
  if AData = nil then Exit(False);
  AData.Clear;
  for I := 0 to FTemplate.NodeCount - 1 do
  begin
    N := FTemplate.NodeAt(I)^;   { copy the value record }
    N.ParentIdx := -1;            { re-resolved by BuildHierarchy }
    AData.AddNode(N);
  end;
  for I := 0 to FTemplate.EdgeCount - 1 do
    AData.AddEdge(FTemplate.EdgeAt(I));
  AData.BuildHierarchy;
  Result := True;
end;

function TPreloadedSource.GetDoc(const AQName: string): TGraphDoc;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function TPreloadedSource.ResolveCref(const AText: string): TCrefResolution;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Text := AText;
  Result.Kind := crkUnresolved;
end;

function TPreloadedSource.LocateSymbol(const AQName: string; out AFile: string;
  out ALine: Integer): Boolean;
begin
  AFile := '';
  ALine := 0;
  Result := False;
end;
```

IMPORTANT: the template built by `BuildTwoUnitGraph` already called `BuildHierarchy`, so it contains a synthetic `@project` node. Copying all nodes (including `@project`) and re-running `BuildHierarchy` is idempotent: `@project` already exists so no second one is synthesized, and `uA`/`uB` already carry no explicit ParentId but get re-parented to the existing `@project`. Net: 7 nodes. (Verify this in the test; if a second project node appears, the copy loop must skip nodes whose `Kind = nkProject` — but it should not, because synthesis reuses an existing project node.)

- [ ] **Step 5: Register units** — In `tests/console/drag_lint_graph_tests.dpr` `uses`, add after the existing entries:

```pascal
  DragLint.Graph.ViewModel in '..\..\src\control\DragLint.Graph.ViewModel.pas',
  Test.Graph.Builders in 'Test.Graph.Builders.pas',
  Test.Graph.ViewModel in 'Test.Graph.ViewModel.pas',
```

- [ ] **Step 6:** Follow the per-task protocol. FILES for normalization: `src\control\DragLint.Graph.ViewModel.pas`, `tests\console\Test.Graph.Builders.pas`, `tests\console\Fake.GraphSource.pas`, `tests\console\Test.Graph.ViewModel.pas`, `tests\console\drag_lint_graph_tests.dpr`. Expect 10 tests, 0 failed.

Commit message: `feat: graph viewmodel skeleton - load, selection, flat projection`

---

## Task 2: Collapse / expand + visibility

**Files:** Modify `src/control/DragLint.Graph.ViewModel.pas`, `tests/console/Test.Graph.ViewModel.pas`.

- [ ] **Step 1: Tests first** — add to `Test.Graph.ViewModel.pas`:

```pascal
procedure Test_VMCollapseHidesDescendants;
var
  VM: IGraphViewModel;
  Proj: TGraphProjection;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.Collapse('uA');
  Proj := VM.Projection;
  { hidden: uA.TA, uA.TA.MA. visible: @project, uA(collapsed), uB, uB.TB, uB.TB.MB }
  CheckEqualsInt(5, Length(Proj.Nodes), 'collapsing uA hides its 2 descendants');
end;

procedure Test_VMCollapseReroutesEdge;
var
  VM: IGraphViewModel;
  Proj: TGraphProjection;
  I, UaIdx, MbIdx, CallCount: Integer;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.Collapse('uA');
  Proj := VM.Projection;
  UaIdx := VM.Data.FindNodeIndex('uA');
  MbIdx := VM.Data.FindNodeIndex('uB.TB.MB');
  CallCount := 0;
  for I := 0 to High(Proj.Edges) do
    if (Proj.Edges[I].Kind = ekCalls) and (Proj.Edges[I].SourceIdx = UaIdx)
       and (Proj.Edges[I].TargetIdx = MbIdx) then
      Inc(CallCount);
  CheckEqualsInt(1, CallCount, 'MA->MB call reroutes to uA->MB when uA collapsed');
end;

procedure Test_VMExpandRestores;
var
  VM: IGraphViewModel;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.Collapse('uA');
  CheckEqualsInt(5, Length(VM.Projection.Nodes), 'collapsed');
  VM.Expand('uA');
  CheckEqualsInt(7, Length(VM.Projection.Nodes), 'expanded back to full');
  VM.CollapseAll;
  { CollapseAll collapses every node with children; only roots + their direct... }
  Check(Length(VM.Projection.Nodes) < 7, 'collapse-all reduces visible nodes');
  VM.ExpandAll;
  CheckEqualsInt(7, Length(VM.Projection.Nodes), 'expand-all restores full');
end;
```

Register all three.

- [ ] **Step 2: Add collapse state + methods to the interface and class.** In `IGraphViewModel` add:

```pascal
    procedure Collapse(const AId: string);
    procedure Expand(const AId: string);
    procedure ToggleCollapse(const AId: string);
    procedure CollapseAll;
    procedure ExpandAll;
    function  IsCollapsed(const AId: string): Boolean;
```

In `TGraphViewModel` `strict private` add `FCollapsed: TDictionary<string, Boolean>;` and helpers:

```pascal
    function NodeHasChildren(AIndex: Integer): Boolean;
    function NodeIsCollapsed(AIndex: Integer): Boolean;  { collapsed AND has children }
    function NodeIsVisible(AIndex: Integer): Boolean;     { no collapsed ancestor }
    function RepresentativeOf(AIndex: Integer): Integer;  { nearest visible ancestor-or-self; -1 if none }
```

Create/free `FCollapsed` in constructor/destructor (`TDictionary<string,Boolean>.Create`). In `Reload`, add `FCollapsed.Clear;` before reloading (fresh graph = nothing collapsed).

Add the public method bodies and helpers:

```pascal
function TGraphViewModel.NodeHasChildren(AIndex: Integer): Boolean;
begin
  Result := Length(FData.ChildrenOf(AIndex)) > 0;
end;

function TGraphViewModel.NodeIsCollapsed(AIndex: Integer): Boolean;
var
  Id: string;
begin
  Id := FData.NodeAt(AIndex).Id;
  Result := FCollapsed.ContainsKey(Id) and NodeHasChildren(AIndex);
end;

function TGraphViewModel.NodeIsVisible(AIndex: Integer): Boolean;
var
  P: Integer;
begin
  P := FData.ParentIndexOf(AIndex);
  while P >= 0 do
  begin
    if NodeIsCollapsed(P) then Exit(False);
    P := FData.ParentIndexOf(P);
  end;
  Result := True;
end;

function TGraphViewModel.RepresentativeOf(AIndex: Integer): Integer;
var
  Cur: Integer;
begin
  if NodeIsVisible(AIndex) then Exit(AIndex);
  Cur := FData.ParentIndexOf(AIndex);
  while Cur >= 0 do
  begin
    if NodeIsVisible(Cur) then Exit(Cur);
    Cur := FData.ParentIndexOf(Cur);
  end;
  Result := -1;
end;

procedure TGraphViewModel.Collapse(const AId: string);
begin
  FCollapsed.AddOrSetValue(AId, True);
  DoChanged;
end;

procedure TGraphViewModel.Expand(const AId: string);
begin
  FCollapsed.Remove(AId);
  DoChanged;
end;

procedure TGraphViewModel.ToggleCollapse(const AId: string);
begin
  if FCollapsed.ContainsKey(AId) then
    FCollapsed.Remove(AId)
  else
    FCollapsed.AddOrSetValue(AId, True);
  DoChanged;
end;

procedure TGraphViewModel.CollapseAll;
var
  I: Integer;
begin
  FCollapsed.Clear;
  for I := 0 to FData.NodeCount - 1 do
    if NodeHasChildren(I) then
      FCollapsed.AddOrSetValue(FData.NodeAt(I).Id, True);
  DoChanged;
end;

procedure TGraphViewModel.ExpandAll;
begin
  FCollapsed.Clear;
  DoChanged;
end;

function TGraphViewModel.IsCollapsed(const AId: string): Boolean;
begin
  Result := FCollapsed.ContainsKey(AId);
end;
```

- [ ] **Step 3: Rewrite `Projection`** so node visibility and edge rerouting honor collapse. Replace the `Projection` body with:

```pascal
function TGraphViewModel.Projection: TGraphProjection;
var
  Nodes: TList<TProjNode>;
  Edges: TList<TProjEdge>;
  I, SI, TI: Integer;
  PN: TProjNode;
  PE: TProjEdge;
  E: TGraphEdge;
begin
  Nodes := TList<TProjNode>.Create;
  Edges := TList<TProjEdge>.Create;
  try
    for I := 0 to FData.NodeCount - 1 do
      if NodeIsVisible(I) then
      begin
        PN.NodeIdx := I;
        PN.Collapsed := NodeIsCollapsed(I);
        PN.Dimmed := False;
        Nodes.Add(PN);
      end;
    for I := 0 to FData.EdgeCount - 1 do
    begin
      E := FData.EdgeAt(I);
      if E.Kind = ekContains then Continue;
      SI := RepresentativeOf(FData.FindNodeIndex(E.SourceId));
      TI := RepresentativeOf(FData.FindNodeIndex(E.TargetId));
      if (SI < 0) or (TI < 0) or (SI = TI) then Continue;
      PE.SourceIdx := SI;
      PE.TargetIdx := TI;
      PE.Kind := E.Kind;
      PE.Count := 1;
      PE.Weight := E.Weight;
      PE.Aggregated := False;
      PE.Dimmed := False;
      Edges.Add(PE);
    end;
    Result.Nodes := Nodes.ToArray;
    Result.Edges := Edges.ToArray;
  finally
    Nodes.Free;
    Edges.Free;
  end;
end;
```

(Note: `FindNodeIndex` may return -1 for an unknown id; `RepresentativeOf(-1)` must return -1. Guard it: at the top of `RepresentativeOf`, `if AIndex < 0 then Exit(-1);`. Add that guard.)

- [ ] **Step 4:** Per-task protocol. FILES: `src\control\DragLint.Graph.ViewModel.pas`, `tests\console\Test.Graph.ViewModel.pas`. Expect 13 tests, 0 failed.

Commit: `feat: viewmodel collapse/expand with visibility + edge rerouting`

---

## Task 3: Edge aggregation (merge duplicates, mixed kinds)

**Files:** Modify `src/control/DragLint.Graph.ViewModel.pas`, `tests/console/Test.Graph.ViewModel.pas`.

- [ ] **Step 1: Test first:**

```pascal
procedure Test_VMEdgeAggregation;
var
  VM: IGraphViewModel;
  Proj: TGraphProjection;
  I, UaIdx, UbIdx, Found: Integer;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.Collapse('uA');
  VM.Collapse('uB');
  Proj := VM.Projection;
  { Now MA->MB (calls) reroutes to uA->uB, and uA->uB (uses) already exists.
    Two underlying edges between the same (uA,uB) pair with different kinds
    must merge into ONE aggregated edge. }
  UaIdx := VM.Data.FindNodeIndex('uA');
  UbIdx := VM.Data.FindNodeIndex('uB');
  Found := 0;
  for I := 0 to High(Proj.Edges) do
    if (Proj.Edges[I].SourceIdx = UaIdx) and (Proj.Edges[I].TargetIdx = UbIdx) then
    begin
      Inc(Found);
      CheckEqualsInt(2, Proj.Edges[I].Count, 'merged edge counts 2 underlying');
      Check(Proj.Edges[I].Aggregated, 'mixed-kind merged edge is aggregated');
      Check(Proj.Edges[I].Kind = ekOther, 'mixed kinds collapse to ekOther');
    end;
  CheckEqualsInt(1, Found, 'exactly one merged uA->uB edge');
end;
```

Register it.

- [ ] **Step 2:** Replace the edge-building portion of `Projection` with a merging version. Keep the node loop unchanged; replace the edge loop and array assignment. Use a dictionary keyed by an ordered pair string. Add `System.Generics.Defaults` is NOT needed; use a `TDictionary<string, Integer>` mapping `"src|dst"` to an index into the `Edges` list:

```pascal
    { edges with merge by (src,dst) pair }
    EdgeKey := TDictionary<string, Integer>.Create;
    try
      for I := 0 to FData.EdgeCount - 1 do
      begin
        E := FData.EdgeAt(I);
        if E.Kind = ekContains then Continue;
        SI := RepresentativeOf(FData.FindNodeIndex(E.SourceId));
        TI := RepresentativeOf(FData.FindNodeIndex(E.TargetId));
        if (SI < 0) or (TI < 0) or (SI = TI) then Continue;
        Key := IntToStr(SI) + '|' + IntToStr(TI);
        if EdgeKey.TryGetValue(Key, EI) then
        begin
          PE := Edges[EI];
          Inc(PE.Count);
          PE.Weight := PE.Weight + E.Weight;
          if PE.Kind <> E.Kind then PE.Kind := ekOther;
          PE.Aggregated := True;
          Edges[EI] := PE;
        end
        else
        begin
          PE.SourceIdx := SI;
          PE.TargetIdx := TI;
          PE.Kind := E.Kind;
          PE.Count := 1;
          PE.Weight := E.Weight;
          PE.Aggregated := False;
          PE.Dimmed := False;
          EdgeKey.Add(Key, Edges.Count);
          Edges.Add(PE);
        end;
      end;
    finally
      EdgeKey.Free;
    end;
```

Declare the extra locals in `Projection`: `EdgeKey: TDictionary<string, Integer>; Key: string; EI: Integer;`. (`Aggregated` becomes True whenever `Count>1`, including same-kind duplicates — that matches the spec.)

- [ ] **Step 3:** Per-task protocol. FILES: `src\control\DragLint.Graph.ViewModel.pas`, `tests\console\Test.Graph.ViewModel.pas`. Expect 14 tests, 0 failed. Re-confirm Task 2's `Test_VMCollapseReroutesEdge` still passes (single uA->MB edge before uB is collapsed).

Commit: `feat: viewmodel edge aggregation (merge duplicates, mixed->aggregated)`

---

## Task 4: Neighborhood focus

**Files:** Modify `src/control/DragLint.Graph.ViewModel.pas`, `tests/console/Test.Graph.ViewModel.pas`.

- [ ] **Step 1: Tests first:**

```pascal
procedure Test_VMFocusDims;
var
  VM: IGraphViewModel;
  Proj: TGraphProjection;
  I, DimmedCount: Integer;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.CollapseAll;                 { reduce to unit-level: @project, uA, uB }
  VM.SetFocus('uA', 1);           { neighborhood: uA + uB (uses edge) }
  Proj := VM.Projection;
  DimmedCount := 0;
  for I := 0 to High(Proj.Nodes) do
    if Proj.Nodes[I].Dimmed then Inc(DimmedCount);
  { @project is not adjacent to uA in projection edges, so it should be dimmed;
    uA (focus) and uB (1 hop) are not dimmed. }
  CheckEqualsInt(1, DimmedCount, 'only @project dimmed at 1 hop from uA');
  Check(Length(Proj.Nodes) = 3, 'dim mode keeps all nodes visible');
end;

procedure Test_VMFocusIsolateHides;
var
  VM: IGraphViewModel;
  Proj: TGraphProjection;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.CollapseAll;
  VM.SetIsolate(True);
  VM.SetFocus('uA', 1);
  Proj := VM.Projection;
  CheckEqualsInt(2, Length(Proj.Nodes), 'isolate hides non-neighbors (uA + uB only)');
end;

procedure Test_VMClearFocus;
var
  VM: IGraphViewModel;
  I, DimmedCount: Integer;
  Proj: TGraphProjection;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.CollapseAll;
  VM.SetFocus('uA', 1);
  VM.ClearFocus;
  Proj := VM.Projection;
  DimmedCount := 0;
  for I := 0 to High(Proj.Nodes) do
    if Proj.Nodes[I].Dimmed then Inc(DimmedCount);
  CheckEqualsInt(0, DimmedCount, 'clearing focus undims all');
end;
```

Register all three.

- [ ] **Step 2: Interface additions:**

```pascal
    procedure SetFocus(const AId: string; AHops: Integer = 1);
    procedure ClearFocus;
    function  GetIsolate: Boolean;
    procedure SetIsolate(AValue: Boolean);
```

`strict private` fields: `FFocusId: string; FFocusHops: Integer; FIsolate: Boolean;`. Initialize in constructor (`FFocusId := ''; FFocusHops := 1; FIsolate := False;`) and reset `FFocusId := ''` in `Reload`.

Bodies:

```pascal
procedure TGraphViewModel.SetFocus(const AId: string; AHops: Integer);
begin
  FFocusId := AId;
  if AHops < 0 then AHops := 0;
  FFocusHops := AHops;
  DoChanged;
end;

procedure TGraphViewModel.ClearFocus;
begin
  FFocusId := '';
  DoChanged;
end;

function TGraphViewModel.GetIsolate: Boolean;
begin
  Result := FIsolate;
end;

procedure TGraphViewModel.SetIsolate(AValue: Boolean);
begin
  if FIsolate <> AValue then
  begin
    FIsolate := AValue;
    DoChanged;
  end;
end;
```

- [ ] **Step 3: Apply focus in `Projection`.** After the node + edge lists are built (visible projection) but BEFORE assigning to `Result`, compute the neighborhood and mark Dimmed / drop. Insert this block after the edge loop, before `Result.Nodes := ...`:

```pascal
    { focus: BFS over the visible projection graph from the focus node's
      representative, marking nodes within FFocusHops as in-neighborhood. }
    if FFocusId <> '' then
    begin
      FocusRep := RepresentativeOf(FData.FindNodeIndex(FFocusId));
      if FocusRep >= 0 then
      begin
        InHood := TDictionary<Integer, Boolean>.Create;
        try
          ComputeNeighborhood(FocusRep, FFocusHops, Edges, InHood);
          { mark node Dimmed when not in neighborhood }
          for I := 0 to Nodes.Count - 1 do
          begin
            PN := Nodes[I];
            PN.Dimmed := not InHood.ContainsKey(PN.NodeIdx);
            Nodes[I] := PN;
          end;
          { dim edges touching a dimmed node }
          for I := 0 to Edges.Count - 1 do
          begin
            PE := Edges[I];
            PE.Dimmed := (not InHood.ContainsKey(PE.SourceIdx))
                      or (not InHood.ContainsKey(PE.TargetIdx));
            Edges[I] := PE;
          end;
          if FIsolate then
          begin
            for I := Nodes.Count - 1 downto 0 do
              if Nodes[I].Dimmed then Nodes.Delete(I);
            for I := Edges.Count - 1 downto 0 do
              if Edges[I].Dimmed then Edges.Delete(I);
          end;
        finally
          InHood.Free;
        end;
      end;
    end;
```

Declare locals in `Projection`: `FocusRep: Integer; InHood: TDictionary<Integer, Boolean>;`. Add a private helper:

```pascal
procedure TGraphViewModel.ComputeNeighborhood(AStart, AHops: Integer;
  AEdges: TList<TProjEdge>; ASet: TDictionary<Integer, Boolean>);
var
  Frontier, Next: TList<Integer>;
  Hop, I, J, N: Integer;
begin
  ASet.AddOrSetValue(AStart, True);
  Frontier := TList<Integer>.Create;
  Next := TList<Integer>.Create;
  try
    Frontier.Add(AStart);
    for Hop := 1 to AHops do
    begin
      Next.Clear;
      for I := 0 to Frontier.Count - 1 do
      begin
        N := Frontier[I];
        for J := 0 to AEdges.Count - 1 do
        begin
          if AEdges[J].SourceIdx = N then
            if not ASet.ContainsKey(AEdges[J].TargetIdx) then
            begin ASet.AddOrSetValue(AEdges[J].TargetIdx, True); Next.Add(AEdges[J].TargetIdx); end;
          if AEdges[J].TargetIdx = N then
            if not ASet.ContainsKey(AEdges[J].SourceIdx) then
            begin ASet.AddOrSetValue(AEdges[J].SourceIdx, True); Next.Add(AEdges[J].SourceIdx); end;
        end;
      end;
      Frontier.Clear;
      Frontier.AddRange(Next);
    end;
  finally
    Frontier.Free;
    Next.Free;
  end;
end;
```

Declare `ComputeNeighborhood` in `strict private` with matching signature (it takes the `TList<TProjEdge>` built in `Projection`; since `TProjEdge`/`TList<TProjEdge>` are in this unit, that is fine).

- [ ] **Step 4:** Per-task protocol. FILES: `src\control\DragLint.Graph.ViewModel.pas`, `tests\console\Test.Graph.ViewModel.pas`. Expect 17 tests, 0 failed.

Commit: `feat: viewmodel neighborhood focus (dim/isolate, N-hop)`

---

## Task 5: Navigation back-stack + cross-DB jump + cref/locate delegation

**Files:** Modify `src/control/DragLint.Graph.ViewModel.pas`; create `tests/console/Fake.DbCatalog.pas`; modify `tests/console/Test.Graph.ViewModel.pas` and `tests/console/drag_lint_graph_tests.dpr`.

- [ ] **Step 1: Fake catalog** — Create `tests/console/Fake.DbCatalog.pas`:

```pascal
unit Fake.DbCatalog;

{ Two-store catalog for cross-DB tests. Store 0 contains 'A.TThing';
  store 1 contains 'B.TOther'. ResolveAcrossStores finds a qname in the
  first store (priority order) that declares it. }

interface

uses
  System.SysUtils,
  DragLint.Graph.Types,
  DragLint.Graph.Source;

type
  TStoreSource = class(TInterfacedObject, IGraphSource)
  strict private
    FIndex: Integer;
    FRootId: string;
  public
    constructor Create(AIndex: Integer; const ARootId: string);
    function StoreIndex: Integer;
    function LoadTopology(AData: TGraphData): Boolean;
    function GetDoc(const AQName: string): TGraphDoc;
    function ResolveCref(const AText: string): TCrefResolution;
    function LocateSymbol(const AQName: string; out AFile: string;
      out ALine: Integer): Boolean;
  end;

  TFakeDbCatalog = class(TInterfacedObject, IDbCatalog)
  public
    function StoreCount: Integer;
    function StorePath(AIndex: Integer): string;
    function SourceForStore(AIndex: Integer): IGraphSource;
    function ResolveAcrossStores(const AName: string): TCrossDbResolution;
  end;

implementation

function MakeUnitNode(const AId: string): TGraphNode;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Id := AId; Result.Label_ := AId; Result.Kind := nkUnit;
  Result.ParentId := ''; Result.ParentIdx := -1; Result.Radius := 12;
end;

constructor TStoreSource.Create(AIndex: Integer; const ARootId: string);
begin
  inherited Create;
  FIndex := AIndex;
  FRootId := ARootId;
end;

function TStoreSource.StoreIndex: Integer;
begin
  Result := FIndex;
end;

function TStoreSource.LoadTopology(AData: TGraphData): Boolean;
begin
  if AData = nil then Exit(False);
  AData.Clear;
  AData.AddNode(MakeUnitNode(FRootId));
  AData.BuildHierarchy;
  Result := True;
end;

function TStoreSource.GetDoc(const AQName: string): TGraphDoc;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function TStoreSource.ResolveCref(const AText: string): TCrefResolution;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Text := AText;
  Result.Kind := crkUnresolved;
end;

function TStoreSource.LocateSymbol(const AQName: string; out AFile: string;
  out ALine: Integer): Boolean;
begin
  AFile := ''; ALine := 0; Result := False;
end;

function TFakeDbCatalog.StoreCount: Integer;
begin
  Result := 2;
end;

function TFakeDbCatalog.StorePath(AIndex: Integer): string;
begin
  Result := Format('store%d.sqlite', [AIndex]);
end;

function TFakeDbCatalog.SourceForStore(AIndex: Integer): IGraphSource;
begin
  if AIndex = 0 then
    Result := TStoreSource.Create(0, 'A')
  else
    Result := TStoreSource.Create(1, 'B');
end;

function TFakeDbCatalog.ResolveAcrossStores(const AName: string): TCrossDbResolution;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Found := False;
  if AName = 'B' then
  begin
    Result.Found := True;
    Result.StoreIndex := 1;
    Result.TargetId := 'B';
  end
  else if AName = 'A' then
  begin
    Result.Found := True;
    Result.StoreIndex := 0;
    Result.TargetId := 'A';
  end;
end;

end.
```

- [ ] **Step 2: Tests** — add to `Test.Graph.ViewModel.pas` (and add `Fake.DbCatalog` to its `uses`):

```pascal
procedure Test_VMNavBackStack;
var
  VM: IGraphViewModel;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.SelectNode('uA');
  Check(not VM.CanGoBack, 'no history initially');
  VM.NavigateTo('uB');
  CheckEqualsStr('uB', VM.SelectedId, 'navigated to uB');
  Check(VM.CanGoBack, 'history after navigate');
  VM.Back;
  CheckEqualsStr('uA', VM.SelectedId, 'back restores prior selection');
  Check(not VM.CanGoBack, 'history empty after back');
end;

procedure Test_VMCrossDbJump;
var
  VM: IGraphViewModel;
  Res: TCrossDbResolution;
begin
  VM := TGraphViewModel.Create;
  VM.SetCatalog(TFakeDbCatalog.Create);
  VM.OpenStore(0);
  CheckEqualsInt(0, VM.ActiveStoreIndex, 'start in store 0');
  Check(VM.Data.FindNodeIndex('A') >= 0, 'store 0 has A');

  Res := VM.ResolveCrossDb('B');
  Check(Res.Found, 'B resolves in catalog');
  CheckEqualsInt(1, Res.StoreIndex, 'B is in store 1');

  VM.JumpToCrossDb('B');
  CheckEqualsInt(1, VM.ActiveStoreIndex, 'jumped to store 1');
  Check(VM.Data.FindNodeIndex('B') >= 0, 'store 1 has B');
  CheckEqualsStr('B', VM.SelectedId, 'target selected after jump');

  Check(VM.CanGoBack, 'jump pushed history');
  VM.Back;
  CheckEqualsInt(0, VM.ActiveStoreIndex, 'back returns to store 0');
  Check(VM.Data.FindNodeIndex('A') >= 0, 'store 0 reloaded on back');
end;
```

Register both. Add `Fake.DbCatalog in 'Fake.DbCatalog.pas',` to `drag_lint_graph_tests.dpr` uses.

- [ ] **Step 3: Interface additions:**

```pascal
    procedure NavigateTo(const AId: string);
    function  ResolveCrossDb(const AName: string): TCrossDbResolution;
    procedure JumpToCrossDb(const AName: string);
    procedure Back;
    function  CanGoBack: Boolean;
    function  ResolveCref(const AText: string): TCrefResolution;
    function  LocateSymbol(const AId: string; out AFile: string;
      out ALine: Integer): Boolean;
    procedure SetOnStoreChanged(AValue: TGraphVMNotify);
```

- [ ] **Step 4: Nav-entry type + stack.** In the `implementation` (or a private type), define a nav entry and add a stack field. Add to `strict private`:

```pascal
    FNavStack: TStack<TNavEntry>;
    FOnStoreChanged: TGraphVMNotify;
    procedure DoStoreChanged;
    function  CaptureState: TNavEntry;
    procedure RestoreState(const AEntry: TNavEntry);
    procedure ExpandAncestors(const AId: string);
```

Add the record to the unit's `interface` `type` section (after `TGraphProjection`):

```pascal
  TNavEntry = record
    StoreIndex: Integer;
    SelectedId: string;
    Collapsed:  TArray<string>;
    FocusId:    string;
    FocusHops:  Integer;
    Isolate:    Boolean;
  end;
```

Create/free `FNavStack: TStack<TNavEntry>` in constructor/destructor. In `Reload`, do NOT clear the nav stack (history survives reload), but DO clear collapse/focus/selection as already specified — except when restoring (see RestoreState). To avoid wiping state during a Back-triggered reload, add a `strict private FRestoring: Boolean;` guard: `Reload` only clears `FCollapsed`/`FFocusId`/`FSelectedId` when `not FRestoring`.

Bodies:

```pascal
procedure TGraphViewModel.DoStoreChanged;
begin
  if Assigned(FOnStoreChanged) then FOnStoreChanged(Self);
end;

procedure TGraphViewModel.SetOnStoreChanged(AValue: TGraphVMNotify);
begin
  FOnStoreChanged := AValue;
end;

function TGraphViewModel.CaptureState: TNavEntry;
var
  Key: string;
  L: TList<string>;
begin
  Result.StoreIndex := FActiveStore;
  Result.SelectedId := FSelectedId;
  Result.FocusId := FFocusId;
  Result.FocusHops := FFocusHops;
  Result.Isolate := FIsolate;
  L := TList<string>.Create;
  try
    for Key in FCollapsed.Keys do
      L.Add(Key);
    Result.Collapsed := L.ToArray;
  finally
    L.Free;
  end;
end;

procedure TGraphViewModel.RestoreState(const AEntry: TNavEntry);
var
  Key: string;
begin
  if AEntry.StoreIndex <> FActiveStore then
  begin
    FRestoring := True;
    try
      OpenStore(AEntry.StoreIndex);
    finally
      FRestoring := False;
    end;
  end;
  FCollapsed.Clear;
  for Key in AEntry.Collapsed do
    FCollapsed.AddOrSetValue(Key, True);
  FFocusId := AEntry.FocusId;
  FFocusHops := AEntry.FocusHops;
  FIsolate := AEntry.Isolate;
  FSelectedId := AEntry.SelectedId;
  DoChanged;
  DoSelectionChanged;
end;

procedure TGraphViewModel.ExpandAncestors(const AId: string);
var
  Idx, P: Integer;
begin
  Idx := FData.FindNodeIndex(AId);
  if Idx < 0 then Exit;
  P := FData.ParentIndexOf(Idx);
  while P >= 0 do
  begin
    FCollapsed.Remove(FData.NodeAt(P).Id);
    P := FData.ParentIndexOf(P);
  end;
end;

procedure TGraphViewModel.NavigateTo(const AId: string);
begin
  FNavStack.Push(CaptureState);
  ExpandAncestors(AId);          { ensure target visible }
  FCollapsed.Remove(AId);        { expand target one level }
  FSelectedId := AId;
  DoChanged;
  DoSelectionChanged;
end;

function TGraphViewModel.ResolveCrossDb(const AName: string): TCrossDbResolution;
begin
  if FCatalog <> nil then
    Result := FCatalog.ResolveAcrossStores(AName)
  else
    FillChar(Result, SizeOf(Result), 0);
end;

procedure TGraphViewModel.JumpToCrossDb(const AName: string);
var
  Res: TCrossDbResolution;
begin
  Res := ResolveCrossDb(AName);
  if not Res.Found then Exit;
  FNavStack.Push(CaptureState);
  if Res.StoreIndex <> FActiveStore then
  begin
    FRestoring := True;
    try
      OpenStore(Res.StoreIndex);  { reload target store; keeps history }
    finally
      FRestoring := False;
    end;
    DoStoreChanged;
  end;
  FSelectedId := Res.TargetId;
  DoChanged;
  DoSelectionChanged;
end;

procedure TGraphViewModel.Back;
var
  Entry: TNavEntry;
begin
  if FNavStack.Count = 0 then Exit;
  Entry := FNavStack.Pop;
  RestoreState(Entry);
end;

function TGraphViewModel.CanGoBack: Boolean;
begin
  Result := FNavStack.Count > 0;
end;

function TGraphViewModel.ResolveCref(const AText: string): TCrefResolution;
begin
  if FSource <> nil then
    Result := FSource.ResolveCref(AText)
  else
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Text := AText;
    Result.Kind := crkUnresolved;
  end;
end;

function TGraphViewModel.LocateSymbol(const AId: string; out AFile: string;
  out ALine: Integer): Boolean;
begin
  AFile := ''; ALine := 0;
  if FSource <> nil then
    Result := FSource.LocateSymbol(AId, AFile, ALine)
  else
    Result := False;
end;
```

IMPORTANT (state-clearing): update `Reload` so it only clears state when NOT restoring:

```pascal
procedure TGraphViewModel.Reload;
begin
  if not FRestoring then
  begin
    FSelectedId := '';
    FCollapsed.Clear;
    FFocusId := '';
  end;
  FData.Clear;
  if FSource <> nil then
    FSource.LoadTopology(FData);
  DoChanged;
end;
```

(`OpenStore` calls `Reload`; during a Back/jump we set `FRestoring` so the store's data reloads without wiping the state we are about to restore. After `OpenStore` returns we set the collapse/focus/selection explicitly.)

- [ ] **Step 5:** Per-task protocol. FILES: `src\control\DragLint.Graph.ViewModel.pas`, `tests\console\Fake.DbCatalog.pas`, `tests\console\Test.Graph.ViewModel.pas`, `tests\console\drag_lint_graph_tests.dpr`. Expect 19 tests, 0 failed.

Commit: `feat: viewmodel nav back-stack + cross-DB jump + cref/locate delegation`

---

## Self-Review notes

- **Spec coverage (§6, §7):** projection visible-node + aggregated-edge (T1-T3), collapse/expand/all (T2), edge aggregation incl. mixed->ekOther (T3), neighborhood focus dim/isolate/N-hop (T4), selection + lazy SelectedDoc (T1/T5), nav back-stack + NavigateTo expand-one-level + cross-DB jump + Back across stores + ResolveCref/LocateSymbol delegation + OnChanged/OnSelectionChanged/OnStoreChanged (T5).
- **Deviation:** events are single-cast method-pointers, not Spring4D `IEvent` (documented; View is sole subscriber). `OnCrossDbJumpRequested` host-policy event is deferred to P4/P5 wiring (the in-place `JumpToCrossDb` is implemented now; the View can call it directly).
- **Deferred to P3:** real `IGraphSource`/`IDbCatalog` over FireDAC sqlite; here everything runs on fakes.
- **Type consistency:** `TProjNode`/`TProjEdge`/`TGraphProjection`/`TNavEntry`/`TGraphVMNotify`/`IGraphViewModel` names are used identically across the unit and tests; `RepresentativeOf(-1)=-1` guard; `FRestoring` guard prevents Back/jump from wiping restored state.
