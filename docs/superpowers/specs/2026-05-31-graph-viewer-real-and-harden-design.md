# Design: Make the viewer real + harden the skeleton (DB-direct, MVVM)

Date: 2026-05-31
Project: Delphi-RAG-Lint-Graph
Status: approved design (revised x2), pre-implementation

## 1. Context

Phase 0 delivered a working pure-VCL skeleton: `TGraphData` (value-record node
store + id index), a Fruchterman-Reingold force layout, a `TCustomControl`
renderer with pan/zoom/hover/click, a forgiving JSON loader, a viewer EXE, and a
launch-only smoke test.

Inputs that shaped this design, from the drag-lint team's contract docs under
`docs/` (`doc-comments.md`, `unit-uses.md`, `cross-db-symbols.md`,
`sql-symbols.md`) and the authoritative schema
`Delphi-RAG-lint/src/storage/DRagLint.Storage.Schema.pas` (**v5 / v0.40.5-alpha**):

1. **DB-direct.** Topology and docs come straight from the drag-lint SQLite DB(s)
   via FireDAC, not a JSON dump. JSON is demoted to an optional portability path.
2. **Dependency-free core.** Rendering/projection/ViewModel link neither FireDAC
   nor (mostly) VCL; FireDAC is isolated behind a data-source interface.
3. **Near-MVVM.** Model / ViewModel / View with a lightweight observer + command
   objects (not LiveBindings), so logic is unit-testable headlessly.
4. **One graph per DB, jump across DBs.** Stores are never merged into one graph
   (some are huge). Cross-DB references are *navigation jumps* with a back-stack.
5. **Minimal SQL Tier 1.** SQL DDL symbols render as first-class nodes; rich SQL
   visuals and the planned Firebird-snapshot / ORM-linker tiers are deferred.

**Deconfliction note:** `Delphi-RAG-lint/docs/superpowers/specs/2026-05-29-graphing-
component-design.md` is a **declined** drag-lint-side proposal for a same-named
`TDragLintGraphControl` / `drag-lint-graph.exe` built on **WebView2 + Cytoscape.js**
with an HTTP dashboard. It was rejected in favor of this **pure-VCL** repo (README:
no WebView2, no HTML/JS) - confirmed by the user. The shared `TDragLintGraphControl`
/ `drag-lint-graph.exe` names are intentionally inherited by this implementation;
this repo's palette page is `'Delphi-RAG-Lint'`.

Ultimate goal: a ship-ready, reusable VCL component. The eventual headline feature
is semantic / level-of-detail (LOD) zoom over 40k-node Micronite-scale graphs
(deferred, Section 14).

## 2. Goal of this round

1. **Make the viewer real** against the live drag-lint DB: kind styling + legend,
   neighborhood focus, expand/collapse by containment, click-to-navigate along
   `uses` edges (interface vs implementation) and documentation cross-references,
   cross-DB jump navigation, and Minimal SQL Tier 1 rendering.
2. **Harden the skeleton**: MVVM layering, component-first packaging, a clean
   public API, a real (asserting) headless test harness, and cleanup of Phase 0
   loose ends.

Deferred (Section 14): LOD auto-zoom, in-viewer fuzzy search, unit-graph analysis
utilities (circular/move-down/unused/coverage), SQL Tier 2/3, rich SQL visuals,
Barnes-Hut/threaded layout, `TStyleManager` theming.

## 3. The drag-lint database contract (what we read)

SQLite, opened read-only via FireDAC. One graph is built from **one active store**
(Section 3.3). Tables consumed per store:

