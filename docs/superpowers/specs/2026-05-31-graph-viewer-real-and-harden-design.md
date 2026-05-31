# Design: Make the viewer real + harden the skeleton (component-first)

Date: 2026-05-31
Project: Delphi-RAG-Lint-Graph
Status: approved design, pre-implementation

## 1. Context

Phase 0 delivered a working pure-VCL skeleton: `TGraphData` (value-record node
store + id index), a Fruchterman-Reingold force layout, a `TCustomControl`
renderer with pan/zoom/hover/click, a forgiving JSON loader, a viewer EXE
(dummy graph or `--data x.json`), and a launch-only smoke test.

The upstream `drag-lint graph --format json` exporter does **not** exist yet, so
the viewer currently runs on fixtures and a hardcoded dummy. The ultimate goal
is a **ship-ready, reusable VCL component** (`TDragLintGraphControl`); the
eventual headline feature is **semantic / level-of-detail (LOD) zoom** over very
large (40k-node Micronite-scale) graphs.

## 2. Goal of this round

Two things, both confirmed in scope:

1. **Make the viewer real** against fixtures: kind styling + legend, neighborhood
   focus, expand/collapse by containment, and click-to-navigate along
   `uses` / doc-reference edges.
2. **Harden the skeleton**: component-first packaging (runtime BPL + design-time
   `dclpkg`), a clean public API, a real (asserting) test harness, and cleanup of
   the loose ends Phase 0 left behind.

