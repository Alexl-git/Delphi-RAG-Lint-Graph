# Design: side-effect badges on the graph and Code Flow View

**Status:** DESIGN ONLY -- nothing implemented. Written 2026-08-11 while the IDE was
in use, so no build, no reindex, no code change.
**Repo:** `C:\Projects\Delphi-RAG-Lint-Graph` (branch `feat/manifest-dbselect`)
**Related:** `docs/superpowers/specs/2026-06-14-code-flow-view-design.md`

## 1. Motivation

The Code Flow View answers "what calls what". It cannot answer "where does this
flow have *consequences*" -- where it opens a transaction, commits one, writes a
file, or hands a value back through a `var` parameter. That is exactly the
question that matters when reading an unfamiliar Micronite call chain.

drag-lint already computes this and stores it. **Nothing consumes it.**

## 2. The data actually exists -- measured, not assumed

`symbol_facts` (schema v18+, columns added v19) carries per-routine facts. Sampled
on `library-Win64.sqlite` at schema v21:

```
FIBDatabase.TFIBDatabase.StartTransaction   touches = '|starts'
FIBDatabase.TFIBDatabase.Commit             touches = '|commits'
FIBDatabase.TFIBDatabase.Loaded             touches = '|starts'
```

On `ORM3` (v19): `mutates_params` 355 rows (`'CanClose (var)'`, `'AError (out)'`),
`touches` 463 rows, `ui_affinity` 302 rows. `symbol_facts` joins to `symbols` on
13,267 rows.

Column contract (from `INDEX-SCHEMA.md` 2.15):

| Column | Shape |
|---|---|
| `touches` | `'<resources>\|<transactions>'`, ONE column, `\|` always present even when a side is empty. Resource words: `file system`, `registry`, `network`. Transaction words: `starts`, `commits`, `rolls back`. Fixed order, never discovery order. |
| `mutates_params` | CSV, display-ready: `'pList (var), pReason (out)'`. Capped at 8 then ` (+N more)`. |
| `ui_affinity` | CSV of UI controls/globals. **Positive findings only.** |

## 3. Schema compatibility -- no viewer update is needed

Established by diffing a v19 DB against a v21 DB:

* **v19 -> v21 added no tables and no columns.** It added exactly three indexes:
  `idx_call_edges_receiver`, `idx_symbol_docs_symbol`, `idx_symbol_facts_symbol`.
* The viewer's schema gate is `>= 5` (`DragLint.Graph.Source.Db.pas:187`), so every
  version in play passes.
* The viewer references `symbol_facts` nowhere today and issues no `SELECT *`, so
  the v19 additive columns were invisible to it.
* The viewer persists no `symbols.id` (the only registry write is its own HWND), so
  id reassignment across reindexes cannot bite.
* The viewer's own doc-join SQL was executed against both a v19 and a v21 DB and
  returned rows in both.

Two of the new indexes land directly under this feature: `idx_symbol_facts_symbol`
serves the badge join, `idx_symbol_docs_symbol` serves the doc join already in use.

**Mixed versions are live right now** -- library DBs at v21, project DBs at v19.
The design must not assume a uniform version.

## 4. Design

### 4.1 What renders

Two surfaces, same underlying fact set:

* **Code Flow View** (primary) -- a badge strip on each step box. This is where the
  feature earns its keep: a flow that crosses `starts` ... `commits` becomes
  visible as a boundary rather than something you reconstruct by reading bodies.
* **UML class boxes** (secondary) -- badges on member rows.

### 4.2 Badge vocabulary

Derived, not raw text:

| Badge | Source |
|---|---|
| TX-start / TX-commit / TX-rollback | `touches` right side |
| file / registry / network | `touches` left side |
| var-out | `mutates_params` non-empty |

Hover reveals the raw column text (e.g. `pList (var), pReason (out)`), so the badge
is a summary and the detail is never lost.

### 4.3 Storage -- deliberately not strings

**This is the load-bearing decision.** `FMaxNodes` defaults to 20000. Carrying two
raw strings per node would add meaningful memory to a process that already
materialises up to `FMaxNodes * 50` ref rows.

Parse once at load into a small set per node:

```pascal
type
  TSideEffect  = (seTxStart, seTxCommit, seTxRollback,
                  seFile, seRegistry, seNetwork, seVarOut);
  TSideEffects = set of TSideEffect;   { one byte }
```

One byte per node instead of two heap strings. Raw text is fetched lazily on hover
for the one node under the cursor, not held for all 20000.

### 4.4 Query

One additional LEFT JOIN in the existing topology load, not a second pass:

```sql
LEFT JOIN symbol_facts f ON f.symbol_id = s.id
```

selecting `f.touches, f.mutates_params`. Backed by `idx_symbol_facts_symbol` on
v21; on v19 it is an unindexed lookup, which is why the cap in 4.3 matters.

### 4.5 Placement

* Parse + set-building: `DragLint.Graph.Source.Db.pas` (package `DragLintGraphDb`).
* `TSideEffects` field on the node record: `DragLint.Graph.Types.pas`.
* Rendering: `DragLint.Graph.FlowControl.pas` (flow) and
  `DragLint.Graph.Control.pas` (UML boxes).

Note `DragLintGraphDb` is **not** required by the design-time package, so none of
this reaches the 32-bit IDE.

### 4.6 Degradation

A DB without `symbol_facts`, or with the column NULL, yields an empty set and no
badge. Never an error, never a dialog. Detect once at connect (`PRAGMA table_info`)
and skip the join entirely if absent, so pre-v18 DBs keep working.

## 5. Deliberately excluded

* **`ui_affinity`.** Sampled values on ORM3 are dominated by `Result`, which is not
  a UI control. The engine team documents it as positive-findings-only and
  under-reporting by construction. Not trustworthy enough to paint. Revisit only
  after sampling it properly.
* **`wiring`.** Documented as RESERVED and never written; computed lazily at
  `document`/`hover` time. Additionally, no index on this machine has a single
  `orm_links` row, so the dataset->table half would be silent regardless.

## 6. Acceptance criteria

1. A v19 DB and a v21 DB both load with badges; a pre-v18 DB loads with none and no
   error.
2. `TFIBDatabase.StartTransaction` shows TX-start; `.Commit` shows TX-commit.
3. A routine with `mutates_params` shows var-out, and hover reveals the raw CSV.
4. Node memory grows by <= 1 byte per node -- asserted by a test on the record size,
   not by inspection.
5. Loading a 20000-node graph is not measurably slower than today (measure before
   and after; the join is the risk on v19 DBs without the index).
6. `ui_affinity` is not read anywhere.

## 7. Open questions

1. Badge strip position on a flow step box -- header line or a corner cluster?
   Affects the existing `MAX_ROWS = 12` visible-row cap.
2. Should a flow that opens a transaction and never commits within the traced depth
   be highlighted as an unbalanced boundary? Genuinely useful, but it is inference
   on top of facts and could mislead when the commit is simply below the depth cap.
3. Colour vs glyph, given the viewer is pure VCL canvas drawing and must stay
   readable over RDP.
