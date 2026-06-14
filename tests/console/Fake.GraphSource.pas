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
    function ResolveName(const AName: string; out AQName: string): Boolean;
    function GetCallees(const AQName: string): TArray<TCallRef>;
    function GetSymbolMeta(const AQName: string;
      out ASignature, AModifiers, AKindText: string): Boolean;
  end;

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
    function ResolveName(const AName: string; out AQName: string): Boolean;
    function GetCallees(const AQName: string): TArray<TCallRef>;
    function GetSymbolMeta(const AQName: string;
      out ASignature, AModifiers, AKindText: string): Boolean;
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

{ Topology-only fake: no name resolution. }
function TFakeGraphSource.ResolveName(const AName: string;
  out AQName: string): Boolean;
begin
  AQName := '';
  Result := False;
end;

function TFakeGraphSource.GetCallees(const AQName: string): TArray<TCallRef>;
begin
  Result := nil;
end;

function TFakeGraphSource.GetSymbolMeta(const AQName: string;
  out ASignature, AModifiers, AKindText: string): Boolean;
begin
  ASignature := '';
  AModifiers := '';
  AKindText  := '';
  Result := False;
end;

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

{ Topology-only preloaded source: no name resolution. }
function TPreloadedSource.ResolveName(const AName: string;
  out AQName: string): Boolean;
begin
  AQName := '';
  Result := False;
end;

function TPreloadedSource.GetCallees(const AQName: string): TArray<TCallRef>;
begin
  Result := nil;
end;

function TPreloadedSource.GetSymbolMeta(const AQName: string;
  out ASignature, AModifiers, AKindText: string): Boolean;
begin
  ASignature := '';
  AModifiers := '';
  AKindText  := '';
  Result := False;
end;

end.
