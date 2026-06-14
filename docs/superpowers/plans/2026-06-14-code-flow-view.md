# Code Flow View (B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Flow mode" to the graph viewer that, from a selected symbol, builds a static call tree (callees, source-ordered) and renders it as a vertical flowchart of DocInsight-annotated boxes, with Brief/Expanded detail modes plus a per-box override; undocumented symbols still show name + parameters.

**Architecture:** A pure call-tree **engine** (`TFlowBuilder` + `IFlowSource`) is the reusable core (the later Protocol Walkthrough C reuses it verbatim). A DB-backed `IFlowSource` composes the existing `IDbCatalog`, which gains two query primitives on `IGraphSource` (`GetCallees`, `GetSymbolMeta`). A `TFlowViewModel` holds interaction state. A `TFlowChartControl` (a `TScrollBox` host with an inner paint surface) renders boxes + connectors and hit-tests clicks. `MainForm` adds the toggle, context-menu entry, and pane swap.

**Tech Stack:** Delphi 13 (RAD Studio 37.0), VCL, FireDAC/SQLite (read-only immutable), the existing console test framework (`DragLint.Graph.TestFramework`). All `.pas` files: strict 7-bit ASCII, CRLF.

---

## Conventions for every task

- **Build + run the console suite:** `powershell -ExecutionPolicy Bypass -File tests\console\run.ps1`
  - Exit `0` = all green; `2` = compile failure; `N` = N failed tests.
  - `run.ps1` compiles every `.pas` under `src\control` and `tests\console`, so new units in those folders are picked up automatically **once added to the `.dpr` uses clause**.
- **Build the viewer (UI tasks):** `cmd.exe /c build\build_viewer.bat` (msbuild of `src\viewer\drag_lint_graph.dproj`). New UI units must be added to that `.dproj`'s source list (open the `.dproj`, or add via the IDE) — Task 5/6 spell this out.
- **ASCII/CRLF guard:** new/edited `.pas` files must stay 7-bit ASCII + CRLF. Before each commit run `powershell -ExecutionPolicy Bypass -File tools\normalize_ascii_crlf.ps1` if available; never paste Unicode (use `->`, not arrows; `...`, not ellipsis char).
- **Commit style:** end the message body with the project's `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
- **DocInsight rule:** every new unit's public types/methods get `///` XML doc-comments (summary at minimum). This is the standard in `C:\Projects\CLAUDE.md` and the feature that rewards it.

## File structure (created / modified)

- **Modify** `src/control/DragLint.Graph.Types.pas` — add `TCallRef` record.
- **Modify** `src/control/DragLint.Graph.Source.pas` — add `GetCallees`, `GetSymbolMeta` to `IGraphSource`.
- **Modify** `src/control/DragLint.Graph.Source.Db.pas` — implement both in `TDbGraphSource`.
- **Modify** `tests/console/Fake.GraphSource.pas` — trivial impls in `TFakeGraphSource`, `TPreloadedSource`.
- **Modify** `tests/console/Fake.DbCatalog.pas` — trivial impl in `TStoreSource`.
- **Create** `src/control/DragLint.Graph.Flow.pas` — engine: `TFlowStep`, `TFlowTree`, `TFlowCallee`, `IFlowSource`, `TFlowBuilder`.
- **Create** `src/control/DragLint.Graph.Flow.Source.Db.pas` — `TDbFlowSource` (implements `IFlowSource` over `IDbCatalog`).
- **Create** `src/control/DragLint.Graph.Flow.ViewModel.pas` — `TFlowViewModel`.
- **Create** `src/control/DragLint.Graph.FlowControl.pas` — `TFlowChartControl` (VCL).
- **Modify** `src/viewer/MainForm.pas` — toggle + context menu + pane swap + selection sync.
- **Create tests** `tests/console/Test.Graph.Flow.pas`, `tests/console/Fake.FlowSource.pas`, `tests/console/Test.Graph.Flow.ViewModel.pas`.
- **Modify** `tests/console/drag_lint_graph_tests.dpr` and `src/viewer/drag_lint_graph.dproj` — register new units.

---

## Task 1: `IGraphSource` callee + symbol-meta primitives

**Files:**
- Modify: `src/control/DragLint.Graph.Types.pas`
- Modify: `src/control/DragLint.Graph.Source.pas`
- Modify: `src/control/DragLint.Graph.Source.Db.pas`
- Modify: `tests/console/Fake.GraphSource.pas`, `tests/console/Fake.DbCatalog.pas`
- Test: `tests/console/Test.Graph.Source.Db.pas`

- [ ] **Step 1: Add `TCallRef` to Types**

In `src/control/DragLint.Graph.Types.pas`, after the `TGraphEdge` record (around line 93), add:

```pascal
  { One outgoing call from a symbol body to a callee. Returned by
    IGraphSource.GetCallees; the flow engine maps it to a TFlowCallee. }
  TCallRef = record
    TargetQName: string;   { resolved callee qualified_name ('' if unresolved) }
    RawName:     string;   { refs.name_text as written (label for unresolved) }
    CallLine:    Integer;  { refs.start_line -- call-site line in the caller }
  end;
```

- [ ] **Step 2: Extend the `IGraphSource` interface**

In `src/control/DragLint.Graph.Source.pas`, inside `IGraphSource` (after `ResolveName`, before `end;`), add:

```pascal
    { Direct callees of ASymbolId, ordered by call-site line. Only refs whose
      innermost enclosing symbol IS ASymbolId are returned (nested symbols are
      not double-counted). Unresolved calls have TargetQName=''. May contain
      duplicate targets (caller de-duplicates). Single indexed query. }
    function GetCallees(const AQName: string): TArray<TCallRef>;
    { Signature + modifiers + raw kind text for one symbol. False if absent.
      Used by the flow engine for the box header / degradation path. }
    function GetSymbolMeta(const AQName: string;
      out ASignature, AModifiers, AKindText: string): Boolean;
```

Add `System.Types` is not needed; `TArray<TCallRef>` only needs `DragLint.Graph.Types`, already in `uses`.

- [ ] **Step 3: Write the failing tests (DB source)**

In `tests/console/Test.Graph.Source.Db.pas`, add two procedures before the `initialization` block:

