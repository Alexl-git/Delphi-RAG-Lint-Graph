# P1: Model Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the pure Model layer with the containment hierarchy, the new node/edge kinds and node flags, the documentation/cref/cross-DB result records, and the `IGraphSource`/`IDbCatalog` gateway interfaces — all backed by a headless console test harness.

**Architecture:** Pure Object Pascal, no VCL, no FireDAC. `DragLint.Graph.Types` holds the raw graph + hierarchy; `DragLint.Graph.Source` holds the data-gateway interfaces and result records consume `Types`. A dependency-free console test runner (mirroring drag-lint's autotest: exit 0 = green) drives everything.

**Tech Stack:** Delphi 13 (RAD Studio 37.0), `dcc32` Win32, `System.Generics.Collections`. Strict ASCII / CRLF in all `.pas`.

Spec: [`../specs/2026-05-31-graph-viewer-real-and-harden-design.md`](../specs/2026-05-31-graph-viewer-real-and-harden-design.md) — Sections 3.1, 4, 5.
Roadmap: [`2026-05-31-graph-roadmap.md`](2026-05-31-graph-roadmap.md).

---

## File Structure

| File | Responsibility |
|------|----------------|
| Create `tests/console/DragLint.Graph.TestFramework.pas` | Minimal assert/registry/runner (no external deps). |
| Create `tests/console/drag_lint_graph_tests.dpr` | Console test program; `ExitCode := RunAllTests`. |
| Create `tests/console/Test.Graph.Types.pas` | Tests for kinds, flags, hierarchy. |
| Create `tests/console/Test.Graph.Source.pas` | Tests for the gateway interfaces via a fake source. |
| Create `tests/console/Fake.GraphSource.pas` | In-memory `IGraphSource` returning canned topology. |
| Create `tests/console/run.ps1` | Compile + run the console suite; propagate exit code. |
| Modify `src/control/DragLint.Graph.Types.pas` | New kinds/edge-kinds, node fields/flags, hierarchy, doc/cref/cross-db records. |
| Create `src/control/DragLint.Graph.Source.pas` | `IGraphSource`, `IDbCatalog` interfaces. |

---

## Task 1: Headless test harness

**Files:**
- Create: `tests/console/DragLint.Graph.TestFramework.pas`
- Create: `tests/console/Test.Graph.Types.pas`
- Create: `tests/console/drag_lint_graph_tests.dpr`
- Create: `tests/console/run.ps1`

- [ ] **Step 1: Write the test framework unit**

Create `tests/console/DragLint.Graph.TestFramework.pas`:

```pascal
unit DragLint.Graph.TestFramework;

{ Minimal dependency-free test harness. Mirrors drag-lint's console autotest:
  each registered test runs; any failed Check increments the test's failure
  count; RunAllTests returns the number of failed tests for use as ExitCode. }

interface

type
  TTestProc = procedure;

procedure RegisterTest(const AName: string; AProc: TTestProc);
procedure Check(ACondition: Boolean; const AMessage: string);
procedure CheckEqualsInt(AExpected, AActual: Integer; const AMessage: string);
procedure CheckEqualsStr(const AExpected, AActual, AMessage: string);
function RunAllTests: Integer;

implementation

uses
  System.SysUtils, System.Generics.Collections;

type
  TTestEntry = record
    Name: string;
    Proc: TTestProc;
  end;

var
  GTests: TList<TTestEntry>;
  GCurrentFailures: Integer;

procedure RegisterTest(const AName: string; AProc: TTestProc);
var
  E: TTestEntry;
begin
  E.Name := AName;
  E.Proc := AProc;
  GTests.Add(E);
end;

procedure Fail(const AMessage: string);
begin
  Inc(GCurrentFailures);
  WriteLn('    FAIL: ' + AMessage);
end;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then Fail(AMessage);
end;

procedure CheckEqualsInt(AExpected, AActual: Integer; const AMessage: string);
begin
  if AExpected <> AActual then
    Fail(Format('%s (expected %d, got %d)', [AMessage, AExpected, AActual]));
end;

procedure CheckEqualsStr(const AExpected, AActual, AMessage: string);
begin
  if AExpected <> AActual then
    Fail(Format('%s (expected "%s", got "%s")', [AMessage, AExpected, AActual]));
end;

function RunAllTests: Integer;
var
  I: Integer;
  E: TTestEntry;
begin
  Result := 0;
  for I := 0 to GTests.Count - 1 do
  begin
    E := GTests[I];
    GCurrentFailures := 0;
    try
      E.Proc;
    except
      on Ex: Exception do
      begin
        Inc(GCurrentFailures);
        WriteLn('    EXCEPTION: ' + Ex.ClassName + ': ' + Ex.Message);
      end;
    end;
    if GCurrentFailures = 0 then
      WriteLn('  [PASS] ' + E.Name)
    else
    begin
      WriteLn('  [FAIL] ' + E.Name);
      Inc(Result);
    end;
  end;
  WriteLn('');
  WriteLn(Format('%d test(s), %d failed', [GTests.Count, Result]));
end;

initialization
  GTests := TList<TTestEntry>.Create;
finalization
  GTests.Free;
end.
```

- [ ] **Step 2: Write a trivial test unit (proves the harness runs)**

Create `tests/console/Test.Graph.Types.pas`:

```pascal
unit Test.Graph.Types;

interface

implementation

uses
  DragLint.Graph.TestFramework;

procedure Test_HarnessSelfCheck;
begin
  Check(True, 'harness self-check should pass');
  CheckEqualsInt(2, 1 + 1, 'arithmetic sanity');
end;

initialization
  RegisterTest('HarnessSelfCheck', Test_HarnessSelfCheck);
end.
```

- [ ] **Step 3: Write the runner program**

Create `tests/console/drag_lint_graph_tests.dpr`:

```pascal
program drag_lint_graph_tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DragLint.Graph.TestFramework in 'DragLint.Graph.TestFramework.pas',
  Test.Graph.Types in 'Test.Graph.Types.pas';

begin
  WriteLn('drag-lint-graph console tests');
  WriteLn('');
  ExitCode := RunAllTests;
end.
```

- [ ] **Step 4: Write the compile+run script**

Create `tests/console/run.ps1`:

```powershell
# Compile and run the drag-lint-graph console test suite.
# Exit 0 = all green; 2 = compile failure; N = N failed tests.
$ErrorActionPreference = 'Stop'
$IDE  = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $repo
try {
    New-Item -ItemType Directory -Force 'bin\Win32\dcu' | Out-Null
    $dpr   = 'tests\console\drag_lint_graph_tests.dpr'
    $build = "call `"$IDE\bin\rsvars.bat`" && dcc32 -B -NSSystem " +
             "-U`"src\control`";`"tests\console`" " +
             "-E`"bin\Win32`" -N0`"bin\Win32\dcu`" `"$dpr`""
    cmd.exe /c $build
    if ($LASTEXITCODE -ne 0) { Write-Host 'COMPILE FAILED' -ForegroundColor Red; exit 2 }
    & 'bin\Win32\drag_lint_graph_tests.exe'
    $code = $LASTEXITCODE
    if ($code -eq 0) { Write-Host 'GREEN' -ForegroundColor Green }
    else { Write-Host ("RED ({0} failed)" -f $code) -ForegroundColor Red }
    exit $code
} finally { Pop-Location }
```

- [ ] **Step 5: Run to verify the harness is green**

Run: `pwsh tests\console\run.ps1`
Expected: compiles, prints `[PASS] HarnessSelfCheck`, `1 test(s), 0 failed`, `GREEN`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/console/
git commit -m "test: headless console test harness for graph model"
```

