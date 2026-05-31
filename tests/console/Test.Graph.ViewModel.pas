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

initialization
  RegisterTest('VMLoadsViaSource', Test_VMLoadsViaSource);
  RegisterTest('VMSelectionFiresEvent', Test_VMSelectionFiresEvent);
  RegisterTest('VMFlatProjection', Test_VMFlatProjection);
  RegisterTest('VMCollapseHidesDescendants', Test_VMCollapseHidesDescendants);
  RegisterTest('VMCollapseReroutesEdge', Test_VMCollapseReroutesEdge);
  RegisterTest('VMExpandRestores', Test_VMExpandRestores);
end.