```pascal
{ ---- Task 1 (flow): GetCallees + GetSymbolMeta ---- }

procedure Test_DbSource_GetCallees;
var
  DbPath: string;
  Src:    IGraphSource;
  Calls:  TArray<TCallRef>;
begin
  DbPath := CreateTempV6Db;
  try
    Src := TDbGraphSource.Create(DbPath, 0);

    { Bar (lines 10..15) has one 'call' ref at line 12 -> U.TBaz.MB.
      The line-13 ref is 'type_use', NOT a call, so it must be excluded. }
    Calls := Src.GetCallees('U.TFoo.Bar');
    CheckEqualsInt(1, Length(Calls), 'GetCallees(Bar): exactly one call');
    if Length(Calls) >= 1 then
    begin
      CheckEqualsStr('U.TBaz.MB', Calls[0].TargetQName,
        'GetCallees(Bar)[0].TargetQName = U.TBaz.MB');
      CheckEqualsInt(12, Calls[0].CallLine,
        'GetCallees(Bar)[0].CallLine = 12');
    end;

    { MB makes no calls. }
    Calls := Src.GetCallees('U.TBaz.MB');
    CheckEqualsInt(0, Length(Calls), 'GetCallees(MB): no calls');

    Src := nil;
  finally
    DeleteTempDb(DbPath);
  end;
end;

procedure Test_DbSource_GetSymbolMeta;
var
  DbPath: string;
  Src:    IGraphSource;
  Sig, Mods, KindText: string;
begin
  DbPath := CreateTempV6Db;
  try
    Src := TDbGraphSource.Create(DbPath, 0);

    Check(Src.GetSymbolMeta('U.TFoo.Bar', Sig, Mods, KindText),
      'GetSymbolMeta(Bar) = True');
    CheckEqualsStr('procedure Bar', Sig, 'GetSymbolMeta(Bar).Signature');
    CheckEqualsStr('method', KindText, 'GetSymbolMeta(Bar).KindText = method');

    Check(not Src.GetSymbolMeta('No.Such', Sig, Mods, KindText),
      'GetSymbolMeta(missing) = False');

    Src := nil;
  finally
    DeleteTempDb(DbPath);
  end;
end;
```

Register them in the `initialization` block:

```pascal
  RegisterTest('DbSource_GetCallees',   Test_DbSource_GetCallees);
  RegisterTest('DbSource_GetSymbolMeta', Test_DbSource_GetSymbolMeta);
```

- [ ] **Step 4: Run tests to verify they fail to compile**

Run: `powershell -ExecutionPolicy Bypass -File tests\console\run.ps1`
Expected: COMPILE FAILED (exit 2) — `GetCallees`/`GetSymbolMeta` not yet implemented in the source classes.

- [ ] **Step 5: Implement in `TDbGraphSource`**

In `src/control/DragLint.Graph.Source.Db.pas`, add both methods to the `TDbGraphSource` class declaration (public, next to `GetDoc`) and implement them. Reuse the connection field (`FConn`) the class already owns. Implementation:

```pascal
function TDbGraphSource.GetCallees(const AQName: string): TArray<TCallRef>;
var
  Q: TFDQuery;
  List: TList<TCallRef>;
  R: TCallRef;
begin
  List := TList<TCallRef>.Create;
  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      { Calls inside the caller's own body range, excluding refs that belong to
        a more deeply-nested symbol in the same file. Resolve target qname. }
      Q.SQL.Text :=
        'SELECT r.start_line AS cl, r.name_text AS nm, t.qualified_name AS tq ' +
        'FROM refs r ' +
        'JOIN symbols src ON src.qualified_name = :q ' +
        'JOIN symbols t   ON t.id = r.symbol_id ' +
        'WHERE r.kind = ''call'' ' +
        '  AND r.file_id = src.file_id ' +
        '  AND r.start_line BETWEEN src.start_line AND src.end_line ' +
        '  AND NOT EXISTS (' +
        '    SELECT 1 FROM symbols ins ' +
        '    WHERE ins.file_id = src.file_id ' +
        '      AND ins.start_line > src.start_line ' +
        '      AND ins.start_line <= r.start_line ' +
        '      AND ins.end_line   >= r.start_line) ' +
        'ORDER BY r.start_line';
      Q.ParamByName('q').AsString := AQName;
      Q.Open;
      while not Q.Eof do
      begin
        R.CallLine    := Q.FieldByName('cl').AsInteger;
        R.RawName     := Q.FieldByName('nm').AsString;
        R.TargetQName := Q.FieldByName('tq').AsString;
        List.Add(R);
        Q.Next;
      end;
      Q.Close;
    finally
      Q.Free;
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TDbGraphSource.GetSymbolMeta(const AQName: string;
  out ASignature, AModifiers, AKindText: string): Boolean;
var
  Q: TFDQuery;
begin
  ASignature := '';
  AModifiers := '';
  AKindText  := '';
  Result := False;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'SELECT signature, modifiers, kind FROM symbols ' +
      'WHERE qualified_name = :q LIMIT 1';
    Q.ParamByName('q').AsString := AQName;
    Q.Open;
    if not Q.Eof then
    begin
      ASignature := Q.FieldByName('signature').AsString;
      AModifiers := Q.FieldByName('modifiers').AsString;
      AKindText  := Q.FieldByName('kind').AsString;
      Result := True;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
```

Ensure `System.Generics.Collections` is in this unit's `uses` (it already is — `TDictionary` is used). `TFDQuery` is already used.

- [ ] **Step 6: Add trivial impls to the three fake sources (so the project compiles)**

In `tests/console/Fake.GraphSource.pas`, add to **both** `TFakeGraphSource` and `TPreloadedSource` declarations:

```pascal
    function GetCallees(const AQName: string): TArray<TCallRef>;
    function GetSymbolMeta(const AQName: string;
      out ASignature, AModifiers, AKindText: string): Boolean;
```

and implement (identical bodies for both classes — repeat them):

```pascal
function TFakeGraphSource.GetCallees(const AQName: string): TArray<TCallRef>;
begin
  Result := nil;
end;

function TFakeGraphSource.GetSymbolMeta(const AQName: string;
  out ASignature, AModifiers, AKindText: string): Boolean;
begin
  ASignature := '';
  AModifiers := '';
  AKindText  := '';
  Result := False;
end;
```

```pascal
function TPreloadedSource.GetCallees(const AQName: string): TArray<TCallRef>;
begin
  Result := nil;
end;

function TPreloadedSource.GetSymbolMeta(const AQName: string;
  out ASignature, AModifiers, AKindText: string): Boolean;
begin
  ASignature := '';
  AModifiers := '';
  AKindText  := '';
  Result := False;
end;
```

In `tests/console/Fake.DbCatalog.pas`, add the same two method declarations to `TStoreSource` and implement:

