unit DragLint.Graph.Flow.Source.Db;

{ IFlowSource backed by the existing IDbCatalog. GetCallees resolves the
  caller in the first store that knows it, then maps each TCallRef to a
  TFlowCallee, marking cross-store / unresolved targets. GetInfo composes
  GetSymbolMeta + GetDoc from the owning store.

  ASCII / CRLF per the project rule. }

interface

uses
  System.SysUtils,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  DragLint.Graph.Flow;

type
  /// <summary>IFlowSource that pulls callees and per-symbol info from an
  ///  IDbCatalog (first store that declares the symbol wins).</summary>
  TDbFlowSource = class(TInterfacedObject, IFlowSource)
  strict private
    FCatalog: IDbCatalog;
    function StoreThatHas(const AQName: string;
      out ASrc: IGraphSource): Boolean;
  public
    constructor Create(const ACatalog: IDbCatalog);
    function GetCallees(const ASymbolId: string): TArray<TFlowCallee>;
    function GetInfo(const ASymbolId: string): TFlowInfo;
  end;

implementation

constructor TDbFlowSource.Create(const ACatalog: IDbCatalog);
begin
  inherited Create;
  FCatalog := ACatalog;
end;

function TDbFlowSource.StoreThatHas(const AQName: string;
  out ASrc: IGraphSource): Boolean;
var
  I: Integer;
  Sig, Mods, KindText: string;
begin
  { First store whose symbols table contains AQName (priority order). }
  for I := 0 to FCatalog.StoreCount - 1 do
  begin
    ASrc := FCatalog.SourceForStore(I);
    if (ASrc <> nil) and ASrc.GetSymbolMeta(AQName, Sig, Mods, KindText) then
      Exit(True);
  end;
  ASrc := nil;
  Result := False;
end;

function TDbFlowSource.GetCallees(const ASymbolId: string): TArray<TFlowCallee>;
var
  Src: IGraphSource;
  Raw: TArray<TCallRef>;
  Res: TArray<TFlowCallee>;
  I: Integer;
begin
  if not StoreThatHas(ASymbolId, Src) then Exit(nil);
  Raw := Src.GetCallees(ASymbolId);
  SetLength(Res, Length(Raw));
  for I := 0 to High(Raw) do
  begin
    Res[I].CallLine := Raw[I].CallLine;
    Res[I].RawName  := Raw[I].RawName;
    Res[I].SymbolId := Raw[I].TargetQName;  { '' stays '' -> external in engine }
  end;
  Result := Res;
end;

function TDbFlowSource.GetInfo(const ASymbolId: string): TFlowInfo;
var
  Src: IGraphSource;
  Sig, Mods, KindText: string;
begin
  Result := Default(TFlowInfo);
  if not StoreThatHas(ASymbolId, Src) then Exit;
  if Src.GetSymbolMeta(ASymbolId, Sig, Mods, KindText) then
  begin
    Result.Found     := True;
    Result.Signature := Sig;
    Result.KindText  := KindText;
    Result.Doc       := Src.GetDoc(ASymbolId);
  end;
end;

end.
