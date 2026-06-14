unit DragLint.Graph.Flow;

{ Pure call-tree engine. Builds a TFlowTree (flat, parent-before-children)
  from a starting symbol by repeatedly asking an IFlowSource for callees.
  No VCL, no DB -- the DB-backed IFlowSource lives in
  DragLint.Graph.Flow.Source.Db. This engine is reused unchanged by the
  later Protocol Walkthrough (C); only the renderer differs.

  ASCII / CRLF per the project rule. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  DragLint.Graph.Types;

type
  /// <summary>One direct callee of a symbol (input to the builder).</summary>
  TFlowCallee = record
    SymbolId: string;   { resolved qualified name; '' => unresolved/external }
    CallLine: Integer;  { first call-site line in the parent body }
    RawName:  string;   { name as written (label when SymbolId='') }
  end;

  /// <summary>Per-symbol info for a flow box (signature + doc).</summary>
  TFlowInfo = record
    Found:     Boolean;
    Signature: string;
    KindText:  string;
    Doc:       TGraphDoc;   { Doc.HasDoc=False => undocumented }
  end;

  /// <summary>Data gateway for the flow builder. Faked in tests;
  ///  DB-backed in DragLint.Graph.Flow.Source.Db.</summary>
  IFlowSource = interface
    ['{B1C2D3E4-F5A6-47B8-9C0D-1E2F3A4B5C6D}']
    function GetCallees(const ASymbolId: string): TArray<TFlowCallee>;
    function GetInfo(const ASymbolId: string): TFlowInfo;
  end;

  /// <summary>One node in the rendered flow tree.</summary>
  TFlowStep = record
    SymbolId:    string;
    Depth:       Integer;       { 0 = root }
    CallLine:    Integer;       { call-site line in the parent ( -1 for root) }
    Signature:   string;        { always populated when the symbol resolves }
    KindText:    string;
    Doc:         TGraphDoc;
    IsRecursion: Boolean;       { symbol reappears on its ancestor path }
    IsExternal:  Boolean;       { unresolved callee (no SymbolId) }
    RawName:     string;        { display name for external steps }
    TruncatedChildren: Integer; { >0 => "... N more" beyond a cap / depth }
    ChildIndices: TArray<Integer>;
  end;

  /// <summary>Flat call tree, parent-before-children. Steps[0] is the root.</summary>
  TFlowTree = record
    RootId: string;
    Steps:  TArray<TFlowStep>;
  end;

  /// <summary>Builds a TFlowTree from a root symbol, applying depth/breadth
  ///  caps, duplicate-callee collapse, and recursion detection.</summary>
  TFlowBuilder = class
  strict private
    FSource:     IFlowSource;
    FMaxDepth:   Integer;
    FMaxBreadth: Integer;
    FSteps:      TList<TFlowStep>;
    function DedupOrder(const ACallees: TArray<TFlowCallee>): TArray<TFlowCallee>;
    function AddExternal(const ACallee: TFlowCallee; ADepth: Integer): Integer;
    function AddStep(const AId: string; ADepth, ACallLine: Integer;
      const AAncestors: TArray<string>): Integer;
  public
    constructor Create(const ASource: IFlowSource;
      AMaxDepth: Integer = 6; AMaxBreadth: Integer = 12);
    function Build(const ARootId: string): TFlowTree;
  end;

implementation

constructor TFlowBuilder.Create(const ASource: IFlowSource;
  AMaxDepth, AMaxBreadth: Integer);
begin
  inherited Create;
  FSource     := ASource;
  FMaxDepth   := AMaxDepth;
  FMaxBreadth := AMaxBreadth;
end;

function TFlowBuilder.DedupOrder(
  const ACallees: TArray<TFlowCallee>): TArray<TFlowCallee>;
var
  Seen: TDictionary<string, Boolean>;
  C: TFlowCallee;
  Res: TList<TFlowCallee>;
  Key: string;
begin
  { Input is already ordered by call line (DB source / fakes guarantee it).
    Keep the first occurrence of each distinct target; external ('') entries
    are keyed by RawName so two different unresolved names both survive. }
  Seen := TDictionary<string, Boolean>.Create;
  Res  := TList<TFlowCallee>.Create;
  try
    for C in ACallees do
    begin
      if C.SymbolId <> '' then Key := 's:' + C.SymbolId
                          else Key := 'x:' + C.RawName;
      if not Seen.ContainsKey(Key) then
      begin
        Seen.Add(Key, True);
        Res.Add(C);
      end;
    end;
    Result := Res.ToArray;
  finally
    Res.Free;
    Seen.Free;
  end;
end;

function TFlowBuilder.AddExternal(const ACallee: TFlowCallee;
  ADepth: Integer): Integer;
var
  X: TFlowStep;
begin
  FillChar(X, SizeOf(X), 0);
  X.Depth      := ADepth;
  X.CallLine   := ACallee.CallLine;
  X.IsExternal := True;
  X.RawName    := ACallee.RawName;
  Result := FSteps.Add(X);
end;

function TFlowBuilder.AddStep(const AId: string; ADepth, ACallLine: Integer;
  const AAncestors: TArray<string>): Integer;
var
  Step: TFlowStep;
  Info: TFlowInfo;
  Callees: TArray<TFlowCallee>;
  Anc: TArray<string>;
  Kids: TList<Integer>;
  I, Take: Integer;
  A: string;
  OnPath: Boolean;
begin
  Info := FSource.GetInfo(AId);

  FillChar(Step, SizeOf(Step), 0);
  Step.SymbolId  := AId;
  Step.Depth     := ADepth;
  Step.CallLine  := ACallLine;
  Step.Signature := Info.Signature;
  Step.KindText  := Info.KindText;
  Step.Doc       := Info.Doc;

  { Recursion guard: is AId already on the ancestor path? }
  OnPath := False;
  for A in AAncestors do
    if A = AId then begin OnPath := True; Break; end;

  if OnPath then
  begin
    Step.IsRecursion := True;
    Result := FSteps.Add(Step);
    Exit;
  end;

  Result := FSteps.Add(Step);   { reserve our slot before recursing }

  Callees := DedupOrder(FSource.GetCallees(AId));

  { Depth cap: at the deepest allowed level, do not expand; record the count. }
  if ADepth >= FMaxDepth then
  begin
    Step.TruncatedChildren := Length(Callees);
    FSteps[Result] := Step;     { write back scalar change }
    Exit;
  end;

  { Breadth cap. }
  Take := Length(Callees);
  if Take > FMaxBreadth then Take := FMaxBreadth;

  SetLength(Anc, Length(AAncestors) + 1);
  for I := 0 to High(AAncestors) do Anc[I] := AAncestors[I];
  Anc[High(Anc)] := AId;

  Kids := TList<Integer>.Create;
  try
    for I := 0 to Take - 1 do
    begin
      if Callees[I].SymbolId = '' then
        Kids.Add(AddExternal(Callees[I], ADepth + 1))
      else
        Kids.Add(AddStep(Callees[I].SymbolId, ADepth + 1,
                         Callees[I].CallLine, Anc));
    end;
    Step.ChildIndices := Kids.ToArray;
  finally
    Kids.Free;
  end;

  if Length(Callees) > Take then
    Step.TruncatedChildren := Length(Callees) - Take;

  FSteps[Result] := Step;       { write back children + truncation }
end;

function TFlowBuilder.Build(const ARootId: string): TFlowTree;
begin
  FSteps := TList<TFlowStep>.Create;
  try
    AddStep(ARootId, 0, -1, nil);   { nil = empty ancestor path }
    Result.RootId := ARootId;
    Result.Steps  := FSteps.ToArray;
  finally
    FreeAndNil(FSteps);
  end;
end;

end.
