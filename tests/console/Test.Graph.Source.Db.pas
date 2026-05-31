unit Test.Graph.Source.Db;

{ Deterministic temp-DB tests for TDbGraphSource (Task 1) plus a soft
  real-DB smoke against C:\Projects\DB\ORM3\drag-lint.sqlite.
  The temp DB is built from the v6 DDL with known fixture rows and is
  deleted after each test.  The smoke SKIPS (passes) if the real DB is
  absent; a genuine open/read failure on an existing file is a real FAIL. }

interface

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Data.DB,
  FireDAC.Comp.Client,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Phys.SQLite,
  FireDAC.Stan.Param,
  FireDAC.DApt,
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  DragLint.Graph.Source.Db,
  Test.Db.Fixtures;

{ ---- Test 1: connection + schema guard + symbols->nodes ---- }

procedure Test_DbSource_LoadTopology;
var
  DbPath:  string;
  Src:     IGraphSource;
  D:       TGraphData;
  BarIdx:  Integer;
  FooIdx:  Integer;
  UnitIdx: Integer;
  UnitNode: PGraphNode;
begin
  DbPath := CreateTempV6Db;
  try
    Src := TDbGraphSource.Create(DbPath, 0);
    D := TGraphData.Create;
    try
      Check(Src.LoadTopology(D), 'LoadTopology returns True');
      { 4 symbols (U, U.TFoo, U.TFoo.Bar, V)
        + 1 external node (@ext:System.SysUtils, from unit_uses fixture rows)
        + 1 synthetic @project = 6 nodes.
        Note: V and @ext:System.SysUtils were added in Task 2 to support
        unit_uses tests; all three rootless units (U, V, @ext:...) are
        parented under the single @project sentinel by BuildHierarchy. }
      CheckEqualsInt(6, D.NodeCount, '4 symbols + 1 external + @project = 6 nodes');

      BarIdx := D.FindNodeIndex('U.TFoo.Bar');
      Check(BarIdx >= 0, 'U.TFoo.Bar node present');

      FooIdx := D.FindNodeIndex('U.TFoo');
      Check(FooIdx >= 0, 'U.TFoo node present');

      UnitIdx := D.FindNodeIndex('U');
      Check(UnitIdx >= 0, 'U (unit) node present');

      { Containment: Bar.ParentIdx -> TFoo }
      CheckEqualsInt(FooIdx, D.ParentIndexOf(BarIdx), 'Bar parent = TFoo');

      { Documented flag: the fixture inserted a symbol_docs row for unit U }
      UnitNode := D.NodeAt(UnitIdx);
      Check(UnitNode.Documented, 'U.Documented = True (has symbol_docs row)');

      { StoreIndex }
      CheckEqualsInt(0, Src.StoreIndex, 'StoreIndex = 0');

    finally
      D.Free;
    end;
    { Release the source (and its DB connection) before we try to delete
      the temp file.  On Windows, an open file cannot be deleted. }
    Src := nil;
  finally
    DeleteTempDb(DbPath);
  end;
end;

{ ---- Test 1b: schema guard raises EDbSchemaMismatch on version < 5 ---- }

procedure BuildMinimalV4Db(const ADbPath: string);
var
  Conn: TFDConnection;
begin
  Conn := TFDConnection.Create(nil);
  try
    Conn.DriverName := 'SQLite';
    Conn.Params.Values['Database']    := ADbPath;
    Conn.Params.Values['LockingMode'] := 'Normal';
    Conn.LoginPrompt := False;
    Conn.Connected   := True;
    Conn.ExecSQL(
      'CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    Conn.ExecSQL(
      'INSERT INTO schema_meta(key,value) VALUES (''schema_version'',''4'')');
    Conn.ExecSQL(
      'CREATE TABLE files (' +
      '  id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,' +
      '  mtime_unix INTEGER NOT NULL, sha256 TEXT NOT NULL,' +
      '  parsed_at INTEGER NOT NULL, language TEXT NOT NULL)');
    Conn.ExecSQL(
      'CREATE TABLE symbols (' +
      '  id INTEGER PRIMARY KEY,' +
      '  file_id INTEGER NOT NULL, parent_id INTEGER,' +
      '  kind TEXT NOT NULL, name TEXT NOT NULL,' +
      '  qualified_name TEXT NOT NULL, signature TEXT, modifiers TEXT,' +
      '  start_line INTEGER NOT NULL, start_col INTEGER NOT NULL,' +
      '  end_line INTEGER NOT NULL, end_col INTEGER NOT NULL)');
  finally
    Conn.Free;
  end;
