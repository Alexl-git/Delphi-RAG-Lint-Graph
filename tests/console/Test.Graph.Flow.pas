unit Test.Graph.Flow;

interface

implementation

uses
  System.SysUtils,
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Flow,
  Fake.FlowSource,
  DragLint.Graph.Source,
  DragLint.Graph.Source.Db,
  DragLint.Graph.Flow.Source.Db,
  Test.Db.Fixtures;

{ Lifetime convention for these tests: the local `Fake: TFakeFlowSource` object
  is used only for setup (AddInfo/AddCall). It is then handed to the builder as
  `Fake as IFlowSource`, which holds the only counted reference; when `B.Free`
  drops the builder, that reference releases and frees the fake. Do NOT call
  Fake.Free, and do NOT touch `Fake` after `B.Free` -- it is a dangling pointer
  at that point. }

{ Returns the index of the first NON-recursion step whose SymbolId = AId, or -1.
  Recursion markers (re-visited ancestors) are skipped so callers can ask
  "is this symbol present as a real, expandable step?". External steps have an
  empty SymbolId and so never match a non-empty AId. }
function StepById(const T: TFlowTree; const AId: string): Integer;
var I: Integer;
begin
  for I := 0 to High(T.Steps) do
    if (T.Steps[I].SymbolId = AId) and (not T.Steps[I].IsRecursion) then
      Exit(I);
  Result := -1;
end;

procedure Test_Flow_OrderAndDedup;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  Root: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'procedure A', True, 'root');
  Fake.AddInfo('B', 'procedure B', True, 'bee');
  Fake.AddInfo('C', 'procedure C', False);
  { A calls B at 30, C at 20, B again at 10 -> dedup B to first occurrence,
    insertion order preserved: B then C. }
  Fake.AddCall('A', 'B', 30);
  Fake.AddCall('A', 'C', 20);
  Fake.AddCall('A', 'B', 10);
  B := TFlowBuilder.Create(Fake as IFlowSource);
  try
    T := B.Build('A');
    Root := StepById(T, 'A');
    Check(Root = 0, 'root is step 0');
    CheckEqualsInt(2, Length(T.Steps[Root].ChildIndices),
      'A has 2 children after dedup');
    CheckEqualsStr('B', T.Steps[T.Steps[Root].ChildIndices[0]].SymbolId,
      'first child = B');
    CheckEqualsStr('C', T.Steps[T.Steps[Root].ChildIndices[1]].SymbolId,
      'second child = C');
  finally
    B.Free;
  end;
end;

procedure Test_Flow_Recursion;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  I, RecCount: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'procedure A', True, 'a');
  Fake.AddInfo('B', 'procedure B', True, 'b');
  Fake.AddCall('A', 'B', 10);
  Fake.AddCall('B', 'A', 10);   { back-edge -> recursion }
  B := TFlowBuilder.Create(Fake as IFlowSource);
  try
    T := B.Build('A');
    RecCount := 0;
    for I := 0 to High(T.Steps) do
      if T.Steps[I].IsRecursion then Inc(RecCount);
    CheckEqualsInt(1, RecCount, 'exactly one recursion marker (A under B)');
  finally
    B.Free;
  end;
end;

procedure Test_Flow_DepthCap;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  I, MaxDepth: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'a', True, 'a'); Fake.AddInfo('B', 'b', True, 'b');
  Fake.AddInfo('C', 'c', True, 'c'); Fake.AddInfo('D', 'd', True, 'd');
  Fake.AddCall('A', 'B', 1); Fake.AddCall('B', 'C', 1); Fake.AddCall('C', 'D', 1);
  B := TFlowBuilder.Create(Fake as IFlowSource, 2, 12);  { MaxDepth=2 }
  try
    T := B.Build('A');
    MaxDepth := 0;
    for I := 0 to High(T.Steps) do
      if T.Steps[I].Depth > MaxDepth then MaxDepth := T.Steps[I].Depth;
    CheckEqualsInt(2, MaxDepth, 'no step deeper than MaxDepth=2');
    Check(StepById(T, 'D') < 0, 'D (depth 3) is excluded');
    Check(T.Steps[StepById(T, 'C')].TruncatedChildren > 0,
      'C records its truncated children at the depth cap');
  finally
    B.Free;
  end;
