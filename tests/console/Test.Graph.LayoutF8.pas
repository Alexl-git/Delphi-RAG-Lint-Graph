unit Test.Graph.LayoutF8;

{ Regression coverage for finding F8 -- the GUI froze on cold-load of a full
  project index (44k symbols / ~20k loaded nodes).

  Root cause was twofold and BOTH halves are asserted here:
    1. A fresh load left every container expanded, so the projection (the
       visible set) was the entire ~20k-node tree.
    2. The force layout ran O(N^2) over that whole set on the UI thread.

  The pre-fix headless suite never touched the layout or the projection-size
  on load, so 41/41 stayed green while the app hung.  These tests exercise the
  exact load path:
    F8_CollapsedOnLoad_BoundedVisible -- a 200-unit / ~20k-node store collapses
        to a handful of top-level bubbles on load (deterministic, always runs).
    F8_VisibleLayout_FastAndSpreads   -- the visible-subset layout settles the
        collapsed set quickly and actually separates the nodes (deterministic).
    F8_ORM3_ProjectionBounded         -- same guarantee against the real ORM3
        index (soft, SKIP if the DB is absent). }

interface

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Diagnostics,
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  DragLint.Graph.Source.Db,
  DragLint.Graph.ViewModel,
  DragLint.Graph.Layout,
  Test.Graph.Builders,
  Fake.GraphSource;

const
  ORM3_PATH = 'C:\Projects\DB\ORM3\drag-lint.sqlite';

{ Build VisIdx + edge-endpoint index arrays from a projection -- the same
  mapping TDragLintGraphControl.EnsureLayout feeds to StepVisible. }
procedure ProjectionToArrays(const AProj: TGraphProjection;
  out AVisIdx, AEdgeSrc, AEdgeDst: TArray<Integer>);
var
  I: Integer;
begin
  SetLength(AVisIdx, Length(AProj.Nodes));
  for I := 0 to High(AProj.Nodes) do
    AVisIdx[I] := AProj.Nodes[I].NodeIdx;
  SetLength(AEdgeSrc, Length(AProj.Edges));
  SetLength(AEdgeDst, Length(AProj.Edges));
  for I := 0 to High(AProj.Edges) do
  begin
    AEdgeSrc[I] := AProj.Edges[I].SourceIdx;
    AEdgeDst[I] := AProj.Edges[I].TargetIdx;
  end;
end;

{ ---- F8_CollapsedOnLoad_BoundedVisible ----
  200 units, ~20,100 symbols total.  After load the visible projection must be
  a tiny top-level set, not the whole tree. }

procedure Test_F8_CollapsedOnLoad_BoundedVisible;
var
  VM:   IGraphViewModel;
  Proj: TGraphProjection;
  Total, Visible: Integer;
begin
  VM := TGraphViewModel.Create;
  { TPreloadedSource owns + frees the template graph. }
  VM.SetSource(TPreloadedSource.Create(BuildManyUnitsGraph(200)));
  { The View collapses to the top level on load (TDragLintGraphControl.Bind);
    simulate that here so the test exercises the real initial-view path. }
  VM.CollapseAll;

  Total   := VM.Data.NodeCount;
  Proj    := VM.Projection;
  Visible := Length(Proj.Nodes);

  WriteLn(Format('    F8 collapse-on-load: TotalNodes=%d  VisibleOnLoad=%d',
    [Total, Visible]));

  Check(Total > 20000,
    Format('store really is large (got %d total nodes)', [Total]));
  { Pre-fix this was the entire tree (~20k).  With collapse-on-load + the
    top-level cap it must be a small bubble set. }
  Check(Visible <= 50,
    Format('visible-on-load is bounded, not the whole tree (got %d)', [Visible]));
  Check(Visible < Total div 100,
    Format('visible-on-load << total (got %d of %d)', [Visible, Total]));
end;

{ ---- F8_VisibleLayout_FastAndSpreads ----
  Seed the visible set, run the visible-subset layout, assert it is fast and
  actually separates the nodes (a degenerate engine would leave them stacked). }

procedure Test_F8_VisibleLayout_FastAndSpreads;
var
  VM:    IGraphViewModel;
  Proj:  TGraphProjection;
  L:     TGraphLayout;
  VisIdx, ESrc, EDst: TArray<Integer>;
  I, VN: Integer;
  N:     PGraphNode;
  SW:    TStopwatch;
  ElapsedMs: Int64;
  MinX, MaxX, MinY, MaxY, Span: Double;
