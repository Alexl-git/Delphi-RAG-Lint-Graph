unit DragLint.Graph.Types;

{ Shared types for TDragLintGraphControl.

  Kept ASCII / no Unicode per the project-wide ANSI rule for .pas files. }

interface

uses
  System.SysUtils
  , System.Types
  , System.Generics.Collections
  ;

type
  TGraphNodeKind = (
    nkUnit, nkType, nkClass, nkInterface, nkRecord, nkProcedure, nkFunction, nkMethod, nkField, nkProperty, nkConst, nkVar, nkDfmForm, nkProject, nkSqlTable, nkSqlColumn,
    nkSqlIndex, nkSqlTrigger, nkSqlGenerator, nkSqlView, nkSqlProcedure, nkSqlException, nkSqlDomain, nkOther);

  TGraphEdgeKind = ( ekCalls, ekUses, ekInherits, ekImplements, ekContains, ekDfmBinds, ekTypeRef, ekSqlTableRef, ekOther );

  { TGraphNode is a value record (no class allocation) so we can keep
    tens of thousands of them in a TList<TGraphNode> with minimal overhead. }
  TGraphNode = record
    Id      : string        ; { stable id, e.g. fully qualified name }
    Label_  : string        ; { display label -- note trailing _ avoids Delphi reserved word }
    Kind    : TGraphNodeKind;
    FilePath: string        ; { source path (.pas / .dfm) for "open in IDE" }
    Line    : Integer       ; { 1-based line for jump-to-source }
    Col     : Integer       ; { 1-based col }
    Layer   : string        ; { optional grouping key (e.g. "CLIENT", "SERVER", "RTL") }

    DbId         : Int64  ; { originating symbols.id (0 if synthetic) }
    Signature    : string ; { symbols.signature (e.g. SQL column type) }
    Modifiers    : string ; { symbols.modifiers -- member visibility for UML glyphs }
    Section      : string ; { 'interface' | 'implementation' | '' (usability) }
    KindText     : string ; { raw symbols.kind ('enum','set','alias',...) for display }
    ParentId     : string ; { id of containment parent; '' if none/root }
    ParentIdx    : Integer; { resolved by BuildHierarchy; -1 = root }
    Documented   : Boolean; { has a symbol_docs row }
    Deprecated   : Boolean; { symbol_docs.deprecated }
    IsExternal   : Boolean; { used unit/ref with no in-store target }
    CrossDbTarget: Boolean; { name resolves only in another store }

    { Layout state - mutated by the layout engine }
    X     : Double ;
    Y     : Double ;
    VX    : Double ;
    VY    : Double ;
    Radius: Double ; { rendered node radius }
    Fixed : Boolean; { true => excluded from layout updates }

    { Render state }
    Selected: Boolean;
    Hovered : Boolean;
  end; // record
  PGraphNode = ^TGraphNode;

  TGraphEdge = record
    SourceId: string        ;
    TargetId: string        ;
    Kind    : TGraphEdgeKind;
    Label_  : string        ; { optional }
    Weight  : Double        ; { for spring strength; default 1.0 }
  end;

  { One outgoing call from a symbol body to a callee. Returned by
    IGraphSource.GetCallees; the flow engine maps it to a TFlowCallee. }
  TCallRef = record
    TargetQName: string ; { resolved callee qualified_name ('' if unresolved) }
    RawName    : string ; { refs.name_text as written (label for unresolved) }
    CallLine   : Integer; { refs.start_line -- call-site line in the caller }
  end;

  TDocParam = record
    Name: string;
    Desc: string;
  end;

  TDocException = record
    TypeName: string;
    Desc    : string;
  end;

  TGraphDoc = record
    HasDoc     : Boolean              ; { False => undocumented (no symbol_docs row) }
    Format     : string               ; { 'xmldoc' | 'pasdoc' | 'oneline' | 'loose' }
    Summary    : string               ;
    Remarks    : string               ;
    ReturnsText: string               ;
    ExampleText: string               ;
    SinceText  : string               ;
    Deprecated : Boolean              ;
    Params     : TArray<TDocParam>    ;
    Exceptions : TArray<TDocException>;
    SeeAlso    : TArray<string>       ; { verbatim cref strings }
  end;

  TCrefKind = (crkUrl, crkResolved, crkAmbiguous, crkUnresolved);

  TCrefResolution = record
    Kind      : TCrefKind     ;
    Text      : string        ; { original cref text }
    Url       : string        ; { when crkUrl }
    TargetId  : string        ; { when crkResolved }
    StoreIndex: Integer       ; { when crkResolved }
    Candidates: TArray<string>; { when crkAmbiguous }
  end;

  TCrossDbResolution = record
    Found     : Boolean;
    StoreIndex: Integer;
    TargetId  : string ;
  end;

  TGraphData = class
    strict private
      FNodes    : TList<TGraphNode>           ;
      FEdges    : TList<TGraphEdge>           ;
      FIndexById: TDictionary<string, Integer>; { node id -> node index }
      FChildren : TObjectList<TList<Integer>> ; { adjacency, index-aligned }
      procedure RebuildIndex;
      procedure BuildChildren;
    public
      constructor Create;
      destructor Destroy; override;

      procedure Clear;
      procedure AddNode(const ANode: TGraphNode);
      procedure AddEdge(const AEdge: TGraphEdge);

      function NodeCount: Integer;
      function EdgeCount: Integer;
      function NodeAt(AIndex: Integer): PGraphNode; { direct mutation }
      function EdgeAt(AIndex: Integer): TGraphEdge;
      function FindNodeIndex(const AId: string): Integer; { -1 if absent }
      function FindNode     (const AId: string): PGraphNode; { nil if absent }

      procedure BuildHierarchy;
      function ParentIndexOf(AIndex: Integer): Integer     ;
      function ChildrenOf(AIndex: Integer): TArray<Integer>;
      function RootIndices: TArray<Integer>                ;
      function DescendantCount(AIndex: Integer): Integer   ;
  end;

