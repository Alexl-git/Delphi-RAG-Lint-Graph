program drag_lint_graph_tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DragLint.Graph.Types in '..\..\src\control\DragLint.Graph.Types.pas',
  DragLint.Graph.Source in '..\..\src\control\DragLint.Graph.Source.pas',
  DragLint.Graph.TestFramework in 'DragLint.Graph.TestFramework.pas',
  Fake.GraphSource in 'Fake.GraphSource.pas',
  Test.Graph.Types in 'Test.Graph.Types.pas',
  Test.Graph.Source in 'Test.Graph.Source.pas',
  DragLint.Graph.ViewModel in '..\..\src\control\DragLint.Graph.ViewModel.pas',
  Test.Graph.Builders in 'Test.Graph.Builders.pas',
  Test.Graph.ViewModel in 'Test.Graph.ViewModel.pas';

begin
  WriteLn('drag-lint-graph console tests');
  WriteLn('');
  ExitCode := RunAllTests;
end.
