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
      { 6 symbols (U, U.TFoo, U.TFoo.Bar, U.TBaz, U.TBaz.MB, V)
        + 1 external node (@ext:System.SysUtils, from unit_uses fixture rows)
        + 1 synthetic @project = 8 nodes.
        Note: V and @ext:System.SysUtils added in Task 2 (unit_uses tests);
        U.TBaz and U.TBaz.MB added in Task 3 (refs/enclosing-symbol tests).
        All rootless units (U, V, @ext:...) parented under @project by BuildHierarchy. }
      CheckEqualsInt(8, D.NodeCount, '6 symbols + 1 external + @project = 8 nodes');

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

{ ---- Test 3: refs -> call/typeref edges via enclosing-symbol resolution ---- }

procedure Test_DbSource_Refs;
var
  DbPath:        string;
  Src:           IGraphSource;
  D:             TGraphData;
  I:             Integer;
  E:             TGraphEdge;
  FoundCall:     Boolean;
  FoundTypeRef:  Boolean;
begin
  DbPath := CreateTempV6Db;
  try
    Src := TDbGraphSource.Create(DbPath, 0);
    D := TGraphData.Create;
    try
      Check(Src.LoadTopology(D), 'LoadTopology returns True');

      FoundCall    := False;
      FoundTypeRef := False;
      for I := 0 to D.EdgeCount - 1 do
      begin
        E := D.EdgeAt(I);
        if (E.Kind = ekCalls) and
           (E.SourceId = 'U.TFoo.Bar') and (E.TargetId = 'U.TBaz.MB') then
          FoundCall := True;
        if (E.Kind = ekTypeRef) and (E.SourceId = 'U.TFoo.Bar') then
          FoundTypeRef := True;
      end;

      Check(FoundCall,
        'ekCalls edge U.TFoo.Bar -> U.TBaz.MB (enclosing-symbol resolution)');
      Check(FoundTypeRef,
        'ekTypeRef edge from U.TFoo.Bar (type_use ref inside Bar range)');

    finally
      D.Free;
    end;
    Src := nil;
  finally
    DeleteTempDb(DbPath);
  end;
end;

{ ---- Test 4: GetDoc + ResolveCref + LocateSymbol ---- }

procedure Test_DbSource_Docs;
var
  DbPath: string;
  Src:    IGraphSource;
  Doc:    TGraphDoc;
  Cref:   TCrefResolution;
  AFile:  string;
  ALine:  Integer;
begin
  DbPath := CreateTempV6Db;
  try
    Src := TDbGraphSource.Create(DbPath, 0);

    { GetDoc: U.TFoo.Bar has a docs row }
    Doc := Src.GetDoc('U.TFoo.Bar');
    Check(Doc.HasDoc,    'GetDoc(U.TFoo.Bar).HasDoc = True');
    CheckEqualsStr('Hi', Doc.Summary, 'GetDoc(U.TFoo.Bar).Summary = Hi');
    CheckEqualsStr('1.0', Doc.SinceText, 'GetDoc(U.TFoo.Bar).SinceText = 1.0');
    CheckEqualsInt(2, Length(Doc.SeeAlso),
      'GetDoc(U.TFoo.Bar): SeeAlso length = 2');
    CheckEqualsInt(1, Length(Doc.Params),
      'GetDoc(U.TFoo.Bar): Params length = 1');
    if Length(Doc.Params) >= 1 then
      CheckEqualsStr('AX', Doc.Params[0].Name,
        'GetDoc(U.TFoo.Bar): Params[0].Name = AX');

    { GetDoc: U has a docs row (fixture) but we test a symbol with no doc row }
    Doc := Src.GetDoc('U');
    { U has a docs row in the fixture; ensure it is loaded correctly }
    Check(Doc.HasDoc, 'GetDoc(U).HasDoc = True (fixture row present)');

    { GetDoc: missing symbol -> HasDoc False }
    Doc := Src.GetDoc('NoSuch.Symbol');
    Check(not Doc.HasDoc, 'GetDoc(missing).HasDoc = False');

    { ResolveCref: URL -> crkUrl }
    Cref := Src.ResolveCref('https://x');
    CheckEqualsInt(Ord(crkUrl), Ord(Cref.Kind),
      'ResolveCref(https://x).Kind = crkUrl');

    { ResolveCref: exact qname -> crkResolved }
    Cref := Src.ResolveCref('U.TFoo');
    CheckEqualsInt(Ord(crkResolved), Ord(Cref.Kind),
      'ResolveCref(U.TFoo).Kind = crkResolved');
    CheckEqualsStr('U.TFoo', Cref.TargetId,
      'ResolveCref(U.TFoo).TargetId = U.TFoo');

    { ResolveCref: nonexistent name -> crkUnresolved }
    Cref := Src.ResolveCref('Nope.Missing');
    CheckEqualsInt(Ord(crkUnresolved), Ord(Cref.Kind),
      'ResolveCref(Nope.Missing).Kind = crkUnresolved');

    { ResolveCref: bare name with exactly one match -> crkResolved }
    Cref := Src.ResolveCref('Bar');
    CheckEqualsInt(Ord(crkResolved), Ord(Cref.Kind),
      'ResolveCref(Bar) bare-name: Kind = crkResolved (only U.TFoo.Bar named Bar)');
    CheckEqualsStr('U.TFoo.Bar', Cref.TargetId,
      'ResolveCref(Bar).TargetId = U.TFoo.Bar');

    { LocateSymbol: found -> True, non-empty path }
    Check(Src.LocateSymbol('U.TFoo.Bar', AFile, ALine),
      'LocateSymbol(U.TFoo.Bar) = True');
    Check(AFile <> '', 'LocateSymbol(U.TFoo.Bar): AFile <> empty');

    { LocateSymbol: missing -> False }
    Check(not Src.LocateSymbol('NoSuch.QName', AFile, ALine),
      'LocateSymbol(NoSuch.QName) = False');

    Src := nil;
  finally
    DeleteTempDb(DbPath);
  end;