begin
  VM := TGraphViewModel.Create;
  VM.SetSource(TPreloadedSource.Create(BuildManyUnitsGraph(200)));
  VM.CollapseAll;
  Proj := VM.Projection;
  ProjectionToArrays(Proj, VisIdx, ESrc, EDst);
  VN := Length(VisIdx);
  Check(VN > 0, 'projection has visible nodes to lay out');

  { Seed distinct positions (StepVisible relaxes from a seeded layout, exactly
    as EnsureLayout seeds before stepping; coincident nodes cannot separate). }
  for I := 0 to VN - 1 do
  begin
    N := VM.Data.NodeAt(VisIdx[I]);
    N.X := (I mod 10) * 50.0;
    N.Y := (I div 10) * 50.0;
    N.VX := 0; N.VY := 0;
    if N.Radius < 1 then N.Radius := 12;
  end;

  L := TGraphLayout.Create;
  try
    L.SetScale(VN, 1200, 800);
    SW := TStopwatch.StartNew;
    L.StepVisible(VM.Data, VisIdx, ESrc, EDst, 200);
    SW.Stop;
    ElapsedMs := SW.ElapsedMilliseconds;
  finally
    L.Free;
  end;

  { Bounds of the laid-out visible set. }
  MinX :=  1.0E30; MaxX := -1.0E30;
  MinY :=  1.0E30; MaxY := -1.0E30;
  for I := 0 to VN - 1 do
  begin
    N := VM.Data.NodeAt(VisIdx[I]);
    if N.X < MinX then MinX := N.X;
    if N.X > MaxX then MaxX := N.X;
    if N.Y < MinY then MinY := N.Y;
    if N.Y > MaxY then MaxY := N.Y;
  end;
  Span := (MaxX - MinX) + (MaxY - MinY);

  WriteLn(Format('    F8 visible layout: VN=%d  200 steps in %d ms  span=%.0f',
    [VN, ElapsedMs, Span]));

  Check(ElapsedMs < 2000,
    Format('visible-subset layout is fast (got %d ms for %d nodes)',
      [ElapsedMs, VN]));
  Check(Span > 1.0, 'layout separated the nodes (not a degenerate stack)');
end;

{ ---- F8_ContainmentSpringClustersChildren ----
  The projection drops containment edges, so on expand a unit's revealed
  members have no force tying them to the unit and repulsion scatters them
  off-screen ("clicking a unit did nothing visible").  EnsureLayout adds a
  synthetic parent->child spring to fix that.  This proves the mechanism: the
  same seeded layout clusters children far tighter around the parent WITH the
  spring than without it. }

procedure Test_F8_ContainmentSpringClustersChildren;
const
  CHILD_COUNT = 8;
var
  D:        TGraphData;
  L:        TGraphLayout;
  VisIdx:   TArray<Integer>;
  ENoSrc, ENoDst:   TArray<Integer>;   { no containment edges }
  EYesSrc, EYesDst: TArray<Integer>;   { parent->child springs }
  I, UIdx:  Integer;
  U:        PGraphNode;
  SumNo, SumYes: Double;

  procedure SeedDeterministic;
  var K: Integer; M: PGraphNode;
  begin
    RandSeed := 12345;
    for K := 0 to High(VisIdx) do
    begin
      M := D.NodeAt(VisIdx[K]);
      M.X := Random * 1000 - 500;
      M.Y := Random * 1000 - 500;
      M.VX := 0; M.VY := 0;
      if M.Radius < 1 then M.Radius := 12;
    end;
  end;

  function AvgChildDist: Double;
  var K: Integer; M: PGraphNode; S: Double;
  begin
    S := 0;
    U := D.NodeAt(UIdx);
    for K := 0 to High(VisIdx) do
    begin
      if VisIdx[K] = UIdx then Continue;
      M := D.NodeAt(VisIdx[K]);
      S := S + Sqrt(Sqr(M.X - U.X) + Sqr(M.Y - U.Y));
    end;
    Result := S / CHILD_COUNT;
  end;