```pascal
function TStoreSource.GetCallees(const AQName: string): TArray<TCallRef>;
begin
  Result := nil;
end;

function TStoreSource.GetSymbolMeta(const AQName: string;
  out ASignature, AModifiers, AKindText: string): Boolean;
begin
  ASignature := '';
  AModifiers := '';
  AKindText  := '';
  Result := False;
end;
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `powershell -ExecutionPolicy Bypass -File tests\console\run.ps1`
Expected: GREEN (exit 0). The two new tests pass; all prior tests still pass.

- [ ] **Step 8: Commit**

```bash
git add src/control/DragLint.Graph.Types.pas src/control/DragLint.Graph.Source.pas src/control/DragLint.Graph.Source.Db.pas tests/console/Fake.GraphSource.pas tests/console/Fake.DbCatalog.pas tests/console/Test.Graph.Source.Db.pas
git commit -m "feat(flow): GetCallees + GetSymbolMeta on IGraphSource"
```

---

## Task 2: Flow engine (`TFlowBuilder`)

**Files:**
- Create: `src/control/DragLint.Graph.Flow.pas`
- Create: `tests/console/Fake.FlowSource.pas`
- Create: `tests/console/Test.Graph.Flow.pas`
- Modify: `tests/console/drag_lint_graph_tests.dpr`

- [ ] **Step 1: Create the engine unit with types + empty builder**

Create `src/control/DragLint.Graph.Flow.pas`:

```pascal
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
        Kids.Add(  { external leaf -- no recursion, no info lookup }
          (function: Integer
           var X: TFlowStep;
           begin
             FillChar(X, SizeOf(X), 0);
             X.Depth      := ADepth + 1;
             X.CallLine   := Callees[I].CallLine;
             X.IsExternal := True;
             X.RawName    := Callees[I].RawName;
             Result := FSteps.Add(X);
           end)() )
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
```

> Note: the anonymous-function inline for external leaves keeps the closure
> capturing `I`/`Callees`/`ADepth` correct. If your style forbids inline
> anonymous methods, replace it with a private `AddExternal(...)` method that
> takes the callee + depth and returns `FSteps.Add(X)`.

- [ ] **Step 2: Create the fake flow source**

Create `tests/console/Fake.FlowSource.pas`:

```pascal
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
    FillChar(Result, SizeOf(Result), 0);
end;

end.
```

- [ ] **Step 3: Write the failing engine tests**

Create `tests/console/Test.Graph.Flow.pas`:

```pascal
unit Test.Graph.Flow;

interface

implementation

uses
  System.SysUtils,
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Flow,
  Fake.FlowSource;

function StepById(const T: TFlowTree; const AId: string): Integer;
var I: Integer;
begin
  for I := 0 to High(T.Steps) do
    if (T.Steps[I].SymbolId = AId) and (not T.Steps[I].IsRecursion) then
      Exit(I);
  Result := -1;
end;

procedure Test_Flow_OrderAndDedup;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  Root: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'procedure A', True, 'root');
  Fake.AddInfo('B', 'procedure B', True, 'bee');
  Fake.AddInfo('C', 'procedure C', False);
  { A calls B at 30, C at 20, B again at 10 -> dedup B to first (10),
    ordered by line: B(10), C(20). }
  Fake.AddCall('A', 'B', 30);
  Fake.AddCall('A', 'C', 20);
  Fake.AddCall('A', 'B', 10);
  B := TFlowBuilder.Create(Fake as IFlowSource);
  try
    T := B.Build('A');
    Root := StepById(T, 'A');
    Check(Root = 0, 'root is step 0');
    CheckEqualsInt(2, Length(T.Steps[Root].ChildIndices),
      'A has 2 children after dedup');
    { Dedup keeps first occurrence by insertion; ToArray order = B then C? }
    CheckEqualsStr('B', T.Steps[T.Steps[Root].ChildIndices[0]].SymbolId,
      'first child = B');
    CheckEqualsStr('C', T.Steps[T.Steps[Root].ChildIndices[1]].SymbolId,
      'second child = C');
  finally
    B.Free;
    { Fake released via interface ref count when last reference drops:
      hold one explicitly to control lifetime. }
  end;
end;

procedure Test_Flow_Recursion;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  I, RecCount: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'procedure A', True, 'a');
  Fake.AddInfo('B', 'procedure B', True, 'b');
  Fake.AddCall('A', 'B', 10);
  Fake.AddCall('B', 'A', 10);   { back-edge -> recursion }
  B := TFlowBuilder.Create(Fake as IFlowSource);
  try
    T := B.Build('A');
    RecCount := 0;
    for I := 0 to High(T.Steps) do
      if T.Steps[I].IsRecursion then Inc(RecCount);
    CheckEqualsInt(1, RecCount, 'exactly one recursion marker (A under B)');
  finally
    B.Free;
  end;
end;

procedure Test_Flow_DepthCap;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  I, MaxDepth: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'a', True, 'a'); Fake.AddInfo('B', 'b', True, 'b');
  Fake.AddInfo('C', 'c', True, 'c'); Fake.AddInfo('D', 'd', True, 'd');
  Fake.AddCall('A', 'B', 1); Fake.AddCall('B', 'C', 1); Fake.AddCall('C', 'D', 1);
  B := TFlowBuilder.Create(Fake as IFlowSource, 2, 12);  { MaxDepth=2 }
  try
    T := B.Build('A');
    MaxDepth := 0;
    for I := 0 to High(T.Steps) do
      if T.Steps[I].Depth > MaxDepth then MaxDepth := T.Steps[I].Depth;
    CheckEqualsInt(2, MaxDepth, 'no step deeper than MaxDepth=2');
    Check(StepById(T, 'D') < 0, 'D (depth 3) is excluded');
    Check(T.Steps[StepById(T, 'C')].TruncatedChildren > 0,
      'C records its truncated children at the depth cap');
  finally
    B.Free;
  end;
end;

procedure Test_Flow_BreadthCap;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  Root: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'a', True, 'a');
  Fake.AddInfo('B', 'b', True, ''); Fake.AddInfo('C', 'c', True, '');
  Fake.AddInfo('D', 'd', True, ''); Fake.AddInfo('E', 'e', True, '');
  Fake.AddCall('A', 'B', 1); Fake.AddCall('A', 'C', 2);
  Fake.AddCall('A', 'D', 3); Fake.AddCall('A', 'E', 4);
  B := TFlowBuilder.Create(Fake as IFlowSource, 6, 2);  { MaxBreadth=2 }
  try
    T := B.Build('A');
    Root := StepById(T, 'A');
    CheckEqualsInt(2, Length(T.Steps[Root].ChildIndices),
      'A shows only MaxBreadth=2 children');
    CheckEqualsInt(2, T.Steps[Root].TruncatedChildren,
      'A records 2 truncated children');
  finally
    B.Free;
  end;
end;

