# Doc Comments — what's stored, how to fetch, how to make them clickable

This document is for the graphing tool. It describes the contract for
querying in-code documentation that drag-lint extracted at index time,
how missing-doc cases surface, and how to turn the cross-reference
strings (`<see cref="…"/>` and friends) into clickable navigation.

It is accurate against `Delphi-RAG-Lint` as of v0.40.3-alpha. Where the
contract is expected to grow (e.g., the `hover --format json` payload
is currently slim), I've noted what's stable today and what to expect
later.

---

## 1. Storage model — separate entity, optional join

Docs are NOT an attribute on the symbol record. They live in their own
table, `symbol_docs`, with a 1:1 foreign key to `symbols.id`:

```sql
-- symbols (one row per declaration)
CREATE TABLE symbols (
  id              INTEGER PRIMARY KEY,
  file_id         INTEGER NOT NULL,
  parent_id       INTEGER,
  kind            TEXT NOT NULL,    -- 'class', 'method', 'field', 'unit', …
  name            TEXT NOT NULL,
  qualified_name  TEXT NOT NULL,    -- 'SampleUnit.TKnownClass.KnownMethod'
  signature       TEXT,
  modifiers       TEXT,
  start_line      INTEGER,
  start_col       INTEGER,
  end_line        INTEGER,
  end_col         INTEGER
);

-- symbol_docs (0 or 1 row per symbol)
CREATE TABLE symbol_docs (
  symbol_id        INTEGER PRIMARY KEY REFERENCES symbols(id) ON DELETE CASCADE,
  format           TEXT NOT NULL,      -- 'xmldoc' | 'pasdoc' | 'oneline' | 'loose'
  raw_block        TEXT NOT NULL,      -- verbatim comment block
  summary          TEXT,               -- <summary> body
  remarks          TEXT,               -- <remarks> body / prose
  returns_text     TEXT,               -- <returns> body
  params_json      TEXT,               -- JSON: [{"name":"X","desc":"…"}, …]
  exceptions_json  TEXT,               -- JSON: [{"type":"E…","desc":"…"}, …]
  example_text     TEXT,               -- <example> body
  seealso_json     TEXT,               -- JSON: ["TStream.Read", "Foo.Bar", …]
  since_text       TEXT,               -- @since version
  deprecated       INTEGER DEFAULT 0,  -- 0/1 indexed when 1
  start_line       INTEGER,            -- doc block range in source
  end_line         INTEGER
);
```

### Practical consequence

Missing docs are **not** stored as NULL columns on `symbols` — they are
**no row at all** in `symbol_docs`. This makes "which symbols are
undocumented?" a fast left-join + null-check:

```sql
SELECT s.qualified_name
FROM   symbols s
LEFT   JOIN symbol_docs d ON d.symbol_id = s.id
WHERE  d.symbol_id IS NULL
  AND  s.kind IN ('class','method','procedure','function','property')
ORDER  BY s.qualified_name;
```

For graph rendering, you can color undocumented nodes via the same
left-join with no extra query.

---

## 2. The three ways to fetch docs for one symbol

### A. CLI — quick and ASCII

```
drag-lint hover --qname SampleUnit.TKnownClass.KnownMethod \
                --db <project.sqlite> --format json
```

Current JSON shape (v0.40.3) — small, stable:

```json
{
  "qname":      "SampleUnit.TKnownClass.KnownMethod",
  "format":     "xmldoc",
  "summary":    "Decrements AParam and recurses until zero.",
  "returns":    "",
  "since":      "1.0",
  "deprecated": false
}
```

When the symbol has no doc, `format` is the empty string and
`summary` / `returns` / `since` are empty; `deprecated` is `false`.
The command succeeds (exit 0) regardless — absence is **not** an error.

When the symbol doesn't exist at all, the command exits non-zero and
emits an error line on stderr. Treat exit ≠ 0 as "unknown qname",
not "no docs".

Other formats (`--format md`, `--format plain`) render the full
TParsedDoc — `Params`, `Exceptions`, `SeeAlso`, `Example` all show up
in those views. The slim JSON shape is a known limitation we expect
to expand; for now, if the graphing tool needs the structured arrays,
go straight to SQL (option B).

### B. SQL — full record, single round-trip

```sql
SELECT s.qualified_name, s.kind, s.signature, s.start_line,
       d.format, d.summary, d.remarks, d.returns_text,
       d.params_json, d.exceptions_json, d.example_text,
       d.seealso_json, d.since_text, d.deprecated
FROM   symbols s
LEFT   JOIN symbol_docs d ON d.symbol_id = s.id
WHERE  s.qualified_name = :qname
LIMIT  1;
```

For a missing doc, all `d.*` columns come back NULL. Treat that as
"undocumented" in your renderer — don't conflate NULL with empty
string (an empty summary means "doc exists with no <summary>", which
is different from "no doc at all").

`params_json`, `exceptions_json`, `seealso_json` are TEXT containing
serialised JSON arrays. Decode them as:

