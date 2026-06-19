unit DragLint.Graph.ViewModel;

{ Pure ViewModel: owns a TGraphData, loads it through IGraphSource, and derives
  a TGraphProjection. No VCL/FireDAC/Spring. Events are single-cast method
  pointers (the View is the sole subscriber). }

interface

uses
  System.SysUtils
  , System  .Generics.Collections
  , DragLint.Graph   .Types
  , DragLint.Graph   .Source
  ;

type
  TProjNode = record
    NodeIdx  : Integer; { index into Data }
    Collapsed: Boolean; { collapsed and has children (drawn with +N badge) }
    Dimmed   : Boolean; { focus active and node outside neighborhood }
  end;

  TProjEdge = record
    SourceIdx : Integer       ; { representative visible node index }
    TargetIdx : Integer       ;
    Kind      : TGraphEdgeKind;
    Count     : Integer       ; { underlying edges merged into this one }
    Weight    : Double        ;
    Aggregated: Boolean       ; { Count>1 or mixed kinds }
    Dimmed    : Boolean       ;
    Section   : string        ; { for ekUses: 'interface'|'implementation'|... }
    CrossDb   : Boolean       ; { target lives in a different store (P4: always False) }
  end;

  TGraphProjection = record
    Nodes: TArray<TProjNode>;
    Edges: TArray<TProjEdge>;
  end;

  TNavEntry = record
    StoreIndex : Integer       ;
    SelectedId : string        ;
    Collapsed  : TArray<string>;
    FocusId    : string        ;
    FocusHops  : Integer       ;
    Isolate    : Boolean       ;
    DrillRootId: string        ; { containment drill-in root ('' = whole project) }
  end;

  TGraphVMNotify = procedure(Sender: TObject) of object;

  IGraphViewModel = interface
    ['{B1C2D3E4-F5A6-4B7C-8D9E-0A1B2C3D4E5F}']
    procedure SetSource (const ASource : IGraphSource);
    procedure SetCatalog(const ACatalog: IDbCatalog  );
    procedure OpenStore(AStoreIndex: Integer);
    function ActiveStoreIndex: Integer;
    function Data            : TGraphData;
    function Projection      : TGraphProjection;
    procedure SelectNode(const AId: string);
    function SelectedId: string                  ;
    function SelectedNodeIndex: Integer;
    function SelectedDoc      : TGraphDoc;
    function DocFor(const AId: string): TGraphDoc;
    procedure SetOnChanged         (AValue: TGraphVMNotify);
    procedure SetOnSelectionChanged(AValue: TGraphVMNotify);
    procedure Collapse      (const AId: string);
    procedure Expand        (const AId: string);
    procedure ToggleCollapse(const AId: string);
    procedure CollapseAll;
    procedure ExpandAll;
    function IsCollapsed(const AId: string): Boolean;
    procedure SetFocus(const AId: string; AHops: Integer = 1);
    procedure ClearFocus;
    function GetIsolate: Boolean;
    procedure SetIsolate(AValue: Boolean);
    procedure NavigateTo(const AId: string);
    procedure DrillInto (const AId: string);
    function DrillRootId: string      ;
    function DrillPath: TArray<string>;
    procedure DrillToDepth(ADepth: Integer);
    function ResolveCrossDb(const AName: string): TCrossDbResolution;
    procedure JumpToCrossDb(const AName: string);
    procedure Back;
    procedure Forward;
    function CanGoBack: Boolean                                                             ;
    function CanGoForward: Boolean                                                          ;
    function ResolveCref(const AText: string): TCrefResolution                              ;
    function LocateSymbol(const AId: string; out AFile: string; out ALine: Integer): Boolean;
    procedure SetOnStoreChanged(AValue: TGraphVMNotify);
    { Top-level cap: limits the number of visible direct children of the
      project root to the top-N by descendant count (largest first).
      FShowAllTopLevel, FTopLevelLimit, and FTopLevelCapThreshold are view
      preferences; they are NOT reset on Reload/source change so the user's
      preference survives store switches.  FHiddenTopLevelCount is updated
      each time Projection runs.
      Adaptive rule: cap is applied only when TopLevel.Count >
      FTopLevelCapThreshold (default 25).  When applied, keep FTopLevelLimit
      (10) units and hide the rest.  So with defaults: <=25 units -> all
      shown; >25 units -> show 10, rest hidden. }
    procedure SetShowAllTopLevel(AValue: Boolean);
    function ShowAllTopLevel: Boolean;
    procedure SetTopLevelLimit(AValue: Integer);
    function TopLevelLimit: Integer;
    procedure SetTopLevelCapThreshold(AValue: Integer);
    function TopLevelCapThreshold: Integer;
    function HiddenTopLevelCount : Integer;
  end;

  TGraphViewModel = class(TInterfacedObject, IGraphViewModel)
    strict private
      FData                : TGraphData                  ;
      FSource              : IGraphSource                ;
      FCatalog             : IDbCatalog                  ;
      FActiveStore         : Integer                     ;
      FSelectedId          : string                      ;
      FOnChanged           : TGraphVMNotify              ;
      FOnSelectionChanged  : TGraphVMNotify              ;
      FCollapsed           : TDictionary<string, Boolean>;
      FFocusId             : string                      ;
      FFocusHops           : Integer                     ;
      FIsolate             : Boolean                     ;
      FNavStack            : TList<TNavEntry>            ; { back history (capped) }
      FNavFwd              : TList<TNavEntry>            ; { forward history (capped) }
      FDrillPath           : TList<string>               ; { containment drill roots; empty = project }
      FOnStoreChanged      : TGraphVMNotify              ;
      FRestoring           : Boolean                     ;
      FShowAllTopLevel     : Boolean                     ;
      FTopLevelLimit       : Integer                     ;
      FTopLevelCapThreshold: Integer                     ;
      FHiddenTopLevelCount : Integer                     ;
      procedure DoChanged;
      procedure DoSelectionChanged;
      procedure DoStoreChanged;
      procedure Reload;
      function NodeHasChildren (AIndex: Integer): Boolean;
      function NodeIsCollapsed (AIndex: Integer): Boolean;
      function NodeIsVisible   (AIndex: Integer): Boolean;
      function RepresentativeOf(AIndex: Integer): Integer;
      procedure ComputeNeighborhood(AStart, AHops: Integer; AEdges: TList<TProjEdge>; ASet: TDictionary<Integer, Boolean>);
      function CaptureState: TNavEntry;
      procedure RestoreState(const AEntry: TNavEntry);
      procedure ExpandAncestors(const AId: string);
      function IsWithinDrill(const AId: string): Boolean;
      procedure PushNav(AList: TList<TNavEntry>; const AEntry: TNavEntry);
      function PopNav(AList: TList<TNavEntry>): TNavEntry;
    public
      constructor Create;
      destructor Destroy; override;
      procedure SetSource (const ASource : IGraphSource);
      procedure SetCatalog(const ACatalog: IDbCatalog  );
      procedure OpenStore(AStoreIndex: Integer);
      function ActiveStoreIndex: Integer;
      function Data            : TGraphData;
      function Projection      : TGraphProjection;
      procedure SelectNode(const AId: string);
      function SelectedId: string                  ;
      function SelectedNodeIndex: Integer;
      function SelectedDoc      : TGraphDoc;
      function DocFor(const AId: string): TGraphDoc;
      procedure SetOnChanged         (AValue: TGraphVMNotify);
      procedure SetOnSelectionChanged(AValue: TGraphVMNotify);
      procedure Collapse      (const AId: string);
      procedure Expand        (const AId: string);
      procedure ToggleCollapse(const AId: string);
      procedure CollapseAll;
      procedure ExpandAll;
      function IsCollapsed(const AId: string): Boolean;
      procedure SetFocus(const AId: string; AHops: Integer = 1);
      procedure ClearFocus;
      function GetIsolate: Boolean;
      procedure SetIsolate(AValue: Boolean);
      procedure NavigateTo(const AId: string);
      procedure DrillInto (const AId: string);
      function DrillRootId: string      ;
      function DrillPath: TArray<string>;
      procedure DrillToDepth(ADepth: Integer);
      function ResolveCrossDb(const AName: string): TCrossDbResolution;
      procedure JumpToCrossDb(const AName: string);
      procedure Back;
      procedure Forward;
      function CanGoBack: Boolean                                                             ;
      function CanGoForward: Boolean                                                          ;
      function ResolveCref(const AText: string): TCrefResolution                              ;
      function LocateSymbol(const AId: string; out AFile: string; out ALine: Integer): Boolean;
      procedure SetOnStoreChanged (AValue: TGraphVMNotify);
      procedure SetShowAllTopLevel(AValue: Boolean       );
      function ShowAllTopLevel: Boolean;
      procedure SetTopLevelLimit(AValue: Integer);
      function TopLevelLimit: Integer;
      procedure SetTopLevelCapThreshold(AValue: Integer);
      function TopLevelCapThreshold: Integer;
      function HiddenTopLevelCount : Integer;
  end;

