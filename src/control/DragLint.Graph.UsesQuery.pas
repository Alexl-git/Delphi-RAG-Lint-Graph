unit DragLint.Graph.UsesQuery;

{ Reads the unit_uses table (v0.40.4+) directly for the structure panel's
  "Uses (interface) / Uses (implementation) / Used by" sections.

  This data is exact -- the scanner records every uses-clause entry with its
  section and a resolved target_file_id -- but it is NOT carried in the
  in-memory graph model (which is symbol/ref-centric).  Rather than widen the
  model/VM interfaces, this helper opens its own short-lived read-only +
  immutable SQLite connection (the same way DragLint.Graph.Source.Db does, and
  relying on that unit's process-wide SQLITE_CONFIG_URI init) and runs three
  small indexed queries.  Called only on structure-tree expansion, so the
  open/query/close cost is negligible.

  Only this unit (besides Source.Db) links FireDAC on the viewer side. }

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TUnitUseRow = record
    UnitName: string;    { as written, e.g. 'System.SysUtils' }
    External: Boolean;   { True if target_file_id is NULL (not in this store) }
  end;

{ For the unit whose qualified name is AUnitName, returns its interface-uses,
  implementation-uses, and the units that use it (dependents).  Returns False
  (and empty arrays) if the DB can't be opened or the unit isn't found.
  Never raises. }
function QueryUnitUses(const ADbPath, AUnitName: string;
  out AIntfUses, AImplUses: TArray<TUnitUseRow>;
  out AUsedBy: TArray<string>): Boolean;

implementation

uses
  Data.DB,
  FireDAC.Comp.Client,
  FireDAC.Stan.Def,
  FireDAC.Phys.SQLite,
  FireDAC.Stan.Param,
  FireDAC.DApt;

function OpenImmutable(const ADbPath: string): TFDConnection;
begin
  Result := TFDConnection.Create(nil);
  Result.DriverName := 'SQLite';
  Result.Params.Values['OpenMode']    := 'ReadOnly';
  Result.Params.Values['LockingMode'] := 'Normal';
  Result.LoginPrompt := False;
  Result.Params.Values['Database'] :=
    'file:///'
    + StringReplace(
        StringReplace(
          StringReplace(
            StringReplace(ADbPath, '\', '/', [rfReplaceAll]),
          ' ', '%20', [rfReplaceAll]),
        '#', '%23', [rfReplaceAll]),
      '?', '%3F', [rfReplaceAll])
    + '?immutable=1';
  Result.Connected := True;
end;

function QueryUnitUses(const ADbPath, AUnitName: string;
  out AIntfUses, AImplUses: TArray<TUnitUseRow>;
  out AUsedBy: TArray<string>): Boolean;
var
  Conn: TFDConnection;
  Q:    TFDQuery;
  FileId: Int64;
  Intf, Impl: TList<TUnitUseRow>;
  UsedBy: TList<string>;
  Row: TUnitUseRow;

  procedure CollectUses(const ASection: string; ADest: TList<TUnitUseRow>);
  begin
    Q.Close;
    Q.SQL.Text :=
      'SELECT unit_name, target_file_id FROM unit_uses ' +
      ' WHERE file_id = :fid AND section = :sec ORDER BY unit_name';
    Q.ParamByName('fid').AsLargeInt := FileId;
    Q.ParamByName('sec').AsString   := ASection;
    Q.Open;
    while not Q.Eof do
    begin
      Row.UnitName := Q.FieldByName('unit_name').AsString;
      Row.External := Q.FieldByName('target_file_id').IsNull;
      ADest.Add(Row);
      Q.Next;
    end;
  end;

begin
  Result := False;
  SetLength(AIntfUses, 0); SetLength(AImplUses, 0); SetLength(AUsedBy, 0);
  Conn := nil;
  Q := nil;
  Intf := TList<TUnitUseRow>.Create;
  Impl := TList<TUnitUseRow>.Create;
  UsedBy := TList<string>.Create;
  try
    try
      Conn := OpenImmutable(ADbPath);
      Q := TFDQuery.Create(nil);
      Q.Connection := Conn;

      { resolve the unit's file_id from its unit symbol }
      Q.SQL.Text :=
        'SELECT file_id FROM symbols ' +
        ' WHERE kind = ''unit'' AND qualified_name = :u LIMIT 1';
      Q.ParamByName('u').AsString := AUnitName;
      Q.Open;
      if Q.IsEmpty then Exit;
      FileId := Q.Fields[0].AsLargeInt;

      CollectUses('interface', Intf);
      CollectUses('implementation', Impl);

      { dependents: units whose uses-clause resolved to this file }
      Q.Close;
      Q.SQL.Text :=
        'SELECT DISTINCT s.qualified_name FROM unit_uses uu ' +
        ' JOIN symbols s ON s.file_id = uu.file_id AND s.kind = ''unit'' ' +
        ' WHERE uu.target_file_id = :fid ORDER BY s.qualified_name';
      Q.ParamByName('fid').AsLargeInt := FileId;
      Q.Open;
      while not Q.Eof do
      begin
        UsedBy.Add(Q.Fields[0].AsString);
        Q.Next;
      end;

      AIntfUses := Intf.ToArray;
      AImplUses := Impl.ToArray;
      AUsedBy   := UsedBy.ToArray;
      Result := True;
    except
      { swallow -- a missing table / locked DB just yields no uses info }
      Result := False;
    end;
  finally
    Q.Free;
    if Conn <> nil then
    begin
      if Conn.Connected then Conn.Close;
      Conn.Free;
    end;
    Intf.Free; Impl.Free; UsedBy.Free;
  end;
end;

end.
