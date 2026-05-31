# Delphi-RAG-Lint-Graph

Pure-VCL interactive graph visualization component and standalone viewer for
[Delphi-RAG-Lint](https://github.com/Alexl-git/Delphi-RAG-Lint).

## What this is

- **`TDragLintGraphControl`** — a VCL `TWinControl` you drop on a TForm to
  show a force-directed, pannable, zoomable, clickable graph of any symbol
  network drag-lint can produce (units, types, methods, callers, callees,
  DFM bindings, etc.).
- **`drag-lint-graph.exe`** — a standalone viewer that loads a JSON
  graph dump (from `drag-lint graph --format json --db ...`) and shows it.
- **No WebView2.** No HTML, no JavaScript, no embedded browser. Pure
  Delphi canvas rendering, native event handling, VCL TStyleManager
  for skin support.

## Why pure VCL?

- Native responsiveness (no IPC, no JS GC pauses).
- 40k+ node Micronite-scale targets feasible with quadtree culling.
- Single-BPL distribution, no WebView2 runtime dependency.
- `TStyleManager` skin support works automatically.
- Zero outbound network traffic, ever.

## Status

Phase 0 — skeleton + hardcoded 5-node dummy graph rendering, pan/zoom,
click selection.

## Layout

```
src/
  control/           TDragLintGraphControl + supporting units
  viewer/            drag-lint-graph.exe sources
  dclpkg/            design-time package for IDE install
  examples/          small standalone apps demonstrating the control
tests/
  autotest/          smoke test harness (mirrors drag-lint's pattern)
  fixtures/          known-good graph JSON files for assertions
build/               build scripts
docs/                design notes, API reference
third_party/         (empty — we own everything)
```

## Build

```
build\build_all.bat
```

Produces `bin\drag-lint-graph.exe` and the design+runtime BPL pair.

## Test

```
pwsh tests\autotest\run_smoke.ps1
```

Exit 0 = green. Mirrors the main drag-lint autotest pattern.
