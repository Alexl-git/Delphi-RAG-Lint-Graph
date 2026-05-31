program drag_lint_graph;

{$APPTYPE GUI}
{$R *.res}

uses
  Vcl.Forms,
  FireDAC.VCLUI.Wait,
  DragLint.Graph.Types    in '..\control\DragLint.Graph.Types.pas',
  DragLint.Graph.Layout   in '..\control\DragLint.Graph.Layout.pas',
  DragLint.Graph.Style    in '..\control\DragLint.Graph.Style.pas',
  DragLint.Graph.Source   in '..\control\DragLint.Graph.Source.pas',
  DragLint.Graph.ViewModel in '..\control\DragLint.Graph.ViewModel.pas',
  DragLint.Graph.Source.Db in '..\control\DragLint.Graph.Source.Db.pas',
  DragLint.Graph.Control  in '..\control\DragLint.Graph.Control.pas',
  MainForm                in 'MainForm.pas';

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'drag-lint-graph';
  Application.CreateForm(TfrmMain, MainForm.frmMain);
  Application.Run;
end.
