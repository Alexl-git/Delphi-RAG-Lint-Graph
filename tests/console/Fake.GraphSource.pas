unit Fake.GraphSource;

{ In-memory IGraphSource for headless tests. Returns a fixed 3-node topology
  (one unit containing one class containing one method) so consumers can be
  exercised without a database. }

interface

uses
  DragLint.Graph.Types,
  DragLint.Graph.Source;

type
  TFakeGraphSource = class(TInterfacedObject, IGraphSource)
  public
    function StoreIndex: Integer;
    function LoadTopology(AData: TGraphData): Boolean;
    function GetDoc(const AQName: string): TGraphDoc;
    function ResolveCref(const AText: string): TCrefResolution;
    function LocateSymbol(const AQName: string; out AFile: string;
      out ALine: Integer): Boolean;
  end;

implementation

uses
  System.SysUtils;

function MakeNode(const AId: string; AKind: TGraphNodeKind;
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

function TFakeGraphSource.StoreIndex: Integer;
begin
  Result := 0;
end;

function TFakeGraphSource.LoadTopology(AData: TGraphData): Boolean;
begin
  if AData = nil then Exit(False);
  AData.Clear;
  AData.AddNode(MakeNode('U', nkUnit, ''));
  AData.AddNode(MakeNode('U.TFoo', nkClass, 'U'));
  AData.AddNode(MakeNode('U.TFoo.Bar', nkMethod, 'U.TFoo'));
  AData.BuildHierarchy;
  Result := True;
end;

function TFakeGraphSource.GetDoc(const AQName: string): TGraphDoc;
begin
  FillChar(Result, SizeOf(Result), 0);
  if AQName = 'U.TFoo.Bar' then
  begin
    Result.HasDoc := True;
    Result.Format := 'xmldoc';
    Result.Summary := 'Fake summary for Bar.';
  end;
end;

function TFakeGraphSource.ResolveCref(const AText: string): TCrefResolution;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Text := AText;
  if AText = 'U.TFoo' then
  begin
    Result.Kind := crkResolved;
    Result.TargetId := 'U.TFoo';
    Result.StoreIndex := 0;
  end
  else
    Result.Kind := crkUnresolved;
end;

function TFakeGraphSource.LocateSymbol(const AQName: string; out AFile: string;
  out ALine: Integer): Boolean;
begin
  AFile := '';
  ALine := 0;
  if AQName = 'U.TFoo' then
  begin
    AFile := 'U.pas';
    ALine := 12;
    Exit(True);
  end;
  Result := False;
end;

end.