---

## Task 2: New node/edge kinds + IsSqlKind helper

**Files:**
- Modify: `src/control/DragLint.Graph.Types.pas` (enums + helper)
- Modify: `tests/console/Test.Graph.Types.pas`

- [ ] **Step 1: Write the failing test**

Add to `tests/console/Test.Graph.Types.pas` (inside `implementation`, before `initialization`):

```pascal
procedure Test_SqlKindClassification;
begin
  Check(IsSqlKind(nkSqlTable), 'nkSqlTable is a SQL kind');
  Check(IsSqlKind(nkSqlColumn), 'nkSqlColumn is a SQL kind');
  Check(IsSqlKind(nkSqlDomain), 'nkSqlDomain is a SQL kind');
  Check(not IsSqlKind(nkClass), 'nkClass is not a SQL kind');
  Check(not IsSqlKind(nkProject), 'nkProject is not a SQL kind');
  Check(not IsSqlKind(nkUnit), 'nkUnit is not a SQL kind');
end;
```

Add `DragLint.Graph.Types` to this unit's `uses` clause (it currently uses only `DragLint.Graph.TestFramework`):

```pascal
uses
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types;
```

Register it in `initialization`:

```pascal
  RegisterTest('SqlKindClassification', Test_SqlKindClassification);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests\console\run.ps1`