procedure Test_Flow_DegradeAndExternal;
var
  Fake: TFakeFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  Cidx, Eidx, I: Integer;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'procedure A', True, 'a');
  Fake.AddInfo('C', 'procedure C', False);          { undocumented but resolves }
  Fake.AddCall('A', 'C', 10);
  Fake.AddCall('A', '', 20, 'Writeln');             { external/unresolved call }
  B := TFlowBuilder.Create(Fake as IFlowSource);
  try
    T := B.Build('A');
    Cidx := StepById(T, 'C');
    Check(Cidx >= 0, 'C present');
    Check(not T.Steps[Cidx].Doc.HasDoc, 'C undocumented');
    CheckEqualsStr('procedure C', T.Steps[Cidx].Signature,
      'C still shows its signature (degradation)');
    Eidx := -1;
    for I := 0 to High(T.Steps) do
      if T.Steps[I].IsExternal then Eidx := I;
    Check(Eidx >= 0, 'external step present');
    CheckEqualsStr('Writeln', T.Steps[Eidx].RawName,
      'external step uses RawName');
  finally
    B.Free;
  end;
end;

initialization
  RegisterTest('Flow_OrderAndDedup',      Test_Flow_OrderAndDedup);
  RegisterTest('Flow_Recursion',          Test_Flow_Recursion);
  RegisterTest('Flow_DepthCap',           Test_Flow_DepthCap);
  RegisterTest('Flow_BreadthCap',         Test_Flow_BreadthCap);
  RegisterTest('Flow_DegradeAndExternal', Test_Flow_DegradeAndExternal);
end.
```

> Lifetime note: `TFakeFlowSource` is a `TInterfacedObject`. Assigning it to an
> `IFlowSource` (via `Fake as IFlowSource` in the builder) makes the builder
> hold a reference; it is freed when the last interface reference drops at end
> of scope. Do **not** call `Fake.Free` — the local `Fake: TFakeFlowSource`
> object variable plus the interface reference would double-free. Keep `Fake`
> as shown (object var used only for setup); the cast hands a counted ref to
> the builder, and release happens automatically. (If the suite reports a leak,
> change the local to `Fake: IFlowSource` and a separate setup variable.)

- [ ] **Step 4: Register the new units in the test program**

In `tests/console/drag_lint_graph_tests.dpr`, add to the `uses` clause (after the existing flow-independent entries, keeping the `in '...'` paths):

```pascal
  DragLint.Graph.Flow in '..\..\src\control\DragLint.Graph.Flow.pas',
  Fake.FlowSource in 'Fake.FlowSource.pas',
  Test.Graph.Flow in 'Test.Graph.Flow.pas',
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `powershell -ExecutionPolicy Bypass -File tests\console\run.ps1`
Expected: GREEN. The five `Flow_*` tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/control/DragLint.Graph.Flow.pas tests/console/Fake.FlowSource.pas tests/console/Test.Graph.Flow.pas tests/console/drag_lint_graph_tests.dpr
git commit -m "feat(flow): call-tree engine (TFlowBuilder) with caps + recursion"
```

---

## Task 3: DB-backed `IFlowSource`

**Files:**
- Create: `src/control/DragLint.Graph.Flow.Source.Db.pas`
- Modify: `tests/console/Test.Graph.Flow.pas`, `tests/console/drag_lint_graph_tests.dpr`

- [ ] **Step 1: Create `TDbFlowSource`**

Create `src/control/DragLint.Graph.Flow.Source.Db.pas`:

```pascal
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
  FillChar(Result, SizeOf(Result), 0);
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
```

- [ ] **Step 2: Write the failing integration test (real fixture DB)**

In `tests/console/Test.Graph.Flow.pas`, extend the `uses` clause with:

```pascal
  DragLint.Graph.Source,
  DragLint.Graph.Source.Db,
  DragLint.Graph.Flow.Source.Db,
  Test.Db.Fixtures,
```

Add this test before `initialization`:

```pascal
procedure Test_Flow_DbSource_RealFixture;
var
  DbPath: string;
  Cat: IDbCatalog;
  FlowSrc: IFlowSource;
  B: TFlowBuilder;
  T: TFlowTree;
  Root, Child: Integer;
begin
  DbPath := CreateTempV6Db;
  try
    Cat := TDbCatalog.Create([DbPath]);
    FlowSrc := TDbFlowSource.Create(Cat);
    B := TFlowBuilder.Create(FlowSrc);
    try
      T := B.Build('U.TFoo.Bar');

      Root := 0;
      CheckEqualsStr('U.TFoo.Bar', T.Steps[Root].SymbolId, 'root = Bar');
      Check(T.Steps[Root].Doc.HasDoc, 'Bar documented');
      CheckEqualsStr('Hi', T.Steps[Root].Doc.Summary, 'Bar summary = Hi');
      CheckEqualsInt(1, Length(T.Steps[Root].ChildIndices),
        'Bar has one callee (MB; the type_use is not a call)');

      Child := T.Steps[Root].ChildIndices[0];
      CheckEqualsStr('U.TBaz.MB', T.Steps[Child].SymbolId, 'callee = MB');
      CheckEqualsInt(12, T.Steps[Child].CallLine, 'MB called at line 12');
      Check(not T.Steps[Child].Doc.HasDoc,
        'MB undocumented (degradation path)');
      CheckEqualsStr('procedure MB', T.Steps[Child].Signature,
        'MB still shows its signature');
    finally
      B.Free;
    end;
    Cat := nil;
    FlowSrc := nil;
  finally
    DeleteTempDb(DbPath);
  end;
end;
```

Register it:

```pascal
  RegisterTest('Flow_DbSource_RealFixture', Test_Flow_DbSource_RealFixture);
```

- [ ] **Step 3: Register the new source unit in the test program**

In `tests/console/drag_lint_graph_tests.dpr` `uses`, add:

```pascal
  DragLint.Graph.Flow.Source.Db in '..\..\src\control\DragLint.Graph.Flow.Source.Db.pas',
```

(Place it after `DragLint.Graph.Flow`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `powershell -ExecutionPolicy Bypass -File tests\console\run.ps1`
Expected: GREEN. `Flow_DbSource_RealFixture` passes — proving the engine + DB source produce a documented root with an undocumented, source-line-ordered callee.

- [ ] **Step 5: Commit**

```bash
git add src/control/DragLint.Graph.Flow.Source.Db.pas tests/console/Test.Graph.Flow.pas tests/console/drag_lint_graph_tests.dpr
git commit -m "feat(flow): DB-backed IFlowSource over IDbCatalog"
```

---

## Task 4: Flow view model

**Files:**
- Create: `src/control/DragLint.Graph.Flow.ViewModel.pas`
- Create: `tests/console/Test.Graph.Flow.ViewModel.pas`
- Modify: `tests/console/drag_lint_graph_tests.dpr`

- [ ] **Step 1: Create `TFlowViewModel`**

Create `src/control/DragLint.Graph.Flow.ViewModel.pas`:

```pascal
unit DragLint.Graph.Flow.ViewModel;

