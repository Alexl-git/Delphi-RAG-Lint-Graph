unit DragLint.Graph.Source.Db;

{ TDbGraphSource: IGraphSource implementation over a drag-lint SQLite database.
  ONLY this unit links FireDAC; all P1/P2 units remain FireDAC-free.

  Node cap: FMaxNodes (default 20000) bounds how many symbol rows are loaded.
  LoadTopology first counts all symbols; if the count exceeds FMaxNodes, only
  the first FMaxNodes symbols are loaded (LIMIT :max in the SELECT) and
  FWasTruncated is set True.  The refs and unit_uses queries are bounded too:
    - refs:      LIMIT (FMaxNodes * 50)  -- safety ceiling to avoid scanning
                 2.5M rows on the library; a ref-per-node ceiling.
    - unit_uses: LIMIT (FMaxNodes * 10)  -- smaller table, lighter bound.
  Rows whose file_id is not in the loaded-file set are skipped in-code after
  fetch so both queries stay simple (no IN-list of thousands). }

interface

uses
  Winapi.Windows
  , System.SysUtils
  , System.StrUtils
  , System.Classes
  , System.Generics.Collections
  , System.JSON
  , Data.Db
  , FireDAC.Comp.Client
  , FireDAC.Stan.Def
  , FireDAC.Stan.Async
  , FireDAC.Phys.SQLite
  , FireDAC.Stan.Param
  , FireDAC.DApt
  , DragLint.Graph.Types
  , DragLint.Graph.Source
  ;

type
  EDbSchemaMismatch = class(Exception);

    TDbGraphSource = class(TInterfacedObject, IGraphSource)
      strict private
        FConn            : TFDConnection;
        FStoreIndex      : Integer      ;
        FMaxNodes        : Integer      ;
        FSchemaVer       : Integer      ; { for optional columns added in later versions }
        FWasTruncated    : Boolean      ;
        FTotalSymbolCount: Integer      ;
        procedure Connect(const ADbPath: string);
        procedure CheckSchema;
        function KindTextToNodeKind(const AKind: string): TGraphNodeKind;
      public
        constructor Create(const ADbPath: string; AStoreIndex: Integer);
        destructor Destroy; override;

        { Node cap -- default 20000.  Set before calling LoadTopology. }
        procedure SetMaxNodes(AValue: Integer);
        function MaxNodes: Integer;
        { True when the last LoadTopology call stopped short because
      TotalSymbolCount > MaxNodes. }
        function WasTruncated: Boolean;
        { The full symbol count from SELECT COUNT(*) in the last LoadTopology call.
      0 when LoadTopology has not been called yet. }
        function TotalSymbolCount: Integer;

        { IGraphSource }
        function StoreIndex: Integer                                                               ;
        function LoadTopology(AData: TGraphData): Boolean                                          ;
        function GetDoc     (const AQName: string): TGraphDoc;
        function ResolveCref(const AText : string): TCrefResolution;
        function LocateSymbol(const AQName: string; out AFile: string; out ALine: Integer): Boolean;
        { Lightweight: exact qualified_name match, then bare name (kind-priority).
      Returns first hit; does NOT call LoadTopology.  Used by TDbCatalog. }
        function ResolveName(const AName: string; out AQName: string): Boolean                              ;
        function GetCallees(const AQName: string): TArray<TCallRef>                                         ;
        function GetSymbolMeta(const AQName: string; out ASignature, AModifiers, AKindText: string): Boolean;
    end;

    { TDbCatalog: ordered set of DB stores.  SourceForStore lazily creates and
    caches a TDbGraphSource per index.  ResolveAcrossStores runs ResolveName
    against each store in order (first-hit-wins) without LoadTopology. }
    TDbCatalog = class(TInterfacedObject, IDbCatalog)
      strict private
        FPaths  : TArray<string>      ;
        FSources: TArray<IGraphSource>;
      public
        constructor Create(const APaths: TArray<string>);
        { IDbCatalog }
        function StoreCount: Integer                                         ;
        function StorePath(AIndex: Integer): string                          ;
        function SourceForStore(AIndex: Integer): IGraphSource               ;
        function ResolveAcrossStores(const AName: string): TCrossDbResolution;
    end;

implementation

{ TDbGraphSource }

constructor TDbGraphSource.Create(const ADbPath: string; AStoreIndex: Integer);
begin
  inherited Create;
  FStoreIndex      := AStoreIndex;
  FMaxNodes        := 20000;
  FWasTruncated    := False;
  FTotalSymbolCount:= 0;
  Connect(ADbPath);
  CheckSchema;
end;

procedure TDbGraphSource.SetMaxNodes(AValue: Integer);
begin
  if AValue < 1 then AValue:= 1;
  FMaxNodes:= AValue;
end;

function TDbGraphSource.MaxNodes: Integer;
begin
  Result:= FMaxNodes;
end;

function TDbGraphSource.WasTruncated: Boolean;
begin
  Result:= FWasTruncated;
end;

function TDbGraphSource.TotalSymbolCount: Integer;
begin
  Result:= FTotalSymbolCount;
end;

destructor TDbGraphSource.Destroy;
begin
  if Assigned(FConn) then
  begin
    if FConn.Connected then FConn.Close;
    FConn.Free;
  end;
  inherited;
