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
  Fake.GraphSource,
  Fake.DbCatalog;

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

procedure Test_VMProjEdgeSection;
var
  VM: IGraphViewModel;
  Proj: TGraphProjection;
  I, UaIdx, UbIdx: Integer;
  Found: Boolean;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildTwoUnitGraph));
  VM.Collapse('uA');
  Proj := VM.Projection;
  UaIdx := VM.Data.FindNodeIndex('uA');
  UbIdx := VM.Data.FindNodeIndex('uB');
  Found := False;
  for I := 0 to High(Proj.Edges) do
    if (Proj.Edges[I].Kind = ekUses)
       and (Proj.Edges[I].SourceIdx = UaIdx)
       and (Proj.Edges[I].TargetIdx = UbIdx) then
    begin
      Found := True;
      CheckEqualsStr('interface', Proj.Edges[I].Section,
        'uses edge section carries label from raw edge');
    end;
  Check(Found, 'uA->uB uses edge found in projection');
end;

procedure Test_VMTopLevelCap;
var
  VM: IGraphViewModel;
  Proj: TGraphProjection;
  ProjRootIdx, I, J, TopCount: Integer;
  Found0, Found1: Boolean;
  AllBigPresent: Boolean;
  NodeIdx: Integer;
begin
  { --- Case 1: 30 units (>25 default threshold) ---
    unit_i has i methods, so DescendantCount = i.
    Defaults: Threshold=25, Limit=10.
    Expected: cap applied, 10 shown, 20 hidden. }
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildManyUnitsGraph(30)));

  Proj := VM.Projection;
  ProjRootIdx := VM.Data.FindNodeIndex('@project');
  Check(ProjRootIdx >= 0, 'project root present (30 units)');

  TopCount := 0;
  for I := 0 to High(Proj.Nodes) do
    if VM.Data.ParentIndexOf(Proj.Nodes[I].NodeIdx) = ProjRootIdx then
      Inc(TopCount);
  CheckEqualsInt(10, TopCount, '30 units: cap applied, 10 top-level shown');
  CheckEqualsInt(20, VM.HiddenTopLevelCount, '30 units: 20 hidden');

  { The 10 BIGGEST units (unit_20..unit_29) must be present }
  AllBigPresent := True;
  for I := 20 to 29 do
  begin
    NodeIdx := VM.Data.FindNodeIndex('unit_' + IntToStr(I));
    Found0 := False;
    if NodeIdx >= 0 then
      for J := 0 to High(Proj.Nodes) do
        if Proj.Nodes[J].NodeIdx = NodeIdx then Found0 := True;
    if not Found0 then AllBigPresent := False;
  end;
  Check(AllBigPresent, 'unit_20..unit_29 (top 10 biggest) all present');

  { The two SMALLEST units must NOT be in the projection }
  Found0 := False;
  Found1 := False;
  for I := 0 to High(Proj.Nodes) do
  begin
    NodeIdx := Proj.Nodes[I].NodeIdx;
    if VM.Data.NodeAt(NodeIdx)^.Id = 'unit_0' then Found0 := True;
    if VM.Data.NodeAt(NodeIdx)^.Id = 'unit_1' then Found1 := True;
  end;
  Check(not Found0, 'unit_0 (smallest) excluded from projection');
  Check(not Found1, 'unit_1 (second smallest) excluded from projection');

  { ShowAll=True: all 30 shown, hidden=0 }
  VM.SetShowAllTopLevel(True);
  Proj := VM.Projection;
  TopCount := 0;
  for I := 0 to High(Proj.Nodes) do
    if VM.Data.ParentIndexOf(Proj.Nodes[I].NodeIdx) = ProjRootIdx then
      Inc(TopCount);
  CheckEqualsInt(30, TopCount, 'ShowAll=True: all 30 units visible');
  CheckEqualsInt(0, VM.HiddenTopLevelCount, 'ShowAll=True: HiddenTopLevelCount=0');

  { --- Case 2: 20 units (<=25 threshold): adaptive -- cap NOT applied --- }
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildManyUnitsGraph(20)));

  Proj := VM.Projection;
  ProjRootIdx := VM.Data.FindNodeIndex('@project');
  TopCount := 0;
  for I := 0 to High(Proj.Nodes) do
    if VM.Data.ParentIndexOf(Proj.Nodes[I].NodeIdx) = ProjRootIdx then
      Inc(TopCount);
  CheckEqualsInt(20, TopCount, '20 units (<=25): all 20 shown (no cap)');
  CheckEqualsInt(0, VM.HiddenTopLevelCount, '20 units: HiddenTopLevelCount=0');

  { --- Case 3: SetTopLevelCapThreshold(10), 20 units -> cap to 10 --- }
  VM.SetTopLevelCapThreshold(10);
  Proj := VM.Projection;
  TopCount := 0;
  for I := 0 to High(Proj.Nodes) do
    if VM.Data.ParentIndexOf(Proj.Nodes[I].NodeIdx) = ProjRootIdx then
      Inc(TopCount);
  CheckEqualsInt(10, TopCount, 'Threshold=10: 20 units capped to 10');
  CheckEqualsInt(10, VM.HiddenTopLevelCount, 'Threshold=10: 10 units hidden');
end;

initialization
  RegisterTest('VMLoadsViaSource', Test_VMLoadsViaSource);
  RegisterTest('VMSelectionFiresEvent', Test_VMSelectionFiresEvent);
  RegisterTest('VMFlatProjection', Test_VMFlatProjection);
  RegisterTest('VMCollapseHidesDescendants', Test_VMCollapseHidesDescendants);
  RegisterTest('VMCollapseReroutesEdge', Test_VMCollapseReroutesEdge);
  RegisterTest('VMExpandRestores', Test_VMExpandRestores);
  RegisterTest('VMEdgeAggregation', Test_VMEdgeAggregation);
  RegisterTest('VMFocusDims', Test_VMFocusDims);
  RegisterTest('VMFocusIsolateHides', Test_VMFocusIsolateHides);
  RegisterTest('VMClearFocus', Test_VMClearFocus);
  RegisterTest('VMNavBackStack', Test_VMNavBackStack);
  RegisterTest('VMCrossDbJump', Test_VMCrossDbJump);
  RegisterTest('VMProjEdgeSection', Test_VMProjEdgeSection);
  RegisterTest('VMTopLevelCap', Test_VMTopLevelCap);
end.
