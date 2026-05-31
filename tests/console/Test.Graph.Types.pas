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

initialization
  RegisterTest('HarnessSelfCheck', Test_HarnessSelfCheck);
  RegisterTest('SqlKindClassification', Test_SqlKindClassification);
end.
