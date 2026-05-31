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

{ TSymbolRange: lightweight record stored per file_id for enclosing-symbol
  resolution.  StartLine/EndLine are the symbol's declared source range;
  QName is the symbol's qualified_name used as graph node id. }
type
  TSymbolRange = record
    StartLine: Integer;
    EndLine:   Integer;
    QName:     string;
  end;

function TDbGraphSource.LoadTopology(AData: TGraphData): Boolean;
var
  Q:               TFDQuery;
  FileMap:         TDictionary<Int64, string>;
  IdToQName:       TDictionary<Int64, string>;
  FileIdToUnit:    TDictionary<Int64, string>;
  DocSymIds:       TDictionary<Int64, Boolean>;
  ExtSeen:         TDictionary<string, Boolean>;
  { Per-file symbol ranges for enclosing-symbol lookup (Task 3) }
  FileRanges:      TObjectDictionary<Int64, TList<TSymbolRange>>;
  RangeList:       TList<TSymbolRange>;
  SR:              TSymbolRange;
  Node:            TGraphNode;
  Edge:            TGraphEdge;
  SymId:           Int64;
  FileId:          Int64;
  TargetFileId:    Int64;
  ParentDbId:      Int64;
  Deprecated:      Boolean;
  SrcQName:        string;
  TgtQName:        string;
  ExtId:           string;
  UnitName:        string;
  Section:         string;
  RefKindText:     string;
  EdgeKind:        TGraphEdgeKind;
  RefLine:         Integer;
  RefSymId:        Int64;
  BestStart:       Integer;
  BestQName:       string;
  J:               Integer;
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

        { ---- 4. Load symbols -> graph nodes; build file_id->unit map
               and per-file symbol ranges for enclosing-symbol resolution ---- }
        FileIdToUnit := TDictionary<Int64, string>.Create;
        { TObjectDictionary owns the TList<TSymbolRange> values }
        FileRanges   := TObjectDictionary<Int64, TList<TSymbolRange>>.Create(
                          [doOwnsValues]);
        try
          Q := TFDQuery.Create(nil);
          try
            Q.Connection := FConn;
            Q.SQL.Text   :=
              'SELECT id, file_id, parent_id, kind, name, qualified_name, ' +
              '  signature, start_line, start_col, end_line ' +
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

              { Populate file_id -> unit qualified_name map }
              if Q.FieldByName('kind').AsString = 'unit' then
                FileIdToUnit.AddOrSetValue(FileId, Node.Id);

              { Record symbol range for enclosing-symbol lookup }
              if not FileRanges.TryGetValue(FileId, RangeList) then
              begin
                RangeList := TList<TSymbolRange>.Create;
                FileRanges.Add(FileId, RangeList);
              end;
              SR.StartLine := Q.FieldByName('start_line').AsInteger;
              SR.EndLine   := Q.FieldByName('end_line').AsInteger;
              SR.QName     := Node.Id;
              RangeList.Add(SR);

              Q.Next;
            end;
            Q.Close;
          finally
            Q.Free;
          end;

          { ---- 5. Load unit_uses -> ekUses edges + external nodes ---- }
          { External nodes are added BEFORE BuildHierarchy so BuildHierarchy
            can parent them under @project like any other rootless unit.
            Deduplication via ExtSeen dictionary. }
          ExtSeen := TDictionary<string, Boolean>.Create;
          try
            Q := TFDQuery.Create(nil);
            try
              Q.Connection := FConn;
              Q.SQL.Text   :=
                'SELECT file_id, unit_name, section, target_file_id ' +
                'FROM unit_uses';
              Q.Open;
              while not Q.Eof do
              begin
                FileId   := Q.FieldByName('file_id').AsLargeInt;
                UnitName := Q.FieldByName('unit_name').AsString;
                Section  := Q.FieldByName('section').AsString;

                { Source: the unit symbol for this file }
                if not FileIdToUnit.TryGetValue(FileId, SrcQName) then
                begin
                  Q.Next;
                  Continue;
                end;

                { Target: in-store unit or external synthetic node }
                if not Q.FieldByName('target_file_id').IsNull then
                begin
                  TargetFileId := Q.FieldByName('target_file_id').AsLargeInt;
                  if not FileIdToUnit.TryGetValue(TargetFileId, TgtQName) then
                  begin
                    { target_file_id set but no unit symbol found -> treat as external }
                    TgtQName := '';
                  end;
                end
                else
                  TgtQName := '';

                if TgtQName = '' then
                begin
                  { External: create-once synthetic node }
                  ExtId := '@ext:' + UnitName;
                  if not ExtSeen.ContainsKey(ExtId) then
                  begin
                    FillChar(Node, SizeOf(Node), 0);
                    Node.Id         := ExtId;
                    Node.Label_     := UnitName;
                    Node.Kind       := nkUnit;
                    Node.IsExternal := True;
                    Node.ParentId   := '';
                    Node.ParentIdx  := -1;
                    Node.Radius     := 10;
                    AData.AddNode(Node);
                    ExtSeen.AddOrSetValue(ExtId, True);
                  end;
                  TgtQName := ExtId;
                end;

                { Add uses edge }
                FillChar(Edge, SizeOf(Edge), 0);
                Edge.SourceId := SrcQName;
                Edge.TargetId := TgtQName;
                Edge.Kind     := ekUses;
                Edge.Label_   := Section;
                Edge.Weight   := 1.0;
                AData.AddEdge(Edge);

                Q.Next;
              end;
              Q.Close;
            finally
              Q.Free;
            end;
          finally
            ExtSeen.Free;
          end;

          { ---- 6. Load refs -> call/typeref/dfm/sqltableref edges
                 using enclosing-symbol resolution ---- }
          Q := TFDQuery.Create(nil);
          try
            Q.Connection := FConn;
            Q.SQL.Text   :=
              'SELECT symbol_id, file_id, kind, name_text, start_line ' +
              'FROM refs';
            Q.Open;
            while not Q.Eof do
            begin
              { Map ref kind to edge kind; skip unrecognised kinds }
              RefKindText := Q.FieldByName('kind').AsString;
              if      RefKindText = 'call'          then EdgeKind := ekCalls
              else if RefKindText = 'type_use'      then EdgeKind := ekTypeRef
              else if RefKindText = 'event-binding' then EdgeKind := ekDfmBinds
              else if RefKindText = 'sql_table_ref' then EdgeKind := ekSqlTableRef
              else
              begin
                Q.Next;
                Continue;
              end;

              { Target: symbol_id must be non-null; else skip unresolved ref }
              if Q.FieldByName('symbol_id').IsNull then
              begin
                Q.Next;
                Continue;
              end;
              RefSymId := Q.FieldByName('symbol_id').AsLargeInt;
              if not IdToQName.TryGetValue(RefSymId, TgtQName) then
              begin
                Q.Next;
                Continue;
              end;

              { Source: find innermost symbol in same file whose range
                contains the ref's start_line (greatest StartLine wins) }
              FileId  := Q.FieldByName('file_id').AsLargeInt;
              RefLine := Q.FieldByName('start_line').AsInteger;
              SrcQName  := '';
              BestStart := -1;
              if FileRanges.TryGetValue(FileId, RangeList) then
              begin
                for J := 0 to RangeList.Count - 1 do
                begin
                  SR := RangeList[J];
                  if (SR.StartLine <= RefLine) and (RefLine <= SR.EndLine) then
                  begin
                    if SR.StartLine > BestStart then
                    begin
                      BestStart := SR.StartLine;
                      BestQName := SR.QName;
                    end;
                  end;
                end;
                if BestStart >= 0 then
                  SrcQName := BestQName;
              end;

              { Skip if no enclosing symbol found, or self-edge }
              if (SrcQName = '') or (SrcQName = TgtQName) then
              begin
                Q.Next;
                Continue;
              end;

              FillChar(Edge, SizeOf(Edge), 0);
              Edge.SourceId := SrcQName;
              Edge.TargetId := TgtQName;
              Edge.Kind     := EdgeKind;
              Edge.Weight   := 1.0;
              AData.AddEdge(Edge);

              Q.Next;
            end;
            Q.Close;
          finally
            Q.Free;
          end;

          { ---- 7. BuildHierarchy ---- }
          AData.BuildHierarchy;
          Result := True;

        finally
          FileRanges.Free;
          FileIdToUnit.Free;
        end;

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