{ Interaction state for the flow view: current tree, global Brief/Expanded
  mode, and per-box expand/collapse overrides. UI-agnostic (no VCL) so it is
  unit-testable; the control observes OnChanged and repaints.

  ASCII / CRLF per the project rule. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  DragLint.Graph.Flow;

type
  TFlowMode = (fmBrief, fmExpanded);

  /// <summary>Holds the built flow tree plus view state. Build a tree with
  ///  SetRoot; flip detail with ToggleGlobalMode; override one box with
  ///  ToggleBox. EffectiveExpanded answers what the renderer should draw.</summary>
  TFlowViewModel = class
  strict private
    FBuilder:   TFlowBuilder;
    FTree:      TFlowTree;
    FHasTree:   Boolean;
    FMode:      TFlowMode;
    FOverrides: TDictionary<Integer, Boolean>;  { step idx -> expanded? }
    FOnChanged: TNotifyEvent;
    procedure Changed;
  public
    constructor Create(ABuilder: TFlowBuilder);
    destructor Destroy; override;
    procedure SetRoot(const ARootId: string);
    procedure ToggleGlobalMode;
    procedure ToggleBox(AStepIndex: Integer);
    function  EffectiveExpanded(AStepIndex: Integer): Boolean;
    property  Tree: TFlowTree read FTree;
    property  HasTree: Boolean read FHasTree;
    property  Mode: TFlowMode read FMode;
    property  OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

constructor TFlowViewModel.Create(ABuilder: TFlowBuilder);
begin
  inherited Create;
  FBuilder   := ABuilder;
  FMode      := fmBrief;
  FOverrides := TDictionary<Integer, Boolean>.Create;
end;

destructor TFlowViewModel.Destroy;
begin
  FOverrides.Free;
  inherited;
end;

procedure TFlowViewModel.Changed;
begin
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

procedure TFlowViewModel.SetRoot(const ARootId: string);
begin
  FOverrides.Clear;
  FTree := FBuilder.Build(ARootId);
  FHasTree := Length(FTree.Steps) > 0;
  Changed;
end;

procedure TFlowViewModel.ToggleGlobalMode;
begin
  if FMode = fmBrief then FMode := fmExpanded else FMode := fmBrief;
  FOverrides.Clear;   { a global flip resets per-box overrides }
  Changed;
end;

procedure TFlowViewModel.ToggleBox(AStepIndex: Integer);
begin
  FOverrides.AddOrSetValue(AStepIndex, not EffectiveExpanded(AStepIndex));
  Changed;
end;

function TFlowViewModel.EffectiveExpanded(AStepIndex: Integer): Boolean;
begin
  if not FOverrides.TryGetValue(AStepIndex, Result) then
    Result := (FMode = fmExpanded);
end;

end.
```

- [ ] **Step 2: Write the failing VM tests**

Create `tests/console/Test.Graph.Flow.ViewModel.pas`:

```pascal
unit Test.Graph.Flow.ViewModel;

interface

implementation

uses
  System.SysUtils, System.Classes,
  DragLint.Graph.TestFramework,
  DragLint.Graph.Flow,
  DragLint.Graph.Flow.ViewModel,
  Fake.FlowSource;

type
  TChangeCounter = class
    Count: Integer;
    procedure OnChanged(Sender: TObject);
  end;

procedure TChangeCounter.OnChanged(Sender: TObject);
begin
  Inc(Count);
end;

procedure Test_FlowVM_SetRootAndModes;
var
  Fake: TFakeFlowSource;
  Bld:  TFlowBuilder;
  VM:   TFlowViewModel;
  CC:   TChangeCounter;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'procedure A', True, 'a');
  Fake.AddInfo('B', 'procedure B', True, 'b');
  Fake.AddCall('A', 'B', 10);
  Bld := TFlowBuilder.Create(Fake as IFlowSource);
  VM  := TFlowViewModel.Create(Bld);
  CC  := TChangeCounter.Create;
  try
    VM.OnChanged := CC.OnChanged;

    VM.SetRoot('A');
    Check(VM.HasTree, 'tree built');
    CheckEqualsInt(1, CC.Count, 'SetRoot fired OnChanged once');

    { default mode = Brief => box 0 not expanded }
    Check(not VM.EffectiveExpanded(0), 'Brief: box 0 collapsed by default');

    VM.ToggleGlobalMode;   { -> Expanded }
    CheckEqualsInt(2, CC.Count, 'ToggleGlobalMode fired OnChanged');
    Check(VM.EffectiveExpanded(0), 'Expanded: box 0 expanded by default');

    { per-box override: collapse box 0 while global is Expanded }
    VM.ToggleBox(0);
    Check(not VM.EffectiveExpanded(0), 'override collapses box 0');
    CheckEqualsInt(3, CC.Count, 'ToggleBox fired OnChanged');
  finally
    CC.Free;
    VM.Free;
    Bld.Free;
  end;
end;

initialization
  RegisterTest('FlowVM_SetRootAndModes', Test_FlowVM_SetRootAndModes);
end.
```

- [ ] **Step 3: Register the units**

In `tests/console/drag_lint_graph_tests.dpr` `uses`, add:

```pascal
  DragLint.Graph.Flow.ViewModel in '..\..\src\control\DragLint.Graph.Flow.ViewModel.pas',
  Test.Graph.Flow.ViewModel in 'Test.Graph.Flow.ViewModel.pas',
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `powershell -ExecutionPolicy Bypass -File tests\console\run.ps1`
Expected: GREEN. `FlowVM_SetRootAndModes` passes.

- [ ] **Step 5: Commit**

```bash
git add src/control/DragLint.Graph.Flow.ViewModel.pas tests/console/Test.Graph.Flow.ViewModel.pas tests/console/drag_lint_graph_tests.dpr
git commit -m "feat(flow): TFlowViewModel (Brief/Expanded + per-box override)"
```

---

## Task 5: Flow chart control (UI — manual validation)

**Files:**
- Create: `src/control/DragLint.Graph.FlowControl.pas`
- Modify: `src/viewer/drag_lint_graph.dproj` (add the unit to the project)

> This control is VCL and is **not** in the console test suite (the suite does
> not link the UI controls). Validation is by compiling the viewer and a manual
> smoke in Task 6. Keep the first version focused: single-column vertical stack,
> depth shown by left indent, Brief/Expanded box bodies, per-box +/- toggle,
> click-to-select. See-also chips and "... N more" expansion are concrete
> additions noted at the end of the task.