implementation

constructor TGraphViewModel.Create;
begin
  inherited Create;
  FData:= TGraphData.Create;
  FActiveStore:= -1;
  FSelectedId:= '';
  FCollapsed:= TDictionary<string, Boolean>.Create;
  FFocusId  := '';
  FFocusHops:= 1;
  FIsolate  := False;
  FNavStack:= TList<TNavEntry>.Create;
  FNavFwd  := TList<TNavEntry>.Create;
  FDrillPath:= TList<string>.Create;
  FRestoring           := False;
  FShowAllTopLevel     := False;
  FTopLevelLimit       := 10;
  FTopLevelCapThreshold:= 25;
  FHiddenTopLevelCount := 0;
end; // constructor

destructor TGraphViewModel.Destroy;
begin
  FNavStack.Free;
  FNavFwd.Free;
  FDrillPath.Free;
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
  if not FRestoring then
  begin
    FSelectedId:= '';
    FCollapsed.Clear;
    FFocusId:= '';
    FDrillPath.Clear;
    if FNavStack <> nil then FNavStack.Clear;   { fresh graph -> fresh history }
    if FNavFwd   <> nil then FNavFwd.Clear;
  end;
  FData.Clear;
  if FSource <> nil then FSource.LoadTopology(FData);
  DoChanged;