end;

procedure Test_DbSource_SchemaMismatch;
var
  DbPath: string;
  Raised: Boolean;
  Src:    IGraphSource;
begin
  DbPath := TPath.GetTempFileName;
  TFile.Delete(DbPath);
  DbPath := ChangeFileExt(DbPath, '.sqlite');
  Raised := False;
  BuildMinimalV4Db(DbPath);
  try
    try
      Src := TDbGraphSource.Create(DbPath, 0);
      Src := nil;
    except
      on E: EDbSchemaMismatch do
        Raised := True;
      { any other exception propagates -- do not catch }
    end;
    Check(Raised, 'EDbSchemaMismatch raised for version 4');
  finally
    DeleteTempDb(DbPath);
  end;
end;

{ ---- Test 2: unit_uses -> ekUses edges + external nodes ---- }

procedure Test_DbSource_UnitUses;
var
  DbPath:  string;
  Src:     IGraphSource;
  D:       TGraphData;
  I:       Integer;
  E:       TGraphEdge;
  ExtNode: PGraphNode;
  FoundUV:   Boolean;
  FoundUExt: Boolean;
begin
  DbPath := CreateTempV6Db;
  try
    Src := TDbGraphSource.Create(DbPath, 0);
    D := TGraphData.Create;
    try
      Check(Src.LoadTopology(D), 'LoadTopology returns True');

      { External node @ext:System.SysUtils must exist with IsExternal=True }
      ExtNode := D.FindNode('@ext:System.SysUtils');
      Check(ExtNode <> nil, '@ext:System.SysUtils node present');
      if ExtNode <> nil then
        Check(ExtNode.IsExternal, '@ext:System.SysUtils.IsExternal = True');

      { Check edges: U->V (interface) and U->@ext:System.SysUtils (implementation) }
      FoundUV   := False;
      FoundUExt := False;
      for I := 0 to D.EdgeCount - 1 do
      begin
        E := D.EdgeAt(I);
        if E.Kind <> ekUses then Continue;
        if (E.SourceId = 'U') and (E.TargetId = 'V') and
           (E.Label_ = 'interface') then
          FoundUV := True;
        if (E.SourceId = 'U') and
           (E.TargetId = '@ext:System.SysUtils') and
           (E.Label_ = 'implementation') then
          FoundUExt := True;
      end;
      Check(FoundUV,   'ekUses edge U->V with Label_=interface exists');
      Check(FoundUExt, 'ekUses edge U->@ext:System.SysUtils with Label_=implementation exists');

    finally
      D.Free;
    end;
    Src := nil;
  finally
    DeleteTempDb(DbPath);
  end;
end;

{ ---- Smoke 1 (soft): real ORM3 DB ---- }

procedure Test_DbSource_ORM3Smoke;
const
  ORM3_PATH = 'C:\Projects\DB\ORM3\drag-lint.sqlite';
var
  Src: IGraphSource;
  D:   TGraphData;
begin
  if not TFile.Exists(ORM3_PATH) then
  begin
    WriteLn('    SKIP: ORM3 DB not found at ' + ORM3_PATH);
    Exit;
  end;

  Src := TDbGraphSource.Create(ORM3_PATH, 0);
  D := TGraphData.Create;
  try
    Check(Src.LoadTopology(D), 'ORM3 LoadTopology returns True');
    Check(D.NodeCount > 100,
      Format('ORM3 NodeCount > 100 (got %d)', [D.NodeCount]));
    WriteLn(Format('    ORM3 smoke: NodeCount = %d', [D.NodeCount]));
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest('DbSource_LoadTopology',   Test_DbSource_LoadTopology);
  RegisterTest('DbSource_SchemaMismatch', Test_DbSource_SchemaMismatch);
  RegisterTest('DbSource_UnitUses',       Test_DbSource_UnitUses);
  RegisterTest('DbSource_ORM3Smoke',      Test_DbSource_ORM3Smoke);
end.