Expected: COMPILE FAILED (exit 2) — `nkSqlTable`/`IsSqlKind` undeclared.

- [ ] **Step 3: Add the enum members and helper**

In `src/control/DragLint.Graph.Types.pas`, replace the `TGraphNodeKind` declaration with (note new members added **before** `nkOther` so `nkOther` stays the fallback):

```pascal
  TGraphNodeKind = (
    nkUnit,
    nkType,
    nkClass,
    nkInterface,
    nkRecord,
    nkProcedure,
    nkFunction,
    nkMethod,
    nkField,
    nkProperty,
    nkConst,
    nkVar,
    nkDfmForm,
    nkProject,
    nkSqlTable,
    nkSqlColumn,
    nkSqlIndex,
    nkSqlTrigger,
    nkSqlGenerator,
    nkSqlView,
    nkSqlProcedure,
    nkSqlException,
    nkSqlDomain,
    nkOther
  );
```

Replace the `TGraphEdgeKind` declaration with (new members before `ekOther`):

```pascal
  TGraphEdgeKind = (
    ekCalls,
    ekUses,
    ekInherits,
    ekImplements,
    ekContains,
    ekDfmBinds,
    ekTypeRef,
    ekSqlTableRef,
    ekOther
  );
```

Add the helper to the `interface` section, after the type declarations (before `implementation`):

```pascal
function IsSqlKind(AKind: TGraphNodeKind): Boolean;
```

Add its body in the `implementation` section (e.g. just after the `uses`-less `implementation` keyword, before `constructor TGraphData.Create`):

```pascal
function IsSqlKind(AKind: TGraphNodeKind): Boolean;
begin
  Result := AKind in [nkSqlTable, nkSqlColumn, nkSqlIndex, nkSqlTrigger,
    nkSqlGenerator, nkSqlView, nkSqlProcedure, nkSqlException, nkSqlDomain];
end;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests\console\run.ps1`
Expected: `[PASS] SqlKindClassification`; `0 failed`; exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/control/DragLint.Graph.Types.pas tests/console/Test.Graph.Types.pas
git commit -m "feat: add project + SQL Tier 1 node kinds, typeref/sqltableref edges, IsSqlKind"
```

---

## Task 3: Node hierarchy fields + BuildHierarchy from explicit parent

**Files:**
- Modify: `src/control/DragLint.Graph.Types.pas` (node fields, TGraphData hierarchy)
- Modify: `tests/console/Test.Graph.Types.pas`

- [ ] **Step 1: Write the failing test**

Add to `tests/console/Test.Graph.Types.pas`:

```pascal
function MakeNode(const AId: string; AKind: TGraphNodeKind;
  const AParentId: string): TGraphNode;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Id := AId;
  Result.Label_ := AId;
  Result.Kind := AKind;
  Result.ParentId := AParentId;
  Result.ParentIdx := -1;
  Result.Radius := 12;
end;

procedure Test_HierarchyFromExplicitParent;
var
  D: TGraphData;
  UIdx, FooIdx, BarIdx: Integer;
begin
  D := TGraphData.Create;
  try
    D.AddNode(MakeNode('U', nkUnit, ''));
    D.AddNode(MakeNode('U.TFoo', nkClass, 'U'));
    D.AddNode(MakeNode('U.TFoo.Bar', nkMethod, 'U.TFoo'));
    D.BuildHierarchy;

    UIdx   := D.FindNodeIndex('U');
    FooIdx := D.FindNodeIndex('U.TFoo');
    BarIdx := D.FindNodeIndex('U.TFoo.Bar');

    CheckEqualsInt(UIdx, D.ParentIndexOf(FooIdx), 'TFoo parent is U');
    CheckEqualsInt(FooIdx, D.ParentIndexOf(BarIdx), 'Bar parent is TFoo');
    CheckEqualsInt(1, Length(D.ChildrenOf(UIdx)), 'U has one child');
    CheckEqualsInt(2, D.DescendantCount(UIdx), 'U has two descendants');
    CheckEqualsInt(0, D.DescendantCount(BarIdx), 'Bar has no descendants');
  finally
    D.Free;
  end;