| Table | Use |
|-------|-----|
| `files` | path / language; resolve `target_file_id` -> unit; open-in-source. |
| `symbols` | one row per declaration (Delphi **and** SQL DDL): `id, file_id, parent_id, kind, name, qualified_name, signature, ...`. Becomes **nodes**; `parent_id` becomes **containment**. |
| `refs` | reference sites: `symbol_id` (resolved target), `file_id` + location, `kind`, `name_text`. Source of **call / type_use / event-binding / sql_table_ref** edges. |
| `unit_uses` | `file_id, unit_name, unit_name_norm, section, in_path, target_file_id, ...`. Source of **uses** edges with interface/implementation `section`. |
| `symbol_docs` | per-symbol documentation, fetched lazily; crefs in `seealso_json`. |

### 3.1 Edge derivation (the real work)

No edges table. Edges are derived:

- **Containment** (`ekContains`): `symbols.parent_id`. Drives the hierarchy
  (Section 5); not necessarily drawn.
- **Uses** (`ekUses`, carries `section`): `unit_uses`. Source = the `kind='unit'`
  symbol of `file_id`; target = the unit of `target_file_id` (resolved) or a
  synthetic **external** unit node when NULL. Per `unit-uses.md` resolution is
  best-effort, by bare unit name (last-file-wins); ~10-20% resolved in a project
  DB. Multi-section uses of the same unit collapse to one visual edge (tooltip
  lists sections).
- **Calls** (`ekCalls`): `refs WHERE kind='call'`. Target = `refs.symbol_id`;
  **source = the symbol whose line/col range encloses the ref site** (innermost) -
  `refs` stores no source symbol, so the reader resolves it by enclosing range.
- **Type references** (`ekTypeRef`): `refs WHERE kind='type_use'` (inheritance /
  implements / field-type all bucketed; not split). Same enclosing-source resolution.
- **DFM bindings** (`ekDfmBinds`): `refs WHERE kind='event-binding'`.
- **SQL table refs** (`ekSqlTableRef`): `refs WHERE kind='sql_table_ref'` (trigger
  or index -> table, by `name_text`).

Unresolved refs (`symbol_id IS NULL`) and external uses become **external /
unresolved nodes**, flagged so the View styles them distinctly and focus does not
treat them as first-class. A reference whose name resolves only in *another* store
becomes a **cross-DB link** (Section 3.3), not an in-graph edge.

### 3.2 Documentation & crefs (lazy, render-time)

- Docs live in `symbol_docs` (0/1 row per symbol). Fetched **on selection**, not at
  topology build. NULL row => undocumented (distinct from empty summary).
- `seealso_json` holds verbatim cref strings; drag-lint does not pre-resolve them.
  The ViewModel resolves at render time: external URL -> exact `qualified_name` ->
  bare `name` (disambiguate if many) -> other stores -> unresolved ("?"). Surfaced
  as clickable chips in the host detail panel (Section 8), not base-graph edges.
- `deprecated` and undocumented are cheap left-join signals for node styling.

### 3.3 Multi-DB: one graph per store, jump across stores

There are **no cross-DB foreign keys**; each `--db` is an independent store. We do
**not** merge stores into one graph. Instead:

- The viewer is configured with an **ordered DB set** (priority order, e.g.
  `[project, sql, library]`). Exactly **one store is active**; the graph shows only
  that store's symbols - no artifacts from other stores.
- An `IDbCatalog` holds the ordered set and can (a) create an `IGraphSource` for a
  given store, and (b) **resolve a qname/name across the set** in priority order
  (first-hit-wins, mirroring the LSP), returning `(storeIndex, symbol)`.
- A reference whose target lives in another store renders as a **cross-DB link
  affordance** (distinct marker/stub, not a merged edge). Activating it resolves the
  target via `IDbCatalog` and is handled by **host policy** (below).
- **Host-policy jump seam (key design point).** The ViewModel does not assume a
  window model. It resolves the target `(storeIndex, symbol)` and raises
  `OnCrossDbJumpRequested`. The host decides what to do:
  - **This round (in-place):** the host calls `OpenStore(targetIndex)` +
    `NavigateTo(target)` on the *same* control - swap the active `IGraphSource`, load
    the target store's graph, focus the symbol. `JumpToCrossDb` is a convenience that
    does exactly this in-place.
  - **Later (host-only change):** spawn a new form / split view bound to a fresh
    ViewModel opened on the target store. No control/VM changes required - hence we do
    not build multi-window now (it is not simpler, and would add window management
    with no benefit this round).