end;

procedure TGraphViewModel.SetSource(const ASource: IGraphSource);
begin
  FSource:= ASource;
  if FSource <> nil then FActiveStore:= FSource.StoreIndex
  else FActiveStore:= -1;
  Reload;
end;

procedure TGraphViewModel.SetCatalog(const ACatalog: IDbCatalog);
begin
  FCatalog:= ACatalog;
end;

procedure TGraphViewModel.OpenStore(AStoreIndex: Integer);
begin
  if FCatalog = nil then Exit;
  FActiveStore:= AStoreIndex;
  FSource:= FCatalog.SourceForStore(AStoreIndex);
  Reload;
end;

function TGraphViewModel.ActiveStoreIndex: Integer;
begin
  Result:= FActiveStore;
end;

function TGraphViewModel.Data: TGraphData;
begin
  Result:= FData;
end;

function TGraphViewModel.NodeHasChildren(AIndex: Integer): Boolean;
begin
  Result:= Length(FData.ChildrenOf(AIndex)) > 0;
end;

function TGraphViewModel.NodeIsCollapsed(AIndex: Integer): Boolean;
var
  Id: string;
begin
  Id:= FData.NodeAt(AIndex)^.Id;
  Result:= FCollapsed.ContainsKey(Id) and NodeHasChildren(AIndex);
end;

function TGraphViewModel.NodeIsVisible(AIndex: Integer): Boolean;
var
  P: Integer;
begin
  P:= FData.ParentIndexOf(AIndex);
  while P >= 0 do
  begin
    if NodeIsCollapsed(P) then Exit(False);
    P:= FData.ParentIndexOf(P);
  end;
  Result:= True;
end;

function TGraphViewModel.RepresentativeOf(AIndex: Integer): Integer;
var
  Cur: Integer;
begin
  if AIndex < 0 then Exit(-1);
  if NodeIsVisible(AIndex) then Exit(AIndex);
  Cur:= FData.ParentIndexOf(AIndex);
  while Cur >= 0 do
  begin
    if NodeIsVisible(Cur) then Exit(Cur);
    Cur:= FData.ParentIndexOf(Cur);
  end;
  Result:= -1;
end;

