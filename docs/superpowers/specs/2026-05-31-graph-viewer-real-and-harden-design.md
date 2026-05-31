# Design: Make the viewer real + harden the skeleton (DB-direct, MVVM)

Date: 2026-05-31
Project: Delphi-RAG-Lint-Graph
Status: approved design (revised), pre-implementation

## 1. Context

Phase 0 delivered a working pure-VCL skeleton: `TGraphData` (value-record node
store + id index), a Fruchterman-Reingold force layout, a `TCustomControl`
renderer with pan/zoom/hover/click, a forgiving JSON loader, a viewer EXE, and a
launch-only smoke test.

Two inputs reshaped the design after Phase 0:

1. **The drag-lint team's data contract** (`docs/doc-comments.md` + the
   authoritative schema `Delphi-RAG-lint/src/storage/DRagLint.Storage.Schema.pas`,
   now **v5 / v0.40.4**). The analyzer already persists everything we need in a
   SQLite database; we should read it directly, not invent a JSON dump.
2. **Two architecture decisions**: the viewer reads **topology and docs directly
   from the drag-lint SQLite DB via FireDAC**, and the **rendering/projection core
   stays FireDAC-free** (FireDAC isolated behind a data-source interface).
3. **MVVM**: structure the component as Model / ViewModel / View ("near MVVM",
   lightweight observer + command objects, not LiveBindings) so the logic is
   flexible and unit-testable without a UI.

Ultimate goal: a **ship-ready, reusable VCL component** (`TDragLintGraphControl`).
The eventual headline feature is **semantic / level-of-detail (LOD) zoom** over
40k-node Micronite-scale graphs (deferred).

## 2. Goal of this round

1. **Make the viewer real** against the live drag-lint DB: kind styling + legend,
   neighborhood focus, expand/collapse by containment, and click-to-navigate along
   `uses` edges (interface vs implementation) and documentation cross-references.
2. **Harden the skeleton**: MVVM layering, component-first packaging, a clean
   public API, a real (asserting) headless test harness, and cleanup of the loose
   ends Phase 0 left behind.

LOD auto-zoom, in-viewer fuzzy search, Barnes-Hut/threaded layout, and the
`TStyleManager` theming pass remain explicitly deferred (Section 14).

## 3. The drag-lint database contract (what we read)

SQLite, opened read-only via FireDAC. Tables we consume:

| Table | Use |
|-------|-----|
| `files` | path / language; used to resolve `target_file_id` -> unit, and for open-in-source. |
| `symbols` | one row per declaration: `id, file_id, parent_id, kind, name, qualified_name, signature, modifiers, start/end line/col`. Becomes graph **nodes**; `parent_id` becomes **containment**. |
| `refs` | reference sites: `symbol_id` (resolved target), `file_id` + location (the site), `kind`, `name_text`. Source of **call / type_use / event-binding** edges. |
| `unit_uses` (v5) | `file_id, unit_name, unit_name_norm, section, in_path, target_file_id, location`. Source of **uses** edges, with interface/implementation `section`. |
| `symbol_docs` | per-symbol documentation, fetched lazily; crefs in `seealso_json`. |

### 3.1 Edge derivation (the real work)

There is **no edges table**. Edges are derived:

- **Containment** (`ekContains`): `symbols.parent_id`. Drives the hierarchy
  (Section 5); not necessarily drawn as a visible edge.
- **Uses** (`ekUses`, carries `section`): `unit_uses`. Source = the `kind='unit'`
  symbol whose `file_id` matches; target = the unit symbol in `target_file_id`
  (resolved) or a synthetic **external** unit node when `target_file_id IS NULL`
  (e.g. RTL units not indexed). `section` = interface | implementation | program |
  package.
- **Calls** (`ekCalls`): `refs WHERE kind='call'`. Target = `refs.symbol_id`;
  **source = the symbol whose `[start..end]` range in the same `file_id` encloses
  the ref site** (innermost). `refs` does not store the source symbol, so the
  reader resolves it via an enclosing-range lookup.
- **Type references** (`ekTypeRef`, NEW enum): `refs WHERE kind='type_use'`. Same
  enclosing-source resolution. drag-lint buckets inheritance/implements/field-type
  all under `type_use`; we do not attempt to split them.
- **DFM bindings** (`ekDfmBinds`): `refs WHERE kind='event-binding'`.

