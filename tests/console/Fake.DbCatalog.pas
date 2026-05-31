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
    function ResolveName(const AName: string; out AQName: string): Boolean;
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

{ Resolve against the single canned root id for this store. }
function TStoreSource.ResolveName(const AName: string;
  out AQName: string): Boolean;
begin
  if AName = FRootId then
  begin
    AQName := FRootId;
    Result := True;
  end
  else
  begin
    AQName := '';
    Result := False;
  end;
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