function TGraphViewModel.Projection: TGraphProjection;
var
  Nodes   : TList<TProjNode>             ;
  Edges   : TList<TProjEdge>             ;
  EdgeKey : TDictionary<string, Integer> ;
  I       : Integer                      ;
  SI      : Integer                      ;
  TI      : Integer                      ;
  EI      : Integer                      ;
  PN      : TProjNode                    ;
  PE      : TProjEdge                    ;
  E       : TGraphEdge                   ;
  Key     : string                       ;
  FocusRep: Integer                      ;
  InHood  : TDictionary<Integer, Boolean>;
  { top-level cap }
  ProjRootIdx: Integer                      ;
  TopLevel   : TList<Integer>               ;
  Removed    : TDictionary<Integer, Boolean>;
  Cur        : Integer                      ;
  CapCount   : Integer                      ;
  NIdx       : Integer                      ;
  CapIdxArr  : TArray<Integer>              ;
  CapDescArr : TArray<Integer>              ;
  Tmp        : Integer                      ;
  Swapped    : Boolean                      ;
  DrillIdx   : Integer                      ;
  Anc        : Integer                      ;
  InDrill    : Boolean                      ;
begin
  { Containment drill-in: when a drill root is set, show ONLY its subtree. }
  DrillIdx:= -1;
  if DrillRootId <> '' then DrillIdx:= FData.FindNodeIndex(DrillRootId);

  Nodes:= TList<TProjNode>.Create;
  Edges:= TList<TProjEdge>.Create;
  try
    for I:= 0 to FData.NodeCount - 1 do
    begin
      if not NodeIsVisible(I) then Continue;
      if DrillIdx >= 0 then
      begin
        { keep only strict descendants of the drill root }
        InDrill:= False;
        Anc:= FData.ParentIndexOf(I);
        while Anc >= 0 do
        begin
          if Anc = DrillIdx then begin InDrill:= True; Break; end;
          Anc:= FData.ParentIndexOf(Anc);
        end;
        if not InDrill then Continue;
      end;
      PN.NodeIdx:= I;
      PN.Collapsed:= NodeIsCollapsed(I);
      PN.Dimmed:= False;
      Nodes.Add(PN);
    end; // for
    { edges with merge by (src,dst) pair }
    EdgeKey:= TDictionary<string, Integer>.Create;
    try
      for I:= 0 to FData.EdgeCount - 1 do
      begin
        E:= FData.EdgeAt(I);
        if E.Kind = ekContains then Continue;
        SI:= RepresentativeOf(FData.FindNodeIndex(E.SourceId));
        TI:= RepresentativeOf(FData.FindNodeIndex(E.TargetId));
        if (SI < 0) or (TI < 0) or (SI = TI) then Continue;
        Key:= IntToStr(SI) + '|' + IntToStr(TI);
        if EdgeKey.TryGetValue(Key, EI) then
        begin
          PE:= Edges[EI];
          Inc(PE.Count);
          PE.Weight:= PE.Weight + E.Weight;
          if PE.Kind <> E.Kind then PE.Kind:= ekOther;
          PE.Aggregated:= True;
          { adopt first non-empty section }
          if (PE.Section = '') and (E.Label_ <> '') then PE.Section:= E.Label_;
          Edges[EI]:= PE;
        end
        else
        begin
          PE.SourceIdx:= SI;
          PE.TargetIdx:= TI;
          PE.Kind:= E.Kind;
          PE.Count:= 1;
          PE.Weight:= E.Weight;
          PE.Aggregated:= False;
          PE.Dimmed    := False;
          PE.Section:= E.Label_;
          PE.CrossDb:= False;
          EdgeKey.Add(Key, Edges.Count);
          Edges.Add(PE);
        end;
      end; // for
    finally
      EdgeKey.Free;
    end; // try
    { --- top-level cap ---
      Applied BEFORE focus dimming so the cap operates on the
      collapse-resolved visible set.  Removing a top-level unit also removes
      all its currently-visible descendants (they share the same ancestor
      chain) and any edge touching a removed node.
      View preferences FShowAllTopLevel/FTopLevelLimit survive Reload. }
    if DrillIdx >= 0 then ProjRootIdx:= DrillIdx { drilled in: cap on the drill root's children }
    else ProjRootIdx:= FData.FindNodeIndex('@project');
    if ProjRootIdx >= 0 then
    begin
      { collect visible top-level units: direct children of @project }
      TopLevel:= TList<Integer>.Create;
      try
        for I:= 0 to Nodes.Count - 1 do
          if FData.ParentIndexOf(Nodes[I].NodeIdx) = ProjRootIdx then TopLevel.Add(Nodes[I].NodeIdx);

        if (not FShowAllTopLevel) and (TopLevel.Count > FTopLevelCapThreshold) then
        begin
          { Sort TopLevel by DescendantCount DESC, tie-break by index ASC
            using a simple bubble sort (counts small in unit tests; this is
            fine for reasonable numbers of units in real use too). }
          CapCount:= TopLevel.Count;
          SetLength(CapIdxArr , CapCount);
          SetLength(CapDescArr, CapCount);
          for I:= 0 to CapCount - 1 do
          begin
            CapIdxArr[I]:= TopLevel[I];
            CapDescArr[I]:= FData.DescendantCount(TopLevel[I]);
          end;
          repeat
            Swapped:= False;
            for I:= 0 to CapCount - 2 do
            begin
              { want DESC by desc-count; tie-break ASC by node index }
              if (CapDescArr[I] < CapDescArr[I + 1]) or ((CapDescArr[I] = CapDescArr[I + 1]) and (CapIdxArr[I] > CapIdxArr[I + 1])) then
              begin
                Tmp:= CapDescArr[I]; CapDescArr[I]:= CapDescArr[I + 1]; CapDescArr[I + 1]:= Tmp;
                Tmp:= CapIdxArr [I]; CapIdxArr [I]:= CapIdxArr [I + 1]; CapIdxArr [I + 1]:= Tmp;
                Swapped:= True;
              end;
            end;
          until not Swapped;

          { Mark the tail (hidden) top-level units and all their visible
            descendants for removal. }
          Removed:= TDictionary<Integer, Boolean>.Create;
          try
            for I:= FTopLevelLimit to CapCount - 1 do Removed.AddOrSetValue(CapIdxArr[I], True);

            { Propagate: any node whose top-level ancestor is removed }
            for I:= 0 to Nodes.Count - 1 do
            begin
              NIdx:= Nodes[I].NodeIdx;
              if Removed.ContainsKey(NIdx) then Continue;
              { walk up to the top-level ancestor }
              Cur:= NIdx;
              while FData.ParentIndexOf(Cur) <> ProjRootIdx do
              begin
                Cur:= FData.ParentIndexOf(Cur);
                if Cur < 0 then Break;
              end;
              if (Cur >= 0) and Removed.ContainsKey(Cur) then Removed.AddOrSetValue(NIdx, True);
            end;

            { Remove nodes }
            for I:= Nodes.Count - 1 downto 0 do
              if Removed.ContainsKey(Nodes[I].NodeIdx) then Nodes.Delete(I);

            { Remove edges touching removed nodes }
            for I:= Edges.Count - 1 downto 0 do
              if Removed.ContainsKey(Edges[I].SourceIdx) or Removed.ContainsKey(Edges[I].TargetIdx) then Edges.Delete(I);

            FHiddenTopLevelCount:= CapCount - FTopLevelLimit;
          finally
            Removed.Free;
          end; // try
        end // if
        else FHiddenTopLevelCount:= 0;
      finally
        TopLevel.Free;
      end; // try
    end // if
    else FHiddenTopLevelCount:= 0;

    { focus: BFS over the visible projection graph from the focus node's
      representative, marking nodes within FFocusHops as in-neighborhood. }
    if FFocusId <> '' then
    begin
      FocusRep:= RepresentativeOf(FData.FindNodeIndex(FFocusId));
      if FocusRep >= 0 then
      begin
        InHood:= TDictionary<Integer, Boolean>.Create;
        try
          ComputeNeighborhood(FocusRep, FFocusHops, Edges, InHood);
          { mark node Dimmed when not in neighborhood }
          for I:= 0 to Nodes.Count - 1 do
          begin
            PN:= Nodes[I];
            PN.Dimmed:= not InHood.ContainsKey(PN.NodeIdx);
            Nodes[I]:= PN;
          end;
          { dim edges touching a dimmed node }
          for I:= 0 to Edges.Count - 1 do
          begin
            PE:= Edges[I];
            PE.Dimmed:= (not InHood.ContainsKey(PE.SourceIdx)) or (not InHood.ContainsKey(PE.TargetIdx));
            Edges[I]:= PE;
          end;
          if FIsolate then
          begin
            for I:= Nodes.Count - 1 downto 0 do
              if Nodes[I].Dimmed then Nodes.Delete(I);
            for I:= Edges.Count - 1 downto 0 do
              if Edges[I].Dimmed then Edges.Delete(I);
          end;
        finally
          InHood.Free;
        end; // try
      end; // if
    end; // if
    Result.Nodes:= Nodes.ToArray;
    Result.Edges:= Edges.ToArray;
  finally
    Nodes.Free;
    Edges.Free;
  end; // try
end; // function

procedure TGraphViewModel.SelectNode(const AId: string);
begin
  FSelectedId:= AId;
  DoSelectionChanged;
end;

function TGraphViewModel.SelectedId: string;
begin
  Result:= FSelectedId;
end;

function TGraphViewModel.SelectedNodeIndex: Integer;
begin
  if FSelectedId = '' then Result:= -1
  else Result:= FData.FindNodeIndex(FSelectedId);
end;

function TGraphViewModel.SelectedDoc: TGraphDoc;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (FSource <> nil) and (FSelectedId <> '') then Result:= FSource.GetDoc(FSelectedId);
end;

function TGraphViewModel.DocFor(const AId: string): TGraphDoc;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (FSource <> nil) and (AId <> '') then Result:= FSource.GetDoc(AId);
end;

procedure TGraphViewModel.SetOnChanged(AValue: TGraphVMNotify);
begin
  FOnChanged:= AValue;
end;

procedure TGraphViewModel.SetOnSelectionChanged(AValue: TGraphVMNotify);
begin
  FOnSelectionChanged:= AValue;
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
  if FCollapsed.ContainsKey(AId) then FCollapsed.Remove(AId)
  else FCollapsed.AddOrSetValue(AId, True);
  DoChanged;
end;

procedure TGraphViewModel.CollapseAll;
var
  I: Integer;
begin
  FCollapsed.Clear;
  for I:= 0 to FData.NodeCount - 1 do
    if NodeHasChildren(I) and (FData.NodeAt(I)^.Kind <> nkProject) then FCollapsed.AddOrSetValue(FData.NodeAt(I)^.Id, True);
  DoChanged;
end;

procedure TGraphViewModel.ExpandAll;
begin
  FCollapsed.Clear;
  DoChanged;
end;

function TGraphViewModel.IsCollapsed(const AId: string): Boolean;
begin
  Result:= FCollapsed.ContainsKey(AId);
end;

procedure TGraphViewModel.SetFocus(const AId: string; AHops: Integer);
begin
  FFocusId:= AId;
  if AHops < 0 then AHops:= 0;
  FFocusHops:= AHops;
  DoChanged;
end;

procedure TGraphViewModel.ClearFocus;
begin
  FFocusId:= '';
  DoChanged;
end;

function TGraphViewModel.GetIsolate: Boolean;
begin
  Result:= FIsolate;
end;

procedure TGraphViewModel.SetIsolate(AValue: Boolean);
begin
  if FIsolate <> AValue then
  begin
    FIsolate:= AValue;
    DoChanged;
  end;
end;

procedure TGraphViewModel.DoStoreChanged;
begin
  if Assigned(FOnStoreChanged) then FOnStoreChanged(Self);
end;

procedure TGraphViewModel.SetOnStoreChanged(AValue: TGraphVMNotify);
begin
  FOnStoreChanged:= AValue;
end;

function TGraphViewModel.CaptureState: TNavEntry;
var
  Key: string       ;
  L  : TList<string>;
begin
  Result.StoreIndex := FActiveStore;
  Result.SelectedId := FSelectedId;
  Result.FocusId    := FFocusId;
  Result.FocusHops  := FFocusHops;
  Result.Isolate    := FIsolate;
  Result.DrillRootId:= DrillRootId;   { snapshot the drill scope so Back restores it }
  L:= TList<string>.Create;
  try
    for Key in FCollapsed.Keys do L.Add(Key);
    Result.Collapsed:= L.ToArray;
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
    FRestoring:= True;
    try
      OpenStore(AEntry.StoreIndex);
    finally
      FRestoring:= False;
    end;
  end;
  FCollapsed.Clear;
  for Key in AEntry.Collapsed do FCollapsed.AddOrSetValue(Key, True);
  FFocusId   := AEntry.FocusId;
  FFocusHops := AEntry.FocusHops;
  FIsolate   := AEntry.Isolate;
  FSelectedId:= AEntry.SelectedId;
  { restore the drill scope (single-level drill -> at most one root). }
  FDrillPath.Clear;
  if AEntry.DrillRootId <> '' then FDrillPath.Add(AEntry.DrillRootId);
  DoChanged;
  DoSelectionChanged;
end; // procedure

procedure TGraphViewModel.ExpandAncestors(const AId: string);
var
  Idx: Integer;
  P  : Integer;
begin
  Idx:= FData.FindNodeIndex(AId);
  if Idx < 0 then Exit;
  P:= FData.ParentIndexOf(Idx);
  while P >= 0 do
  begin
    FCollapsed.Remove(FData.NodeAt(P)^.Id);
    P:= FData.ParentIndexOf(P);
  end;
end;

procedure TGraphViewModel.PushNav(AList: TList<TNavEntry>; const AEntry: TNavEntry);
const
  NAV_HIST_MAX = 100;   { ~100 steps; oldest entries fall off past that }
begin
  AList.Add(AEntry);
  while AList.Count > NAV_HIST_MAX do AList.Delete(0);
end;

function TGraphViewModel.PopNav(AList: TList<TNavEntry>): TNavEntry;
begin
  Result:= AList.Last;
  AList.Delete(AList.Count - 1);
end;

function TGraphViewModel.IsWithinDrill(const AId: string): Boolean;
{ True when AId is reachable in the current drill scope -- i.e. there is no drill
  root, or AId is a (strict) descendant of it. Walks AId's ancestors. }
var
  Idx, Guard: Integer;
  Root: string;
begin
  Root:= DrillRootId;
  if Root = '' then Exit(True);   { no drill -> whole project is in scope }
  Idx:= FData.FindNodeIndex(AId);
  Guard:= 0;
  while (Idx >= 0) and (Guard < 256) do
  begin
    Idx:= FData.ParentIndexOf(Idx);
    if (Idx >= 0) and SameText(FData.NodeAt(Idx).Id, Root) then Exit(True);
    Inc(Guard);
  end;
  Result:= False;
end;

procedure TGraphViewModel.NavigateTo(const AId: string);
begin
  PushNav(FNavStack, CaptureState);   { record where we were (Back target) }
  FNavFwd.Clear;                      { a new navigation branches -> drop redo }
  { Search / editor-sync can target ANY node. The projection shows only the drill
    root's subtree, so a target outside the current drill scope would stay hidden
    (CenterOnNode then finds nothing to center). Pop the drill back to the project
    so the target is reachable, then reveal it. }
  if not IsWithinDrill(AId) then
    FDrillPath.Clear;
  ExpandAncestors(AId);
  FCollapsed.Remove(AId);
  FSelectedId:= AId;
  DoChanged;
  DoSelectionChanged;
end;

procedure TGraphViewModel.DrillInto(const AId: string);
begin
  if AId = '' then Exit;
  if (FDrillPath.Count > 0) and (FDrillPath.Last = AId) then Exit;
  PushNav(FNavStack, CaptureState);   { drill-in is undoable via Back }
  FNavFwd.Clear;
  FDrillPath.Add   (AId);
  FCollapsed.Remove(AId); { expand the new root so its members are visible }
  FSelectedId:= AId;
  DoChanged;
  DoSelectionChanged;
end;

function TGraphViewModel.DrillRootId: string;
begin
  if FDrillPath.Count > 0 then Result:= FDrillPath.Last
  else Result:= '';
end;

function TGraphViewModel.DrillPath: TArray<string>;
begin
  Result:= FDrillPath.ToArray;
end;

procedure TGraphViewModel.DrillToDepth(ADepth: Integer);
begin
  if ADepth < 0 then ADepth:= 0;
  if ADepth > FDrillPath.Count then Exit;
  if ADepth = FDrillPath.Count then Exit;   { no change -> do not pollute history }
  PushNav(FNavStack, CaptureState);          { level-up is a move -> Back can undo it }
  FNavFwd.Clear;
  while FDrillPath.Count > ADepth do FDrillPath.Delete(FDrillPath.Count - 1);
  DoChanged;
  DoSelectionChanged;
end;

function TGraphViewModel.ResolveCrossDb(const AName: string): TCrossDbResolution;
begin
  if FCatalog <> nil then Result:= FCatalog.ResolveAcrossStores(AName)
  else FillChar(Result, SizeOf(Result), 0);
end;

procedure TGraphViewModel.JumpToCrossDb(const AName: string);
var
  Res: TCrossDbResolution;
begin
  Res:= ResolveCrossDb(AName);
  if not Res.Found then Exit;
  PushNav(FNavStack, CaptureState);
  FNavFwd.Clear;
  if Res.StoreIndex <> FActiveStore then
  begin
    FRestoring:= True;
    try
      OpenStore(Res.StoreIndex);
    finally
      FRestoring:= False;
    end;
    DoStoreChanged;
  end;
  FSelectedId:= Res.TargetId;
  DoChanged;
  DoSelectionChanged;
end; // procedure

procedure TGraphViewModel.Back;
var
  Entry: TNavEntry;
begin
  if FNavStack.Count = 0 then Exit;
  PushNav(FNavFwd, CaptureState);   { current view becomes the Forward target }
  Entry:= PopNav(FNavStack);
  RestoreState(Entry);
end;

procedure TGraphViewModel.Forward;
var
  Entry: TNavEntry;
begin
  if FNavFwd.Count = 0 then Exit;
  PushNav(FNavStack, CaptureState);
  Entry:= PopNav(FNavFwd);
  RestoreState(Entry);
end;

function TGraphViewModel.CanGoBack: Boolean;
begin
  Result:= FNavStack.Count > 0;
end;

function TGraphViewModel.CanGoForward: Boolean;
begin
  Result:= FNavFwd.Count > 0;
end;

function TGraphViewModel.ResolveCref(const AText: string): TCrefResolution;
begin
  if FSource <> nil then Result:= FSource.ResolveCref(AText)
  else
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Text:= AText;
    Result.Kind:= crkUnresolved;
  end;
end;

function TGraphViewModel.LocateSymbol(const AId: string; out AFile: string; out ALine: Integer): Boolean;
begin
  AFile:= ''; ALine:= 0;
  if FSource <> nil then Result:= FSource.LocateSymbol(AId, AFile, ALine)
  else Result:= False;
end;

procedure TGraphViewModel.SetShowAllTopLevel(AValue: Boolean);
begin
  if FShowAllTopLevel <> AValue then
  begin
    FShowAllTopLevel:= AValue;
    DoChanged;
  end;
end;

function TGraphViewModel.ShowAllTopLevel: Boolean;
begin
  Result:= FShowAllTopLevel;
end;

procedure TGraphViewModel.SetTopLevelLimit(AValue: Integer);
begin
  if AValue < 1 then AValue:= 1;
  if FTopLevelLimit <> AValue then
  begin
    FTopLevelLimit:= AValue;
    DoChanged;
  end;
end;

function TGraphViewModel.TopLevelLimit: Integer;
begin
  Result:= FTopLevelLimit;
end;

procedure TGraphViewModel.SetTopLevelCapThreshold(AValue: Integer);
begin
  if AValue < 1 then AValue:= 1;
  if FTopLevelCapThreshold <> AValue then
  begin
    FTopLevelCapThreshold:= AValue;
    DoChanged;
  end;
end;

function TGraphViewModel.TopLevelCapThreshold: Integer;
begin
  Result:= FTopLevelCapThreshold;
end;

function TGraphViewModel.HiddenTopLevelCount: Integer;
begin
  Result:= FHiddenTopLevelCount;
end;

procedure TGraphViewModel.ComputeNeighborhood(AStart, AHops: Integer; AEdges: TList<TProjEdge>; ASet: TDictionary<Integer, Boolean>);
var
  Frontier: TList<Integer>;
  Next    : TList<Integer>;
  Hop     : Integer       ;
  I       : Integer       ;
  J       : Integer       ;
  N       : Integer       ;
begin
  ASet.AddOrSetValue(AStart, True);
  Frontier:= TList<Integer>.Create;
  Next    := TList<Integer>.Create;
  try
    Frontier.Add(AStart);
    for Hop:= 1 to AHops do
    begin
      Next.Clear;
      for I:= 0 to Frontier.Count - 1 do
      begin
        N:= Frontier[I];
        for J:= 0 to AEdges.Count - 1 do
        begin
          if AEdges[J].SourceIdx = N then
            if not ASet.ContainsKey(AEdges[J].TargetIdx) then
            begin
              ASet.AddOrSetValue(AEdges[J].TargetIdx, True);
              Next.Add(AEdges[J].TargetIdx);
            end;
          if AEdges[J].TargetIdx = N then
            if not ASet.ContainsKey(AEdges[J].SourceIdx) then
            begin
              ASet.AddOrSetValue(AEdges[J].SourceIdx, True);
              Next.Add(AEdges[J].SourceIdx);
            end;
        end;
      end; // for
      Frontier.Clear;
      Frontier.AddRange(Next);
    end; // for
  finally
    Frontier.Free;
    Next.Free;
  end; // try
end; // procedure

end.