Unresolved refs (`refs.symbol_id IS NULL`) and external uses become **external /
unresolved nodes**, flagged so the View can style them distinctly and so focus
does not treat them as first-class.

### 3.2 Documentation & crefs (lazy, render-time)

- Docs live in `symbol_docs` (0/1 row per symbol). Fetched **on selection**, not
  at topology build, via the Model gateway. NULL row => undocumented (distinct
  from empty summary).
- `seealso_json` holds verbatim cref strings; drag-lint does **not** pre-resolve
  them. The ViewModel resolves at render time per the team's algorithm: external
  URL -> exact `qualified_name` -> bare `name` (disambiguate if many) -> multi-DB
  repeat -> unresolved ("?"). Resolution is surfaced as clickable chips in the
  detail panel (Section 8), not as base-graph edges (avoids edge explosion).
- `deprecated` and undocumented are cheap left-join signals used for node styling.

### 3.3 Known DB limitations to honor

Parameters/locals are not indexed (parse `signature` text instead); inherited
member docs are not auto-merged (walk the chain if needed); JSON columns are TEXT
(use `json_each` on Win64, else parse client-side on Win32). Multi-DB projects
(CLIENT/SERVER/COMMON) require opening several DBs and merging; first-hit-wins on
cref resolution, recording the originating DB for correct open-in-source.

> Note: `docs/doc-comments.md` prose still reads v0.40.3 and does not yet describe
> `unit_uses`; the capability is confirmed in the v5 schema. Flagged to drag-lint
> to update the prose.

## 4. Architecture: near-MVVM with a dependency-free core

```
                 +-------------------- View (VCL) --------------------+
                 |  TDragLintGraphControl  (passive renderer)         |
                 |  paints projection via Style; forwards input;      |
                 |  subscribes to VM change events -> Invalidate      |
                 +------------------------+---------------------------+
                                          | IGraphViewModel (commands + observable state)
                 +------------------------v---------------------------+
                 |             ViewModel (pure, no VCL/FireDAC)        |
                 |  TGraphViewModel: view state (collapse/focus/sel),  |
                 |  derives TGraphProjection, exposes commands,        |
                 |  lazy SelectedDoc, cref resolution                  |
                 +------+----------------------------+-----------------+
                        | uses                        | uses
            +-----------v-----------+      +----------v------------+
            | Layout (pure service) |      | Style (pure data)     |
            +-----------------------+      +-----------------------+
                        | reads / builds
                 +------v---------------------------------------------+
                 |              Model (pure, no VCL/FireDAC)           |
                 |  TGraphData (raw nodes/edges + hierarchy),          |
                 |  TGraphDoc, TCrefResolution; IGraphSource gateway   |
                 +------------------------+---------------------------+
                                          | IGraphSource
              +---------------------------+----------------------------+
              |                                                        |
   +----------v-----------+                            +---------------v--------------+
   | Source.Db (FireDAC)  |  <-- ONLY unit linking     | Source.Json (optional,       |
   | sqlite, multi-DB     |      FireDAC               | retained for portability)    |
   +----------------------+                            +------------------------------+
```

### Units

| Unit | State | Layer | Responsibility |
|------|-------|-------|----------------|
| `DragLint.Graph.Types`        | exists, extended | Model | Raw records + `TGraphData` + hierarchy; `TGraphDoc`, `TCrefResolution`. Pure. |
| `DragLint.Graph.Source`       | NEW | Model | `IGraphSource` gateway interface: `LoadTopology`, `GetDoc`, `ResolveCref`, `LocateSymbol`. Pure (interface only). |
| `DragLint.Graph.Source.Db`    | NEW | Model | FireDAC sqlite implementation; multi-DB; the **only** FireDAC-linking unit. |
| `DragLint.Graph.Source.Json`  | from existing Json | Model | Optional secondary `IGraphSource` over a JSON dump; existing loader adapted. |
| `DragLint.Graph.ViewModel`    | NEW | ViewModel | `TGraphViewModel`/`IGraphViewModel`: state, projection, commands, observable events. Pure. |
| `DragLint.Graph.Layout`       | exists, adjusted | service | Positions a projection's visible node set. Pure. |
| `DragLint.Graph.Style`        | NEW | service | Kind/edge -> visual mapping + legend entries. Pure data; no Canvas. |
| `DragLint.Graph.Control`      | exists, slimmed | View | Passive VCL renderer + input forwarder bound to an `IGraphViewModel`. VCL-only, no FireDAC. |

