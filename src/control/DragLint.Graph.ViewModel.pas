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
    procedure Collapse(const AId: string);
    procedure Expand(const AId: string);
    procedure ToggleCollapse(const AId: string);
    procedure CollapseAll;
    procedure ExpandAll;
    function  IsCollapsed(const AId: string): Boolean;
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
    FCollapsed:   TDictionary<string, Boolean>;
    procedure DoChanged;
    procedure DoSelectionChanged;
    procedure Reload;
    function NodeHasChildren(AIndex: Integer): Boolean;
    function NodeIsCollapsed(AIndex: Integer): Boolean;
    function NodeIsVisible(AIndex: Integer): Boolean;
    function RepresentativeOf(AIndex: Integer): Integer;
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
    procedure Collapse(const AId: string);
    procedure Expand(const AId: string);
    procedure ToggleCollapse(const AId: string);
    procedure CollapseAll;
    procedure ExpandAll;
    function  IsCollapsed(const AId: string): Boolean;
  end;

implementation

constructor TGraphViewModel.Create;
begin
  inherited Create;
  FData := TGraphData.Create;
  FActiveStore := -1;
  FSelectedId := '';
  FCollapsed := TDictionary<string, Boolean>.Create;
end;

destructor TGraphViewModel.Destroy;
begin
  FCollapsed.Free;
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
  FCollapsed.Clear;
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

function TGraphViewModel.NodeHasChildren(AIndex: Integer): Boolean;
begin
  Result := Length(FData.ChildrenOf(AIndex)) > 0;
end;

function TGraphViewModel.NodeIsCollapsed(AIndex: Integer): Boolean;
var
  Id: string;
begin
  Id := FData.NodeAt(AIndex)^.Id;
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
  if AIndex < 0 then Exit(-1);
  if NodeIsVisible(AIndex) then Exit(AIndex);
  Cur := FData.ParentIndexOf(AIndex);
  while Cur >= 0 do
  begin
    if NodeIsVisible(Cur) then Exit(Cur);
    Cur := FData.ParentIndexOf(Cur);
  end;
  Result := -1;
end;

function TGraphViewModel.Projection: TGraphProjection;
var
  Nodes: TList<TProjNode>;
  Edges: TList<TProjEdge>;
  EdgeKey: TDictionary<string, Integer>;
  I, SI, TI, EI: Integer;
  PN: TProjNode;
  PE: TProjEdge;
  E: TGraphEdge;
  Key: string;
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
      FCollapsed.AddOrSetValue(FData.NodeAt(I)^.Id, True);
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

end.