end;
```

Register in `initialization`:

```pascal
  RegisterTest('HierarchyFromExplicitParent', Test_HierarchyFromExplicitParent);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests\console\run.ps1`
Expected: COMPILE FAILED — `ParentId`/`ParentIdx` fields and `BuildHierarchy`/`ParentIndexOf`/`ChildrenOf`/`DescendantCount` not declared.

- [ ] **Step 3: Add node fields**

In `src/control/DragLint.Graph.Types.pas`, in the `TGraphNode` record, add these fields just after `Layer: string;`:

```pascal
    DbId:     Int64;        { originating symbols.id (0 if synthetic) }
    Signature: string;      { symbols.signature (e.g. SQL column type) }
    ParentId: string;       { id of containment parent; '' if none/root }
    ParentIdx: Integer;     { resolved by BuildHierarchy; -1 = root }
    Documented:    Boolean; { has a symbol_docs row }
    Deprecated:    Boolean; { symbol_docs.deprecated }
    IsExternal:    Boolean; { used unit/ref with no in-store target }
    CrossDbTarget: Boolean; { name resolves only in another store }
```

- [ ] **Step 4: Add hierarchy storage + methods to TGraphData**

In the `TGraphData` class declaration, add to `strict private`:

```pascal
    FChildren: TObjectList<TList<Integer>>;  { adjacency, index-aligned }
    procedure BuildChildren;
```

Add to the `public` section:

```pascal
    procedure BuildHierarchy;
    function ParentIndexOf(AIndex: Integer): Integer;
    function ChildrenOf(AIndex: Integer): TArray<Integer>;
    function RootIndices: TArray<Integer>;
    function DescendantCount(AIndex: Integer): Integer;
```

In `constructor TGraphData.Create`, add after `FIndexById := ...`:

```pascal
  FChildren := TObjectList<TList<Integer>>.Create(True);
```

In `destructor TGraphData.Destroy`, add before `FIndexById.Free;`:

```pascal
  FChildren.Free;
```

In `procedure TGraphData.Clear`, add after `FIndexById.Clear;`:

```pascal
  FChildren.Clear;
```

Add the method bodies at the end of the `implementation` (before `end.`):

```pascal
procedure TGraphData.BuildChildren;
var
  I, P: Integer;
begin
  FChildren.Clear;
  for I := 0 to FNodes.Count - 1 do
    FChildren.Add(TList<Integer>.Create);
  for I := 0 to FNodes.Count - 1 do
  begin
    P := NodeAt(I).ParentIdx;
    if (P >= 0) and (P < FNodes.Count) then
      FChildren[P].Add(I);
  end;
end;

procedure TGraphData.BuildHierarchy;
var
  I: Integer;
  N: PGraphNode;
begin
  RebuildIndex;
  for I := 0 to FNodes.Count - 1 do
  begin
    N := NodeAt(I);
    if N.ParentId <> '' then
      N.ParentIdx := FindNodeIndex(N.ParentId)
    else
      N.ParentIdx := -1;
  end;
  BuildChildren;
end;

function TGraphData.ParentIndexOf(AIndex: Integer): Integer;
begin
  Result := NodeAt(AIndex).ParentIdx;
end;

function TGraphData.ChildrenOf(AIndex: Integer): TArray<Integer>;
begin
  if (AIndex >= 0) and (AIndex < FChildren.Count) then
    Result := FChildren[AIndex].ToArray
  else
    Result := nil;
end;

function TGraphData.RootIndices: TArray<Integer>;
var
  I: Integer;
  L: TList<Integer>;
begin
  L := TList<Integer>.Create;
  try
    for I := 0 to FNodes.Count - 1 do
      if NodeAt(I).ParentIdx < 0 then
        L.Add(I);
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function TGraphData.DescendantCount(AIndex: Integer): Integer;
var
  Child: Integer;
begin
  Result := 0;
  if (AIndex < 0) or (AIndex >= FChildren.Count) then Exit;
  for Child in FChildren[AIndex] do
    Result := Result + 1 + DescendantCount(Child);