- [ ] **Step 1: Create the control**

Create `src/control/DragLint.Graph.FlowControl.pas`:

```pascal
unit DragLint.Graph.FlowControl;

{ Vertical-flowchart renderer for a TFlowViewModel. A TScrollBox host with an
  inner TPaintBox sized to the laid-out content; paints stacked detail-boxes
  joined by connectors, hit-tests clicks for select / per-box expand toggle.

  Text is ASCII only ('->' not arrows). CRLF line endings. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls,
  DragLint.Graph.Types,
  DragLint.Graph.Flow,
  DragLint.Graph.Flow.ViewModel;

type
  TFlowSymbolEvent = procedure(Sender: TObject; const ASymbolId: string) of object;

  TFlowChartControl = class(TScrollBox)
  strict private
    FPaint:   TPaintBox;
    FVM:      TFlowViewModel;
    FBoxRects:   TList<TRect>;     { index-aligned with VM.Tree.Steps }
    FToggleRects: TList<TRect>;    { per-step +/- hit rect }
    FContentH: Integer;
    FOnSelect: TFlowSymbolEvent;
    procedure PaintBoxPaint(Sender: TObject);
    procedure PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure VMChanged(Sender: TObject);
    function  BoxLines(AIndex: Integer): TArray<string>;
    procedure Relayout;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Attach(AVM: TFlowViewModel);
    property OnSelectSymbol: TFlowSymbolEvent read FOnSelect write FOnSelect;
  end;

implementation

const
  BOX_W      = 360;
  BOX_PAD    = 8;
  LINE_H     = 16;
  V_GAP      = 28;     { vertical gap between boxes (room for connector) }
  INDENT     = 24;     { px per depth level }
  LEFT_MARGIN = 16;
  TOP_MARGIN  = 12;
  TOGGLE_SZ   = 14;

constructor TFlowChartControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FBoxRects    := TList<TRect>.Create;
  FToggleRects := TList<TRect>.Create;
  BorderStyle := bsNone;
  Color := clWindow;
  FPaint := TPaintBox.Create(Self);
  FPaint.Parent := Self;
  FPaint.Align  := alNone;
  FPaint.OnPaint     := PaintBoxPaint;
  FPaint.OnMouseDown := PaintBoxMouseDown;
end;

destructor TFlowChartControl.Destroy;
begin
  FToggleRects.Free;
  FBoxRects.Free;
  inherited;
end;

procedure TFlowChartControl.Attach(AVM: TFlowViewModel);
begin
  FVM := AVM;
  if FVM <> nil then
    FVM.OnChanged := VMChanged;
  Relayout;
  FPaint.Invalidate;
end;

procedure TFlowChartControl.VMChanged(Sender: TObject);
begin
  Relayout;
  FPaint.Invalidate;
end;

function TFlowChartControl.BoxLines(AIndex: Integer): TArray<string>;
var
  S: TFlowStep;
  L: TList<string>;
  P: TDocParam;
  E: TDocException;
  Expanded: Boolean;
  Head: string;
  CR: string;
begin
  S := FVM.Tree.Steps[AIndex];
  L := TList<string>.Create;
  try
    if S.IsExternal then
    begin
      L.Add(S.RawName + '  [external]');
      Exit(L.ToArray);
    end;

    { Header: name(params) from signature; fall back to id. }
    if S.Signature <> '' then Head := S.Signature
                         else Head := S.SymbolId;
    if S.IsRecursion then Head := Head + '   (recursion)';
    L.Add(Head);

    { Brief: one-line summary (or [no doc]). }
    if S.Doc.HasDoc and (S.Doc.Summary <> '') then
      L.Add(S.Doc.Summary)
    else if not S.Doc.HasDoc then
      L.Add('[no doc]');

    Expanded := FVM.EffectiveExpanded(AIndex);
    if Expanded and S.Doc.HasDoc then
    begin
      for P in S.Doc.Params do
        L.Add('  param ' + P.Name + ' - ' + P.Desc);
      if S.Doc.ReturnsText <> '' then
        L.Add('  returns ' + S.Doc.ReturnsText);
      for E in S.Doc.Exceptions do
        L.Add('  raises ' + E.TypeName);
      if S.Doc.Remarks <> '' then
        L.Add('  remarks ' + S.Doc.Remarks);
      if Length(S.Doc.SeeAlso) > 0 then
      begin
        CR := '  see also: ' + string.Join(', ', S.Doc.SeeAlso);
        L.Add(CR);
      end;
    end;

    if S.TruncatedChildren > 0 then
      L.Add('  ... ' + IntToStr(S.TruncatedChildren) + ' more');

    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

procedure TFlowChartControl.Relayout;
var
  I, Y, H, X: Integer;
  Lines: TArray<string>;
  R, TR: TRect;
begin
  FBoxRects.Clear;
  FToggleRects.Clear;
  Y := TOP_MARGIN;
  if (FVM = nil) or (not FVM.HasTree) then
  begin
    FContentH := Y;
    FPaint.SetBounds(0, 0, BOX_W + 4 * INDENT + 2 * LEFT_MARGIN, FContentH);
    Exit;
  end;

  for I := 0 to High(FVM.Tree.Steps) do
  begin
    Lines := BoxLines(I);
    H := 2 * BOX_PAD + Length(Lines) * LINE_H;
    X := LEFT_MARGIN + FVM.Tree.Steps[I].Depth * INDENT;
    R := Rect(X, Y, X + BOX_W, Y + H);
    FBoxRects.Add(R);
    { toggle hit rect, top-right of the box (only meaningful for non-external) }
    TR := Rect(R.Right - TOGGLE_SZ - 4, R.Top + 4,
               R.Right - 4, R.Top + 4 + TOGGLE_SZ);
    FToggleRects.Add(TR);
    Y := Y + H + V_GAP;
  end;
  FContentH := Y;
  FPaint.SetBounds(0, 0,
    BOX_W + 5 * INDENT + 2 * LEFT_MARGIN, FContentH);
end;

procedure TFlowChartControl.PaintBoxPaint(Sender: TObject);
var
  I, J, ParentIdx, K: Integer;
  Lines: TArray<string>;
  R, TR: TRect;
  Cv: TCanvas;
  S: TFlowStep;
  Tog: string;
begin
  Cv := FPaint.Canvas;
  Cv.Brush.Color := clWindow;
  Cv.FillRect(FPaint.ClientRect);
  if (FVM = nil) or (not FVM.HasTree) then
  begin
    Cv.Font.Color := clGrayText;
    Cv.TextOut(LEFT_MARGIN, TOP_MARGIN, 'No flow. Right-click a symbol -> Trace flow from here.');
    Exit;
  end;

  { connectors: parent bottom-center -> child top-center }
  Cv.Pen.Color := clSilver;
  for I := 0 to High(FVM.Tree.Steps) do
  begin
    S := FVM.Tree.Steps[I];
    for K := 0 to High(S.ChildIndices) do
    begin
      J := S.ChildIndices[K];
      R  := FBoxRects[I];
      TR := FBoxRects[J];
      Cv.MoveTo(R.Left + 12, R.Bottom);
      Cv.LineTo(R.Left + 12, TR.Top);
      Cv.LineTo(TR.Left, TR.Top);
    end;
  end;
  if ParentIdx = 0 then ;  { silence hint if unused on some compilers }

  { boxes }
  for I := 0 to High(FVM.Tree.Steps) do
  begin
    S := FVM.Tree.Steps[I];
    R := FBoxRects[I];

    if S.IsExternal then Cv.Brush.Color := $00EFEFEF
    else if not S.Doc.HasDoc then Cv.Brush.Color := $00F7F2EC
    else Cv.Brush.Color := $00FBF3E8;
    Cv.Pen.Color := $00B07A2F;
    Cv.Rectangle(R);

    Lines := BoxLines(I);
    Cv.Brush.Style := bsClear;
    for J := 0 to High(Lines) do
    begin
      if J = 0 then Cv.Font.Style := [fsBold] else Cv.Font.Style := [];
      Cv.Font.Color := clWindowText;
      Cv.TextOut(R.Left + BOX_PAD, R.Top + BOX_PAD + J * LINE_H, Lines[J]);
    end;
    Cv.Brush.Style := bsSolid;

    { +/- toggle (skip external) }
    if not S.IsExternal then
    begin
      TR := FToggleRects[I];
      Cv.Brush.Color := clBtnFace;
      Cv.Pen.Color := clGrayText;
      Cv.Rectangle(TR);
      if FVM.EffectiveExpanded(I) then Tog := '-' else Tog := '+';
      Cv.Brush.Style := bsClear;
      Cv.TextOut(TR.Left + 4, TR.Top - 1, Tog);
      Cv.Brush.Style := bsSolid;
    end;
  end;
end;

procedure TFlowChartControl.PaintBoxMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  P: TPoint;
begin
  if (FVM = nil) or (not FVM.HasTree) then Exit;
  P := Point(X, Y);
  { toggle hit first }
  for I := 0 to FToggleRects.Count - 1 do
    if (not FVM.Tree.Steps[I].IsExternal) and PtInRect(FToggleRects[I], P) then
    begin
      FVM.ToggleBox(I);
      Exit;
    end;
  { else box select }
  for I := 0 to FBoxRects.Count - 1 do
    if PtInRect(FBoxRects[I], P) then
    begin
      if Assigned(FOnSelect) and (not FVM.Tree.Steps[I].IsExternal) then
        FOnSelect(Self, FVM.Tree.Steps[I].SymbolId);
      Exit;
    end;
end;

end.
```

