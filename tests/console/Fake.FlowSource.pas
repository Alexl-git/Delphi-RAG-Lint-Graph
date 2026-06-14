unit Fake.FlowSource;

{ Configurable in-memory IFlowSource for engine tests. Add callees and infos
  by qname; GetCallees returns them in insertion order (tests insert in the
  order they want, mimicking call-line order). }

interface

uses
  System.SysUtils, System.Generics.Collections,
  DragLint.Graph.Types, DragLint.Graph.Flow;

type
  TFakeFlowSource = class(TInterfacedObject, IFlowSource)
  strict private
    FCallees: TDictionary<string, TList<TFlowCallee>>;
    FInfos:   TDictionary<string, TFlowInfo>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddInfo(const AId, ASig: string; ADocumented: Boolean;
      const ASummary: string = '');
    procedure AddCall(const AFrom, AToId: string; ALine: Integer;
      const ARaw: string = '');
    function GetCallees(const ASymbolId: string): TArray<TFlowCallee>;
    function GetInfo(const ASymbolId: string): TFlowInfo;
  end;

implementation

constructor TFakeFlowSource.Create;
begin
  inherited;
  FCallees := TObjectDictionary<string, TList<TFlowCallee>>.Create([doOwnsValues]);
  FInfos   := TDictionary<string, TFlowInfo>.Create;
end;

destructor TFakeFlowSource.Destroy;
begin
  FInfos.Free;
  FCallees.Free;
  inherited;
end;

procedure TFakeFlowSource.AddInfo(const AId, ASig: string; ADocumented: Boolean;
  const ASummary: string);
var
  Info: TFlowInfo;
begin
  FillChar(Info, SizeOf(Info), 0);
  Info.Found     := True;
  Info.Signature := ASig;
  Info.KindText  := 'method';
  Info.Doc.HasDoc := ADocumented;
  if ADocumented then
  begin
    Info.Doc.Format  := 'xmldoc';
    Info.Doc.Summary := ASummary;
  end;
  FInfos.AddOrSetValue(AId, Info);
end;

procedure TFakeFlowSource.AddCall(const AFrom, AToId: string; ALine: Integer;
  const ARaw: string);
var
  L: TList<TFlowCallee>;
  C: TFlowCallee;
begin
  if not FCallees.TryGetValue(AFrom, L) then
  begin
    L := TList<TFlowCallee>.Create;
    FCallees.Add(AFrom, L);
  end;
  C.SymbolId := AToId;
  C.CallLine := ALine;
  if ARaw <> '' then C.RawName := ARaw else C.RawName := AToId;
  L.Add(C);
end;

function TFakeFlowSource.GetCallees(const ASymbolId: string): TArray<TFlowCallee>;
var
  L: TList<TFlowCallee>;
begin
  if FCallees.TryGetValue(ASymbolId, L) then Result := L.ToArray
                                        else Result := nil;
end;

function TFakeFlowSource.GetInfo(const ASymbolId: string): TFlowInfo;
begin
  if not FInfos.TryGetValue(ASymbolId, Result) then
    Result := Default(TFlowInfo);   { managed record -- never FillChar }
end;

end.
