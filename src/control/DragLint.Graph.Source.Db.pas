unit DragLint.Graph.Source.Db;

{ TDbGraphSource: IGraphSource implementation over a drag-lint SQLite database.
  ONLY this unit links FireDAC; all P1/P2 units remain FireDAC-free.

  Scope note: LoadTopology loads an entire store's graph.  This is impractical
  for very large stores (e.g. the 881 MB library) -- the real product resolves/
  jumps into such stores rather than rendering them whole.  Scoped/lazy loading
  for huge stores is a deferred LOD concern; P3 Task 1 implements straightforward
  full-store load (fine for project-sized DBs). }

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Data.DB,
  FireDAC.Comp.Client,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Phys.SQLite,
  FireDAC.Stan.Param,
  FireDAC.DApt,
  DragLint.Graph.Types,
  DragLint.Graph.Source;

type
  EDbSchemaMismatch = class(Exception);

  TDbGraphSource = class(TInterfacedObject, IGraphSource)
  strict private
    FConn:       TFDConnection;
    FStoreIndex: Integer;
    procedure Connect(const ADbPath: string);
    procedure CheckSchema;
    function  KindTextToNodeKind(const AKind: string): TGraphNodeKind;
  public
    constructor Create(const ADbPath: string; AStoreIndex: Integer);
    destructor  Destroy; override;

    { IGraphSource }
    function StoreIndex: Integer;
    function LoadTopology(AData: TGraphData): Boolean;
    function GetDoc(const AQName: string): TGraphDoc;
    function ResolveCref(const AText: string): TCrefResolution;
    function LocateSymbol(const AQName: string; out AFile: string;
      out ALine: Integer): Boolean;
  end;

implementation

{ TDbGraphSource }

constructor TDbGraphSource.Create(const ADbPath: string; AStoreIndex: Integer);
begin
  inherited Create;
  FStoreIndex := AStoreIndex;
  Connect(ADbPath);
  CheckSchema;
end;

destructor TDbGraphSource.Destroy;
begin
  if Assigned(FConn) then
  begin
    if FConn.Connected then
      FConn.Close;
    FConn.Free;
  end;
  inherited;
end;

