# Code Flow View (B) — Design

Date: 2026-06-14
Status: Approved (brainstorming) — pending spec review
Branch (planned): `feat/flow-view` off `feat/graph-viewer-real`
Disposition: experimental — built to be tried, kept, or stashed/discarded.

## 1. Summary

A new **Flow mode** for the graph viewer. From a chosen starting symbol, it
builds a **static call tree** (what this routine calls, transitively) and
renders it as a **vertical flowchart** — top-to-bottom boxes joined by arrows.
Each box is annotated from the symbol's DocInsight record, degrading
gracefully to the bare signature when the symbol is undocumented.

This is the first of a two-part initiative:

- **B (this spec): Code Flow View** — interactive flowchart.
- **C (later): Protocol Walkthrough** — the same call tree rendered as a
  readable prose narrative.

The two share one engine. This spec deliberately isolates that engine so C is
later a *rendering-only* addition.

### Non-goals
- Not a runtime/execution trace. It is a **static** call structure ordered by
  source position; it cannot express "called only if X" or loop counts.
- Not a replacement for the force-directed graph or the structure tree — it is
  an additional mode alongside them.
- In-body `//` comment extraction is **out of scope for v1** (deferred to a
  later optional toggle).

## 2. User-facing behaviour

### Entering Flow mode
- Right-click a node (graph) or a symbol (structure tree) → **"Trace flow from
  here"**, or select a symbol and use a toolbar **Flow** toggle.
- The right pane swaps from the force-directed graph to the flowchart, rooted
  at the chosen symbol. Toggling back restores the graph.

### The flowchart
- Root box at top; its callees below it, connected by arrows; their callees
  below them; depth-first, top-down.