> The `if ParentIdx = 0 then ;` line is a deliberate hint-suppressor placeholder
> — remove the unused `ParentIdx` local and that line together if the compiler
> is clean without them.

- [ ] **Step 2: Add the unit to the viewer project**

Open `src/viewer/drag_lint_graph.dproj` and add `DragLint.Graph.Flow.pas`,
`DragLint.Graph.Flow.Source.Db.pas`, `DragLint.Graph.Flow.ViewModel.pas`, and
`DragLint.Graph.FlowControl.pas` to the `<DCCReference Include="..."/>` list
(mirror how `DragLint.Graph.Control.pas` is listed; paths are relative to the
`.dproj`, e.g. `..\control\DragLint.Graph.FlowControl.pas`). If you use the IDE,
`Project > Add to Project` each unit instead.

- [ ] **Step 3: Compile the viewer**

Run: `cmd.exe /c build\build_viewer.bat`
Expected: build succeeds (exit 0), `drag_lint_graph.exe` produced. Fix any
compile errors in the control before proceeding. (No behavior wired yet — this
step only proves the control compiles into the app.)

- [ ] **Step 4: Commit**

```bash
git add src/control/DragLint.Graph.FlowControl.pas src/viewer/drag_lint_graph.dproj
git commit -m "feat(flow): TFlowChartControl renderer (compiles into viewer)"
```

---

## Task 6: Wire Flow mode into MainForm

**Files:**
- Modify: `src/viewer/MainForm.pas`

> Goal: a way to enter Flow mode from a symbol, a Brief/Expanded toggle, a pane
> that swaps between the graph and the flow control, and two-way selection sync
> with the structure tree. Keep diffs additive; reuse existing fields
> (`FCatalog`, `FGraph`, `FTree`, `FSplitter`, `FStatus`).

- [ ] **Step 1: Add fields + uses**

In `MainForm.pas` `uses`, add:
```pascal
  DragLint.Graph.Flow,
  DragLint.Graph.Flow.Source.Db,
  DragLint.Graph.Flow.ViewModel,
  DragLint.Graph.FlowControl,
```
In the `private` section of `TfrmMain`, add:
```pascal
    FFlowControl: TFlowChartControl;
    FFlowVM:      TFlowViewModel;
    FFlowBuilder: TFlowBuilder;
    FFlowSource:  IFlowSource;
    FFlowBtn:     TButton;     { toggles graph <-> flow }
    FModeBtn:     TButton;     { toggles Brief <-> Expanded }
    FInFlow:      Boolean;
    procedure FlowBtnClick(Sender: TObject);
    procedure ModeBtnClick(Sender: TObject);
    procedure StartFlowFrom(const ASymbolId: string);
    procedure FlowSelected(Sender: TObject; const ASymbolId: string);
    procedure UpdateModeButton;
```

- [ ] **Step 2: Build the flow control + buttons (in `CreateControls`)**

At the end of `CreateControls`, after the graph is created, add:
```pascal
  FFlowControl := TFlowChartControl.Create(Self);
  FFlowControl.Parent  := Self;     { same parent/region as FGraph }
  FFlowControl.Align   := alClient;
  FFlowControl.Visible := False;
  FFlowControl.OnSelectSymbol := FlowSelected;

  FFlowBtn := TButton.Create(Self);
  FFlowBtn.Parent := Self;          { place on the same toolbar/panel as FShowAllBtn }
  FFlowBtn.Caption := 'Flow';
  FFlowBtn.OnClick := FlowBtnClick;

  FModeBtn := TButton.Create(Self);
  FModeBtn.Parent := Self;
  FModeBtn.Caption := 'Brief';
  FModeBtn.Enabled := False;
  FModeBtn.OnClick := ModeBtnClick;
```
> Position `FFlowBtn`/`FModeBtn` next to the existing `FShowAllBtn`/`FFitBtn`
> using the same `SetBounds`/anchoring pattern those buttons already use in
> `CreateControls` (copy their `Left/Top/Width/Height` idiom).

