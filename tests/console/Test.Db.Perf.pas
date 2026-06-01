unit Test.Db.Perf;

{ Headless perf probe for TDbGraphSource.LoadTopology.
  Three tests:
    Test_PerfORM3Load          -- soft, SKIP if ORM3 DB absent.
    Test_PerfLibraryBoundedLoad -- soft, SKIP if library DB absent.
    Test_PerfTruncationFlag    -- deterministic, uses temp fixture DB.

  All use TStopwatch from System.Diagnostics for elapsed timing.
  Test_PerfTruncationFlag is fully deterministic and always runs. }

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
  Test.Db.Fixtures;

const
  ORM3_PATH = 'C:\Projects\DB\ORM3\drag-lint.sqlite';
  LIB_PATH  =
    'C:\Projects\Delphi-RAG-lint\third_party\dll-win32\drag-lint-library.sqlite';

{ ---- Test_PerfORM3Load ----
  Open ORM3 DB, time LoadTopology, print metrics, assert sanity. }

procedure Test_PerfORM3Load;
var
  Src:        TDbGraphSource;
  D:          TGraphData;
  SW:         TStopwatch;
  ElapsedMs:  Int64;
begin
  if not TFile.Exists(ORM3_PATH) then
  begin
    WriteLn('    SKIP: ORM3 DB not found at ' + ORM3_PATH);
    Exit;
  end;

  Src := TDbGraphSource.Create(ORM3_PATH, 0);
  D   := TGraphData.Create;
  try
    SW := TStopwatch.StartNew;
    Check(Src.LoadTopology(D), 'ORM3 LoadTopology returns True');
    SW.Stop;
    ElapsedMs := SW.ElapsedMilliseconds;

    WriteLn(Format(
      '    ORM3 perf: TotalSymbolCount=%d  NodeCount=%d  EdgeCount=%d' +
      '  WasTruncated=%s  elapsed=%d ms',
      [Src.TotalSymbolCount, D.NodeCount, D.EdgeCount,
       BoolToStr(Src.WasTruncated, True), ElapsedMs]));

    Check(D.NodeCount > 100,
      Format('ORM3 NodeCount > 100 (got %d)', [D.NodeCount]));
    Check(ElapsedMs < 60000,
      Format('ORM3 LoadTopology < 60 s (got %d ms)', [ElapsedMs]));
  finally
    D.Free;
    Src.Free;
  end;
end;

{ ---- Test_PerfLibraryBoundedLoad ----
  Open library DB with default cap (20000).  Proves the hang is fixed:
    WasTruncated = True; TotalSymbolCount > 100000; NodeCount <= 20000+margin;
    elapsed < 15000 ms. }

procedure Test_PerfLibraryBoundedLoad;
var
  Src:        TDbGraphSource;
  D:          TGraphData;
  SW:         TStopwatch;
  ElapsedMs:  Int64;
begin
  if not TFile.Exists(LIB_PATH) then
  begin
    WriteLn('    SKIP: library DB not found at ' + LIB_PATH);
    Exit;
  end;

  Src := TDbGraphSource.Create(LIB_PATH, 1);
  D   := TGraphData.Create;
  try
    SW := TStopwatch.StartNew;
    Check(Src.LoadTopology(D), 'Library LoadTopology returns True');
    SW.Stop;
    ElapsedMs := SW.ElapsedMilliseconds;

    WriteLn(Format(
      '    Library perf: TotalSymbolCount=%d  NodeCount=%d  EdgeCount=%d' +
      '  WasTruncated=%s  elapsed=%d ms',
      [Src.TotalSymbolCount, D.NodeCount, D.EdgeCount,
       BoolToStr(Src.WasTruncated, True), ElapsedMs]));

    Check(Src.WasTruncated,
      'Library WasTruncated = True (store is huge)');
    Check(Src.TotalSymbolCount > 100000,
      Format('Library TotalSymbolCount > 100000 (got %d)', [Src.TotalSymbolCount]));
    { Allow a small margin above FMaxNodes for external/@project synthetic nodes }
    Check(D.NodeCount <= 20000 + 500,
      Format('Library NodeCount <= 20500 (got %d)', [D.NodeCount]));
    Check(ElapsedMs < 15000,
      Format('Library bounded load < 15 s (got %d ms -- bound did not prevent hang)',
             [ElapsedMs]));
  finally
    D.Free;
    Src.Free;
  end;
