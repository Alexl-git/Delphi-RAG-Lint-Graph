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