function IsSqlKind(AKind: TGraphNodeKind): Boolean;

implementation

function IsSqlKind(AKind: TGraphNodeKind): Boolean;
begin
  Result:= AKind in [nkSqlTable, nkSqlColumn, nkSqlIndex, nkSqlTrigger, nkSqlGenerator, nkSqlView, nkSqlProcedure, nkSqlException, nkSqlDomain];
end;

constructor TGraphData.Create;
begin
  inherited;
  FNodes:= TList<TGraphNode>.Create;
  FEdges:= TList<TGraphEdge>.Create;
  FIndexById:= TDictionary<string, Integer>.Create;
  FChildren:= TObjectList<TList<Integer>>.Create(True);
end;

destructor TGraphData.Destroy;
begin
  FChildren.Free;
  FIndexById.Free;
  FEdges.Free;
  FNodes.Free;
  inherited;
end;

procedure TGraphData.Clear;
begin
  FNodes.Clear;
  FEdges.Clear;
  FIndexById.Clear;
  FChildren.Clear;
end;

procedure TGraphData.AddNode(const ANode: TGraphNode);
begin
  FIndexById.AddOrSetValue(ANode.Id, FNodes.Count);
  FNodes.Add(ANode);
end;

procedure TGraphData.AddEdge(const AEdge: TGraphEdge);
begin
  FEdges.Add(AEdge);
end;

procedure TGraphData.RebuildIndex;
var
  I: Integer;
begin
  FIndexById.Clear;
  for I:= 0 to FNodes.Count - 1 do FIndexById.AddOrSetValue(FNodes[I].Id, I);
end;

function TGraphData.NodeCount: Integer;
begin
  Result:= FNodes.Count;
end;

function TGraphData.EdgeCount: Integer;
begin
  Result:= FEdges.Count;
end;

function TGraphData.NodeAt(AIndex: Integer): PGraphNode;
begin
  Result:= PGraphNode(FNodes.List);
  Inc(Result, AIndex);
end;

function TGraphData.EdgeAt(AIndex: Integer): TGraphEdge;
begin
  Result:= FEdges[AIndex];
end;

function TGraphData.FindNodeIndex(const AId: string): Integer;
begin
  if not FIndexById.TryGetValue(AId, Result) then Result:= -1;
end;

function TGraphData.FindNode(const AId: string): PGraphNode;
var
  Idx: Integer;
begin
  Idx:= FindNodeIndex(AId);
  if Idx >= 0 then Result:= NodeAt(Idx)
  else Result:= nil;
end;

procedure TGraphData.BuildChildren;
var
  I: Integer;
  P: Integer;