end;
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pwsh tests\console\run.ps1`
Expected: `[PASS] HierarchyFromExplicitParent`; `0 failed`; exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/control/DragLint.Graph.Types.pas tests/console/Test.Graph.Types.pas
git commit -m "feat: node hierarchy fields + BuildHierarchy from explicit parent"
```

---

## Task 4: Project-root synthesis + contains-edge fallback

**Files:**
- Modify: `src/control/DragLint.Graph.Types.pas` (`BuildHierarchy`)
- Modify: `tests/console/Test.Graph.Types.pas`

- [ ] **Step 1: Write the failing tests**

Add to `tests/console/Test.Graph.Types.pas`:

```pascal
procedure Test_ProjectRootSynthesis;
var
  D: TGraphData;
  Roots: TArray<Integer>;
  ProjIdx: Integer;
begin
  D := TGraphData.Create;
  try
    D.AddNode(MakeNode('UA', nkUnit, ''));
    D.AddNode(MakeNode('UB', nkUnit, ''));
    D.BuildHierarchy;

    Roots := D.RootIndices;
    CheckEqualsInt(1, Length(Roots), 'exactly one root after synthesis');
    ProjIdx := Roots[0];
    Check(D.NodeAt(ProjIdx).Kind = nkProject, 'synthetic root is nkProject');
    CheckEqualsInt(2, Length(D.ChildrenOf(ProjIdx)), 'both units parented to project');
    CheckEqualsInt(3, D.NodeCount, 'project node was appended');
  finally
    D.Free;
  end;
end;

procedure Test_ContainsEdgeFallback;
var
  D: TGraphData;
  E: TGraphEdge;
  UIdx, FooIdx: Integer;
begin
  D := TGraphData.Create;
  try
    D.AddNode(MakeNode('U', nkUnit, ''));            { no explicit ParentId }
    D.AddNode(MakeNode('U.TFoo', nkClass, ''));      { parent only via edge }
    FillChar(E, SizeOf(E), 0);
    E.SourceId := 'U';
    E.TargetId := 'U.TFoo';
    E.Kind := ekContains;
    E.Weight := 1.0;
    D.AddEdge(E);
    D.BuildHierarchy;

    UIdx   := D.FindNodeIndex('U');
    FooIdx := D.FindNodeIndex('U.TFoo');
    CheckEqualsInt(UIdx, D.ParentIndexOf(FooIdx), 'TFoo parent derived from contains edge');
  finally
    D.Free;
  end;
end;
```

Register both in `initialization`:

```pascal
  RegisterTest('ProjectRootSynthesis', Test_ProjectRootSynthesis);
  RegisterTest('ContainsEdgeFallback', Test_ContainsEdgeFallback);
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh tests\console\run.ps1`
Expected: `[FAIL] ProjectRootSynthesis` (2 roots, no nkProject) and `[FAIL] ContainsEdgeFallback` (parent still -1); non-zero exit.

- [ ] **Step 3: Extend BuildHierarchy**

In `src/control/DragLint.Graph.Types.pas`, replace the whole `BuildHierarchy` body with:

