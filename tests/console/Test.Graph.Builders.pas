unit Test.Graph.Builders;

interface

uses
  DragLint.Graph.Types;

function BuildNode(const AId: string; AKind: TGraphNodeKind;
  const AParentId: string): TGraphNode;
{ Two units (uA, uB), each a class with one method; plus a call edge
  MA->MB and an interface uses edge uA->uB. Containment via ParentId.
  Caller owns the returned TGraphData and must call BuildHierarchy. }
function BuildTwoUnitGraph: TGraphData;

implementation

uses
  System.SysUtils;

function BuildNode(const AId: string; AKind: TGraphNodeKind;
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

function BuildTwoUnitGraph: TGraphData;
var
  E: TGraphEdge;
begin
  Result := TGraphData.Create;
  Result.AddNode(BuildNode('uA', nkUnit, ''));
  Result.AddNode(BuildNode('uA.TA', nkClass, 'uA'));
  Result.AddNode(BuildNode('uA.TA.MA', nkMethod, 'uA.TA'));
  Result.AddNode(BuildNode('uB', nkUnit, ''));
  Result.AddNode(BuildNode('uB.TB', nkClass, 'uB'));
  Result.AddNode(BuildNode('uB.TB.MB', nkMethod, 'uB.TB'));

  FillChar(E, SizeOf(E), 0);
  E.SourceId := 'uA.TA.MA'; E.TargetId := 'uB.TB.MB'; E.Kind := ekCalls; E.Weight := 1.0;
  Result.AddEdge(E);
  FillChar(E, SizeOf(E), 0);
  E.SourceId := 'uA'; E.TargetId := 'uB'; E.Kind := ekUses; E.Weight := 1.0;
  E.Label_ := 'interface';
  Result.AddEdge(E);

  Result.BuildHierarchy;  { adds synthetic @project root over uA, uB }
end;

end.