**Dependency rule:** Model (minus `Source.Db`), ViewModel, Layout, and Style link
**neither VCL nor FireDAC** and compile into the headless console test EXE. The
View links VCL but not FireDAC. Only `Source.Db` links FireDAC.

## 5. Data model & containment hierarchy

Explicit 4-level forest, derived at topology build:

```
Project          nkProject   (synthetic root; no DB row -> injected)
 +- Unit         nkUnit       (symbols.kind = 'unit')
     +- Object   nkClass / nkInterface / nkRecord / nkType
     |   +- Method     nkMethod / nkProcedure / nkFunction
     |   +- Property   nkProperty / nkField
     +- unit-level routine / const / var   (Level-2 sibling of Objects)
```

- **Parent** = `symbols.parent_id` (mapped DB id -> node index). Rootless units are
  parented under the synthetic `nkProject`. Single-parent (a forest).
- Node id = `symbols.qualified_name` (stable, matches cref text). Node carries
  `DbId`, `FilePath` (via `file_id`), `Line/Col`, `Documented`, `Deprecated`,
  `External` flags.
- `symbols.kind` text maps to `TGraphNodeKind` forgivingly (unknown -> `nkOther`).

## 6. Projection semantics (ViewModel)

### Collapse / expand
- Collapsible iff it has children. Collapsing `U` hides descendants; `U` stays
  visible with a collapsed affordance (`+N` count, distinct outline). Visible iff
  no ancestor collapsed.
- **Edge aggregation:** map each edge endpoint to its nearest *visible* ancestor;
  same target -> drop (internal); else emit an aggregated edge, merging duplicates
  (count + summed weight). Mixed kinds -> "aggregated" style.

### Neighborhood focus
- Distinct from selection. Default **dims** non-neighbors; `Isolate` toggle hides
  them. Default radius **1 hop**, adjustable. Runs over the visible projection, so
  collapse + focus compose.

## 7. ViewModel API (commands + observable state)

```pascal
IGraphViewModel = interface
  // load / source
  procedure SetSource(const ASource: IGraphSource);
  procedure Reload;
  // projection (read state)
  function  Projection: TGraphProjection;          // visible nodes + aggregated edges
  function  SelectedNode: PGraphNode;               // nil if none
  function  SelectedDoc: TGraphDoc;                 // lazily fetched on selection
  // commands
  procedure Collapse(const AId: string);
  procedure Expand(const AId: string);
  procedure ToggleCollapse(const AId: string);
  procedure CollapseAll; procedure ExpandAll;
  procedure SelectNode(const AId: string);
  procedure SetFocus(const AId: string; AHops: Integer = 1);
  procedure ClearFocus;
  procedure NavigateTo(const AId: string);          // select + center + expand one level
  function  ResolveCref(const AText: string): TCrefResolution;
  procedure OpenSource(const AId: string);          // via IGraphSource.LocateSymbol + host opener
  // observable (lightweight observer; Spring4D-style multicast)
  property  OnChanged: IEvent;                      // projection/layout invalidated
  property  OnSelectionChanged: IEvent;
  property  Isolate: Boolean read ... write ...;
end;
```

The ViewModel never references VCL. `NavigateTo`/`OpenSource` delegate the actual
editor jump to a host-supplied opener callback (`ShellExecute` in standalone,
`IOTAActionServices.OpenFile` in IDE mode).

## 8. View: control bindings & detail rendering

Default bindings (host may rebind): left-click = `SelectNode`; double-click
collapsible = `ToggleCollapse`; double-click leaf = `NavigateTo`; Ctrl+click =
`OpenSource`; click a `uses` edge line = `NavigateTo` far endpoint; `F` = focus
selected; `Esc` = clear focus; drag/wheel = pan/zoom.

The control is a passive renderer: on `OnChanged` it re-runs layout (if topology
changed) and repaints. Documentation UX follows the team's recommendation — the
**host** renders a detail panel from `SelectedDoc`: summary, params grid, returns,
then `seealso` as clickable chips. Each chip calls `ResolveCref`; resolved ->
`NavigateTo`/`OpenSource`, ambiguous -> candidate menu, unresolved -> dim "?" with
tooltip. Crefs are panel chips, not graph edges.

## 9. Kind styling + legend (`DragLint.Graph.Style`)

