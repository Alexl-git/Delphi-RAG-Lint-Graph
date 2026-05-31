unit DragLint.Graph.Types;

{ Shared types for TDragLintGraphControl.

  Kept ASCII / no Unicode per the project-wide ANSI rule for .pas files. }

interface

uses
  System.SysUtils, System.Types, System.Generics.Collections;

type
  TGraphNodeKind = (
    nkUnit,
    nkType,
    nkClass,
    nkInterface,
    nkRecord,
    nkProcedure,
    nkFunction,
    nkMethod,
    nkField,
    nkProperty,
    nkConst,
    nkVar,
    nkDfmForm,
    nkProject,
    nkSqlTable,
    nkSqlColumn,
    nkSqlIndex,
    nkSqlTrigger,
    nkSqlGenerator,
    nkSqlView,
    nkSqlProcedure,
    nkSqlException,
    nkSqlDomain,
    nkOther
  );

  TGraphEdgeKind = (
    ekCalls,
    ekUses,
    ekInherits,
    ekImplements,
    ekContains,
    ekDfmBinds,
    ekTypeRef,
    ekSqlTableRef,
    ekOther
  );

  { TGraphNode is a value record (no class allocation) so we can keep
    tens of thousands of them in a TList<TGraphNode> with minimal overhead. }
  TGraphNode = record
    Id:       string;       { stable id, e.g. fully qualified name }
    Label_:   string;       { display label -- note trailing _ avoids Delphi reserved word }
    Kind:     TGraphNodeKind;
    FilePath: string;       { source path (.pas / .dfm) for "open in IDE" }
    Line:     Integer;      { 1-based line for jump-to-source }
    Col:      Integer;      { 1-based col }
    Layer:    string;       { optional grouping key (e.g. "CLIENT", "SERVER", "RTL") }

    { Layout state - mutated by the layout engine }
    X, Y:     Double;       { logical world coordinates (not screen pixels) }
    VX, VY:   Double;       { velocity for force-directed iteration }
    Radius:   Double;       { rendered node radius }
    Fixed:    Boolean;      { true => excluded from layout updates }

    { Render state }
    Selected: Boolean;
    Hovered:  Boolean;
  end;
  PGraphNode = ^TGraphNode;

  TGraphEdge = record
    SourceId: string;
    TargetId: string;
    Kind:     TGraphEdgeKind;
    Label_:   string;       { optional }
    Weight:   Double;       { for spring strength; default 1.0 }
  end;

  TGraphData = class
  strict private
    FNodes: TList<TGraphNode>;
    FEdges: TList<TGraphEdge>;
    FIndexById: TDictionary<string, Integer>;  { node id -> node index }
    procedure RebuildIndex;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    procedure AddNode(const ANode: TGraphNode);
    procedure AddEdge(const AEdge: TGraphEdge);

    function NodeCount: Integer;
    function EdgeCount: Integer;
    function NodeAt(AIndex: Integer): PGraphNode;       { direct mutation }
    function EdgeAt(AIndex: Integer): TGraphEdge;
    function FindNodeIndex(const AId: string): Integer; { -1 if absent }
    function FindNode(const AId: string): PGraphNode;   { nil if absent }
  end;

function IsSqlKind(AKind: TGraphNodeKind): Boolean;

implementation

function IsSqlKind(AKind: TGraphNodeKind): Boolean;
begin
  Result := AKind in [nkSqlTable, nkSqlColumn, nkSqlIndex, nkSqlTrigger,
    nkSqlGenerator, nkSqlView, nkSqlProcedure, nkSqlException, nkSqlDomain];
end;

constructor TGraphData.Create;
begin
  inherited;
  FNodes     := TList<TGraphNode>.Create;
  FEdges     := TList<TGraphEdge>.Create;
  FIndexById := TDictionary<string, Integer>.Create;
end;

destructor TGraphData.Destroy;
begin
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
  for I := 0 to FNodes.Count - 1 do
    FIndexById.AddOrSetValue(FNodes[I].Id, I);
end;

function TGraphData.NodeCount: Integer;
begin
  Result := FNodes.Count;
end;

function TGraphData.EdgeCount: Integer;
begin
  Result := FEdges.Count;
end;

function TGraphData.NodeAt(AIndex: Integer): PGraphNode;
begin
  Result := PGraphNode(FNodes.List);
  Inc(Result, AIndex);
end;

function TGraphData.EdgeAt(AIndex: Integer): TGraphEdge;
begin
  Result := FEdges[AIndex];
end;

function TGraphData.FindNodeIndex(const AId: string): Integer;
begin
  if not FIndexById.TryGetValue(AId, Result) then
    Result := -1;
end;

function TGraphData.FindNode(const AId: string): PGraphNode;
var
  Idx: Integer;
begin
  Idx := FindNodeIndex(AId);
  if Idx >= 0 then
    Result := NodeAt(Idx)
  else
    Result := nil;
end;

end.