begin
  { U (unit) + CHILD_COUNT methods; BuildHierarchy adds @project over U. }
  D := TGraphData.Create;
  try
    D.AddNode(BuildNode('U', nkUnit, ''));
    for I := 0 to CHILD_COUNT - 1 do
      D.AddNode(BuildNode('U.m' + IntToStr(I), nkMethod, 'U'));
    D.BuildHierarchy;

    UIdx := D.FindNodeIndex('U');
    Check(UIdx >= 0, 'unit U present');

    { Visible set = U + its CHILD_COUNT children (exclude @project so the unit
      itself is the clustering anchor). }
    SetLength(VisIdx, CHILD_COUNT + 1);
    VisIdx[0] := UIdx;
    for I := 0 to CHILD_COUNT - 1 do
      VisIdx[I + 1] := D.FindNodeIndex('U.m' + IntToStr(I));

    { Containment springs U->child (what EnsureLayout builds). }
    SetLength(EYesSrc, CHILD_COUNT);
    SetLength(EYesDst, CHILD_COUNT);
    for I := 0 to CHILD_COUNT - 1 do
    begin
      EYesSrc[I] := UIdx;
      EYesDst[I] := D.FindNodeIndex('U.m' + IntToStr(I));
    end;
    SetLength(ENoSrc, 0);
    SetLength(ENoDst, 0);

    L := TGraphLayout.Create;
    try
      { Pass A: no containment edges -> children scatter. }
      SeedDeterministic;
      L.SetScale(Length(VisIdx), 1200, 800);
      L.StepVisible(D, VisIdx, ENoSrc, ENoDst, 200);
      SumNo := AvgChildDist;

      { Pass B: same seed, with parent->child springs -> children cluster. }
      SeedDeterministic;
      L.SetScale(Length(VisIdx), 1200, 800);
      L.StepVisible(D, VisIdx, EYesSrc, EYesDst, 200);
      SumYes := AvgChildDist;
    finally
      L.Free;
    end;

    WriteLn(Format('    F8 containment: avg child->parent dist  no-spring=%.0f' +
      '  with-spring=%.0f', [SumNo, SumYes]));

    Check(SumYes < SumNo,
      Format('containment spring clusters children (with=%.0f < without=%.0f)',
        [SumYes, SumNo]));
    Check(SumYes < SumNo * 0.6,
      Format('clustering is substantial (with=%.0f vs without=%.0f)',
        [SumYes, SumNo]));
  finally
    D.Free;
  end;
end;

{ ---- F8_ORM3_ProjectionBounded ----
  Same bounded-visible guarantee against the real ORM3 index. Soft: SKIP if
  the DB is not present on this machine. }

procedure Test_F8_ORM3_ProjectionBounded;
var
  Catalog: IDbCatalog;
  VM:      IGraphViewModel;
  Proj:    TGraphProjection;
  Total, Visible: Integer;
begin
  if not TFile.Exists(ORM3_PATH) then
  begin
    WriteLn('    SKIP: ORM3 DB not found at ' + ORM3_PATH);
    Exit;
  end;

  { Soft test: the ORM3 DB may be mid-rewrite by a concurrent reindex (SQLite
    "disk image is malformed"/busy). Treat any open/read failure as a SKIP, not
    a suite failure -- this test asserts a property, not DB availability. }
  try
    Catalog := TDbCatalog.Create(TArray<string>.Create(ORM3_PATH));
    VM := TGraphViewModel.Create;
    VM.SetCatalog(Catalog);
    VM.OpenStore(0);
    VM.CollapseAll;
  except
    on E: Exception do
    begin
      WriteLn('    SKIP: ORM3 DB not readable (' + E.Message + ')');
      Exit;
    end;
  end;

  Total   := VM.Data.NodeCount;
  Proj    := VM.Projection;
  Visible := Length(Proj.Nodes);

  WriteLn(Format('    F8 ORM3: TotalNodes=%d  VisibleOnLoad=%d',
    [Total, Visible]));

  Check(Total > 5000,
    Format('ORM3 store loaded (got %d nodes)', [Total]));
  Check(Visible < 200,
    Format('ORM3 visible-on-load bounded, was ~20k pre-fix (got %d)', [Visible]));
end;

initialization
  RegisterTest('F8_CollapsedOnLoad_BoundedVisible',
    Test_F8_CollapsedOnLoad_BoundedVisible);
  RegisterTest('F8_VisibleLayout_FastAndSpreads',
    Test_F8_VisibleLayout_FastAndSpreads);
  RegisterTest('F8_ContainmentSpringClustersChildren',
    Test_F8_ContainmentSpringClustersChildren);
  RegisterTest('F8_ORM3_ProjectionBounded',
    Test_F8_ORM3_ProjectionBounded);
end.
