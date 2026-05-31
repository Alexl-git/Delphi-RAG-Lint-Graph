unit Test.Db.Fixtures;

{ Builds a temporary v6 SQLite database from the exact schema DDL so
  deterministic DB-source tests can run without a real drag-lint.sqlite.
  The temp file is created in %TEMP% and must be deleted by the caller
  via DeleteTempDb. }

interface

function CreateTempV6Db: string;
procedure DeleteTempDb(const APath: string);

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
  FireDAC.DApt;

{ ---- v6 DDL (copied from DRagLint.Storage.Schema) ---- }

const
  SCHEMA_DDL: array[0..36] of string = (
    'CREATE TABLE IF NOT EXISTS schema_meta (' +
    '  key   TEXT PRIMARY KEY,' +
    '  value TEXT NOT NULL' +
    ')',

    'CREATE TABLE IF NOT EXISTS files (' +
    '  id          INTEGER PRIMARY KEY,' +
    '  path        TEXT NOT NULL UNIQUE,' +
    '  mtime_unix  INTEGER NOT NULL,' +
    '  sha256      TEXT NOT NULL,' +
    '  parsed_at   INTEGER NOT NULL,' +
    '  language    TEXT NOT NULL' +
    ')',

    'CREATE TABLE IF NOT EXISTS symbols (' +
    '  id              INTEGER PRIMARY KEY,' +
    '  file_id         INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,' +
    '  parent_id       INTEGER REFERENCES symbols(id) ON DELETE CASCADE,' +
    '  kind            TEXT NOT NULL,' +
    '  name            TEXT NOT NULL,' +
    '  qualified_name  TEXT NOT NULL,' +
    '  signature       TEXT,' +
    '  modifiers       TEXT,' +
    '  start_line      INTEGER NOT NULL,' +
    '  start_col       INTEGER NOT NULL,' +
    '  end_line        INTEGER NOT NULL,' +
    '  end_col         INTEGER NOT NULL' +
    ')',

    'CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name)',
    'CREATE INDEX IF NOT EXISTS idx_symbols_qname ON symbols(qualified_name)',
    'CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id)',
    'CREATE INDEX IF NOT EXISTS idx_symbols_parent ON symbols(parent_id)',

    'CREATE TABLE IF NOT EXISTS refs (' +
    '  id          INTEGER PRIMARY KEY,' +
    '  symbol_id   INTEGER REFERENCES symbols(id) ON DELETE SET NULL,' +
    '  file_id     INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,' +
    '  kind        TEXT NOT NULL,' +
    '  name_text   TEXT NOT NULL,' +
    '  start_line  INTEGER NOT NULL,' +
    '  start_col   INTEGER NOT NULL,' +
    '  end_line    INTEGER NOT NULL,' +
    '  end_col     INTEGER NOT NULL' +
    ')',

    'CREATE TABLE IF NOT EXISTS symbol_trigrams (' +
    '  trigram     TEXT NOT NULL,' +
    '  symbol_id   INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,' +
    '  PRIMARY KEY (trigram, symbol_id)' +
    ') WITHOUT ROWID',

    'CREATE INDEX IF NOT EXISTS idx_symbol_trigrams_trigram ' +
    '  ON symbol_trigrams(trigram)',

    'CREATE TABLE IF NOT EXISTS compiler_findings (' +
    '  id          INTEGER PRIMARY KEY,' +
    '  file_id     INTEGER REFERENCES files(id) ON DELETE SET NULL,' +
    '  raw_path    TEXT NOT NULL,' +
    '  code        TEXT NOT NULL,' +
    '  severity    TEXT NOT NULL,' +
    '  line_no     INTEGER,' +
    '  col_no      INTEGER,' +
    '  message     TEXT NOT NULL,' +
    '  imported_at INTEGER NOT NULL' +
    ')',

    'CREATE INDEX IF NOT EXISTS idx_compiler_findings_code ' +
    '  ON compiler_findings(code)',

    'CREATE TABLE IF NOT EXISTS symbol_docs (' +
    '  symbol_id        INTEGER PRIMARY KEY REFERENCES symbols(id) ON DELETE CASCADE,' +
    '  format           TEXT NOT NULL,' +
    '  raw_block        TEXT NOT NULL,' +
    '  summary          TEXT,' +
    '  remarks          TEXT,' +
    '  returns_text     TEXT,' +
    '  params_json      TEXT,' +
    '  exceptions_json  TEXT,' +
    '  example_text     TEXT,' +
    '  seealso_json     TEXT,' +
    '  since_text       TEXT,' +
    '  deprecated       INTEGER NOT NULL DEFAULT 0,' +
    '  start_line       INTEGER,' +
    '  end_line         INTEGER' +
    ')',

    'CREATE INDEX IF NOT EXISTS idx_symbol_docs_format ON symbol_docs(format)',

    'CREATE INDEX IF NOT EXISTS idx_symbol_docs_deprecated ' +
    '  ON symbol_docs(deprecated) WHERE deprecated = 1',

    'CREATE TABLE IF NOT EXISTS unit_uses (' +
    '  id              INTEGER PRIMARY KEY,' +
    '  file_id         INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,' +
    '  unit_name       TEXT NOT NULL,' +
    '  unit_name_norm  TEXT NOT NULL,' +
    '  section         TEXT NOT NULL,' +
    '  in_path         TEXT,' +
    '  target_file_id  INTEGER REFERENCES files(id) ON DELETE SET NULL,' +
    '  start_line      INTEGER NOT NULL,' +
    '  start_col       INTEGER NOT NULL,' +
    '  end_line        INTEGER,' +
    '  end_col         INTEGER' +
    ')',

    'CREATE INDEX IF NOT EXISTS idx_unit_uses_file '       +
    '  ON unit_uses(file_id)',
    'CREATE INDEX IF NOT EXISTS idx_unit_uses_unit_norm '  +
    '  ON unit_uses(unit_name_norm)',
    'CREATE INDEX IF NOT EXISTS idx_unit_uses_section '    +
    '  ON unit_uses(section)',
    'CREATE INDEX IF NOT EXISTS idx_unit_uses_target '     +
    '  ON unit_uses(target_file_id) WHERE target_file_id IS NOT NULL',

    'CREATE TABLE IF NOT EXISTS fb_relations (' +
    '  id                   INTEGER PRIMARY KEY,' +
    '  name                 TEXT NOT NULL,' +
    '  sql_table_symbol_id  INTEGER REFERENCES symbols(id) ON DELETE SET NULL,' +
    '  owner                TEXT,' +
    '  system_flag          INTEGER NOT NULL DEFAULT 0,' +
    '  description          TEXT,' +
    '  snapshot_at          INTEGER NOT NULL' +
    ')',
    'CREATE INDEX IF NOT EXISTS idx_fb_relations_name ON fb_relations(name)',

    'CREATE TABLE IF NOT EXISTS fb_columns (' +
    '  id                   INTEGER PRIMARY KEY,' +
    '  relation_id          INTEGER NOT NULL REFERENCES fb_relations(id) ON DELETE CASCADE,' +
    '  name                 TEXT NOT NULL,' +
    '  position             INTEGER NOT NULL,' +
    '  field_source         TEXT,' +
    '  field_type           INTEGER,' +
    '  field_length         INTEGER,' +
    '  field_scale          INTEGER,' +
    '  field_precision      INTEGER,' +
    '  nullable             INTEGER NOT NULL DEFAULT 1,' +
    '  default_value        TEXT,' +
    '  sql_column_symbol_id INTEGER REFERENCES symbols(id) ON DELETE SET NULL,' +
    '  description          TEXT,' +
    '  snapshot_at          INTEGER NOT NULL' +
    ')',
    'CREATE INDEX IF NOT EXISTS idx_fb_columns_relation ON fb_columns(relation_id)',
    'CREATE INDEX IF NOT EXISTS idx_fb_columns_name ON fb_columns(name)',

    'CREATE TABLE IF NOT EXISTS fb_field_info (' +
    '  id              INTEGER PRIMARY KEY,' +
    '  field_name      TEXT NOT NULL,' +
    '  table_name      TEXT,' +
    '  display_label   TEXT,' +
    '  display_format  TEXT,' +
    '  edit_format     TEXT,' +
    '  visible         INTEGER,' +
    '  read_only       INTEGER,' +
    '  triggered       INTEGER,' +
    '  display_width   INTEGER,' +
    '  fib_version     INTEGER,' +
    '  snapshot_at     INTEGER NOT NULL' +
    ')',
    'CREATE INDEX IF NOT EXISTS idx_fb_field_info_field ON fb_field_info(field_name)',
    'CREATE INDEX IF NOT EXISTS idx_fb_field_info_table ON fb_field_info(table_name)',

    'CREATE TABLE IF NOT EXISTS fb_datasets (' +
    '  id                          INTEGER PRIMARY KEY,' +
    '  ds_id                       INTEGER,' +
    '  description                 TEXT,' +
    '  select_sql                  TEXT,' +
    '  update_sql                  TEXT,' +
    '  insert_sql                  TEXT,' +
    '  delete_sql                  TEXT,' +
    '  refresh_sql                 TEXT,' +
    '  name_generator              TEXT,' +
    '  key_field                   TEXT,' +
    '  update_table_name           TEXT,' +
    '  update_only_modified_fields INTEGER,' +
    '  conditions                  TEXT,' +
    '  fib_version                 INTEGER,' +
    '  snapshot_at                 INTEGER NOT NULL' +
    ')',
    'CREATE INDEX IF NOT EXISTS idx_fb_datasets_ds_id ON fb_datasets(ds_id)',
    'CREATE INDEX IF NOT EXISTS idx_fb_datasets_table ON fb_datasets(update_table_name)',

    'CREATE TABLE IF NOT EXISTS fb_enum_values (' +
    '  id           INTEGER PRIMARY KEY,' +
    '  enum_name    TEXT NOT NULL,' +
    '  value_code   TEXT NOT NULL,' +
    '  value_label  TEXT,' +
    '  fib_version  INTEGER,' +
    '  snapshot_at  INTEGER NOT NULL' +
    ')',
    'CREATE INDEX IF NOT EXISTS idx_fb_enum_name ON fb_enum_values(enum_name)',

    'CREATE TABLE IF NOT EXISTS orm_links (' +
    '  id                INTEGER PRIMARY KEY,' +
    '  delphi_symbol_id  INTEGER NOT NULL,' +
    '  delphi_db_index   INTEGER NOT NULL DEFAULT 0,' +
    '  sql_symbol_id     INTEGER NOT NULL,' +
    '  sql_db_index      INTEGER NOT NULL DEFAULT 0,' +
    '  confidence        REAL NOT NULL DEFAULT 1.0,' +
    '  link_kind         TEXT NOT NULL,' +
    '  evidence          TEXT,' +
    '  computed_at       INTEGER NOT NULL' +
    ')',
    'CREATE INDEX IF NOT EXISTS idx_orm_links_delphi ON orm_links(delphi_symbol_id, delphi_db_index)',
    'CREATE INDEX IF NOT EXISTS idx_orm_links_sql    ON orm_links(sql_symbol_id, sql_db_index)',
    'CREATE INDEX IF NOT EXISTS idx_orm_links_kind   ON orm_links(link_kind)'
  );

  SCHEMA_VERSION = 6;