Pure-data tables: `TGraphNodeKind` -> fill/shape; `TGraphEdgeKind` -> pen
(color/width/dash) + directed arrowheads. Interface-vs-implementation `uses`,
`type_use`, `call`, and aggregated edges each get distinct pens. `External`,
undocumented, and `deprecated` nodes get distinct borders. The control paints a
toggleable legend of kinds present in the current projection. Built-in palette;
funneled through `Style` so the later `TStyleManager` swap is localized.

## 10. Layout

Operates on the projection's visible node set each relayout. Collapsed node radius
scales with descendant count. Synchronous O(N^2) this round (fine for the
hundreds-to-low-thousands visible after collapse). Barnes-Hut / threaded layout
for 40k nodes deferred. `TGraphLayout.Reset` dead code removed.

## 11. Packaging (component-first)

- **`DragLintGraph.bpl`** (runtime core, requires VCL, **not** FireDAC): Types,
  Source (interface), ViewModel, Style, Layout, Control.
- **`DragLintGraphDb.bpl`** (requires FireDAC + the bundled sqlite driver):
  `Source.Db` only — so consumers feeding their own `TGraphData`/`IGraphSource`
  never pull FireDAC.
- **`dclpkg/DragLintGraphDcl.bpl`** (design-time): registers
  `TDragLintGraphControl` on a "Delphi-RAG-Lint" palette page.
- **Demo host EXE**: wires `TGraphViewModel` + `Source.Db` (open a `.sqlite`) into
  the control, renders the detail panel. The EXE is a test host, not the product.
- `build/build_all.bat`: builds the BPLs + demo EXE, then runs the console harness.

## 12. Testing & hardening

- **Console harness** (non-VCL, links Types/Source/Source.Db/ViewModel/Style/Layout):
  asserts on real behavior. Builds a **temp sqlite from checked-in fixture `.sql`
  scripts** (transparent, diffable) covering files/symbols/refs/unit_uses/symbol_docs,
  plus a fake in-memory `IGraphSource` for pure-VM tests. Assertions: topology build
  (containment from `parent_id`, project-root synthesis, enclosing-symbol resolution
  for call/type_use, unit_uses source/target + section, external/unresolved
  flagging), projection (collapse hides descendants, edge aggregation merges/drops,
  N-hop focus set), doc fetch (undocumented vs empty), and cref resolution (URL /
  exact / bare / ambiguous / unresolved). Exit 0 = green.
- **Integration smoke**: run real drag-lint on a tiny sample project to produce a
  `.sqlite`, open it via `Source.Db`, assert non-empty topology — guards the real
  schema, not just fixtures.
- **Launch smoke** (`run_smoke.ps1`): kept for the GUI host; fixed to the real
  build output path; backed by the asserting harness for logic.
- **Loose-end cleanup**: remove dead `TGraphLayout.Reset`; rewrite README (DB-direct,
  MVVM, dependency story: core dep-free, DB source needs FireDAC, still zero-network);
  reconcile `dclpkg/`/`build_all.bat`; all new `.pas` strict ASCII / CRLF.

## 13. Open dependencies & risks

- **`docs/doc-comments.md` prose lags the schema** (no `unit_uses` description).
  Capability verified in v5 schema; ask drag-lint to update the prose.
- **Enclosing-symbol resolution** for `refs` is the trickiest reader logic
  (range-containment, innermost wins). Must be unit-tested directly.
- **Multi-DB** open/merge + cref first-hit-wins is real complexity; scope it as a
  capability of `Source.Db` and test with two fixture DBs.
- **Win32 sqlite JSON1** may be too old for `json_each`; client-side parse of
  `seealso_json` as fallback.
- **Schema drift**: pin to `SCHEMA_VERSION = 5`; `Source.Db` checks `schema_meta`
  and fails clearly on mismatch.

## 14. Explicitly deferred (out of scope this round)

- Semantic / level-of-detail auto-zoom. The 4-level hierarchy + manual
  collapse/expand + navigate built here is its foundation.
- In-viewer fuzzy search (drag-lint already has trigram search; surface later).
- Barnes-Hut quadtree + threaded/async layout for 40k+ nodes.
- `TStyleManager` theme integration (palette funneled through `Style`).
- A `graph --format json` exporter (the `Source.Json` path stays a thin
  portability option; the DB is the primary source).