- A **navigation back-stack** records `(storeIndex, selectedId, collapse/focus
  state)` per entry; Back pops and restores - across store boundaries too. Recently
  loaded graphs may be cached to make Back cheap on large stores (optimization, not
  required for correctness).
- **Split-screen / second window** for two stores side by side is a deferred option,
  enabled purely by the host-policy seam above.

`db_index` therefore identifies the active store and the jump target; it is not a
per-node merge tag in our model.

### 3.4 SQL symbols (Minimal Tier 1)

SQL DDL symbols share the `symbols` table, distinguished by `kind`: `sql_table`,
`sql_column`, `sql_index`, `sql_trigger`, `sql_generator`, `sql_view`,
`sql_procedure`, `sql_exception`, `sql_domain`. Columns are parented to their table
via `parent_id` (same shape as class fields), so containment "just works".
`signature` carries the column type. Recommended deployment is a separate
`drag-lint-sql.sqlite` passed as another store - which the one-graph-per-DB + jump
model already handles. This round maps these kinds to first-class nodes with a
*simple distinct* style; rich per-kind shapes/icons and Tier 2/3 are deferred.

### 3.5 Known DB limits to honor

Parameters/locals not indexed (parse `signature`); inherited docs not auto-merged;
JSON columns are TEXT (`json_each` on Win64, client-side parse on Win32); generics
collapse (`IList<string>` -> `IList`); `unit_uses` conditional-compilation branches
not distinguished; `target_file_id` bare-name resolution can mis-pick on collisions.

> Note: `docs/doc-comments.md` prose still reads v0.40.3 and omits `unit_uses`;
> capability verified in the v5 schema. Flagged to drag-lint to update the prose.

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
                 |  projection, commands, nav back-stack, lazy doc,    |
                 |  cref + cross-DB resolution (via IDbCatalog)        |
                 +------+----------------------------+-----------------+
                        | uses                        | uses
            +-----------v-----------+      +----------v------------+
            | Layout (pure service) |      | Style (pure data)     |
            +-----------------------+      +-----------------------+
                        | builds / reads
                 +------v---------------------------------------------+
                 |              Model (pure, no VCL/FireDAC)           |
                 |  TGraphData (raw nodes/edges + hierarchy),          |
                 |  TGraphDoc, TCrefResolution; IGraphSource,          |
                 |  IDbCatalog gateways                                |
                 +------------------------+---------------------------+
                                          | IGraphSource / IDbCatalog
              +---------------------------+----------------------------+
   +----------v-----------+                            +--------------v---------------+
   | Source.Db (FireDAC)  |  <-- ONLY FireDAC-linking  | Source.Json (optional,       |
   | sqlite, per store    |      unit                  | portability/fixtures)        |
   +----------------------+                            +------------------------------+