procedure TDbGraphSource.Connect(const ADbPath: string);
begin
  FConn := TFDConnection.Create(nil);
  FConn.DriverName := 'SQLite';
  FConn.Params.Values['Database'] := ADbPath;
  { Open read-write so WAL-mode databases can access the -shm coordination
    file; we enforce the "never mutate" contract via PRAGMA query_only = ON
    which raises SQLITE_READONLY on any attempt to execute DML or DDL.
    Note: OpenMode=ReadOnly fails on WAL-mode databases (SQLite cannot
    create the -shm file when the connection has SQLITE_OPEN_READONLY). }
  FConn.Params.Values['OpenMode']    := 'ReadWrite';
  FConn.Params.Values['LockingMode'] := 'Normal';
  FConn.LoginPrompt := False;
  FConn.Connected   := True;
  { Enforce read-only semantics for this session.  Any DML/DDL will raise
    SQLITE_READONLY (8) rather than silently modifying the user's database. }
  FConn.ExecSQL('PRAGMA query_only = ON');
end;

procedure TDbGraphSource.CheckSchema;
var
  Q: TFDQuery;
  Ver: Integer;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'SELECT value FROM schema_meta WHERE key = ''schema_version'' LIMIT 1';
    Q.Open;
    if Q.IsEmpty then
      raise EDbSchemaMismatch.Create(
        'schema_meta has no schema_version row; expected >= 5');
    Ver := Q.Fields[0].AsInteger;
    if Ver < 5 then
      raise EDbSchemaMismatch.CreateFmt(
        'DB schema version %d is too old (need >= 5); run the indexer to upgrade.',
        [Ver]);
  finally
    Q.Free;
  end;
end;

function TDbGraphSource.KindTextToNodeKind(
  const AKind: string): TGraphNodeKind;
begin
  if      AKind = 'unit'           then Result := nkUnit
  else if AKind = 'class'          then Result := nkClass
  else if AKind = 'interface'      then Result := nkInterface
  else if AKind = 'record'         then Result := nkRecord
  else if AKind = 'method'         then Result := nkMethod
  else if AKind = 'procedure'      then Result := nkProcedure
  else if AKind = 'function'       then Result := nkFunction
  else if AKind = 'property'       then Result := nkProperty
  else if AKind = 'field'          then Result := nkField
  else if AKind = 'const'          then Result := nkConst
  else if AKind = 'var'            then Result := nkVar
  else if AKind = 'type'           then Result := nkType
  else if AKind = 'sql_table'      then Result := nkSqlTable
  else if AKind = 'sql_column'     then Result := nkSqlColumn
  else if AKind = 'sql_index'      then Result := nkSqlIndex
  else if AKind = 'sql_trigger'    then Result := nkSqlTrigger
  else if AKind = 'sql_generator'  then Result := nkSqlGenerator
  else if AKind = 'sql_view'       then Result := nkSqlView
  else if AKind = 'sql_procedure'  then Result := nkSqlProcedure
  else if AKind = 'sql_exception'  then Result := nkSqlException
  else if AKind = 'sql_domain'     then Result := nkSqlDomain
  else                                  Result := nkOther;
end;

function TDbGraphSource.StoreIndex: Integer;
begin
  Result := FStoreIndex;
end;

function TDbGraphSource.LoadTopology(AData: TGraphData): Boolean;
var
  Q:            TFDQuery;
  FileMap:      TDictionary<Int64, string>;   { file_id -> path }
  IdToQName:    TDictionary<Int64, string>;   { symbol.id -> qualified_name }
  DocSymIds:    TDictionary<Int64, Boolean>;  { symbol_id -> deprecated }
  Node:         TGraphNode;
  SymId:        Int64;
  FileId:       Int64;
  ParentDbId:   Int64;
  Deprecated:   Boolean;
begin
  Result := False;
  if AData = nil then Exit;
  AData.Clear;

  { ---- 1. Build file_id -> path map ---- }
  FileMap := TDictionary<Int64, string>.Create;
  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text   := 'SELECT id, path FROM files';
      Q.Open;
      while not Q.Eof do
      begin
        FileMap.AddOrSetValue(Q.FieldByName('id').AsLargeInt,
                              Q.FieldByName('path').AsString);
        Q.Next;
      end;
      Q.Close;
    finally
      Q.Free;
    end;

    { ---- 2. Build symbol id -> qualified_name map ---- }
    IdToQName := TDictionary<Int64, string>.Create;
    try
      Q := TFDQuery.Create(nil);
      try
        Q.Connection := FConn;
        Q.SQL.Text   := 'SELECT id, qualified_name FROM symbols';
        Q.Open;
        while not Q.Eof do
        begin
          IdToQName.AddOrSetValue(Q.FieldByName('id').AsLargeInt,
                                  Q.FieldByName('qualified_name').AsString);
          Q.Next;
        end;
        Q.Close;
      finally
        Q.Free;
      end;

      { ---- 3. Load symbol_docs flags (one pass) ---- }
      DocSymIds := TDictionary<Int64, Boolean>.Create;
      try
        Q := TFDQuery.Create(nil);
        try
          Q.Connection := FConn;
          Q.SQL.Text   :=
            'SELECT symbol_id, deprecated FROM symbol_docs';
          Q.Open;
          while not Q.Eof do
          begin
            Deprecated := Q.FieldByName('deprecated').AsInteger <> 0;
            DocSymIds.AddOrSetValue(
              Q.FieldByName('symbol_id').AsLargeInt, Deprecated);
            Q.Next;
          end;
          Q.Close;
        finally
          Q.Free;
        end;

        { ---- 4. Load symbols -> graph nodes ---- }
        Q := TFDQuery.Create(nil);
        try
          Q.Connection := FConn;
          Q.SQL.Text   :=
            'SELECT id, file_id, parent_id, kind, name, qualified_name, ' +
            '  signature, start_line, start_col ' +
            'FROM symbols';
          Q.Open;
          while not Q.Eof do
          begin
            FillChar(Node, SizeOf(Node), 0);
            SymId  := Q.FieldByName('id').AsLargeInt;
            FileId := Q.FieldByName('file_id').AsLargeInt;

            Node.Id        := Q.FieldByName('qualified_name').AsString;
            Node.Label_    := Q.FieldByName('name').AsString;
            Node.Kind      := KindTextToNodeKind(
                                Q.FieldByName('kind').AsString);
            Node.DbId      := SymId;
            Node.Signature := Q.FieldByName('signature').AsString;
            Node.Line      := Q.FieldByName('start_line').AsInteger;
            Node.Col       := Q.FieldByName('start_col').AsInteger;
            Node.Radius    := 12;
            Node.ParentIdx := -1;

            { FilePath from file_id map }
            if not FileMap.TryGetValue(FileId, Node.FilePath) then
              Node.FilePath := '';

            { ParentId: resolve parent_id (db int) to qualified_name }
            if not Q.FieldByName('parent_id').IsNull then
            begin
              ParentDbId := Q.FieldByName('parent_id').AsLargeInt;
              if not IdToQName.TryGetValue(ParentDbId, Node.ParentId) then
                Node.ParentId := '';
            end
            else
              Node.ParentId := '';

            { Documented / Deprecated flags from symbol_docs }
            Node.Documented := DocSymIds.ContainsKey(SymId);
            if Node.Documented then
              Node.Deprecated := DocSymIds[SymId];

            AData.AddNode(Node);
            Q.Next;
          end;
          Q.Close;
        finally
          Q.Free;
        end;

        { ---- 5. BuildHierarchy ---- }
        AData.BuildHierarchy;
        Result := True;

      finally
        DocSymIds.Free;
      end;
    finally
      IdToQName.Free;
    end;
  finally
    FileMap.Free;
  end;
end;

{ Stubs -- implemented in Task 4 }

function TDbGraphSource.GetDoc(const AQName: string): TGraphDoc;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function TDbGraphSource.ResolveCref(const AText: string): TCrefResolution;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Text := AText;
  Result.Kind := crkUnresolved;
end;

function TDbGraphSource.LocateSymbol(const AQName: string; out AFile: string;
  out ALine: Integer): Boolean;
begin
  AFile  := '';
  ALine  := 0;
  Result := False;
end;

end.