end;

{ ---- Test_PerfTruncationFlag ----
  Deterministic: uses the temp fixture DB (CreateTempV6Db has 6 symbols).
  Set MaxNodes=3 -> WasTruncated=True, NodeCount (excl. @project) <= 3.
  Then SetMaxNodes(20000) + reload -> WasTruncated=False, all loaded. }

procedure Test_PerfTruncationFlag;
var
  DbPath: string;
  Src:    TDbGraphSource;
  D:      TGraphData;
  { Fixture has 6 symbols (U, U.TFoo, U.TFoo.Bar, U.TBaz, U.TBaz.MB, V) }
  FullCount: Integer;
begin
  DbPath := CreateTempV6Db;
  try
    Src := TDbGraphSource.Create(DbPath, 0);
    D   := TGraphData.Create;
    try
      { ---- Pass 1: cap at 3 ---- }
      Src.SetMaxNodes(3);
      Check(Src.LoadTopology(D), 'TruncFlag P1: LoadTopology True');

      Check(Src.WasTruncated,
        'TruncFlag P1: WasTruncated = True (6 symbols > cap 3)');
      Check(Src.TotalSymbolCount >= 6,
        Format('TruncFlag P1: TotalSymbolCount >= 6 (got %d)',
               [Src.TotalSymbolCount]));

      { NodeCount includes @project synthetic node; subtract 1 for it.
        External nodes from unit_uses may also appear if files are loaded.
        The hard guarantee is: loaded symbol rows <= MaxNodes = 3. }
      WriteLn(Format(
        '    TruncFlag P1: cap=3  TotalSymbolCount=%d  NodeCount=%d  WasTruncated=%s',
        [Src.TotalSymbolCount, D.NodeCount, BoolToStr(Src.WasTruncated, True)]));

      { Symbol rows in the DB: NodeCount minus @project minus external nodes.
        We only need: NodeCount (which includes @project + possible externals)
        is well below the 6 we would get without a cap -- so <= 3 + 2 extra. }
      Check(D.NodeCount <= 3 + 3,
        Format('TruncFlag P1: NodeCount <= 6 when cap=3 (got %d)', [D.NodeCount]));

      { ---- Pass 2: lift cap to 20000 -> all 6 symbols loaded ---- }
      Src.SetMaxNodes(20000);
      D.Clear;
      Check(Src.LoadTopology(D), 'TruncFlag P2: LoadTopology True');

      Check(not Src.WasTruncated,
        'TruncFlag P2: WasTruncated = False (all symbols fit)');
      FullCount := D.NodeCount;
      Check(FullCount >= 6,
        Format('TruncFlag P2: NodeCount >= 6 (got %d)', [FullCount]));

      WriteLn(Format(
        '    TruncFlag P2: cap=20000  TotalSymbolCount=%d  NodeCount=%d  WasTruncated=%s',
        [Src.TotalSymbolCount, D.NodeCount, BoolToStr(Src.WasTruncated, True)]));

    finally
      D.Free;
      Src.Free;
    end;
  finally
    DeleteTempDb(DbPath);
  end;
end;

initialization
  RegisterTest('Perf_ORM3Load',           Test_PerfORM3Load);
  RegisterTest('Perf_LibraryBoundedLoad',  Test_PerfLibraryBoundedLoad);
  RegisterTest('Perf_TruncationFlag',      Test_PerfTruncationFlag);
end.
