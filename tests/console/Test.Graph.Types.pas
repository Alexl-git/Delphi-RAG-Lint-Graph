unit Test.Graph.Types;

interface

implementation

uses
  DragLint.Graph.TestFramework;

procedure Test_HarnessSelfCheck;
begin
  Check(True, 'harness self-check should pass');
  CheckEqualsInt(2, 1 + 1, 'arithmetic sanity');
end;

initialization
  RegisterTest('HarnessSelfCheck', Test_HarnessSelfCheck);
end.
