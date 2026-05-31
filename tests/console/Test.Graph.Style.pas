unit Test.Graph.Style;

interface

implementation

uses
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Style;

procedure Test_NodeStyleShapes;
begin
  Check(NodeStyleFor(nkSqlTable).Shape = nsBox, 'sql_table is a box');
  Check(NodeStyleFor(nkSqlTrigger).Shape = nsHexagon, 'sql_trigger is a hexagon');
  Check(NodeStyleFor(nkProject).Shape = nsRoundBox, 'project is a round box');
  Check(NodeStyleFor(nkMethod).Shape = nsEllipse, 'method is an ellipse');
  Check(NodeStyleFor(nkSqlTable).Fill = CL_SQL, 'sql kinds use SQL fill');
end;

procedure Test_EdgeStyleSection;
var
  S: TEdgeStyle;
begin
  S := EdgeStyleFor(ekUses, 'interface', False, False);
  Check(S.Dash = edSolid, 'interface uses = solid');
  S := EdgeStyleFor(ekUses, 'implementation', False, False);
  Check(S.Dash = edDash, 'implementation uses = dashed');
  S := EdgeStyleFor(ekUses, 'program', False, False);
  Check(S.Dash = edBold, 'program uses = bold');
  S := EdgeStyleFor(ekCalls, '', False, False);
  Check(S.Color = CL_EDGE_CALL, 'call edge has call color');
end;

procedure Test_EdgeStyleAggregatedAndCrossDb;
var
  S: TEdgeStyle;
begin
  S := EdgeStyleFor(ekCalls, '', True, False);
  Check(S.Width = 2, 'aggregated widens to 2');
  S := EdgeStyleFor(ekUses, 'interface', False, True);
  Check(S.Color = CL_EDGE_XDB, 'cross-db edge uses xdb accent');
  Check(S.Dash = edDash, 'cross-db edge dashed');
end;

initialization
  RegisterTest('NodeStyleShapes', Test_NodeStyleShapes);
  RegisterTest('EdgeStyleSection', Test_EdgeStyleSection);
  RegisterTest('EdgeStyleAggregatedAndCrossDb', Test_EdgeStyleAggregatedAndCrossDb);
end.
