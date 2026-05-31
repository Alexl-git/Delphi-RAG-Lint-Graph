unit DragLint.Graph.Reg;
{ Design-time registration unit.
  Contained ONLY in DragLintGraphDcl.dpk (design-time package).
  Must NOT be in the runtime package (RegisterComponents pulls in designide). }

interface

procedure Register;

implementation

uses
  Classes,
  DragLint.Graph.Control;

procedure Register;
begin
  RegisterComponents('Delphi-RAG-Lint', [TDragLintGraphControl]);
end;

end.