function CreateTempV6Db: string;
var
  Conn: TFDConnection;
  Stmt: string;
  FileId, FileIdV, UnitId, ClassId, MethodBarId: Int64;
  BazClassId, BazMethodId: Int64;
  Q: TFDQuery;
begin
  { Build a unique temp path without actually creating/locking the file.
    TPath.GetTempFileName would create a 0-byte file AND hold it open on
    Windows, causing an EInOutError when SQLite tries to open it.  Instead,
    combine the temp dir with a GUID-based name. }
  Result := TPath.Combine(TPath.GetTempPath,
    'draglint_test_' + TPath.GetGUIDFileName(False) + '.sqlite');

  Conn := TFDConnection.Create(nil);
  try
    Conn.DriverName := 'SQLite';
    Conn.Params.Values['Database'] := Result;
    Conn.Params.Values['LockingMode'] := 'Normal';
    { Do NOT set JournalMode -- leave SQLite default (DELETE) so no WAL/SHM
      files are created for the temp test database. }
    Conn.LoginPrompt := False;
    Conn.Connected := True;

    { DDL }
    Conn.StartTransaction;
    try
      for Stmt in SCHEMA_DDL do
        Conn.ExecSQL(Stmt);
      Conn.ExecSQL(
        'INSERT OR REPLACE INTO schema_meta(key, value) VALUES (''schema_version'', ?)',
        [IntToStr(SCHEMA_VERSION)]);
      Conn.Commit;
    except
      Conn.Rollback;
      raise;
    end;

    { Fixture data }
    Conn.StartTransaction;
    try
      { File row for unit U }
      Conn.ExecSQL(
        'INSERT INTO files(path, mtime_unix, sha256, parsed_at, language) ' +
        'VALUES (''C:\src\U.pas'', 0, ''abc'', 0, ''delphi'')');
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := Conn;
        Q.SQL.Text := 'SELECT last_insert_rowid()';
        Q.Open;
        FileId := Q.Fields[0].AsLargeInt;
        Q.Close;
      finally
        Q.Free;
      end;

      { Unit symbol U, no parent }
      Conn.ExecSQL(
        'INSERT INTO symbols(file_id, parent_id, kind, name, qualified_name, ' +
        '  signature, modifiers, start_line, start_col, end_line, end_col) ' +
        'VALUES (' + IntToStr(FileId) + ', NULL, ''unit'', ''U'', ''U'', ' +
        '  NULL, NULL, 1, 1, 50, 1)');
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := Conn;
        Q.SQL.Text := 'SELECT last_insert_rowid()';
        Q.Open;
        UnitId := Q.Fields[0].AsLargeInt;
        Q.Close;
      finally
        Q.Free;
      end;

      { Class symbol U.TFoo, parent = unit }
      Conn.ExecSQL(
        'INSERT INTO symbols(file_id, parent_id, kind, name, qualified_name, ' +
        '  signature, modifiers, start_line, start_col, end_line, end_col) ' +
        'VALUES (' + IntToStr(FileId) + ', ' + IntToStr(UnitId) +
        ', ''class'', ''TFoo'', ''U.TFoo'', ' +
        '  NULL, NULL, 5, 3, 30, 1)');
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := Conn;
        Q.SQL.Text := 'SELECT last_insert_rowid()';
        Q.Open;
        ClassId := Q.Fields[0].AsLargeInt;
        Q.Close;
      finally
        Q.Free;
      end;

      { Method symbol U.TFoo.Bar, parent = class, lines 10..15 }
      Conn.ExecSQL(
        'INSERT INTO symbols(file_id, parent_id, kind, name, qualified_name, ' +
        '  signature, modifiers, start_line, start_col, end_line, end_col) ' +
        'VALUES (' + IntToStr(FileId) + ', ' + IntToStr(ClassId) +
        ', ''method'', ''Bar'', ''U.TFoo.Bar'', ' +
        '  ''procedure Bar'', NULL, 10, 5, 15, 7)');
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := Conn;
        Q.SQL.Text := 'SELECT last_insert_rowid()';
        Q.Open;
        MethodBarId := Q.Fields[0].AsLargeInt;
        Q.Close;
      finally
        Q.Free;
      end;

      { Class U.TBaz: call target class, parent = unit U, lines 20..40 }
      Conn.ExecSQL(
        'INSERT INTO symbols(file_id, parent_id, kind, name, qualified_name, ' +
        '  signature, modifiers, start_line, start_col, end_line, end_col) ' +
        'VALUES (' + IntToStr(FileId) + ', ' + IntToStr(UnitId) +
        ', ''class'', ''TBaz'', ''U.TBaz'', ' +
        '  NULL, NULL, 20, 3, 40, 1)');
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := Conn;
        Q.SQL.Text := 'SELECT last_insert_rowid()';
        Q.Open;
        BazClassId := Q.Fields[0].AsLargeInt;
        Q.Close;
      finally
        Q.Free;
      end;

      { Method U.TBaz.MB: call target method, parent = U.TBaz, lines 25..30 }
      Conn.ExecSQL(
        'INSERT INTO symbols(file_id, parent_id, kind, name, qualified_name, ' +
        '  signature, modifiers, start_line, start_col, end_line, end_col) ' +
        'VALUES (' + IntToStr(FileId) + ', ' + IntToStr(BazClassId) +
        ', ''method'', ''MB'', ''U.TBaz.MB'', ' +
        '  ''procedure MB'', NULL, 25, 5, 30, 7)');
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := Conn;
        Q.SQL.Text := 'SELECT last_insert_rowid()';
        Q.Open;
        BazMethodId := Q.Fields[0].AsLargeInt;
        Q.Close;
      finally
        Q.Free;
      end;

      { refs row 1: kind=''call'', inside Bar (line 12, within 10..15),
        symbol_id = U.TBaz.MB.  Source will be resolved to U.TFoo.Bar. }
      Conn.ExecSQL(
        'INSERT INTO refs(symbol_id, file_id, kind, name_text, ' +
        '  start_line, start_col, end_line, end_col) ' +
        'VALUES (' + IntToStr(BazMethodId) + ', ' + IntToStr(FileId) +
        ', ''call'', ''MB'', 12, 5, 12, 7)');

      { refs row 2: kind=''type_use'', inside Bar (line 13), symbol_id = U.TFoo }
      Conn.ExecSQL(
        'INSERT INTO refs(symbol_id, file_id, kind, name_text, ' +
        '  start_line, start_col, end_line, end_col) ' +
        'VALUES (' + IntToStr(ClassId) + ', ' + IntToStr(FileId) +
        ', ''type_use'', ''TFoo'', 13, 5, 13, 9)');

      { Suppress unused variable hint -- MethodBarId is captured for future use }
      if MethodBarId = 0 then ;

      { symbol_docs row for the unit U (documented = true, deprecated = false) }
      Conn.ExecSQL(
        'INSERT INTO symbol_docs(symbol_id, format, raw_block, summary, ' +
        '  deprecated, start_line, end_line) ' +
        'VALUES (' + IntToStr(UnitId) + ', ''xmldoc'', ''/// unit U'', ' +
        '  ''Unit U summary'', 0, 1, 1)');

      { symbol_docs row for U.TFoo.Bar -- used by Task 4 GetDoc / ResolveCref tests }
      Conn.ExecSQL(
        'INSERT INTO symbol_docs(symbol_id, format, raw_block, summary, ' +
        '  remarks, returns_text, example_text, since_text, deprecated, ' +
        '  params_json, exceptions_json, seealso_json, start_line, end_line) ' +
        'VALUES (' + IntToStr(MethodBarId) + ', ''xmldoc'', ''/// Bar'', ' +
        '  ''Hi'', '''', '''', '''', ''1.0'', 0, ' +
        '  ''[{"name":"AX","desc":"the x"}]'', ''[]'', ' +
        '  ''["U.TFoo","https://x"]'', 10, 15)');

      { ---- Second file + unit V (for Task 2 unit_uses tests) ---- }

      { File row for unit V }
      Conn.ExecSQL(
        'INSERT INTO files(path, mtime_unix, sha256, parsed_at, language) ' +
        'VALUES (''C:\src\V.pas'', 0, ''def'', 0, ''delphi'')');
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := Conn;
        Q.SQL.Text := 'SELECT last_insert_rowid()';
        Q.Open;
        FileIdV := Q.Fields[0].AsLargeInt;
        Q.Close;
      finally
        Q.Free;
      end;

      { Unit symbol V, no parent }
      Conn.ExecSQL(
        'INSERT INTO symbols(file_id, parent_id, kind, name, qualified_name, ' +
        '  signature, modifiers, start_line, start_col, end_line, end_col) ' +
        'VALUES (' + IntToStr(FileIdV) + ', NULL, ''unit'', ''V'', ''V'', ' +
        '  NULL, NULL, 1, 1, 20, 1)');

      { unit_uses: U uses V in interface section (in-store target) }
      Conn.ExecSQL(
        'INSERT INTO unit_uses(file_id, unit_name, unit_name_norm, section, ' +
        '  in_path, target_file_id, start_line, start_col) ' +
        'VALUES (' + IntToStr(FileId) + ', ''V'', ''v'', ''interface'', ' +
        '  NULL, ' + IntToStr(FileIdV) + ', 3, 3)');

      { unit_uses: U uses System.SysUtils in implementation (external) }
      Conn.ExecSQL(
        'INSERT INTO unit_uses(file_id, unit_name, unit_name_norm, section, ' +
        '  in_path, target_file_id, start_line, start_col) ' +
        'VALUES (' + IntToStr(FileId) + ', ''System.SysUtils'', ' +
        '  ''system.sysutils'', ''implementation'', NULL, NULL, 20, 3)');

      Conn.Commit;

    except
      Conn.Rollback;
      raise;
    end;

  finally
    if Conn.Connected then
      Conn.Close;
    Conn.Free;
  end;
end;

procedure DeleteTempDb(const APath: string);
begin
  if TFile.Exists(APath) then
    TFile.Delete(APath);
end;

end.