The data-source strategy is **fixtures first, exporter later** ("both, in
sequence"): the fixtures authored this round *freeze the JSON contract*, and a
later phase adds the real drag-lint exporter that conforms to it.

## 3. Architecture & units

Seam: **raw graph -> view -> projection -> (layout + render)**. `Control` and
`Layout` consume only the *projection*, never the raw graph, so the deferred LOD
feature later becomes a new visibility policy on `TGraphView` rather than a
rendering/layout rewrite.

| Unit | State | Responsibility |
|------|-------|----------------|
| `DragLint.Graph.Types`   | exists, extended | Raw model records + `TGraphData`; derive parent/child hierarchy. |
| `DragLint.Graph.View`    | NEW | `TGraphView`: owns view state (collapsed/focused per node); builds the visible projection (visible nodes + aggregated edges). Pure, non-VCL. |
| `DragLint.Graph.Style`   | NEW | Kind -> color/shape/edge-pen mapping + legend entries. Pure data; no VCL Canvas dependency. |
| `DragLint.Graph.Layout`  | exists, adjusted | Positions the projection's visible node set, not the raw graph. |
| `DragLint.Graph.Control` | exists, extended | Renders the projection + legend; hit-tests; drives collapse/focus/navigate via the View; reads `Style` for colors. |
| `DragLint.Graph.Json`    | exists, extended | Loader; contract frozen + documented this round. |

**Data flow:** `Json.Load -> TGraphData` (immutable after load) -> `TGraphView`
wraps it and holds collapse/focus state -> on any state change the View
recomputes a `TGraphProjection` (visible node indices + aggregated edges) ->
`Layout` positions the visible nodes -> `Control` paints projection + legend and
routes mouse/keyboard events back into the View.

## 4. Data model & containment hierarchy

Containment is an explicit 4-level forest, derived after load:

```
Project          nkProject   (NEW kind; single synthetic root)
 +- Unit         nkUnit
     +- Object   nkClass / nkInterface / nkRecord / nkType
     |   +- Method     nkMethod / nkProcedure / nkFunction
     |   +- Property   nkProperty / nkField
     +- unit-level routine / const / var   (Level-2 sibling of Objects,
                                             contained directly by the Unit)
```

- **Parent assignment** (`BuildHierarchy` in `Types`): each node gets at most one
  parent. An explicit node `parent` field (see contract) wins; otherwise the
  parent is the source of an `ekContains` edge pointing at the node. Containment
  is single-parent (a forest); if two contains-parents are seen for one node,
  keep the first and continue.
- **Project root**: `nkProject` is a synthetic root. The exporter injects it
  later; if absent, the loader synthesizes one and parents all otherwise-rootless
  `nkUnit` nodes under it.
- Stored per node: `ParentIdx: Integer` (-1 = root) and `Children: TList<Integer>`.

## 5. JSON contract (frozen this round)

Documented in `docs/json-contract.md` and pinned by fixtures. Loader stays
forgiving: unknown kinds -> `nkOther` / `ekOther`, missing fields -> neutral
defaults, malformed entries skipped.

**Node object:**

| key | type | notes |
|-----|------|-------|
| `id`     | string | required; stable fully-qualified id |
| `label`  | string | display label; defaults to `id` |
| `kind`   | string | maps to `TGraphNodeKind`; incl. new `"project"` |
| `file`   | string | source path for open-in-IDE |
| `line`   | int    | 1-based |
| `col`    | int    | 1-based |
| `layer`  | string | optional grouping key |
| `parent` | string | NEW, optional; explicit containment parent id |
| `doc`    | string | NEW, optional; doc-comment / XML-doc text for this symbol |

**Edge object:**

| key | type | notes |
|-----|------|-------|
| `src` / `source` | string | required |
| `dst` / `target` | string | required |
| `kind`    | string | maps to `TGraphEdgeKind`; incl. new `"doc_ref"` |
| `label`   | string | optional |
| `weight`  | double | optional; default 1.0 |
| `section` | string | NEW, optional; `"interface"` \| `"implementation"` for `uses` edges |

New enum members: `nkProject`; `ekDocRef`.

## 6. Visible projection semantics (`TGraphView`)

### Collapse / expand
- A node is *collapsible* iff it has children.
- Collapsing `U` hides all descendants of `U`. `U` stays visible, drawn with a
  collapsed affordance (distinct outline + `+N` descendant count).
- A node is *visible* iff none of its ancestors is collapsed.
- **Edge aggregation:** map each raw edge endpoint to its nearest *visible*
  ancestor (itself if already visible). Both map to the same node -> drop
  (internal edge). Otherwise emit an aggregated edge between the two
  representatives, merging duplicates (count + summed weight). If the merged
  underlying edges share one kind, keep it; mixed -> rendered as an "aggregated"
  style.

### Neighborhood focus
- Distinct from selection. Default behavior **dims** non-neighbors (all still
  drawn, faded); an `Isolate` toggle *hides* non-neighbors instead.
- Default radius **1 hop**, adjustable. Operates over the *visible projection*,
  so collapse + focus compose.

## 7. Navigation, interaction & public API

### Navigation
- `uses` edges and `ekDocRef` edges are *traversable*. Clicking a used unit (or a
  doc-reference target) calls `NavigateTo(id)`: select it, center/animate the view
  onto it, and expand it one level. `uses` edges carry `section`, so interface vs
  implementation uses are visually distinguishable and independently actionable.

### Default control bindings (host may rebind)
| input | action |
|-------|--------|
| left-click node            | select |
| double-click collapsible node | toggle collapse |
| double-click leaf node     | `NavigateTo` (center + expand one level) |
| Ctrl+click node            | open source file (existing behavior) |
| click a `uses`/`doc_ref` edge line | `NavigateTo` the far endpoint |
| `F`                        | focus selected node's neighborhood |
| `Esc`                      | clear focus |
| drag empty / wheel         | pan / zoom (existing) |

### Public API (component-first)
```
procedure LoadData(AData: TGraphData; AOwnsData: Boolean = True);
procedure Collapse(const AId: string);
procedure Expand(const AId: string);
procedure ToggleCollapse(const AId: string);
procedure CollapseAll; procedure ExpandAll;
procedure SetFocus(const AId: string; AHops: Integer = 1);
procedure ClearFocus;
procedure NavigateTo(const AId: string);
procedure SelectNode(const AId: string);
procedure FitToWindow;
function  GetNodeDoc(const AId: string): string;
property  Isolate: Boolean;            // focus hides vs dims
property  Data: TGraphData;
// events: OnNodeClick, OnNodeHover, OnSelectionChange, OnNavigate
```
The control exposes the selected node's `doc` (via `GetNodeDoc` /
`OnSelectionChange`); the demo viewer renders it in a simple detail pane. Showing
the doc pane is the host's responsibility in a component-first design.