- Sibling callees are ordered by **call-site source line** (the order the calls
  appear in the parent's body).
- A callee called multiple times in one body appears **once** per parent
  (collapsed), positioned at its first call site.

### Two detail modes (global) + per-box override
- A toolbar segmented toggle: **Brief | Expanded** — sets the default for every
  box.
  - **Brief:** `Name(params) — one-line summary`.
  - **Expanded:** adds **parameter descriptions**, **returns & raises**,
    **remarks**, **see-also** (the approved 1+2+3+4).
- Each box has a **⊕ / ⊖** button that overrides that single box against the
  global mode (expand one box while Brief; collapse one while Expanded).

### Graceful degradation (hard requirement)
- Documented symbol → show the doc text for the active mode.
- Undocumented symbol → still show **name + parameters** (from the signature).
  A box is never blank.

### Navigation
- Click a box → selects the corresponding symbol; selection syncs with the
  structure tree (and with the graph when toggled back).
- See-also / exception refs in an expanded box are clickable → re-root the flow
  on that symbol (or jump to its source), reusing the existing cref-resolution
  algorithm.
- Double-click / "open source" → jump to the `.pas` at the symbol's line, same
  mechanism the graph already uses.

### Bounds (readability + safety)
- **Depth cap** (default 6) — deeper branches collapse into a `… N more`
  marker that expands on click.
- **Breadth cap per parent** (default ~12 children) — overflow shown as
  `… N more`.
- **Recursion / cycles** — when a symbol reappears on its own ancestor path,
  its box is marked `(recursion)` and not expanded further.
- **External / unresolved callees** (RTL/lib not in this index, or `refs`
  rows with null `symbol_id`) → terminal box labelled `name [external]`, no
  expansion.

## 3. Architecture

Four units, isolated by clear interfaces. Only the renderer and form-wiring
touch the UI; the engine and source adapter are pure and unit-testable.

### 3.1 `DragLint.Graph.Flow.pas` — the engine (reused by C)
Pure logic, no VCL. Builds the call tree.

```pascal
type
  TFlowStep = record
    SymbolId:   string;        // qualified name (node id)
    Depth:      Integer;       // 0 = root
    CallLine:   Integer;       // call-site line in the PARENT body (sort key)
    Doc:        TGraphDoc;     // from symbol_docs; HasDoc=False if undocumented
    Signature:  string;        // always populated (degradation path)
    Kind:       TGraphNodeKind;
    IsRecursion: Boolean;      // reappears on ancestor path -> not expanded
    IsExternal:  Boolean;      // unresolved / outside this index
    TruncatedChildren: Integer;// >0 => "... N more" beyond a cap
    ChildIndices: TArray<Integer>; // into the flat TFlowTree.Steps
  end;

  TFlowTree = record
    RootId: string;
    Steps:  TArray<TFlowStep>; // flat, parent-before-children
  end;

  TFlowCallee = record
    SymbolId: string;          // resolved qualified name ('' if unresolved)
    CallLine: Integer;         // first call-site line in the parent body
    RawName:  string;          // refs.name_text as written (for [external] label)
  end;

  IFlowSource = interface
    // Direct callees of ASymbolId, ordered by call-site line, de-duplicated.
    function GetCallees(const ASymbolId: string): TArray<TFlowCallee>;
    // Signature + doc for one symbol (degradation when no doc row).
    function GetSymbolInfo(const ASymbolId: string;
      out ASig: string; out AKind: TGraphNodeKind; out ADoc: TGraphDoc): Boolean;
  end;

  TFlowBuilder = class
    constructor Create(const ASource: IFlowSource;
      AMaxDepth, AMaxBreadth: Integer);
    function Build(const ARootId: string): TFlowTree;
  end;
```

The builder owns: depth cap, breadth cap, cycle detection (ancestor-path set),
ordering, and assembling the flat tree. It is the unit C will reuse verbatim.

> **Why the engine queries a source, not the in-memory graph:** the displayed
> `TGraphData` is bounded by the node/ref display caps (see the F8 finding).
> Building a flow from it would silently drop steps. `IFlowSource` queries the
> index directly so a flow is **complete**, independent of what the graph
> currently shows.

### 3.2 DB-backed `IFlowSource`
A thin adapter over the existing DB layer (`DragLint.Graph.Source.Db` /
`IDbCatalog`). Two queries:
- **GetCallees:** `SELECT symbol_id, start_line, name_text FROM refs WHERE
  kind='call' AND <enclosing symbol = ASymbolId>` — resolve the enclosing
  symbol the same way `LoadTopology` already does (file + line range), order by
  `start_line`, collapse duplicate targets to first line. Across a multi-DB
  catalog, query each store (first-hit-wins), mirroring existing resolution.
- **GetSymbolInfo:** `symbols` LEFT JOIN `symbol_docs` by qualified name — the
  query already documented in `docs/doc-comments.md §2B`. NULL doc row →
  `HasDoc=False`.

No change to `TGraphEdge`/`TGraphData` is required.

### 3.3 `DragLint.Graph.Flow.ViewModel.pas` — `TFlowViewModel`
Holds interaction state and drives the view:
- current root, built `TFlowTree`, global mode (`fmBrief|fmExpanded`),
  per-box override set, expanded `… more` markers.
- `SetRoot(id)`, `ToggleGlobalMode`, `ToggleBox(stepIndex)`,
  `ExpandTruncation(stepIndex)`, `NavigateTo(id)`.
- Emits `OnChanged` so the control repaints; emits `OnSelectSymbol` so the host
  syncs the tree/graph.

### 3.4 `DragLint.Graph.FlowControl.pas` — `TFlowChartControl`
A dedicated VCL control (not the force-directed renderer):
- Top-down layout of detail-boxes + connector arrows; vertical scroll + basic
  zoom; box height varies with the active detail level.
- Hit-testing: box select, ⊕/⊖ button, see-also chips, `… N more` markers.
- Renders each box from its `TFlowStep` + per-box state. ASCII/ANSI-safe text.

### 3.5 MainForm wiring
- Add the **Flow** toggle + **Brief/Expanded** segmented control to the
  toolbar; add **"Trace flow from here"** to the graph and tree context menus.
- Swap the right pane between the existing graph control and the new flow
  control. Keep the structure tree + splitter as-is.
- Two-way selection sync: tree ↔ flow (and graph ↔ flow on toggle), reusing the
  existing `FSyncingTree`/selection plumbing.

## 4. Data flow

```
select symbol -> "Trace flow from here"
  -> FlowVM.SetRoot(id)
     -> TFlowBuilder.Build(id)
        -> IFlowSource.GetCallees(...) recursively  [DB, ordered by call line]
        -> IFlowSource.GetSymbolInfo(...) per step  [signature + doc]
        -> depth cap / breadth cap / cycle marks
     -> TFlowTree
  -> FlowControl paints boxes per (global mode, per-box overrides)
  -> user: toggle mode / ⊕⊖ box / click see-also -> FlowVM mutates -> repaint
  -> user: click box -> OnSelectSymbol -> host syncs tree
```

## 5. Error handling & edge cases
- **Root has no callees** → single root box + "no outgoing calls" hint.
- **Symbol not found** (stale id) → message in the pane; stay in graph mode.
- **Unresolved callee** (`symbol_id` null / external) → terminal `[external]`
  box, never expanded.
- **Recursion** → `(recursion)` badge, expansion stops at the repeat.
- **Huge fan-out** → breadth cap + `… N more`; depth cap + `… N more`.
- **Multi-DB miss** → callee resolved in another store is labelled with its
  origin store, consistent with existing cross-DB handling.

## 6. Testing (TDD, console harness — matches `tests/console`)

Engine + adapter carry the coverage; the control is validated manually (it is
an experimental visual surface).

- **Flow engine** (fake `IFlowSource`, no DB, no UI):
  - sibling ordering by call line; duplicate-target collapse to first line.
  - depth cap produces `TruncatedChildren`; breadth cap likewise.
  - cycle/recursion detection sets `IsRecursion` and halts expansion.
  - undocumented symbol → `Doc.HasDoc=False`, `Signature` still populated.
  - external/unresolved callee → `IsExternal`, no children.
- **DB-backed `IFlowSource`** (against existing SQLite fixtures —
  `Test.Db.Fixtures`):
  - `GetCallees` returns correct enclosing→callee mapping, ordered by
    `start_line`.
  - `GetSymbolInfo` joins `symbol_docs` correctly; missing row → `HasDoc=False`.
- **ViewModel:** mode toggle, per-box override, truncation-expand mutate state
  and raise `OnChanged`.

All new `.pas`/test files: strict 7-bit ASCII, CRLF (project rule). New units
get DocInsight `///` summaries on their public surface (the documentation rule
this feature is designed to reward).

## 7. Interaction with the DocInsight standard
This feature is the payoff for the public-surface DocInsight rule: the better a
codebase documents its public methods, the richer Brief/Expanded boxes and the
later Protocol Walkthrough become. Undocumented code still yields a usable
name+params flow — so the feature is valuable immediately and improves as docs
accrue.

## 8. Deferred / future (not in v1)
- **C — Protocol Walkthrough:** reuse `TFlowBuilder`; render the tree as prose.
- **In-body comment extraction:** read `.pas` between a symbol's line range,
  surface `//` comments behind a "show source notes" toggle.
- **Caller direction** (inverse flow) — "what reaches this": existing
  "Where used" partly covers it.
```
