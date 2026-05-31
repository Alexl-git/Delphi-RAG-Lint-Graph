unit DragLint.Graph.Json;

(* Load TGraphData from a JSON string with this shape:

     "nodes" array of objects with keys
        id, label, kind, file, line, col, layer
     "edges" array of objects with keys
        src (or "source"), dst (or "target"), kind, label, weight

   This is the contract drag-lint's future graph --format json command
   will emit. Loader is forgiving: missing fields default to neutral values.
   See tests/fixtures/sample-graph.json for a concrete example. *)

interface

uses
  System.SysUtils, System.JSON, System.IOUtils,
  DragLint.Graph.Types;

function LoadGraphFromJsonString(const AJson: string; AData: TGraphData): Boolean;
function LoadGraphFromFile(const APath: string; AData: TGraphData): Boolean;

implementation

function ParseNodeKind(const S: string): TGraphNodeKind;
begin
  if      SameText(S, 'unit')      then Result := nkUnit
  else if SameText(S, 'type')      then Result := nkType
  else if SameText(S, 'class')     then Result := nkClass
  else if SameText(S, 'interface') then Result := nkInterface
  else if SameText(S, 'record')    then Result := nkRecord
  else if SameText(S, 'procedure') then Result := nkProcedure
  else if SameText(S, 'function')  then Result := nkFunction
  else if SameText(S, 'method')    then Result := nkMethod
  else if SameText(S, 'field')     then Result := nkField
  else if SameText(S, 'property')  then Result := nkProperty
  else if SameText(S, 'const')     then Result := nkConst
  else if SameText(S, 'var')       then Result := nkVar
  else if SameText(S, 'dfm')       then Result := nkDfmForm
  else if SameText(S, 'dfm_form')  then Result := nkDfmForm
  else                                   Result := nkOther;
end;

function ParseEdgeKind(const S: string): TGraphEdgeKind;
begin
  if      SameText(S, 'calls')      then Result := ekCalls
  else if SameText(S, 'uses')       then Result := ekUses
  else if SameText(S, 'inherits')   then Result := ekInherits
  else if SameText(S, 'implements') then Result := ekImplements
  else if SameText(S, 'contains')   then Result := ekContains
  else if SameText(S, 'dfm_binds')  then Result := ekDfmBinds
  else                                   Result := ekOther;
end;

function LoadGraphFromJsonString(const AJson: string; AData: TGraphData): Boolean;
var
  Root:  TJSONObject;
  Arr:   TJSONArray;
  Obj:   TJSONObject;
  I:     Integer;
  N:     TGraphNode;
  E:     TGraphEdge;
  S:     string;
  Iv:    Integer;
  Dv:    Double;
  V:     TJSONValue;
begin
  Result := False;
  if AData = nil then Exit;
  V := TJSONObject.ParseJSONValue(AJson);
  if not (V is TJSONObject) then
  begin
    V.Free;
    Exit;
  end;
  Root := TJSONObject(V);
  try
    AData.Clear;

    if Root.TryGetValue<TJSONArray>('nodes', Arr) then
    begin
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr.Items[I] is TJSONObject) then Continue;
        Obj := TJSONObject(Arr.Items[I]);
        FillChar(N, SizeOf(N), 0);
        N.Id       := '';
        N.Label_   := '';
        N.Kind     := nkOther;
        N.FilePath := '';
        N.Line     := 0;
        N.Col      := 0;
        N.Layer    := '';
        N.Radius   := 12;
        if Obj.TryGetValue<string>('id',    S)  then N.Id       := S;
        if Obj.TryGetValue<string>('label', S)  then N.Label_   := S;
        if Obj.TryGetValue<string>('kind',  S)  then N.Kind     := ParseNodeKind(S);
        if Obj.TryGetValue<string>('file',  S)  then N.FilePath := S;
        if Obj.TryGetValue<Integer>('line', Iv) then N.Line     := Iv;
        if Obj.TryGetValue<Integer>('col',  Iv) then N.Col      := Iv;
        if Obj.TryGetValue<string>('layer', S)  then N.Layer    := S;
        if N.Id = '' then Continue;
        if N.Label_ = '' then N.Label_ := N.Id;
        AData.AddNode(N);
      end;
    end;

    if Root.TryGetValue<TJSONArray>('edges', Arr) then
    begin
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr.Items[I] is TJSONObject) then Continue;
        Obj := TJSONObject(Arr.Items[I]);
        FillChar(E, SizeOf(E), 0);
        E.SourceId := '';
        E.TargetId := '';
        E.Kind     := ekOther;
        E.Weight   := 1.0;
        if Obj.TryGetValue<string>('src',    S)  then E.SourceId := S;
        if Obj.TryGetValue<string>('source', S)  then E.SourceId := S;
        if Obj.TryGetValue<string>('dst',    S)  then E.TargetId := S;
        if Obj.TryGetValue<string>('target', S)  then E.TargetId := S;
        if Obj.TryGetValue<string>('kind',   S)  then E.Kind     := ParseEdgeKind(S);
        if Obj.TryGetValue<string>('label',  S)  then E.Label_   := S;
        if Obj.TryGetValue<Double>('weight', Dv) then E.Weight   := Dv;
        if (E.SourceId = '') or (E.TargetId = '') then Continue;
        AData.AddEdge(E);
      end;
    end;

    Result := True;
  finally
    Root.Free;
  end;
end;

function LoadGraphFromFile(const APath: string; AData: TGraphData): Boolean;
var
  S: string;
begin
  if not TFile.Exists(APath) then Exit(False);
  S := TFile.ReadAllText(APath, TEncoding.UTF8);
  Result := LoadGraphFromJsonString(S, AData);
end;

end.