## 8. Kind styling + legend (`DragLint.Graph.Style`)

A pure-data table mapping `TGraphNodeKind` -> fill color + shape, and
`TGraphEdgeKind` -> pen (color/width/dash) plus directed arrowheads. Aggregated
edges and `doc_ref` / interface-vs-implementation `uses` get distinct pens. The
`Control` paints a legend (toggleable) listing the kinds present in the current
projection. Built-in palette this round; `TStyleManager`-driven theming remains a
later concern but the palette is funneled through `Style` so that swap is
localized.

## 9. Layout interaction with the projection

`Layout` operates on the projection's visible node set each relayout. Collapsing
removes descendants from the simulation; a collapsed node's radius scales with its
descendant count so big collapsed clusters read as larger. Layout remains
synchronous and O(N^2) this round (fine for the few-hundred-to-low-thousand-node
fixtures). Barnes-Hut / threaded layout for 40k nodes is explicitly deferred.

## 10. Packaging (component-first)

- **Runtime package** `DragLintGraph.dpk` (runtime-only) containing the five
  `DragLint.Graph.*` units. Produces `DragLintGraph.bpl`.
- **Design-time package** `dclpkg/DragLintGraphDcl.dpk` that requires the runtime
  package and registers `TDragLintGraphControl` on a "Delphi-RAG-Lint" palette
  page (`Register` procedure).
- The viewer EXE becomes a thin **demo/test host** that links the runtime units
  and adds the detail pane + legend toggle; it is no longer the product.
- `build/build_all.bat` builds: runtime BPL, design-time BPL, demo EXE, then runs
  the console test harness. Existing `build_viewer.bat` is kept/called for the EXE.

## 11. Testing & hardening

- **Console test harness** (`tests/autotest/`): a non-VCL console EXE that links
  `Types`, `Json`, `View`, `Style`, `Layout` and asserts on real behavior:
  fixture parse counts, hierarchy derivation (parent/child, project-root
  synthesis), projection correctness (collapse hides descendants; edge
  aggregation merges/drops correctly; focus N-hop set), and contract edge cases
  (interface vs implementation `section`, `doc` / `doc_ref` parsing). Exit 0 =
  green, mirroring the main drag-lint autotest pattern.
- **Launch smoke** (`run_smoke.ps1`): kept for the GUI host, fixed to point at the
  real build output path; remains a "doesn't crash" gate, now backed by the
  asserting console harness for logic.
- **Fixtures**: extend with (a) a small 4-level fixture exercising
  Project/Unit/Object/Member + collapse, (b) interface-vs-implementation `uses`,
  (c) `doc` + `doc_ref`, and (d) a few-hundred-node generated fixture for
  interaction/perf sanity.
- **Loose-end cleanup**: remove dead `TGraphLayout.Reset`; reconcile README
  (`build_all.bat`, `dclpkg/` now real); ensure all new `.pas` stay strict ASCII /
  CRLF per project rules.

## 12. Open dependencies & risks

- **drag-lint DB doc coverage.** `doc` and `doc_ref` are only useful if the
  drag-lint database actually captures doc-comments / XML-doc and their
  cross-references. If it does not, that is a feature request to the drag-lint
  project, resolved in the exporter phase. The viewer does not block: forgiving
  loader leaves the fields empty.
- **Exporter is a separate later phase.** This round only freezes the contract;
  `drag-lint graph --format json` conformance is out of scope here.
- **Single-parent containment assumption.** If drag-lint emits genuinely
  multi-parent containment, the "keep first" rule needs revisiting.

## 13. Explicitly deferred (out of scope this round)

- Semantic / level-of-detail auto-zoom (show only the level/locality relevant to
  the current zoom). The 4-level hierarchy + manual collapse/expand + navigate
  built here is its foundation.
- In-viewer search / filter (likely served by drag-lint at query/export time).
- Barnes-Hut quadtree + threaded/async layout for 40k+ nodes.
- `TStyleManager` theme integration (palette funneled through `Style` to make it a
  localized later change).
- The real drag-lint JSON exporter.
