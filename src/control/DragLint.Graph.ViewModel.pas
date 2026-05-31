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