end;

procedure Test_Flow_BreadthCap;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  Root: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'a', True, 'a');
  Fake.AddInfo('B', 'b', True, ''); Fake.AddInfo('C', 'c', True, '');
  Fake.AddInfo('D', 'd', True, ''); Fake.AddInfo('E', 'e', True, '');
  Fake.AddCall('A', 'B', 1); Fake.AddCall('A', 'C', 2);
  Fake.AddCall('A', 'D', 3); Fake.AddCall('A', 'E', 4);
  B := TFlowBuilder.Create(Fake as IFlowSource, 6, 2);  { MaxBreadth=2 }
  try
    T := B.Build('A');
    Root := StepById(T, 'A');
    CheckEqualsInt(2, Length(T.Steps[Root].ChildIndices),
      'A shows only MaxBreadth=2 children');
    CheckEqualsInt(2, T.Steps[Root].TruncatedChildren,
      'A records 2 truncated children');
  finally
    B.Free;
  end;
end;

procedure Test_Flow_DegradeAndExternal;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  Cidx, Eidx, I: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'procedure A', True, 'a');
  Fake.AddInfo('C', 'procedure C', False);          { undocumented but resolves }
  Fake.AddCall('A', 'C', 10);
  Fake.AddCall('A', '', 20, 'Writeln');             { external/unresolved call }
  B := TFlowBuilder.Create(Fake as IFlowSource);
  try
    T := B.Build('A');
    Cidx := StepById(T, 'C');
    Check(Cidx >= 0, 'C present');
    Check(not T.Steps[Cidx].Doc.HasDoc, 'C undocumented');
    CheckEqualsStr('procedure C', T.Steps[Cidx].Signature,
      'C still shows its signature (degradation)');
    Eidx := -1;
    for I := 0 to High(T.Steps) do
      if T.Steps[I].IsExternal then Eidx := I;
    Check(Eidx >= 0, 'external step present');
    CheckEqualsStr('Writeln', T.Steps[Eidx].RawName,
      'external step uses RawName');
  finally
    B.Free;
  end;
end;

procedure Test_Flow_DbSource_RealFixture;
var
  DbPath: string;
  Cat: IDbCatalog;
  FlowSrc: IFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  Root, Child: Integer;
begin
  DbPath := CreateTempV6Db;
  try
    Cat := TDbCatalog.Create([DbPath]);
    FlowSrc := TDbFlowSource.Create(Cat);
    B := TFlowBuilder.Create(FlowSrc);
    try
      T := B.Build('U.TFoo.Bar');

      Root := 0;
      CheckEqualsStr('U.TFoo.Bar', T.Steps[Root].SymbolId, 'root = Bar');
      Check(T.Steps[Root].Doc.HasDoc, 'Bar documented');
      CheckEqualsStr('Hi', T.Steps[Root].Doc.Summary, 'Bar summary = Hi');
      CheckEqualsInt(1, Length(T.Steps[Root].ChildIndices),
        'Bar has one callee (MB; the type_use is not a call)');

      Child := T.Steps[Root].ChildIndices[0];
      CheckEqualsStr('U.TBaz.MB', T.Steps[Child].SymbolId, 'callee = MB');
      CheckEqualsInt(12, T.Steps[Child].CallLine, 'MB called at line 12');
      Check(not T.Steps[Child].Doc.HasDoc,
        'MB undocumented (degradation path)');
      CheckEqualsStr('procedure MB', T.Steps[Child].Signature,
        'MB still shows its signature');
    finally
      B.Free;
    end;
    Cat := nil;
    FlowSrc := nil;
  finally
    DeleteTempDb(DbPath);
  end;
end;

initialization
  RegisterTest('Flow_OrderAndDedup',      Test_Flow_OrderAndDedup);
  RegisterTest('Flow_Recursion',          Test_Flow_Recursion);
  RegisterTest('Flow_DepthCap',           Test_Flow_DepthCap);
  RegisterTest('Flow_BreadthCap',         Test_Flow_BreadthCap);
  RegisterTest('Flow_DegradeAndExternal', Test_Flow_DegradeAndExternal);
  RegisterTest('Flow_DbSource_RealFixture', Test_Flow_DbSource_RealFixture);
end.