end;

procedure TDbGraphSource.Connect(const ADbPath: string);
begin
  FConn:= TFDConnection.Create(nil);
  FConn.DriverName:= 'SQLite';
  { Open read-only + immutable so that:
    (a) no -shm/-wal sidecar files are created next to the user's database,
    (b) no writer lock is acquired -- the connection coexists with a live
        indexer process that may hold an exclusive or reserved lock.

    SQLite immutable=1 is a URI query parameter that tells SQLite the file
    will not change while open, bypassing WAL/locking coordination entirely.
    FireDAC (Delphi 13) does NOT add SQLITE_OPEN_URI to its open flags and
    does NOT map SQLiteAdvanced=immutable=1 to the URI parameter (it runs
    it as a PRAGMA, which is not valid).  To enable URI filenames, our
    unit initialization calls sqlite3_config(SQLITE_CONFIG_URI=17, 1) before
    any connection is made; this enables URI interpretation globally for the
    process.  We then pass a file: URI as the Database path.

    file:///C:/path uses three slashes for the empty authority + Windows
    absolute path.  Forward slashes are required by the URI spec.

    OpenMode=ReadOnly maps to SQLITE_OPEN_READONLY.
    No PRAGMA query_only is needed: ReadOnly already prevents all writes. }
  FConn.Params.Values['OpenMode'   ]:= 'ReadOnly';
  FConn.Params.Values['LockingMode']:= 'Normal';
  FConn.LoginPrompt:= False;
  { Percent-encode characters that are significant in a URI path so that
    paths containing spaces, '#', or '?' do not break the file: URI.
    Current DB paths have no such characters; this is defensive for future
    paths.  '\' -> '/' is required by the URI spec (Windows absolute path). }
  FConn.Params.Values['Database']:= 'file:///' + StringReplace(
    StringReplace( StringReplace( StringReplace(ADbPath, '\', '/', [rfReplaceAll]), ' ', '%20', [rfReplaceAll]), '#', '%23', [rfReplaceAll]), '?', '%3F', [rfReplaceAll])
    + '?immutable=1';
  FConn.Connected:= True;
end; // procedure

procedure TDbGraphSource.CheckSchema;
var
  Q  : TFDQuery;
  Ver: Integer ;
begin
  Q:= TFDQuery.Create(nil);
  try
    Q.Connection:= FConn;
    Q.SQL.Text:= 'SELECT value FROM schema_meta WHERE key = ''schema_version'' LIMIT 1';
    Q.Open;
    if Q.IsEmpty then raise EDbSchemaMismatch.Create( 'schema_meta has no schema_version row; expected >= 5');
    Ver:= Q.Fields[0].AsInteger;
    if Ver < 5 then raise EDbSchemaMismatch.CreateFmt( 'DB schema version %d is too old (need >= 5); run the indexer to upgrade.', [Ver]);
    FSchemaVer:= Ver;
  finally
    Q.Free;
  end;
end; // procedure

function TDbGraphSource.KindTextToNodeKind( const AKind: string): TGraphNodeKind;
begin
  if AKind      = 'unit' then Result:= nkUnit
  else if AKind = 'class'         then Result:= nkClass
  else if AKind = 'interface'     then Result:= nkInterface
  else if AKind = 'record'        then Result:= nkRecord
  else if AKind = 'method'        then Result:= nkMethod
  else if AKind = 'procedure'     then Result:= nkProcedure
  else if AKind = 'function'      then Result:= nkFunction
  else if AKind = 'property'      then Result:= nkProperty
  else if AKind = 'field'         then Result:= nkField
  else if AKind = 'const'         then Result:= nkConst
  else if AKind = 'var'           then Result:= nkVar
  else if AKind = 'type'          then Result:= nkType { type-family declarations: colour + render as a Type rather than a generic
    grey "Other" dot, and (being nkType) draw as a member-listing UML box. }
  else if AKind = 'enum'          then Result:= nkType
  else if AKind = 'set'           then Result:= nkType
  else if AKind = 'subrange'      then Result:= nkType
  else if AKind = 'array'         then Result:= nkType
  else if AKind = 'alias'         then Result:= nkType
  else if AKind = 'pointer'       then Result:= nkType
  else if AKind = 'proc_type'     then Result:= nkType
  else if AKind = 'class_ref'     then Result:= nkType
  else if AKind = 'sql_table'     then Result:= nkSqlTable
  else if AKind = 'sql_column'    then Result:= nkSqlColumn
  else if AKind = 'sql_index'     then Result:= nkSqlIndex
  else if AKind = 'sql_trigger'   then Result:= nkSqlTrigger
  else if AKind = 'sql_generator' then Result:= nkSqlGenerator
  else if AKind = 'sql_view'      then Result:= nkSqlView
  else if AKind = 'sql_procedure' then Result:= nkSqlProcedure
  else if AKind = 'sql_exception' then Result:= nkSqlException
  else if AKind = 'sql_domain'    then Result:= nkSqlDomain
  else Result:= nkOther;
end; // function

function TDbGraphSource.StoreIndex: Integer;
begin
  Result:= FStoreIndex;
end;

{ TSymbolRange: lightweight record stored per file_id for enclosing-symbol
  resolution.  StartLine/EndLine are the symbol's declared source range;
  QName is the symbol's qualified_name used as graph node id. }
type
  TSymbolRange = record
    StartLine: Integer;
    EndLine  : Integer;
    QName    : string ;
  end;

function TDbGraphSource.LoadTopology(AData: TGraphData): Boolean;
var
  Q            : TFDQuery                    ;
  FileMap      : TDictionary<Int64, string>  ;
  LoadedFileIds: TDictionary<Int64, Boolean> ;
  IdToQName    : TDictionary<Int64, string>  ;
  FileIdToUnit : TDictionary<Int64, string>  ;
  DocSymIds    : TDictionary<Int64, Boolean> ;
  ExtSeen      : TDictionary<string, Boolean>;
  { Per-file symbol ranges for enclosing-symbol lookup (Task 3) }
  FileRanges  : TObjectDictionary<Int64, TList<TSymbolRange>>;
  RangeList   : TList<TSymbolRange>                          ;
  SR          : TSymbolRange                                 ;
  Node        : TGraphNode                                   ;
  Edge        : TGraphEdge                                   ;
  SymId       : Int64                                        ;
  FileId      : Int64                                        ;
  TargetFileId: Int64                                        ;
  ParentDbId  : Int64                                        ;
  Deprecated  : Boolean                                      ;
  SrcQName    : string                                       ;
  TgtQName    : string                                       ;
  ExtId       : string                                       ;
  UnitName    : string                                       ;
  Section     : string                                       ;
  RefKindText : string                                       ;
  EdgeKind    : TGraphEdgeKind                               ;
  RefLine     : Integer                                      ;
  RefSymId    : Int64                                        ;
  BestStart   : Integer                                      ;
  BestQName   : string                                       ;
  J           : Integer                                      ;
  RefsLimit   : Integer                                      ;
  UsesLimit   : Integer                                      ;
begin
  Result:= False;
  if AData = nil then Exit;
  AData.Clear;
  FWasTruncated    := False;
  FTotalSymbolCount:= 0;

  { ---- 0. Count total symbols to detect truncation ---- }
  Q:= TFDQuery.Create(nil);
  try
    Q.Connection:= FConn;
    Q.SQL.Text:= 'SELECT COUNT(*) FROM symbols';
    Q.Open;
    FTotalSymbolCount:= Q.Fields[0].AsInteger;
    Q.Close;
  finally
    Q.Free;
  end;
  FWasTruncated:= (FTotalSymbolCount > FMaxNodes);

  { Derived safety limits for refs / unit_uses scans.
    refs:      FMaxNodes * 50  (ref-per-node ceiling for 2.5M-row library).
    unit_uses: FMaxNodes * 10  (smaller table, lighter bound). }
  RefsLimit:= FMaxNodes * 50;
  UsesLimit:= FMaxNodes * 10;

  { ---- 1. Build file_id -> path map ---- }
  FileMap:= TDictionary<Int64, string>.Create;
  { Tracks which file_ids are reachable from loaded symbols.
    Rows in refs / unit_uses whose file_id is NOT in this set are skipped
    in-code (no IN-list needed; avoids scanning 2.5M rows fully). }
  LoadedFileIds:= TDictionary<Int64, Boolean>.Create;
  try
    Q:= TFDQuery.Create(nil);
    try
      Q.Connection:= FConn;
      Q.SQL.Text:= 'SELECT id, path FROM files';
      Q.Open;
      while not Q.Eof do
      begin
        FileMap.AddOrSetValue(Q.FieldByName('id').AsLargeInt, Q.FieldByName('path').AsString);
        Q.Next;
      end;
      Q.Close;
    finally
      Q.Free;
    end;

    { ---- 2. Build symbol id -> qualified_name map (capped) ---- }
    IdToQName:= TDictionary<Int64, string>.Create;
    try
      Q:= TFDQuery.Create(nil);
      try
        Q.Connection:= FConn;
        { LIMIT :max -- plain LIMIT, no ORDER BY, for speed on huge tables.
          FMaxNodes bounds materialisation; WasTruncated records the shortfall. }
        Q.SQL.Text:= 'SELECT id, qualified_name FROM symbols LIMIT :max';
        Q.ParamByName('max').AsInteger:= FMaxNodes;
        Q.Open;
        while not Q.Eof do
        begin
          IdToQName.AddOrSetValue(Q.FieldByName('id').AsLargeInt, Q.FieldByName('qualified_name').AsString);
          Q.Next;
        end;
        Q.Close;
      finally
        Q.Free;
      end; // try

      { ---- 3. Load symbol_docs flags (one pass) ---- }
      DocSymIds:= TDictionary<Int64, Boolean>.Create;
      try
        Q:= TFDQuery.Create(nil);
        try
          Q.Connection:= FConn;
          Q.SQL.Text:= 'SELECT symbol_id, deprecated FROM symbol_docs';
          Q.Open;
          while not Q.Eof do
          begin
            Deprecated:= Q.FieldByName('deprecated').AsInteger <> 0;
            DocSymIds.AddOrSetValue( Q.FieldByName('symbol_id').AsLargeInt, Deprecated);
            Q.Next;
          end;
          Q.Close;
        finally
          Q.Free;
        end;

        { ---- 4. Load symbols -> graph nodes; build file_id->unit map,
               loaded-file set, and per-file symbol ranges ---- }
        FileIdToUnit:= TDictionary<Int64, string>.Create;
        { TObjectDictionary owns the TList<TSymbolRange> values }
        FileRanges:= TObjectDictionary<Int64, TList<TSymbolRange>>.Create( [doOwnsValues]);
        try
          Q:= TFDQuery.Create(nil);
          try
            Q.Connection:= FConn;
            { LIMIT :max matches the id->qname cap so only loaded symbols
              become nodes.  No ORDER BY -- raw storage order is fastest. }
            Q.SQL.Text:= 'SELECT id, file_id, parent_id, kind, name, qualified_name, ' + '  signature, modifiers, start_line, start_col, end_line' +
            IfThen(FSchemaVer >= 7, ', section', '') + ' ' + 'FROM symbols LIMIT :max';
            Q.ParamByName('max').AsInteger:= FMaxNodes;
            Q.Open;
            while not Q.Eof do
            begin
              FillChar(Node, SizeOf(Node), 0);
              SymId := Q.FieldByName('id'     ).AsLargeInt;
              FileId:= Q.FieldByName('file_id').AsLargeInt;

              Node.Id      := Q.FieldByName('qualified_name').AsString;
              Node.Label_  := Q.FieldByName('name'          ).AsString;
              Node.KindText:= Q.FieldByName('kind'          ).AsString;
              Node.Kind:= KindTextToNodeKind(Node.KindText);
              Node.DbId:= SymId;
              Node.Signature:= Q.FieldByName('signature').AsString;
              Node.Modifiers:= Q.FieldByName('modifiers').AsString;
              if Q.FindField('section') <> nil then Node.Section:= Q.FieldByName('section').AsString;
              Node.Line:= Q.FieldByName('start_line').AsInteger;
              Node.Col := Q.FieldByName('start_col' ).AsInteger;
              Node.Radius:= 12;
              Node.ParentIdx:= -1;

              { FilePath from file_id map }
              if not FileMap.TryGetValue(FileId, Node.FilePath) then Node.FilePath:= '';

              { ParentId: resolve parent_id (db int) to qualified_name }
              if not Q.FieldByName('parent_id').IsNull then
              begin
                ParentDbId:= Q.FieldByName('parent_id').AsLargeInt;
                if not IdToQName.TryGetValue(ParentDbId, Node.ParentId) then Node.ParentId:= '';
              end
              else Node.ParentId:= '';

              { Documented / Deprecated flags from symbol_docs }
              Node.Documented:= DocSymIds.ContainsKey(SymId);
              if Node.Documented then Node.Deprecated:= DocSymIds[SymId];

              AData.AddNode(Node);

              { Track this file as reachable (for refs/unit_uses filtering) }
              LoadedFileIds.AddOrSetValue(FileId, True);

              { Populate file_id -> unit qualified_name map }
              if Q.FieldByName('kind').AsString = 'unit' then FileIdToUnit.AddOrSetValue(FileId, Node.Id);

              { Record symbol range for enclosing-symbol lookup }
              if not FileRanges.TryGetValue(FileId, RangeList) then
              begin
                RangeList:= TList<TSymbolRange>.Create;
                FileRanges.Add(FileId, RangeList);
              end;
              SR.StartLine:= Q.FieldByName('start_line').AsInteger;
              SR.EndLine  := Q.FieldByName('end_line'  ).AsInteger;
              SR.QName:= Node.Id;
              RangeList.Add(SR);

              Q.Next;
            end; // while
            Q.Close;
          finally
            Q.Free;
          end; // try

          { ---- 5. Load unit_uses -> ekUses edges + external nodes ---- }
          { External nodes are added BEFORE BuildHierarchy so BuildHierarchy
            can parent them under @project like any other rootless unit.
            Deduplication via ExtSeen dictionary.
            LIMIT UsesLimit prevents scanning all rows on huge stores. }
          ExtSeen:= TDictionary<string, Boolean>.Create;
          try
            Q:= TFDQuery.Create(nil);
            try
              Q.Connection:= FConn;
              Q.SQL.Text:= 'SELECT file_id, unit_name, section, target_file_id ' + 'FROM unit_uses LIMIT :lim';
              Q.ParamByName('lim').AsInteger:= UsesLimit;
              Q.Open;
              while not Q.Eof do
              begin
                FileId  := Q.FieldByName('file_id'  ).AsLargeInt;
                UnitName:= Q.FieldByName('unit_name').AsString;
                Section := Q.FieldByName('section'  ).AsString;

                { Skip rows from files not in the loaded set }
                if not LoadedFileIds.ContainsKey(FileId) then
                begin
                  Q.Next;
                  Continue;
                end;

                { Source: the unit symbol for this file }
                if not FileIdToUnit.TryGetValue(FileId, SrcQName) then
                begin
                  Q.Next;
                  Continue;
                end;

                { Target: in-store unit or external synthetic node }
                if not Q.FieldByName('target_file_id').IsNull then
                begin
                  TargetFileId:= Q.FieldByName('target_file_id').AsLargeInt;
                  if not FileIdToUnit.TryGetValue(TargetFileId, TgtQName) then
                  begin
                    { target_file_id set but no unit symbol found -> treat as external }
                    TgtQName:= '';
                  end;
                end
                else TgtQName:= '';

                if TgtQName = '' then
                begin
                  { External: create-once synthetic node }
                  ExtId:= '@ext:' + UnitName;
                  if not ExtSeen.ContainsKey(ExtId) then
                  begin
                    FillChar(Node, SizeOf(Node), 0);
                    Node.Id        := ExtId;
                    Node.Label_    := UnitName;
                    Node.Kind      := nkUnit;
                    Node.IsExternal:= True;
                    Node.ParentId  := '';
                    Node.ParentIdx:= -1;
                    Node.Radius:= 10;
                    AData.AddNode(Node);
                    ExtSeen.AddOrSetValue(ExtId, True);
                  end;
                  TgtQName:= ExtId;
                end; // if

                { Add uses edge }
                FillChar(Edge, SizeOf(Edge), 0);
                Edge.SourceId:= SrcQName;
                Edge.TargetId:= TgtQName;
                Edge.Kind    := ekUses;
                Edge.Label_  := Section;
                Edge.Weight  := 1.0;
                AData.AddEdge(Edge);

                Q.Next;
              end; // while
              Q.Close;
            finally
              Q.Free;
            end; // try
          finally
            ExtSeen.Free;
          end; // try

          { ---- 6. Load refs -> call/typeref/dfm/sqltableref edges
                 using enclosing-symbol resolution ----
            LIMIT RefsLimit is a safety ceiling so the library's 2.5M ref rows
            do not all stream; only refs from loaded files are processed. }
          Q:= TFDQuery.Create(nil);
          try
            Q.Connection:= FConn;
            Q.SQL.Text:= 'SELECT symbol_id, file_id, kind, name_text, start_line ' + 'FROM refs LIMIT :lim';
            Q.ParamByName('lim').AsInteger:= RefsLimit;
            Q.Open;
            while not Q.Eof do
            begin
              { Skip rows from files not in the loaded set }
              FileId:= Q.FieldByName('file_id').AsLargeInt;
              if not LoadedFileIds.ContainsKey(FileId) then
              begin
                Q.Next;
                Continue;
              end;

              { Map ref kind to edge kind; skip unrecognised kinds }
              RefKindText:= Q.FieldByName('kind').AsString;
              if RefKindText      = 'call' then EdgeKind:= ekCalls
              else if RefKindText = 'type_use'      then EdgeKind:= ekTypeRef
              else if RefKindText = 'event-binding' then EdgeKind:= ekDfmBinds
              else if RefKindText = 'sql_table_ref' then EdgeKind:= ekSqlTableRef
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
              RefSymId:= Q.FieldByName('symbol_id').AsLargeInt;
              if not IdToQName.TryGetValue(RefSymId, TgtQName) then
              begin
                Q.Next;
                Continue;
              end;

              { Source: find innermost symbol in same file whose range
                contains the ref's start_line (greatest StartLine wins) }
              RefLine:= Q.FieldByName('start_line').AsInteger;
              SrcQName:= '';
              BestStart:= -1;
              if FileRanges.TryGetValue(FileId, RangeList) then
              begin
                for J:= 0 to RangeList.Count - 1 do
                begin
                  SR:= RangeList[J];
                  if (SR.StartLine <= RefLine) and (RefLine <= SR.EndLine) then
                  begin
                    if SR.StartLine > BestStart then
                    begin
                      BestStart:= SR.StartLine;
                      BestQName:= SR.QName;
                    end;
                  end;
                end;
                if BestStart >= 0 then SrcQName:= BestQName;
              end; // if

              { Skip if no enclosing symbol found, or self-edge }
              if (SrcQName = '') or (SrcQName = TgtQName) then
              begin
                Q.Next;
                Continue;
              end;

              FillChar(Edge, SizeOf(Edge), 0);
              Edge.SourceId:= SrcQName;
              Edge.TargetId:= TgtQName;
              Edge.Kind    := EdgeKind;
              Edge.Weight  := 1.0;
              AData.AddEdge(Edge);

              Q.Next;
            end; // while
            Q.Close;
          finally
            Q.Free;
          end; // try

          { ---- 7. BuildHierarchy ---- }
          AData.BuildHierarchy;
          Result:= True;

        finally
          FileRanges.Free;
          FileIdToUnit.Free;
        end; // try

      finally
        DocSymIds.Free;
      end; // try
    finally
      IdToQName.Free;
    end; // try
  finally
    LoadedFileIds.Free;
    FileMap.Free;
  end; // try
end; // function

{ ---- Task 4: GetDoc + ResolveCref + LocateSymbol ---- }

{ ParseJsonStringArray: parse a JSON TEXT column value that is an array of
  strings into AResult.  On any parse failure (null / malformed), AResult is
  left empty (no exception raised).  The caller must free returned strings
  via Result being a managed TArray<string>. }
function ParseJsonStringArray(const AJson: string): TArray<string>;
var
  JV: TJSONValue   ;
  JA: TJSONArray   ;
  I : Integer      ;
  L : TList<string>;
begin
  Result:= nil;
  if AJson = '' then Exit;
  JV:= nil;
  try
    try
      JV:= TJSONObject.ParseJSONValue(AJson);
    except
      Exit;
    end;
    if not (JV is TJSONArray) then Exit;
    JA:= TJSONArray(JV);
    L:= TList<string>.Create;
    try
      for I:= 0 to JA.Count - 1 do L.Add(JA.Items[I].Value);
      Result:= L.ToArray;
    finally
      L.Free;
    end;
  finally
    JV.Free;
  end; // try
end; // function

{ ParseJsonParamArray: parse params_json -- array of name/desc objects. }
function ParseJsonParamArray(const AJson: string): TArray<TDocParam>;
var
  JV: TJSONValue      ;
  JA: TJSONArray      ;
  JO: TJSONObject     ;
  I : Integer         ;
  P : TDocParam       ;
  L : TList<TDocParam>;
begin
  Result:= nil;
  if AJson = '' then Exit;
  JV:= nil;
  try
    try
      JV:= TJSONObject.ParseJSONValue(AJson);
    except
      Exit;
    end;
    if not (JV is TJSONArray) then Exit;
    JA:= TJSONArray(JV);
    L:= TList<TDocParam>.Create;
    try
      for I:= 0 to JA.Count - 1 do
      begin
        if not (JA.Items[I] is TJSONObject) then Continue;
        JO:= TJSONObject(JA.Items[I]);
        FillChar(P, SizeOf(P), 0);
        P.Name:= JO.GetValue<string>('name', '');
        P.Desc:= JO.GetValue<string>('desc', '');
        L.Add(P);
      end;
      Result:= L.ToArray;
    finally
      L.Free;
    end;
  finally
    JV.Free;
  end; // try
end; // function

{ ParseJsonExceptionArray: parse exceptions_json -- array of type/desc objects. }
function ParseJsonExceptionArray(const AJson: string): TArray<TDocException>;
var
  JV: TJSONValue          ;
  JA: TJSONArray          ;
  JO: TJSONObject         ;
  I : Integer             ;
  E : TDocException       ;
  L : TList<TDocException>;
begin
  Result:= nil;
  if AJson = '' then Exit;
  JV:= nil;
  try
    try
      JV:= TJSONObject.ParseJSONValue(AJson);
    except
      Exit;
    end;
    if not (JV is TJSONArray) then Exit;
    JA:= TJSONArray(JV);
    L:= TList<TDocException>.Create;
    try
      for I:= 0 to JA.Count - 1 do
      begin
        if not (JA.Items[I] is TJSONObject) then Continue;
        JO:= TJSONObject(JA.Items[I]);
        FillChar(E, SizeOf(E), 0);
        E.TypeName:= JO.GetValue<string>('type', '');
        E.Desc    := JO.GetValue<string>('desc', '');
        L.Add(E);
      end;
      Result:= L.ToArray;
    finally
      L.Free;
    end;
  finally
    JV.Free;
  end; // try
end; // function

function TDbGraphSource.GetDoc(const AQName: string): TGraphDoc;
var
  Q: TFDQuery;
begin
  FillChar(Result, SizeOf(Result), 0);
  Q:= TFDQuery.Create(nil);
  try
    Q.Connection:= FConn;
    Q.SQL.Text:= 'SELECT d.format, d.summary, d.remarks, d.returns_text, d.example_text,' + '  d.since_text, d.deprecated, d.params_json, d.exceptions_json,' + '  d.seealso_json' +
    ' FROM symbols s' + ' LEFT JOIN symbol_docs d ON d.symbol_id = s.id' + ' WHERE s.qualified_name = :q LIMIT 1';
    Q.ParamByName('q').AsString:= AQName;
    Q.Open;
    if Q.IsEmpty or Q.FieldByName('format').IsNull then
    begin
      Result.HasDoc:= False;
      Exit;
    end;
    Result.HasDoc:= True;
    Result.Format     := Q.FieldByName('format'      ).AsString;
    Result.Summary    := Q.FieldByName('summary'     ).AsString;
    Result.Remarks    := Q.FieldByName('remarks'     ).AsString;
    Result.ReturnsText:= Q.FieldByName('returns_text').AsString;
    Result.ExampleText:= Q.FieldByName('example_text').AsString;
    Result.SinceText  := Q.FieldByName('since_text'  ).AsString;
    Result.Deprecated:= Q.FieldByName('deprecated').AsInteger <> 0;
    Result.Params    := ParseJsonParamArray    ( Q.FieldByName('params_json'    ).AsString);
    Result.Exceptions:= ParseJsonExceptionArray( Q.FieldByName('exceptions_json').AsString);
    Result.SeeAlso   := ParseJsonStringArray   ( Q.FieldByName('seealso_json'   ).AsString);
    Q.Close;
  finally
    Q.Free;
  end; // try
end; // function

function TDbGraphSource.LocateSymbol(const AQName: string; out AFile: string; out ALine: Integer): Boolean;
var
  Q: TFDQuery;
begin
  AFile := '';
  ALine := 0;
  Result:= False;
  Q:= TFDQuery.Create(nil);
  try
    Q.Connection:= FConn;
    Q.SQL.Text:= 'SELECT f.path, s.start_line' + ' FROM symbols s' + ' JOIN files f ON f.id = s.file_id' + ' WHERE s.qualified_name = :q LIMIT 1';
    Q.ParamByName('q').AsString:= AQName;
    Q.Open;
    if not Q.IsEmpty then
    begin
      AFile:= Q.FieldByName('path'      ).AsString;
      ALine:= Q.FieldByName('start_line').AsInteger;
      Result:= True;
    end;
    Q.Close;
  finally
    Q.Free;
  end; // try
end; // function

function TDbGraphSource.ResolveCref(const AText: string): TCrefResolution;
var
  Q     : TFDQuery     ;
  Upper : string       ;
  QNames: TList<string>;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Text:= AText;

  { URL shortcut }
  Upper:= UpperCase(AText);
  if (Copy(Upper, 1, 7) = 'HTTP://') or (Copy(Upper, 1, 8) = 'HTTPS://') then
  begin
    Result.Kind:= crkUrl;
    Result.Url := AText;
    Exit;
  end;

  { Exact qualified_name match }
  Q:= TFDQuery.Create(nil);
  try
    Q.Connection:= FConn;
    Q.SQL.Text:= 'SELECT qualified_name FROM symbols WHERE qualified_name = :q LIMIT 1';
    Q.ParamByName('q').AsString:= AText;
    Q.Open;
    if not Q.IsEmpty then
    begin
      Result.Kind:= crkResolved;
      Result.TargetId:= Q.Fields[0].AsString;
      Result.StoreIndex:= FStoreIndex;
      Q.Close;
      Exit;
    end;
    Q.Close;

    { Bare name match (name column) -- up to 5 candidates }
    QNames:= TList<string>.Create;
    try
      Q.SQL.Text:= 'SELECT qualified_name FROM symbols WHERE name = :n' + ' ORDER BY CASE kind' + '   WHEN ''class'' THEN 0 WHEN ''method'' THEN 1' +
      '   WHEN ''property'' THEN 2 ELSE 3 END,' + '  qualified_name LIMIT 5';
      Q.ParamByName('n').AsString:= AText;
      Q.Open;
      while not Q.Eof do
      begin
        QNames.Add(Q.Fields[0].AsString);
        Q.Next;
      end;
      Q.Close;

      if QNames.Count      = 0 then Result.Kind:= crkUnresolved
      else if QNames.Count = 1 then
      begin
        Result.Kind:= crkResolved;
        Result.TargetId:= QNames[0];
        Result.StoreIndex:= FStoreIndex;
      end
      else
      begin
        Result.Kind:= crkAmbiguous;
        Result.Candidates:= QNames.ToArray;
      end;
    finally
      QNames.Free;
    end; // try
  finally
    Q.Free;
  end; // try
end; // function

{ ---- Task 5: ResolveName (lightweight, no LoadTopology) ---- }

function TDbGraphSource.ResolveName(const AName: string; out AQName: string): Boolean;
var
  Q: TFDQuery;
begin
  AQName:= '';
  Result:= False;

  Q:= TFDQuery.Create(nil);
  try
    Q.Connection:= FConn;

    { 1. Exact qualified_name match }
    Q.SQL.Text:= 'SELECT qualified_name FROM symbols WHERE qualified_name = :q LIMIT 1';
    Q.ParamByName('q').AsString:= AName;
    Q.Open;
    if not Q.IsEmpty then
    begin
      AQName:= Q.Fields[0].AsString;
      Result:= True;
      Q.Close;
      Exit;
    end;
    Q.Close;

    { 2. Bare name match (kind-priority order, same as ResolveCref) }
    Q.SQL.Text:= 'SELECT qualified_name FROM symbols WHERE name = :n' + ' ORDER BY CASE kind' + '   WHEN ''class'' THEN 0 WHEN ''method'' THEN 1' +
    '   WHEN ''property'' THEN 2 ELSE 3 END,' + '  qualified_name LIMIT 1';
    Q.ParamByName('n').AsString:= AName;
    Q.Open;
    if not Q.IsEmpty then
    begin
      AQName:= Q.Fields[0].AsString;
      Result:= True;
    end;
    Q.Close;
  finally
    Q.Free;
  end; // try
end; // function

{ ---- Task 1 (flow): GetCallees + GetSymbolMeta ---- }

function TDbGraphSource.GetCallees(const AQName: string): TArray<TCallRef>;
var
  Q   : TFDQuery       ;
  List: TList<TCallRef>;
  R   : TCallRef       ;
begin
  List:= TList<TCallRef>.Create;
  try
    Q:= TFDQuery.Create(nil);
    try
      Q.Connection:= FConn;
      Q.SQL.Text:= 'SELECT r.start_line AS cl, r.name_text AS nm, t.qualified_name AS tq ' + 'FROM refs r ' + 'JOIN symbols src ON src.qualified_name = :q ' +
      'LEFT JOIN symbols t ON t.id = r.symbol_id ' + 'WHERE r.kind = ''call'' ' + '  AND r.file_id = src.file_id ' + '  AND r.start_line BETWEEN src.start_line AND src.end_line ' +
      '  AND NOT EXISTS (' + '    SELECT 1 FROM symbols ins ' + '    WHERE ins.file_id = src.file_id ' + '      AND ins.start_line > src.start_line ' +
      '      AND ins.start_line <= r.start_line ' + '      AND ins.end_line   >= r.start_line) ' + 'ORDER BY r.start_line';
      Q.ParamByName('q').AsString:= AQName;
      Q.Open;
      while not Q.Eof do
      begin
        R.CallLine   := Q.FieldByName('cl').AsInteger;
        R.RawName    := Q.FieldByName('nm').AsString;
        R.TargetQName:= Q.FieldByName('tq').AsString;
        List.Add(R);
        Q.Next;
      end;
      Q.Close;
    finally
      Q.Free;
    end; // try
    Result:= List.ToArray;
  finally
    List.Free;
  end; // try
end; // function

function TDbGraphSource.GetSymbolMeta(const AQName: string; out ASignature, AModifiers, AKindText: string): Boolean;
var
  Q: TFDQuery;
begin
  ASignature:= '';
  AModifiers:= '';
  AKindText := '';
  Result    := False;
  Q:= TFDQuery.Create(nil);
  try
    Q.Connection:= FConn;
    Q.SQL.Text:= 'SELECT signature, modifiers, kind FROM symbols ' + 'WHERE qualified_name = :q LIMIT 1';
    Q.ParamByName('q').AsString:= AQName;
    Q.Open;
    if not Q.IsEmpty then
    begin
      ASignature:= Q.FieldByName('signature').AsString;
      AModifiers:= Q.FieldByName('modifiers').AsString;
      AKindText := Q.FieldByName('kind'     ).AsString;
      Result:= True;
    end;
    Q.Close;
  finally
    Q.Free;
  end; // try
end; // function

{ ---- TDbCatalog ---- }

constructor TDbCatalog.Create(const APaths: TArray<string>);
var
  I: Integer;
begin
  inherited Create;
  FPaths:= APaths;
  SetLength(FSources, Length(APaths));
  for I:= 0 to High(FSources) do FSources[I]:= nil;
end;

function TDbCatalog.StoreCount: Integer;
begin
  Result:= Length(FPaths);
end;

function TDbCatalog.StorePath(AIndex: Integer): string;
begin
  Result:= FPaths[AIndex];
end;

function TDbCatalog.SourceForStore(AIndex: Integer): IGraphSource;
begin
  if FSources[AIndex] = nil then FSources[AIndex]:= TDbGraphSource.Create(FPaths[AIndex], AIndex);
  Result:= FSources[AIndex];
end;

function TDbCatalog.ResolveAcrossStores( const AName: string): TCrossDbResolution;
var
  I  : Integer     ;
  Src: IGraphSource;
  QN : string      ;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Found:= False;
  for I:= 0 to StoreCount - 1 do
  begin
    Src:= SourceForStore(I);
    if Src.ResolveName(AName, QN) then
    begin
      Result.Found     := True;
      Result.StoreIndex:= I;
      Result.TargetId  := QN;
      Exit;
    end;
  end;
end;

{ ---- SQLite global URI filename enable ---- }
{ SQLITE_CONFIG_URI (17): when non-zero, all sqlite3_open* calls treat
  filenames that start with "file:" as URI filenames, enabling query
  parameters such as ?immutable=1 even without the SQLITE_OPEN_URI flag.
  Must be called before sqlite3_initialize().  FireDAC loads sqlite3.dll
  lazily (on first connection); our initialization section runs before any
  connection is made, so sqlite3_initialize has not yet been called.
  IMPORTANT: we load sqlite3.dll but do NOT call FreeLibrary.  Calling
  FreeLibrary would drop the refcount to 0 and unload the DLL, losing the
  global SQLITE_CONFIG_URI setting.  By keeping a module reference alive,
  the setting persists when FireDAC later loads the same DLL (Windows
  returns the same module handle and increments the refcount). }
var
  GUriEnabled: Boolean = False;
  { True when sqlite3_config(SQLITE_CONFIG_URI,1) returned SQLITE_OK(0).
    If False, URI filenames are NOT active and a file:/// open will fail
    with SQLITE_CANTOPEN -- it does NOT silently degrade. }

type
  Tsqlite3_config_vararg = function(op: Integer): Integer; cdecl varargs;

procedure EnableSQLiteUriFilenames;
var
  hLib: HMODULE               ;
  fn  : Tsqlite3_config_vararg;
  rc  : Integer               ;
const
  SQLITE_CONFIG_URI_CONST = 17;
begin
  hLib:= LoadLibrary('sqlite3.dll');
  if hLib = 0 then Exit;
  { hLib intentionally not freed -- keeps the DLL loaded so the config
    state is not lost when this routine returns. }
  fn:= Tsqlite3_config_vararg(GetProcAddress(hLib, 'sqlite3_config'));
  if Assigned(fn) then
  begin
    rc:= fn(SQLITE_CONFIG_URI_CONST, Integer(1));
    GUriEnabled:= (rc = 0);
    if not GUriEnabled then OutputDebugString(
      PChar('DragLint.Graph.Source.Db: sqlite3_config(SQLITE_CONFIG_URI,1)' + ' returned ' + IntToStr(rc) + ' -- URI filenames NOT enabled; file:/// opens will fail'));
  end;
end;

initialization
EnableSQLiteUriFilenames;

end.
