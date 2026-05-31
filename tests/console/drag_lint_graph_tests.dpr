program drag_lint_graph_tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DragLint.Graph.TestFramework in 'DragLint.Graph.TestFramework.pas',
  Test.Graph.Types in 'Test.Graph.Types.pas';

begin
  WriteLn('drag-lint-graph console tests');
  WriteLn('');
  ExitCode := RunAllTests;
end.
