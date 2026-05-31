unit Test.Graph.Types;

interface

implementation

uses
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types;

procedure Test_HarnessSelfCheck;
begin
  Check(True, 'harness self-check should pass');
  CheckEqualsInt(2, 1 + 1, 'arithmetic sanity');
end;

procedure Test_SqlKindClassification;
begin
  Check(IsSqlKind(nkSqlTable), 'nkSqlTable is a SQL kind');
  Check(IsSqlKind(nkSqlColumn), 'nkSqlColumn is a SQL kind');
  Check(IsSqlKind(nkSqlDomain), 'nkSqlDomain is a SQL kind');
  Check(not IsSqlKind(nkClass), 'nkClass is not a SQL kind');
  Check(not IsSqlKind(nkProject), 'nkProject is not a SQL kind');
  Check(not IsSqlKind(nkUnit), 'nkUnit is not a SQL kind');
end;

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

procedure Test_HierarchyFromExplicitParent;
var
  D: TGraphData;
  UIdx, FooIdx, BarIdx: Integer;
begin
  D := TGraphData.Create;
  try
    D.AddNode(MakeNode('U', nkUnit, ''));
    D.AddNode(MakeNode('U.TFoo', nkClass, 'U'));
    D.AddNode(MakeNode('U.TFoo.Bar', nkMethod, 'U.TFoo'));
    D.BuildHierarchy;

    UIdx   := D.FindNodeIndex('U');
    FooIdx := D.FindNodeIndex('U.TFoo');
    BarIdx := D.FindNodeIndex('U.TFoo.Bar');

    CheckEqualsInt(UIdx, D.ParentIndexOf(FooIdx), 'TFoo parent is U');
    CheckEqualsInt(FooIdx, D.ParentIndexOf(BarIdx), 'Bar parent is TFoo');
    CheckEqualsInt(1, Length(D.ChildrenOf(UIdx)), 'U has one child');
    CheckEqualsInt(2, D.DescendantCount(UIdx), 'U has two descendants');
    CheckEqualsInt(0, D.DescendantCount(BarIdx), 'Bar has no descendants');
  finally
    D.Free;
  end;
end;

procedure Test_ProjectRootSynthesis;
var
  D: TGraphData;
  Roots: TArray<Integer>;
  ProjIdx: Integer;
begin
  D := TGraphData.Create;
  try
    D.AddNode(MakeNode('UA', nkUnit, ''));
    D.AddNode(MakeNode('UB', nkUnit, ''));
    D.BuildHierarchy;

    Roots := D.RootIndices;
    CheckEqualsInt(1, Length(Roots), 'exactly one root after synthesis');
    ProjIdx := Roots[0];
    Check(D.NodeAt(ProjIdx).Kind = nkProject, 'synthetic root is nkProject');
    CheckEqualsInt(2, Length(D.ChildrenOf(ProjIdx)), 'both units parented to project');
    CheckEqualsInt(3, D.NodeCount, 'project node was appended');
  finally
    D.Free;
  end;
end;

procedure Test_ContainsEdgeFallback;
var
  D: TGraphData;
  E: TGraphEdge;
  UIdx, FooIdx: Integer;
begin
  D := TGraphData.Create;
  try
    D.AddNode(MakeNode('U', nkUnit, ''));            { no explicit ParentId }
    D.AddNode(MakeNode('U.TFoo', nkClass, ''));      { parent only via edge }
    FillChar(E, SizeOf(E), 0);
    E.SourceId := 'U';
    E.TargetId := 'U.TFoo';
    E.Kind := ekContains;
    E.Weight := 1.0;
    D.AddEdge(E);
    D.BuildHierarchy;

    UIdx   := D.FindNodeIndex('U');
    FooIdx := D.FindNodeIndex('U.TFoo');
    CheckEqualsInt(UIdx, D.ParentIndexOf(FooIdx), 'TFoo parent derived from contains edge');
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest('HarnessSelfCheck', Test_HarnessSelfCheck);
  RegisterTest('SqlKindClassification', Test_SqlKindClassification);
  RegisterTest('HierarchyFromExplicitParent', Test_HierarchyFromExplicitParent);
  RegisterTest('ProjectRootSynthesis', Test_ProjectRootSynthesis);
  RegisterTest('ContainsEdgeFallback', Test_ContainsEdgeFallback);
end.
