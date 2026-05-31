unit Test.Graph.Source;

interface

implementation

uses
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  Fake.GraphSource;

procedure Test_FakeSourceLoadsTopology;
var
  Src: IGraphSource;
  D: TGraphData;
begin
  Src := TFakeGraphSource.Create;
  D := TGraphData.Create;
  try
    Check(Src.LoadTopology(D), 'LoadTopology returns True');
    CheckEqualsInt(4, D.NodeCount, '3 fixture nodes + synthetic project');
    Check(D.FindNodeIndex('U.TFoo.Bar') >= 0, 'method node present');
    CheckEqualsInt(D.FindNodeIndex('U.TFoo'),
      D.ParentIndexOf(D.FindNodeIndex('U.TFoo.Bar')), 'hierarchy built via source');
  finally
    D.Free;
  end;
end;

procedure Test_FakeSourceDocAndCref;
var
  Src: IGraphSource;
  Doc: TGraphDoc;
  Cref: TCrefResolution;
begin
  Src := TFakeGraphSource.Create;
  Doc := Src.GetDoc('U.TFoo.Bar');
  Check(Doc.HasDoc, 'Bar is documented');
  CheckEqualsStr('Fake summary for Bar.', Doc.Summary, 'doc summary roundtrips');

  Cref := Src.ResolveCref('U.TFoo');
  Check(Cref.Kind = crkResolved, 'known cref resolves');
  CheckEqualsStr('U.TFoo', Cref.TargetId, 'cref target id');

  Cref := Src.ResolveCref('Nope.Missing');
  Check(Cref.Kind = crkUnresolved, 'unknown cref unresolved');
end;

initialization
  RegisterTest('FakeSourceLoadsTopology', Test_FakeSourceLoadsTopology);
  RegisterTest('FakeSourceDocAndCref', Test_FakeSourceDocAndCref);
end.