```

### Units

| Unit | State | Layer | Responsibility |
|------|-------|-------|----------------|
| `DragLint.Graph.Types`        | exists, extended | Model | Raw records + `TGraphData` + hierarchy; `TGraphDoc`, `TCrefResolution`. Pure. |
| `DragLint.Graph.Source`       | NEW | Model | `IGraphSource` (per-store gateway: `LoadTopology`, `GetDoc`, `ResolveCref`, `LocateSymbol`) + `IDbCatalog` (ordered store set, cross-store resolve, source factory). Interfaces only. Pure. |
| `DragLint.Graph.Source.Db`    | NEW | Model | FireDAC sqlite implementation; the **only** FireDAC-linking unit. |
| `DragLint.Graph.Source.Json`  | from existing Json | Model | Optional secondary `IGraphSource` over a JSON dump. |
| `DragLint.Graph.ViewModel`    | NEW | ViewModel | `TGraphViewModel`/`IGraphViewModel`: state, projection, commands, nav stack, observable events. Pure. |
| `DragLint.Graph.Layout`       | exists, adjusted | service | Positions a projection's visible node set. Pure. |
| `DragLint.Graph.Style`        | NEW | service | Kind/edge -> visual mapping + legend. Pure data; no Canvas. |
| `DragLint.Graph.Control`      | exists, slimmed | View | Passive VCL renderer + input forwarder bound to an `IGraphViewModel`. VCL-only, no FireDAC. |

**Dependency rule:** Model (minus `Source.Db`), ViewModel, Layout, Style link
neither VCL nor FireDAC and compile into the headless console test EXE. The View
links VCL but not FireDAC. Only `Source.Db` links FireDAC.

## 5. Data model & containment hierarchy

Explicit hierarchy forest, derived at topology build:

```
Project          nkProject   (synthetic root; injected)
 +- Unit         nkUnit                              | SQL store:
     +- Object   nkClass / nkInterface / nkRecord    |  Table   nkSqlTable
     |   +- Method   nkMethod / nkProcedure / nkFunc  |   +- Column  nkSqlColumn
     |   +- Property nkProperty / nkField             |  Index/Trigger/View/Proc/
     +- unit-level routine / const / var              |  Generator/Exception/Domain
```

- **Parent** = `symbols.parent_id` (DB id -> node index). Rootless units parented
  under the synthetic `nkProject`. Single-parent forest.
- Node id = `qualified_name`. Node carries `DbId`, `FilePath`, `Line/Col`,
  `Documented`, `Deprecated`, `External`, `CrossDbTarget` flags, `Signature`.
- `symbols.kind` text -> `TGraphNodeKind` forgivingly. NEW kinds this round:
  `nkProject`; SQL Tier 1 kinds (`nkSqlTable`, `nkSqlColumn`, `nkSqlIndex`,
  `nkSqlTrigger`, `nkSqlGenerator`, `nkSqlView`, `nkSqlProcedure`,
  `nkSqlException`, `nkSqlDomain`). Unknown -> `nkOther`.
- NEW edge kinds: `ekTypeRef`, `ekSqlTableRef`.

## 6. Projection semantics (ViewModel)

### Collapse / expand
- Collapsible iff it has children. Collapsing `U` hides descendants; `U` stays
  visible with a `+N` affordance. Visible iff no ancestor collapsed.
- **Edge aggregation:** map each endpoint to its nearest visible ancestor; same
  target -> drop (internal); else emit an aggregated edge, merging duplicates
  (count + summed weight). Mixed kinds -> "aggregated" style.

### Neighborhood focus
- Distinct from selection. Default **dims** non-neighbors; `Isolate` toggle hides
  them. Default radius **1 hop**, adjustable. Runs over the visible projection.

### Navigation & back-stack
- `NavigateTo(id)` within the active store: select + center + expand one level; push
  prior state. Cross-DB jump (Section 3.3): swap active source, load, focus; push.
- `Back` pops and restores `(store, selection, collapse/focus)`.

## 7. ViewModel API (commands + observable state)

```pascal
IGraphViewModel = interface
  procedure SetCatalog(const ACatalog: IDbCatalog);   // ordered store set
  procedure OpenStore(AStoreIndex: Integer);          // make a store active + load
  function  ActiveStoreIndex: Integer;
  // read state
  function  Projection: TGraphProjection;
  function  SelectedNode: PGraphNode;
  function  SelectedDoc: TGraphDoc;                    // lazy on selection
  function  CanGoBack: Boolean;
  // commands
  procedure Collapse(const AId: string);
  procedure Expand(const AId: string);
  procedure ToggleCollapse(const AId: string);
  procedure CollapseAll; procedure ExpandAll;
  procedure SelectNode(const AId: string);
  procedure SetFocus(const AId: string; AHops: Integer = 1);
  procedure ClearFocus;
  procedure NavigateTo(const AId: string);             // same-store
  function  ResolveCrossDb(const AName: string): TCrossDbResolution;  // (storeIndex, symbol)
  procedure JumpToCrossDb(const AName: string);        // convenience: in-place resolve + swap + focus
  procedure Back;
  function  ResolveCref(const AText: string): TCrefResolution;
  procedure OpenSource(const AId: string);             // host opener callback
  // observable (Spring4D-style multicast events)
  property  OnChanged: IEvent;
  property  OnSelectionChanged: IEvent;
  property  OnStoreChanged: IEvent;
  property  OnCrossDbJumpRequested: IEvent;            // host policy: in-place vs new form/split
  property  Isolate: Boolean read ... write ...;