```pascal
procedure TGraphData.BuildHierarchy;
var
  I, SrcIdx, DstIdx, ProjectIdx: Integer;
  N: PGraphNode;
  E: TGraphEdge;
  RootlessUnits: TList<Integer>;
  ProjNode: TGraphNode;
begin
  RebuildIndex;

  { 1. explicit ParentId }
  for I := 0 to FNodes.Count - 1 do
  begin
    N := NodeAt(I);
    if N.ParentId <> '' then
      N.ParentIdx := FindNodeIndex(N.ParentId)
    else
      N.ParentIdx := -1;
  end;

  { 2. contains-edge fallback for still-unparented targets }
  for I := 0 to FEdges.Count - 1 do
  begin
    E := FEdges[I];
    if E.Kind <> ekContains then Continue;
    SrcIdx := FindNodeIndex(E.SourceId);
    DstIdx := FindNodeIndex(E.TargetId);
    if (SrcIdx < 0) or (DstIdx < 0) then Continue;
    N := NodeAt(DstIdx);
    if N.ParentIdx < 0 then
      N.ParentIdx := SrcIdx;
  end;

  { 3. project-root synthesis: parent rootless units under a single nkProject }
  ProjectIdx := -1;
  for I := 0 to FNodes.Count - 1 do
    if NodeAt(I).Kind = nkProject then
    begin
      ProjectIdx := I;
      Break;
    end;

  RootlessUnits := TList<Integer>.Create;
  try
    for I := 0 to FNodes.Count - 1 do
    begin
      N := NodeAt(I);
      if (N.Kind = nkUnit) and (N.ParentIdx < 0) then
        RootlessUnits.Add(I);
    end;

    if (RootlessUnits.Count > 0) and (ProjectIdx < 0) then
    begin
      FillChar(ProjNode, SizeOf(ProjNode), 0);
      ProjNode.Id := '@project';
      ProjNode.Label_ := 'Project';
      ProjNode.Kind := nkProject;
      ProjNode.ParentId := '';
      ProjNode.ParentIdx := -1;
      ProjNode.Radius := 16;
      AddNode(ProjNode);                  { appends; FIndexById updated }
      ProjectIdx := FNodes.Count - 1;
    end;

    if ProjectIdx >= 0 then
      for I in RootlessUnits do
        NodeAt(I).ParentIdx := ProjectIdx;
  finally
    RootlessUnits.Free;
  end;

  { 4. adjacency }
  BuildChildren;
end;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh tests\console\run.ps1`
Expected: `[PASS] ProjectRootSynthesis`, `[PASS] ContainsEdgeFallback`, and Task 3's `HierarchyFromExplicitParent` still passes (it has a `nkUnit` root, so a project node is now synthesized — its assertions on `U`/`TFoo`/`Bar` parent indices and descendant counts remain correct); `0 failed`; exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/control/DragLint.Graph.Types.pas tests/console/Test.Graph.Types.pas
git commit -m "feat: project-root synthesis + contains-edge parent fallback"
```

---

## Task 5: Doc/cref/cross-db records + gateway interfaces + fake source

**Files:**
- Modify: `src/control/DragLint.Graph.Types.pas` (result records)
- Create: `src/control/DragLint.Graph.Source.pas` (interfaces)
- Create: `tests/console/Fake.GraphSource.pas`
- Create: `tests/console/Test.Graph.Source.pas`
- Modify: `tests/console/drag_lint_graph_tests.dpr` (register new test unit)

- [ ] **Step 1: Add result records to Types**

In `src/control/DragLint.Graph.Types.pas`, add these declarations to the `interface` `type` section, **after** `TGraphEdge` and **before** `TGraphData`:

```pascal
  TDocParam = record
    Name: string;
    Desc: string;
  end;

  TDocException = record
    TypeName: string;
    Desc: string;
  end;

  TGraphDoc = record
    HasDoc:      Boolean;          { False => undocumented (no symbol_docs row) }
    Format:      string;           { 'xmldoc' | 'pasdoc' | 'oneline' | 'loose' }
    Summary:     string;
    Remarks:     string;
    ReturnsText: string;
    ExampleText: string;
    SinceText:   string;
    Deprecated:  Boolean;
    Params:      TArray<TDocParam>;
    Exceptions:  TArray<TDocException>;
    SeeAlso:     TArray<string>;   { verbatim cref strings }
  end;

  TCrefKind = (crkUrl, crkResolved, crkAmbiguous, crkUnresolved);

  TCrefResolution = record
    Kind:       TCrefKind;
    Text:       string;            { original cref text }
    Url:        string;            { when crkUrl }
    TargetId:   string;            { when crkResolved }
    StoreIndex: Integer;           { when crkResolved }
    Candidates: TArray<string>;    { when crkAmbiguous }
  end;

  TCrossDbResolution = record
    Found:      Boolean;
    StoreIndex: Integer;
    TargetId:   string;
  end;
```

- [ ] **Step 2: Write the gateway interfaces**

Create `src/control/DragLint.Graph.Source.pas`:

```pascal
unit DragLint.Graph.Source;

{ Model gateway interfaces. A single store is read through IGraphSource;
  the ordered set of stores (project / sql / library) is held by IDbCatalog,
  which resolves names across stores in priority order (first-hit-wins).
  Pure: depends only on DragLint.Graph.Types. Implementations (FireDAC sqlite,
  JSON, in-memory fake) live elsewhere. }

