program drag_lint_graph_tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  FireDAC.ConsoleUI.Wait,
  DragLint.Graph.Types in '..\..\src\control\DragLint.Graph.Types.pas',
  DragLint.Graph.Source in '..\..\src\control\DragLint.Graph.Source.pas',
  DragLint.Graph.TestFramework in 'DragLint.Graph.TestFramework.pas',
  Fake.GraphSource in 'Fake.GraphSource.pas',
  Test.Graph.Types in 'Test.Graph.Types.pas',
  Test.Graph.Source in 'Test.Graph.Source.pas',
  DragLint.Graph.ViewModel in '..\..\src\control\DragLint.Graph.ViewModel.pas',
  Test.Graph.Builders in 'Test.Graph.Builders.pas',
  Fake.DbCatalog in 'Fake.DbCatalog.pas',
  Test.Graph.ViewModel in 'Test.Graph.ViewModel.pas',
  DragLint.Graph.Source.Db in '..\..\src\control\DragLint.Graph.Source.Db.pas',
  Test.Db.Fixtures in 'Test.Db.Fixtures.pas',
  Test.Graph.Source.Db in 'Test.Graph.Source.Db.pas',
  DragLint.Graph.Style in '..\..\src\control\DragLint.Graph.Style.pas',
  Test.Graph.Style in 'Test.Graph.Style.pas';

begin
  WriteLn('drag-lint-graph console tests');
  WriteLn('');
  ExitCode := RunAllTests;
end.
