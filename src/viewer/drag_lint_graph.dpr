program drag_lint_graph;

{$APPTYPE GUI}
{$R *.res}

uses
  Vcl.Forms,
  DragLint.Graph.Types in '..\control\DragLint.Graph.Types.pas',
  DragLint.Graph.Layout in '..\control\DragLint.Graph.Layout.pas',
  DragLint.Graph.Control in '..\control\DragLint.Graph.Control.pas',
  DragLint.Graph.Json in '..\control\DragLint.Graph.Json.pas',
  MainForm in 'MainForm.pas';

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'drag-lint-graph';
  Application.CreateForm(TfrmMain, MainForm.frmMain);
  Application.Run;
end.