interface

uses
  DragLint.Graph.Types;

type
  IGraphSource = interface
    ['{7A2E4C10-1B3D-4F6A-9C8E-2D5F0A1B3C4D}']
    function StoreIndex: Integer;
    function LoadTopology(AData: TGraphData): Boolean;
    function GetDoc(const AQName: string): TGraphDoc;
    function ResolveCref(const AText: string): TCrefResolution;
    function LocateSymbol(const AQName: string; out AFile: string;
      out ALine: Integer): Boolean;
  end;

  IDbCatalog = interface
    ['{3F9B1E22-6C4A-4D8B-A1E3-7B2C9D0E5F61}']
    function StoreCount: Integer;
    function StorePath(AIndex: Integer): string;
    function SourceForStore(AIndex: Integer): IGraphSource;
    function ResolveAcrossStores(const AName: string): TCrossDbResolution;
  end;

implementation

end.
```

- [ ] **Step 3: Write the fake source**

Create `tests/console/Fake.GraphSource.pas`:

```pascal
unit Fake.GraphSource;

{ In-memory IGraphSource for headless tests. Returns a fixed 3-node topology
  (one unit containing one class containing one method) so consumers can be
  exercised without a database. }

interface

uses
  DragLint.Graph.Types,
  DragLint.Graph.Source;

type
  TFakeGraphSource = class(TInterfacedObject, IGraphSource)
  public
    function StoreIndex: Integer;
    function LoadTopology(AData: TGraphData): Boolean;
    function GetDoc(const AQName: string): TGraphDoc;
    function ResolveCref(const AText: string): TCrefResolution;
    function LocateSymbol(const AQName: string; out AFile: string;
      out ALine: Integer): Boolean;
  end;

implementation

uses
  System.SysUtils;

function MakeNode(const AId: string; AKind: TGraphNodeKind;
  const AParentId: string): TGraphNode;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Id := AId;
  Result.Label_ := AId;
  Result.Kind := AKind;
  Result.ParentId := AParentId;
  Result.ParentIdx := -1;
  Result.Radius := 12;
end;

function TFakeGraphSource.StoreIndex: Integer;
begin
  Result := 0;
end;

function TFakeGraphSource.LoadTopology(AData: TGraphData): Boolean;
begin
  if AData = nil then Exit(False);
  AData.Clear;
  AData.AddNode(MakeNode('U', nkUnit, ''));
  AData.AddNode(MakeNode('U.TFoo', nkClass, 'U'));
  AData.AddNode(MakeNode('U.TFoo.Bar', nkMethod, 'U.TFoo'));
  AData.BuildHierarchy;
  Result := True;
end;

function TFakeGraphSource.GetDoc(const AQName: string): TGraphDoc;
begin
  FillChar(Result, SizeOf(Result), 0);
  if AQName = 'U.TFoo.Bar' then
  begin
    Result.HasDoc := True;
    Result.Format := 'xmldoc';
    Result.Summary := 'Fake summary for Bar.';
  end;
end;

function TFakeGraphSource.ResolveCref(const AText: string): TCrefResolution;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Text := AText;
  if AText = 'U.TFoo' then
  begin
    Result.Kind := crkResolved;
    Result.TargetId := 'U.TFoo';
    Result.StoreIndex := 0;
  end
  else
    Result.Kind := crkUnresolved;
end;

function TFakeGraphSource.LocateSymbol(const AQName: string; out AFile: string;
  out ALine: Integer): Boolean;
begin
  AFile := '';
  ALine := 0;
  if AQName = 'U.TFoo' then
  begin
    AFile := 'U.pas';
    ALine := 12;
    Exit(True);
  end;
  Result := False;
end;

end.
```

- [ ] **Step 4: Write the failing test**

Create `tests/console/Test.Graph.Source.pas`:

```pascal
unit Test.Graph.Source;

interface

implementation

uses
  DragLint.Graph.TestFramework,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  Fake.GraphSource;

procedure Test_FakeSourceLoadsTopology;
var
  Src: IGraphSource;
  D: TGraphData;
