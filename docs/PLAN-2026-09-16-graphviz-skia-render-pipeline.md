# PLAN -- Graphviz layout + Skia rendering for the viewer (2026-09-16)

Design agreed with the owner in a drag-lint session on 2026-09-16. **Nothing is
started.** The full discussion, sizing and rejected options live in
`C:\Projects\Delphi-RAG-lint\docs\BACKLOG-archify-parity.md` (gitignored there,
disk only).

## Why this lives here and not in drag-lint

The viewer is already a separate project with a standalone Win32+Win64 exe and
a named-pipe open-in-IDE contract. **This work touches drag-lint `main` only for
the plugin's pipe SERVER**, so the engine stream (its rows 1-7 and its release)
proceeds in parallel. The only cross-repo coupling is the DOT / node-id
contract -- agree that first, then both sides move independently.

## What is already true (verified 2026-09-16, do not re-derive)

| fact | evidence |
|---|---|
| this viewer is a standalone VCL exe, Win32 **and Win64** | `third_party\dll-win32\drag_lint_graph.exe` (19.5 MB), `dll-win64\` (23 MB) in the drag-lint tree |
| **the 32-bit IDE memory ceiling is therefore already solved** -- nothing graphical need load into the IDE | a Win64 viewer exists |
| open-in-IDE is a named pipe, implemented and tested on THIS side | `src/control/DragLint.Graph.OpenSourceClient.pas`; round-trip proven in `Test.Graph.OpenSource.pas` |
| click a leaf -> `LocateSymbol(qname)` -> `SendOpenSource(file, line)`, falling back to `ShellExecute` after ~200 ms | the pipe-contract note in drag-lint's `docs\BACKLOG-editor-integration\` |
| rendering today is `TPaintBox` + `TCanvas` (plain GDI) | `src\control` |
| the viewer reads the SQLite index via `IGraphSource` -- it does NOT read DOT | `DragLint.Graph.Flow.Source.Db.pas` |
| **Skia ships with Delphi 13 for VCL** | `source\vcl\Vcl.Skia.pas`: `TSkPaintBox`, `TSkSvg`, `TSkAnimatedPaintBox`, `TSkLabel` |
| Skia both READS and WRITES SVG, and writes PDF | `System.Skia.pas`: `ISkSVGDOM`, `TSkSVGCanvas.Make(bounds, stream, flags)`, `ISkDocument.MakePDF` |
| drag-lint EMITS DOT already | `drag-lint graph --format dot` |

## The pipeline

```
drag-lint  --(DOT, with stable node ids encoding the qname)-->  dot.exe
dot -Tsvg -o graph.svg  -Tplain -o graph.plain   (ONE run, ONE layout)
graph.svg   --> ISkSVGDOM --> Render onto TSkPaintBox under OUR transform
graph.plain --> node rectangles --> hit-testing
click --> invert transform --> node id --> qname --> SendOpenSource(file, line)
```

**Nothing in this parses DOT or SVG.** DOT is Graphviz's INPUT; we write it. The
only Graphviz output that would need a DOT parser is `-Tdot`, which we never ask
for. `-Tplain` is four space-separated record types (`graph` / `node` / `edge` /
`stop`) -- roughly 100 lines of Delphi.

## THE ONE DESIGN DECISION -- make it before writing code

**Do NOT use the `TSkSvg` control.** It applies its own fit-and-scale, so a
click would have to be mapped back through a transform we did not choose.
**Use `TSkPaintBox` + `ISkSVGDOM.Render` under a transform WE apply**, and
click-to-graph-coordinates stays arithmetic we own.

## First task: a ONE-DAY SPIKE, before committing to anything

1. Install Graphviz; confirm `dot -Tsvg -o a.svg -Tplain -o a.txt in.dot` really
   emits both in one run (**UNVERIFIED -- `dot` is not installed on this box**).
2. Feed it a REAL ORM3 call graph from `drag-lint graph --format dot`.
3. Render the SVG with `ISkSVGDOM` onto a `TSkPaintBox`.
4. Judge the layout at that scale.

**That spike decides the whole strategy**: if Graphviz's layout looks good on a
real ORM3 graph, bundling it is the cheap answer and no layout code is ever
written. If it disappoints, we know BEFORE investing ~1-2 weeks in a Sugiyama
layered layout of our own. Deciding before the spike is deciding without the
measurement that matters.

## Sizing (corrected twice downward under questioning -- treat as indicative)

| piece | effort |
|---|---|
| IR + validator | **0-3 days** -- DOT already is a typed format with a parser, validator and layout engine attached, and carries arbitrary attributes so evidence rides along |
| Layout | **0** (Graphviz) -- or ~1-2 weeks if we write Sugiyama ourselves |
| Render + display | **days** -- Skia into the EXISTING viewer |
| Motion, PNG/PDF/SVG export | **in the box** |
| plugin pipe SERVER | the one genuinely missing piece |
| **pragmatic total** | **~2-3 weeks** |

## Open risks

* Bundling Graphviz is a new native dependency and an **EPL-1.0** review.
  Precedent: drag-lint already stages tree-sitter companions beside its exe.
* Compiling Graphviz with C++Builder was considered and **NOT recommended** --
  upstream supports MSVC/MinGW, C++Builder is untested there, and the end state
  is owning a fork of a 25-year-old C codebase. Spawning `dot.exe` makes the
  question moot.
* Edge hit-testing is fiddlier than node hit-testing (splines). Nodes first.
* Whether `ISkSVGNode` exposes usable bounds was NOT verified; geometry comes
  from `-Tplain` instead.