- [ ] **Step 3: Add the context-menu entry "Trace flow from here"**

The tree popup already has items (`FMiTOpen` etc.) wired in `CreateControls`.
Add one more in the same place:
```pascal
  FMiTFlow := TMenuItem.Create(FTreePopup);
  FMiTFlow.Caption := 'Trace flow from here';
  FMiTFlow.OnClick := TreeCtxFlow;
  FTreePopup.Items.Add(FMiTFlow);
```
Declare `FMiTFlow: TMenuItem;` and the handler in `private`:
```pascal
    FMiTFlow: TMenuItem;
    procedure TreeCtxFlow(Sender: TObject);
```
Implement (mirrors `TreeCtxCenter`, which already uses `FTreeCtxId`):
```pascal
procedure TfrmMain.TreeCtxFlow(Sender: TObject);
begin
  if FTreeCtxId <> '' then
    StartFlowFrom(FTreeCtxId);
end;
```

- [ ] **Step 4: Implement the flow lifecycle + handlers**

```pascal
procedure TfrmMain.StartFlowFrom(const ASymbolId: string);
begin
  if FCatalog = nil then Exit;
  if FFlowSource = nil then
    FFlowSource := TDbFlowSource.Create(FCatalog);
  if FFlowBuilder = nil then
    FFlowBuilder := TFlowBuilder.Create(FFlowSource);
  if FFlowVM = nil then
  begin
    FFlowVM := TFlowViewModel.Create(FFlowBuilder);
    FFlowControl.Attach(FFlowVM);
  end;
  FFlowVM.SetRoot(ASymbolId);

  FInFlow := True;
  FGraph.Visible       := False;
  FFlowControl.Visible := True;
  FModeBtn.Enabled := True;
  UpdateModeButton;
  FStatus.SimpleText := 'Flow: ' + ASymbolId;
end;

procedure TfrmMain.FlowBtnClick(Sender: TObject);
begin
  { The Flow button only RETURNS to the graph. Entering flow is done from a
    symbol via the tree context menu "Trace flow from here" (StartFlowFrom),
    which always has a concrete root. This keeps the button a pure no-arg
    toggle with no dependency on the graph's selection accessor. }
  if FInFlow then
  begin
    FInFlow := False;
    FFlowControl.Visible := False;
    FGraph.Visible := True;
    FModeBtn.Enabled := False;
    FStatus.SimpleText := '';
  end;
end;

procedure TfrmMain.ModeBtnClick(Sender: TObject);
begin
  if FFlowVM <> nil then
  begin
    FFlowVM.ToggleGlobalMode;
    UpdateModeButton;
  end;
end;

procedure TfrmMain.UpdateModeButton;
begin
  if (FFlowVM <> nil) and (FFlowVM.Mode = fmExpanded) then
    FModeBtn.Caption := 'Expanded'
  else
    FModeBtn.Caption := 'Brief';
end;

procedure TfrmMain.FlowSelected(Sender: TObject; const ASymbolId: string);
begin
  { sync the structure tree to the clicked flow box }
  SelectTreeNodeById(ASymbolId);
end;
```
> For `FlowBtnClick`'s "enter from selection" branch: reuse the same accessor
> `GraphSelectionChanged` already reads to learn the selected node id, and call
> `StartFlowFrom(thatId)`. If no symbol is selected, leave the branch empty
> (button is a no-op until a node is selected).

- [ ] **Step 5: Free the flow objects in `Destroy`**

In `TfrmMain.Destroy`, before `inherited`, add:
```pascal
  FFlowVM.Free;
  FFlowBuilder.Free;
  FFlowSource := nil;
```
(The controls are owned by the form and freed automatically.)

- [ ] **Step 6: Compile the viewer**

Run: `cmd.exe /c build\build_viewer.bat`
Expected: build succeeds (exit 0).

- [ ] **Step 7: Manual smoke test**

Launch with a real DB, e.g.:
`bin\Win32\drag_lint_graph.exe --db C:\Projects\DB\ORM3\drag-lint.sqlite`
(use whatever `--db` argument form `ParseDbArgs` expects — same as the graph
viewer is normally launched). Then:
1. Right-click a method in the structure tree -> "Trace flow from here".
2. Confirm the pane swaps to the flowchart, root box at top with its callees
   below, connectors drawn.
3. Confirm an undocumented callee still shows name + params + `[no doc]`.
4. Click `Brief`/`Expanded` -> boxes grow/shrink; per-box `+`/`-` overrides one.
5. Click a box -> the structure tree selection follows.
6. Click `Flow` -> returns to the graph.

Record the result (pass/fail per step) in the commit message or a short note.

- [ ] **Step 8: Commit**

```bash
git add src/viewer/MainForm.pas
git commit -m "feat(flow): wire Flow mode + Brief/Expanded toggle into MainForm"
```

---

## Task 7: DocInsight comments + final verification

**Files:**
- Modify: the four new `src/control/DragLint.Graph.Flow*.pas` units (doc-comments)

- [ ] **Step 1: Add `///` summaries to public surface**

Ensure each new unit's public types and methods carry `///` XML doc-comments
(summary at minimum; add `<param>`/`<returns>` where non-obvious). The engine
types in Task 2 already show the pattern. Add equivalents to
`TDbFlowSource`, `TFlowViewModel` public methods, and `TFlowChartControl.Attach`
/ `OnSelectSymbol`. ASCII only.

- [ ] **Step 2: Normalize encoding**

Run: `powershell -ExecutionPolicy Bypass -File tools\normalize_ascii_crlf.ps1`
(if present). Confirm no file was rewritten with errors.

- [ ] **Step 3: Full console suite + viewer build**

Run: `powershell -ExecutionPolicy Bypass -File tests\console\run.ps1`
Expected: GREEN (all prior tests + the new `Flow_*`, `FlowVM_*`,
`DbSource_GetCallees`, `DbSource_GetSymbolMeta` pass).

Run: `cmd.exe /c build\build_viewer.bat`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs(flow): DocInsight comments on flow units; final verification"
```

---

## Done criteria
- Console suite GREEN, including all new flow tests.
- Viewer builds and Flow mode works in the manual smoke (Task 6 Step 7).
- Engine (`TFlowBuilder` + `IFlowSource`) is independent of VCL and DB — ready
  for the Protocol Walkthrough (C) to reuse with a prose renderer.
- Branch `feat/flow-view` holds the work; discard/stash freely if not wanted.