end;
```

The ViewModel never references VCL. `NavigateTo`/`JumpToCrossDb`/`OpenSource`
delegate editor jumps to a host-supplied opener (`ShellExecute` standalone,
`IOTAActionServices.OpenFile` in IDE mode), and resolve target file paths via the
originating store's `files.path`.

## 8. View: control bindings & detail rendering

Default bindings (host may rebind): left-click = `SelectNode`; double-click
collapsible = `ToggleCollapse`; double-click leaf = `NavigateTo`; click a `uses`
edge = `NavigateTo` far endpoint; click a **cross-DB link** = `JumpToCrossDb`;
Ctrl+click = `OpenSource`; `Backspace`/Alt+Left = `Back`; `F` = focus selected;
`Esc` = clear focus; drag/wheel = pan/zoom.

Passive renderer: on `OnChanged` re-run layout (if topology changed) and repaint; on
`OnStoreChanged` rebuild for the new active store. Documentation UX follows the
team's recommendation - the **host** renders a detail panel from `SelectedDoc`:
summary, params grid, returns, then `seealso` as clickable chips -> `ResolveCref`
(resolved -> `NavigateTo`/`JumpToCrossDb`/`OpenSource`; ambiguous -> candidate menu;
unresolved -> dim "?"). Crefs are panel chips, not graph edges.

## 9. Kind styling + legend (`DragLint.Graph.Style`)

Pure-data tables: `TGraphNodeKind` -> fill/shape; `TGraphEdgeKind` -> pen + arrows.
This round:
- **Uses edges** (`unit-uses.md` §5.4): interface = solid, implementation = dashed,
  program/package = bold; merged multi-section edge shows a section-list tooltip.
- `call`, `type_use`, `sql_table_ref`, and aggregated edges each get a distinct pen.
- **Cross-DB link** affordance: dashed + colored with a small boundary marker.
- **External / undocumented / deprecated** nodes get distinct borders.
- **SQL Tier 1** nodes: one simple distinct style (e.g. a SQL accent color + box for
  tables, smaller for columns). Rich per-kind shapes/icons (cylinder/hexagon/pk-icon)
  deferred.
- Toggleable legend of kinds present in the current projection.

Built-in palette; funneled through `Style` so the later `TStyleManager` swap is local.

## 10. Layout

Operates on the projection's visible node set each relayout. Collapsed node radius
scales with descendant count. Synchronous O(N^2) this round (fine for the
hundreds-to-low-thousands visible after collapse on a single store). Barnes-Hut /
threaded layout for 40k nodes deferred. Dead `TGraphLayout.Reset` removed.

## 11. Packaging (component-first)

- **`DragLintGraph.bpl`** (runtime core, requires VCL, **not** FireDAC): Types,
  Source (interfaces), ViewModel, Style, Layout, Control.
- **`DragLintGraphDb.bpl`** (requires FireDAC + bundled sqlite driver): `Source.Db`
  only - consumers feeding their own source never pull FireDAC.
- **`dclpkg/DragLintGraphDcl.bpl`** (design-time): registers `TDragLintGraphControl`
  on the `'Delphi-RAG-Lint'` palette page (deconflict vs the parked design's
  `'drag-lint'`).
- **Demo host EXE**: wires `IDbCatalog` (ordered `--db` paths) + `TGraphViewModel`
  into the control; renders the detail panel + cross-DB jump + Back. Test host, not
  the product.
- `build/build_all.bat`: builds BPLs + demo EXE, then runs the console harness.

## 12. Testing & hardening

- **Console harness** (non-VCL): builds temp sqlite stores from checked-in fixture
  `.sql` scripts (transparent, diffable), plus fake in-memory `IGraphSource`/
  `IDbCatalog` for pure-VM tests. Assertions: topology build (containment incl. SQL
  column-in-table, project-root synthesis, enclosing-symbol resolution for
  call/type_use, unit_uses source/target + section, external flagging), projection
  (collapse, aggregation, N-hop focus), nav stack (push/Back restore), cross-DB jump
  (resolve in store B, swap, focus; Back returns to store A), doc fetch (undocumented
  vs empty), cref resolution (URL/exact/bare/ambiguous/cross-store/unresolved). Exit
  0 = green.
- **Integration smoke**: run real drag-lint on a tiny sample project (and a tiny
  `.SQL` file) to produce real `.sqlite` store(s); open via `Source.Db`; assert
  non-empty topology + a known uses edge with section. Guards the real schema.
- **Launch smoke** (`run_smoke.ps1`): kept for the GUI host; fixed build-output path;
  backed by the asserting harness for logic.
- **Loose ends**: remove dead `TGraphLayout.Reset`; rewrite README (DB-direct, MVVM,
  one-graph-per-DB + jump, dependency story: core dep-free, DB source needs FireDAC,
  still zero-network; supersedes the parked WebView2 design); reconcile
  `dclpkg/`/`build_all.bat`; all new `.pas` strict ASCII / CRLF.

## 13. Open dependencies & risks

- **Enclosing-symbol resolution** for `refs` is the trickiest reader logic
  (range-containment, innermost wins). Unit-tested directly.
- **`target_file_id` bare-name resolution** can mis-pick on basename collisions
  (last-file-wins); cross-DB resolution inherits the same first-hit ambiguity. Mirror
  the LSP's `--db` priority order; surface ambiguity as a disambiguation choice.
- **Win32 sqlite JSON1** may lack `json_each`; client-side parse `seealso_json` as
  fallback.
- **Schema drift**: pin to `SCHEMA_VERSION = 5`; `Source.Db` checks `schema_meta`
  and fails clearly on mismatch.
- **Name/exe collision** with the parked drag-lint WebView2 design - settle ownership
  of the `TDragLintGraphControl` / `drag-lint-graph.exe` names with that team.

## 14. Explicitly deferred (out of scope this round)

- Semantic / LOD auto-zoom (the hierarchy + manual collapse/navigate built here is
  its foundation).
- In-viewer fuzzy search (drag-lint has trigram search to surface later).
- **Unit-graph analysis utilities**: circular-dependency detection, interface->
  implementation move-down hints, unused-unit candidates, "% resolved" coverage,
  `uses-report` CSV mode - render-as-hint-only, a dedicated later phase.
- **SQL Tier 2/3**: live Firebird snapshot (`fb_*` tables) and the Delphi<->SQL ORM
  linker (`orm_links`, `orm_class_to_table` edges) - not yet shipped by drag-lint.
- Rich SQL Tier 1 visuals (per-kind shapes/icons, pk-icons, type chips).
- Barnes-Hut quadtree + threaded/async layout for 40k+ nodes.
- `TStyleManager` theme integration.
- Split-screen / second-window multi-DB view.
- A `graph --format json` exporter (the `Source.Json` path stays a thin option).