```js
// params_json
[ {"name": "AParam",  "desc": "Initial counter."},
  {"name": "ASender", "desc": "Originating control."} ]

// exceptions_json
[ {"type": "EConvertError",  "desc": "When AParam can't be parsed."},
  {"type": "EAccessViolation","desc": "On nil dereference."} ]

// seealso_json
[ "TKnownClass.KnownProp", "Foo.Bar.Baz", "https://docwiki…" ]
```

If a JSON field is NULL in the row, it's NULL. If it's an empty array
`[]`, the doc author wrote zero entries for that section. Render the
two cases the same way.

### C. LSP — for any tool already speaking JSON-RPC

```jsonc
// Request
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "textDocument/hover",
  "params": {
    "textDocument": { "uri": "file:///C:/.../SampleUnit.pas" },
    "position":     { "line": 32, "character": 14 }
  }
}

// Response (doc present)
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "contents": {
      "kind":  "markdown",
      "value": "**KnownMethod** `method`\n\n…full hover markdown…"
    }
  }
}

// Response (no symbol under cursor, or no docs)
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": null
}
```

`result == null` means "the LSP found nothing useful here" — covers
both "no identifier under cursor" and "identifier matched no indexed
symbol". The LSP collapses the two on purpose so the IDE doesn't show
an empty bubble.

### Which to use, when

| Caller                          | Use                          |
|---------------------------------|------------------------------|
| Standalone EXE viewer           | A (CLI hover), or B (SQL) for full record |
| HTTP/dashboard mode             | B (SQL) — keeps round-trips low |
| Embedded VCL control in any app | B (SQL) — direct FireDAC query |
| IDE plugin                      | C (LSP, already wired)       |
| LLM tooling                     | A (CLI) or MCP `serve`       |

---

## 3. Are docs clickable? — yes, but you have to resolve the refs

The XMLDoc parser captures `<see cref="X"/>` and `<seealso cref="X"/>`
elements; the PasDoc parser captures `@link(X)` and `@see(X)` similarly.
The matched `cref` text is stored verbatim in `seealso_json`:

```json
[ "TStream.Read", "Foo.Bar.Baz", "MyUnit.MyConst", "https://example.com" ]
```

drag-lint does NOT pre-resolve these to symbol IDs. The text is
whatever the author wrote — which is good (round-tripping) and a
chore (the graphing tool has to resolve them at render time).

### Resolution algorithm — recommended for the graphing tool

For each `cref` string `X`:

1. **External URLs** — if `X` starts with `http://` or `https://`,
   render as an external-link node (open in default browser). Skip
   index lookup.

2. **Exact qualified name match** — first try:
   ```sql
   SELECT id, kind, file_id, start_line
   FROM   symbols
   WHERE  qualified_name = :X
   LIMIT  1;
   ```
   If a row comes back, you have a fully-resolved target. Make
   the cref clickable; the click handler opens the file at
   `start_line` (using whatever editor-jump mechanism the host
   provides — `IOTAActionServices.OpenFile` in IDE mode,
   `ShellExecute(open, file)` in standalone mode).

3. **Bare name match** — if (2) returned nothing, try:
   ```sql
   SELECT id, qualified_name, kind, file_id, start_line
   FROM   symbols
   WHERE  name = :X
   ORDER  BY CASE kind WHEN 'class' THEN 0 WHEN 'method' THEN 1
                       WHEN 'property' THEN 2 ELSE 3 END,
            qualified_name
   LIMIT  5;
   ```
   If exactly one row, treat it as resolved (same as 2).
   If multiple, render the cref as a disambiguation menu — the
   user clicks the cref, you pop up the candidate list, they pick
   one.