begin
  FChildren.Clear;
  for I:= 0 to FNodes.Count - 1 do FChildren.Add(TList<Integer>.Create);
  for I:= 0 to FNodes.Count - 1 do
  begin
    P:= NodeAt(I).ParentIdx;
    if (P >= 0) and (P < FNodes.Count) then FChildren[P].Add(I);
  end;
end;

procedure TGraphData.BuildHierarchy;
var
  I            : Integer       ;
  SrcIdx       : Integer       ;
  DstIdx       : Integer       ;
  ProjectIdx   : Integer       ;
  N            : PGraphNode    ;
  E            : TGraphEdge    ;
  RootlessUnits: TList<Integer>;
  ProjNode     : TGraphNode    ;
begin
  RebuildIndex;

  { 1. explicit ParentId }
  for I:= 0 to FNodes.Count - 1 do
  begin
    N:= NodeAt(I);
    if N.ParentId <> '' then N.ParentIdx:= FindNodeIndex(N.ParentId)
    else N.ParentIdx:= -1;
  end;

  { 2. contains-edge fallback for still-unparented targets }
  for I:= 0 to FEdges.Count - 1 do
  begin
    E:= FEdges[I];
    if E.Kind <> ekContains then Continue;
    SrcIdx:= FindNodeIndex(E.SourceId);
    DstIdx:= FindNodeIndex(E.TargetId);
    if (SrcIdx < 0) or (DstIdx < 0) then Continue;
    N:= NodeAt(DstIdx);
    if N.ParentIdx < 0 then N.ParentIdx:= SrcIdx;
  end;

  { 3. project-root synthesis: parent EVERY rootless node under a single
    nkProject.  Originally only rootless units were adopted, which left
    orphaned non-unit symbols (their parent unit unresolved, or detached by the
    MaxNodes truncation) as free top-level roots.  On a real index that is
    thousands of nodes the top-level cap never sees (it only governs @project's
    children), so the initial view stayed huge (finding F8).  Adopting all
    rootless nodes makes @project the single forest root and lets the cap bound
    the whole visible top level. }
  ProjectIdx:= -1;
  for I:= 0 to FNodes.Count - 1 do
    if NodeAt(I).Kind = nkProject then
    begin
      ProjectIdx:= I;
      Break;
    end;

  RootlessUnits:= TList<Integer>.Create;
  try
    for I:= 0 to FNodes.Count - 1 do
    begin
      N:= NodeAt(I);
      if (N.ParentIdx < 0) and (N.Kind <> nkProject) then RootlessUnits.Add(I);
    end;

    if (RootlessUnits.Count > 0) and (ProjectIdx < 0) then
    begin
      FillChar(ProjNode, SizeOf(ProjNode), 0);
      ProjNode.Id      := '@project';
      ProjNode.Label_  := 'Project';
      ProjNode.Kind    := nkProject;
      ProjNode.ParentId:= '';
      ProjNode.ParentIdx:= -1;
      ProjNode.Radius:= 16;
      AddNode(ProjNode); { appends; FIndexById updated }
      ProjectIdx:= FNodes.Count - 1;
    end;

    if ProjectIdx >= 0 then
      for I in RootlessUnits do NodeAt(I).ParentIdx:= ProjectIdx;
  finally
    RootlessUnits.Free;
  end; // try

  { 4. adjacency }
  BuildChildren;
end; // procedure

function TGraphData.ParentIndexOf(AIndex: Integer): Integer;
begin
  Result:= NodeAt(AIndex).ParentIdx;
end;

function TGraphData.ChildrenOf(AIndex: Integer): TArray<Integer>;
begin
  if (AIndex >= 0) and (AIndex < FChildren.Count) then Result:= FChildren[AIndex].ToArray
  else Result:= nil;
end;

function TGraphData.RootIndices: TArray<Integer>;
var
  I: Integer       ;
  L: TList<Integer>;
begin
  L:= TList<Integer>.Create;
  try
    for I:= 0 to FNodes.Count - 1 do
      if NodeAt(I).ParentIdx < 0 then L.Add(I);
    Result:= L.ToArray;
  finally
    L.Free;
  end;
end;

function TGraphData.DescendantCount(AIndex: Integer): Integer;
var
  Child: Integer;
begin
  Result:= 0;
  if (AIndex < 0) or (AIndex >= FChildren.Count) then Exit;
  for Child in FChildren[AIndex] do Result:= Result + 1 + DescendantCount(Child);
end;

end.