begin
  Src := TFakeGraphSource.Create;
  D := TGraphData.Create;
  try
    Check(Src.LoadTopology(D), 'LoadTopology returns True');
    CheckEqualsInt(4, D.NodeCount, '3 fixture nodes + synthetic project');
    Check(D.FindNodeIndex('U.TFoo.Bar') >= 0, 'method node present');
    CheckEqualsInt(D.FindNodeIndex('U.TFoo'),
      D.ParentIndexOf(D.FindNodeIndex('U.TFoo.Bar')), 'hierarchy built via source');
  finally
    D.Free;
  end;
end;

procedure Test_FakeSourceDocAndCref;
var
  Src: IGraphSource;
  Doc: TGraphDoc;
  Cref: TCrefResolution;
begin
  Src := TFakeGraphSource.Create;
  Doc := Src.GetDoc('U.TFoo.Bar');
  Check(Doc.HasDoc, 'Bar is documented');
  CheckEqualsStr('Fake summary for Bar.', Doc.Summary, 'doc summary roundtrips');

  Cref := Src.ResolveCref('U.TFoo');
  Check(Cref.Kind = crkResolved, 'known cref resolves');
  CheckEqualsStr('U.TFoo', Cref.TargetId, 'cref target id');

  Cref := Src.ResolveCref('Nope.Missing');
  Check(Cref.Kind = crkUnresolved, 'unknown cref unresolved');
end;

initialization
  RegisterTest('FakeSourceLoadsTopology', Test_FakeSourceLoadsTopology);
  RegisterTest('FakeSourceDocAndCref', Test_FakeSourceDocAndCref);
end.
```

Add the new units to `tests/console/drag_lint_graph_tests.dpr`'s `uses` clause:

```pascal
uses
  System.SysUtils,
  DragLint.Graph.Types in '..\..\src\control\DragLint.Graph.Types.pas',
  DragLint.Graph.Source in '..\..\src\control\DragLint.Graph.Source.pas',
  DragLint.Graph.TestFramework in 'DragLint.Graph.TestFramework.pas',
  Fake.GraphSource in 'Fake.GraphSource.pas',
  Test.Graph.Types in 'Test.Graph.Types.pas',
  Test.Graph.Source in 'Test.Graph.Source.pas';
```

(The `in '..\..\src\control\...'` paths let the IDE resolve the units; `dcc32`
already finds them via the `-U"src\control"` search path in `run.ps1`.)

- [ ] **Step 5: Run test to verify it fails, then passes**

Run: `pwsh tests\console\run.ps1`
Expected first: COMPILE FAILED only if a typo; otherwise the suite compiles and
`[PASS] FakeSourceLoadsTopology` + `[PASS] FakeSourceDocAndCref` appear with
`0 failed`, exit 0. (These are written against code authored in this same task,
so they pass on first green compile — the prior tasks established the
red-green rhythm for the hierarchy logic.)

- [ ] **Step 6: Commit**

```bash
git add src/control/DragLint.Graph.Types.pas src/control/DragLint.Graph.Source.pas tests/console/
git commit -m "feat: doc/cref/cross-db records + IGraphSource/IDbCatalog interfaces + fake source"
```

---

## Self-Review notes (already reconciled)

- **Spec coverage (P1 portion):** node kinds incl. `nkProject` + SQL Tier 1 (Task 2),
  edge kinds `ekTypeRef`/`ekSqlTableRef` (Task 2), hierarchy from `parent_id`/explicit
  parent + contains fallback + project synthesis (Tasks 3-4, spec §5), `TGraphDoc` /
  `TCrefResolution` / `TCrossDbResolution` (Task 5, spec §3.2/§7), `IGraphSource` /
  `IDbCatalog` gateway (Task 5, spec §4). Node flags `Documented`/`Deprecated`/
  `IsExternal`/`CrossDbTarget`/`Signature`/`DbId` (Task 3, spec §5).
- **Deferred to later slices (correctly absent here):** projection/collapse/focus (P2),
  FireDAC reader + enclosing-symbol resolution + real cref/cross-db (P3), styling/View
  (P4), packaging (P5).
- **Type consistency:** `ParentIdx` (-1 = root), `ChildrenOf`/`ParentIndexOf`/
  `RootIndices`/`DescendantCount`, `IsExternal` (avoids the `external` directive),
  `TCrefKind` members `crkUrl/crkResolved/crkAmbiguous/crkUnresolved` are used
  identically across Types, Source, the fake, and the tests.