4. **Multi-DB** — when the graph was loaded from a project that
   used multiple DBs (CLIENT/SERVER/COMMON/library), repeat (2)
   and (3) against EACH DB. First hit wins; record the originating
   DB so the click handler opens the right project. (This mirrors
   how the LSP server's multi-DB query works as of v0.40.3.)

5. **Unresolved** — if everything misses, render the cref as a
   dim, non-clickable label with a tooltip explaining it didn't
   resolve. Don't silently drop it; the author wrote it for a
   reason. Show a "?"

### Why click resolution lives in the renderer, not in storage

Pre-resolving crefs at index time has two big problems:

1. **Renames break the link.** If a doc says `<see cref="OldName"/>`
   and someone renames `OldName` → `NewName`, the cref text in the
   source is stale until the doc author updates it. Pre-resolved
   IDs would silently lose the link; renderer-time resolution
   surfaces it as "unresolved", which is the truthful state.
2. **Crefs can target external systems** — DocWiki, internal wiki,
   bug-tracker URLs. The same field accepts both. Resolution context
   matters; the indexer can't know.

Cost of renderer-time resolution: one extra SQL roundtrip per cref.
For a graph view rendering 50 visible nodes with ≤3 crefs each that's
~150 lookups — sub-millisecond against an indexed sqlite. Worth it
for the staleness signal.

---

## 4. Where in the doc to put hyperlinks (recommended UX)

Once you've resolved the crefs:

- **In the hover tooltip / node info panel**: render `summary`, then
  `params` (as a name|desc grid), then `returns`, then `seealso` as
  a horizontal list of clickable chips. Each chip = one cref.
- **In a node's bubble label on the graph**: don't try; bubbles are
  small. Render crefs only in the expanded panel.
- **In the body of `remarks`**: drag-lint stores remarks as plain
  text. If you want inline `<see>` resolution within the prose,
  re-scan the rendered remarks text for `[X]` style links and
  convert them — the parser preserves them as text.
- **In `example_text`**: render as syntax-highlighted Pascal. Don't
  cref-resolve inside examples; that's noise.

---

## 5. Detecting "this symbol has no doc"

Three signals, in increasing strength:

1. **CLI**: `summary` is `""` AND `format` is `""`. (Format is set
   only when a doc block exists.)
2. **SQL**: `d.symbol_id IS NULL` after the LEFT JOIN.
3. **LSP**: `result.contents.value` ends with a stub `(no doc)`
   marker, OR `result == null`.

Use (2) — it's the cleanest test. Use (1) only when you're already
calling the CLI for other reasons.

---

## 6. Bulk queries the graphing tool will probably want

```sql
-- All deprecated symbols (graph: red border)
SELECT s.id, s.qualified_name
FROM   symbols s
INNER  JOIN symbol_docs d ON d.symbol_id = s.id
WHERE  d.deprecated = 1;

-- Coverage by kind (graph: a "% documented" panel)
SELECT s.kind,
       COUNT(*)                                AS total,
       SUM(CASE WHEN d.symbol_id IS NULL THEN 0 ELSE 1 END) AS documented
FROM   symbols s
LEFT   JOIN symbol_docs d ON d.symbol_id = s.id
GROUP  BY s.kind;

-- Symbols whose docs mention a target string (case-insensitive)
SELECT s.qualified_name
FROM   symbols s
INNER  JOIN symbol_docs d ON d.symbol_id = s.id
WHERE  LOWER(d.remarks)      LIKE LOWER('%' || :needle || '%')
   OR  LOWER(d.summary)      LIKE LOWER('%' || :needle || '%')
   OR  LOWER(d.example_text) LIKE LOWER('%' || :needle || '%');

-- Cref-reachable set from a starting symbol (1 hop)
WITH start AS (
  SELECT id FROM symbols WHERE qualified_name = :qname
)
SELECT s2.id, s2.qualified_name
FROM   symbol_docs d
JOIN   start ON start.id = d.symbol_id
JOIN   symbols s2
       ON s2.qualified_name IN (
            SELECT json_each.value FROM json_each(d.seealso_json) )
WHERE  d.seealso_json IS NOT NULL;
```

Last one uses sqlite's `json_each` extension. The drag-lint CLI
binaries ship FireDAC's bundled sqlite which supports JSON1 on Win64
(Win32 build's bundled version is older — fall back to fetching
`seealso_json` as TEXT and parsing client-side if needed).

---

## 7. Known limitations (so the graphing tool doesn't surprise users)

- **Parameters and local variables are not indexed.** They have no
  symbol row, hence no doc row possible. If you graph a method node
  and want to show its parameters, parse `signature` text (which IS
  stored on `symbols`); don't expect cref-resolvable links to them.
- **Inherited member docs are not auto-merged.** If `TKnownClass`
  inherits `KnownMethod` from a base, asking for `TKnownClass.KnownMethod`'s
  doc returns the override's doc only (NULL if not overridden). The
  graphing tool should walk the inheritance chain itself when
  surfacing inherited info.
- **Multi-format docs**: `format` distinguishes XMLDoc vs PasDoc vs
  the unstructured `loose` fallback. The `Summary`/`Remarks` fields
  are populated uniformly regardless, but `params_json` /
  `exceptions_json` may be sparser when the source was a one-line
  comment.
- **JSON columns are TEXT, not BLOB.** Don't try to query into them
  with anything other than `json_each` or client-side parsing.

---

## 8. References inside this repo

- Schema (authoritative): `src/storage/DRagLint.Storage.Schema.pas`
- Record types: `src/core/DRagLint.Core.Model.pas` — `TParsedDoc`, `TDocParam`, `TDocException`
- Parser (XMLDoc + PasDoc + Loose): `src/parser/DRagLint.Parser.DocComments.pas`
- Storage upsert/fetch: `src/storage/DRagLint.Storage.SQLite.pas` — `UpsertSymbolDoc`, `GetSymbolDoc`
- CLI command: `src/cli/DRagLint.CLI.pas` — `DoHover`
- Renderer: `src/cli/DRagLint.Hover.Renderer.pas`
- LSP handler: `src/lsp/DRagLint.LSP.Server.pas` — `HandleHover`

Open an issue on the main repo when the JSON shape for `hover --format
json` expands; this doc will need to be updated.
