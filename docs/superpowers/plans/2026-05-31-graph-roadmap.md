# Graph Viewer (real + harden) — Implementation Roadmap

Spec: [`docs/superpowers/specs/2026-05-31-graph-viewer-real-and-harden-design.md`](../specs/2026-05-31-graph-viewer-real-and-harden-design.md)

The spec spans several subsystems with a clean dependency order. It is sliced into
**5 ordered sub-plans**, each producing working, testable software. Detailed plans
are written **just-in-time**: a slice's plan is authored once the previous slice has
fixed its concrete unit/type signatures, to avoid drift.

| # | Plan | Layer | Produces | Testable by |
|---|------|-------|----------|-------------|
| **P1** | **Model foundation** | Model (pure) | `TGraphData` hierarchy + new kinds/flags/records; `IGraphSource`/`IDbCatalog` interfaces; headless test harness | console unit tests |
| P2 | ViewModel | ViewModel (pure) | `TGraphViewModel`: projection (collapse/aggregation/focus), selection, nav back-stack, cross-DB resolve, observable events | console unit tests over a fake `IGraphSource`/`IDbCatalog` |
| P3 | DB data source | Model (FireDAC) | `Source.Db` + `IDbCatalog` impl: topology reader (containment, unit_uses+section, refs w/ enclosing-symbol resolution, SQL Tier 1), lazy docs, cref + cross-DB resolution, schema-version guard | temp-sqlite from fixture `.sql` + integration smoke vs real drag-lint |
| P4 | Style + View | View (VCL) | `Style` (kind/edge visuals, legend, uses solid/dashed/bold, cross-DB affordance, SQL nodes) + slim passive `TDragLintGraphControl` bound to `IGraphViewModel` | launch smoke + VM tests beneath |
| P5 | Packaging + demo host + hardening | packaging | `DragLintGraph.bpl` / `DragLintGraphDb.bpl` / design-time `dclpkg`; demo host EXE (catalog from `--db`, detail panel, in-place cross-DB jump + Back); `build_all.bat`; README rewrite; dead-code removal | full launch smoke + console suite |

## Dependency order (why this sequence)

1. **P1** defines the data shapes everything consumes — no dependants can be written
   first. Pure, fastest to test.
2. **P2** is the heart of the logic and depends only on P1 + the `IGraphSource`
   interface (uses a fake, not the DB). Keeps the hardest logic in the most testable
   layer.
3. **P3** implements the real `IGraphSource` behind P1's interface; P2 already proved
   the consumer contract, so P3 only has to satisfy it.
4. **P4** renders P2's projection; needs P1+P2 stable, P3 optional (can render a fake
   source).
5. **P5** packages and wires the real host; needs everything.

## Cross-cutting conventions (all plans)

- **ASCII / CRLF** in every `.pas`/`.dfm` (project rule). No Unicode, no BOM.
- **Pure layers link no VCL/FireDAC**: Types, Source (interfaces), ViewModel, Layout,
  Style. View links VCL only. `Source.Db` links FireDAC only.
- **TDD**: failing test -> minimal code -> green -> commit. Console `.dpr` runner
  mirrors drag-lint's autotest (exit 0 = green).
- **Frequent commits**, one logical change each.

## Acceptance per slice

- **P1 green:** `pwsh tests/console/run.ps1` builds + passes hierarchy/kind tests.
- **P2 green:** console suite passes projection/focus/nav/cross-DB-resolve tests over a fake source.
- **P3 green:** console suite builds a temp sqlite from fixtures and asserts the full topology read; integration smoke opens a real drag-lint `.sqlite`.
- **P4 green:** `drag_lint_graph.exe` renders a fixture/DB graph; launch smoke passes.
- **P5 green:** `build/build_all.bat` builds all artifacts and runs both suites clean.