end;

{ ---- Smoke 4 (soft): ORM3 LocateSymbol on a real method ---- }

procedure Test_DbSource_ORM3LocateSmoke;
const
  ORM3_PATH = 'C:\Projects\DB\ORM3\drag-lint.sqlite';
var
  Src:    IGraphSource;
  Q:      TFDQuery;
  Conn:   TFDConnection;
  QName:  string;
  AFile:  string;
  ALine:  Integer;
begin
  if not TFile.Exists(ORM3_PATH) then
  begin
    WriteLn('    SKIP: ORM3 DB not found -- LocateSymbol smoke skipped');
    Exit;
  end;

  { Pick any method qname from the live DB -- open read-only + immutable.
    Use the SQLite URI form (file:///path?immutable=1); SQLITE_CONFIG_URI
    was enabled in DragLint.Graph.Source.Db initialization so file: URIs
    are interpreted by FireDAC even without the SQLITE_OPEN_URI flag. }
  QName := '';
  Conn := TFDConnection.Create(nil);
  try
    Conn.DriverName := 'SQLite';
    Conn.Params.Values['Database'] :=
      'file:///' + StringReplace(ORM3_PATH, '\', '/', [rfReplaceAll]) +
      '?immutable=1';
    Conn.Params.Values['OpenMode']    := 'ReadOnly';
    Conn.Params.Values['LockingMode'] := 'Normal';
    Conn.LoginPrompt := False;
    Conn.Connected   := True;
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := Conn;
      Q.SQL.Text :=
        'SELECT qualified_name FROM symbols WHERE kind=''method'' LIMIT 1';
      Q.Open;
      if not Q.IsEmpty then
        QName := Q.Fields[0].AsString;
      Q.Close;
    finally
      Q.Free;
    end;
  finally
    Conn.Free;
  end;

  if QName = '' then
  begin
    WriteLn('    SKIP: no method symbol found in ORM3 DB');
    Exit;
  end;

  Src := TDbGraphSource.Create(ORM3_PATH, 0);
  try
    Check(Src.LocateSymbol(QName, AFile, ALine),
      'ORM3 LocateSymbol(' + QName + ') = True');
    Check(AFile <> '',
      'ORM3 LocateSymbol: AFile non-empty for ' + QName);
    WriteLn('    ORM3 LocateSymbol: ' + QName + ' -> ' + AFile +
            ':' + IntToStr(ALine));
  finally
    Src := nil;
  end;
end;

{ ---- Smoke 1 (soft): real ORM3 DB ---- }

procedure Test_DbSource_ORM3Smoke;
const
  ORM3_PATH = 'C:\Projects\DB\ORM3\drag-lint.sqlite';
var
  Src:       IGraphSource;
  D:         TGraphData;
  WalPath:   string;
  ShmPath:   string;
  WalExistedBefore: Boolean;
  ShmExistedBefore: Boolean;
begin
  if not TFile.Exists(ORM3_PATH) then
  begin
    WriteLn('    SKIP: ORM3 DB not found at ' + ORM3_PATH);
    Exit;
  end;

  WalPath := ORM3_PATH + '-wal';
  ShmPath := ORM3_PATH + '-shm';
  { Record whether sidecar files pre-existed (another process may own them) }
  WalExistedBefore := TFile.Exists(WalPath);
  ShmExistedBefore := TFile.Exists(ShmPath);

  Src := TDbGraphSource.Create(ORM3_PATH, 0);
  D := TGraphData.Create;
  try
    Check(Src.LoadTopology(D), 'ORM3 LoadTopology returns True');
    Check(D.NodeCount > 100,
      Format('ORM3 NodeCount > 100 (got %d)', [D.NodeCount]));
    Check(D.EdgeCount > 0,
      Format('ORM3 EdgeCount > 0 (got %d)', [D.EdgeCount]));
    WriteLn(Format('    ORM3 smoke: NodeCount = %d, EdgeCount = %d',
      [D.NodeCount, D.EdgeCount]));
  finally
    D.Free;
  end;

  { Release the connection before checking for sidecars }
  Src := nil;

  { Assert that opening with immutable=1 + ReadOnly did NOT create new sidecar
    files.  If they pre-existed (owned by another process) we cannot assert
    their absence -- skip that check with a note. }
  if not WalExistedBefore then
  begin
    Check(not TFile.Exists(WalPath),
      'ORM3 smoke: -wal sidecar created by immutable read-only open (should not happen)');
    if not TFile.Exists(WalPath) then
      WriteLn('    ORM3 smoke: no -wal sidecar created (immutable open OK)');
  end
  else
    WriteLn('    ORM3 smoke: -wal pre-existed (owned by another process) -- sidecar check skipped');

  if not ShmExistedBefore then
  begin
    Check(not TFile.Exists(ShmPath),
      'ORM3 smoke: -shm sidecar created by immutable read-only open (should not happen)');
    if not TFile.Exists(ShmPath) then
      WriteLn('    ORM3 smoke: no -shm sidecar created (immutable open OK)');
  end
  else
    WriteLn('    ORM3 smoke: -shm pre-existed (owned by another process) -- sidecar check skipped');
end;

{ ---- Task 5 (deterministic): TDbCatalog cross-store resolution ---- }

procedure Test_DbCatalog_CrossStoreResolve;
var
  Path0:   string;
  Path1:   string;
  Cat:     IDbCatalog;
  Res:     TCrossDbResolution;
  Src0a:   IGraphSource;
  Src0b:   IGraphSource;
  D:       TGraphData;
begin
  Path0 := CreateTempV6DbNamed('A');
  Path1 := CreateTempV6DbNamed('B');
  try
    Cat := TDbCatalog.Create([Path0, Path1]);

    { StoreCount }
    CheckEqualsInt(2, Cat.StoreCount, 'StoreCount = 2');

    { StorePath }
    CheckEqualsStr(Path0, Cat.StorePath(0), 'StorePath(0) = Path0');
    CheckEqualsStr(Path1, Cat.StorePath(1), 'StorePath(1) = Path1');

    { ResolveAcrossStores('B') -> Found, StoreIndex=1, TargetId='B' }
    Res := Cat.ResolveAcrossStores('B');
    Check(Res.Found,              'ResolveAcrossStores(B).Found = True');
    CheckEqualsInt(1, Res.StoreIndex, 'ResolveAcrossStores(B).StoreIndex = 1');
    CheckEqualsStr('B', Res.TargetId, 'ResolveAcrossStores(B).TargetId = B');

    { ResolveAcrossStores('A') -> Found, StoreIndex=0 }
    Res := Cat.ResolveAcrossStores('A');
    Check(Res.Found,              'ResolveAcrossStores(A).Found = True');
    CheckEqualsInt(0, Res.StoreIndex, 'ResolveAcrossStores(A).StoreIndex = 0');
    CheckEqualsStr('A', Res.TargetId, 'ResolveAcrossStores(A).TargetId = A');

    { ResolveAcrossStores('Zed') -> not Found }
    Res := Cat.ResolveAcrossStores('Zed');
    Check(not Res.Found, 'ResolveAcrossStores(Zed).Found = False');

    { SourceForStore(0).LoadTopology works }
    Src0a := Cat.SourceForStore(0);
    Check(Src0a <> nil, 'SourceForStore(0) <> nil');
    D := TGraphData.Create;
    try
      Check(Src0a.LoadTopology(D), 'SourceForStore(0).LoadTopology = True');
      Check(D.NodeCount > 0, 'LoadTopology NodeCount > 0');
    finally
      D.Free;
    end;

    { SourceForStore(0) returns the SAME cached instance }
    Src0b := Cat.SourceForStore(0);
    Check(Src0b <> nil, 'SourceForStore(0) second call <> nil');
    { Same interface instance (pointer equality via Supports) }
    Check(Src0a = Src0b,
      'SourceForStore(0) cached -- same interface reference');

    { Release catalog BEFORE deleting the temp files so the connection closes }
    Cat  := nil;
    Src0a := nil;
    Src0b := nil;
  finally
    DeleteTempDb(Path0);
    DeleteTempDb(Path1);
  end;
end;

{ ---- Task 5 integration smoke (soft): ORM3 + library catalog ---- }

procedure Test_DbCatalog_LibrarySmoke;
const
  ORM3_PATH = 'C:\Projects\DB\ORM3\drag-lint.sqlite';
  LIB_PATH  =
    'C:\Projects\Delphi-RAG-lint\third_party\dll-win32\drag-lint-library.sqlite';
var
  Cat:      IDbCatalog;
  D:        TGraphData;
  I:        Integer;
  E:        TGraphEdge;
  Res:      TCrossDbResolution;
  FoundSection: Boolean;
  T0:       TDateTime;
  ElapsedMs: Double;
  ResolveNames: array[0..3] of string;
  NName:    string;
begin
  if not (TFile.Exists(ORM3_PATH) and TFile.Exists(LIB_PATH)) then
  begin
    WriteLn('    SKIP: one or both real DBs absent -- catalog smoke skipped');
    Exit;
  end;

  { With immutable=1 + ReadOnly the library DB must open even if the indexer
    holds a write lock.  Any open failure here is now a FAIL (not a SKIP),
    because immutable open should bypass the WAL locking entirely. }
  Cat := TDbCatalog.Create([ORM3_PATH, LIB_PATH]);

  try
    { ---- LoadTopology store 0 (ORM3) ---- }
    D := TGraphData.Create;
    try
      Check(Cat.SourceForStore(0).LoadTopology(D),
        'CatalogSmoke: ORM3 LoadTopology True');
      Check(D.NodeCount > 100,
        Format('CatalogSmoke: ORM3 NodeCount > 100 (got %d)', [D.NodeCount]));

      FoundSection := False;
      for I := 0 to D.EdgeCount - 1 do
      begin
        E := D.EdgeAt(I);
        if (E.Kind = ekUses) and (E.Label_ <> '') then
        begin
          FoundSection := True;
          Break;
        end;
      end;
      Check(FoundSection,
        'CatalogSmoke: at least one ekUses edge has a non-empty section label');

      WriteLn(Format('    CatalogSmoke ORM3: NodeCount=%d EdgeCount=%d',
        [D.NodeCount, D.EdgeCount]));
    finally
      D.Free;
    end;

    { ---- ResolveAcrossStores against library (no LoadTopology) ---- }
    { Try well-known RTL names -- at least one should be in the library.
      With immutable=1 the library open must succeed even when the indexer
      holds a write lock; any exception here is now a FAIL (not a SKIP). }
    ResolveNames[0] := 'TObject';
    ResolveNames[1] := 'IInterface';
    ResolveNames[2] := 'TList';
    ResolveNames[3] := 'SysUtils';

    for NName in ResolveNames do
    begin
      T0 := Now;
      Res := Cat.ResolveAcrossStores(NName);
      ElapsedMs := (Now - T0) * 86400.0 * 1000.0;
      if Res.Found then
      begin
        Check(Res.StoreIndex in [0, 1],
          'CatalogSmoke: StoreIndex in {0,1} for ' + NName);
        WriteLn(Format('    CatalogSmoke: ResolveAcrossStores(%s) -> store %d,' +
                       ' qname=%s (%.0f ms)',
          [NName, Res.StoreIndex, Res.TargetId, ElapsedMs]));
        if ElapsedMs > 10000 then
          WriteLn('    WARNING: ResolveAcrossStores took > 10 s -- check index');
      end
      else
        WriteLn(Format('    CatalogSmoke: ResolveAcrossStores(%s) -> not found' +
                       ' (%.0f ms)', [NName, ElapsedMs]));
    end;

  finally
    Cat := nil;
  end;
end;

initialization
  RegisterTest('DbSource_LoadTopology',   Test_DbSource_LoadTopology);
  RegisterTest('DbSource_SchemaMismatch', Test_DbSource_SchemaMismatch);
  RegisterTest('DbSource_UnitUses',       Test_DbSource_UnitUses);
  RegisterTest('DbSource_Refs',           Test_DbSource_Refs);
  RegisterTest('DbSource_Docs',           Test_DbSource_Docs);
  RegisterTest('DbSource_ORM3LocateSmoke', Test_DbSource_ORM3LocateSmoke);
  RegisterTest('DbSource_ORM3Smoke',      Test_DbSource_ORM3Smoke);
  RegisterTest('DbCatalog_CrossStoreResolve', Test_DbCatalog_CrossStoreResolve);
  RegisterTest('DbCatalog_LibrarySmoke',  Test_DbCatalog_LibrarySmoke);
end.
