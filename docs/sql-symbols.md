# SQL symbols — what drag-lint extracts from MS*.SQL and how the graph tool consumes them

This document covers the SQL DDL extraction added in drag-lint v0.40.5
Tier 1. Subsequent tiers add a live Firebird snapshot (Tier 2) and the
Delphi↔SQL ORM linker (Tier 3) — covered in this doc but marked
"planned" until they ship.

Accurate to drag-lint v0.40.5-alpha Tier 1.

---

## 1. The model

SQL DDL symbols live in the **same** `symbols` table as Delphi symbols.
Their `kind` text distinguishes them:

| kind text         | What it represents                                          |
|-------------------|-------------------------------------------------------------|
| `sql_table`       | `CREATE TABLE <name> (...)`                                 |
| `sql_column`      | One column inside a table (parent_id = table)               |
| `sql_index`       | `CREATE [UNIQUE] [ASC|DESC] INDEX <name> ON <table>`        |
| `sql_trigger`     | `CREATE [OR ALTER] TRIGGER <name> FOR <table>`              |
| `sql_generator`   | `CREATE GENERATOR <name>` / `CREATE SEQUENCE <name>`        |
| `sql_view`        | `CREATE [OR ALTER] VIEW <name>`                             |
| `sql_procedure`   | `CREATE [OR ALTER] PROCEDURE <name>`                        |
| `sql_exception`   | `CREATE EXCEPTION <name>`                                   |
| `sql_domain`      | `CREATE DOMAIN <name>` (custom types like `D_INTEGER`)      |
| `sql_constraint`  | Reserved for future named CHECK/PK constraints              |

Columns are emitted with their table's symbol as parent — same shape as
Delphi class fields. So queries like "all fields of class TFoo" and
"all columns of table FOO" use the same SQL pattern with different kind
filter.

### Recommended storage layout

The user-recommended pattern is **separate `drag-lint-sql.sqlite`**
passed alongside the project DB as a second `--db` flag. Reasons:

- SQL cadence is much slower (DDL changes occur on schema bumps, not on
  every Delphi save)
- Keeps `drag-lint index <projDir>` fast since it doesn't have to scan
  GBs of SQL on every project save
- The graphing tool reads both as a merged view via the multi-DB
  resolver

Build it with:

```
drag-lint index C:\Projects\DB\SQL --db drag-lint-sql.sqlite
```

Then the IDE plugin / graphing tool passes it:

```
drag-lint lsp \
    --db drag-lint.sqlite \
    --db drag-lint-sql.sqlite \
    --db drag-lint-library.sqlite
```

---

## 2. Schema — uses the existing `symbols` + `refs` tables

No new tables for Tier 1. `symbols.signature` carries the verbatim
column type (e.g. `D_INTEGER NOT NULL`, `VARCHAR(40)`,
`NUMERIC(10,2) DEFAULT 0`). Triggers emit a `refs` row of kind
`sql_table_ref` pointing at the target table by name.

### Example after indexing `MS1.SQL`

```
-- symbols
id  kind            name                    qualified_name              signature
--  --------------- ----------------------- --------------------------- ----------------------
1   sql_table       OPERAT                  OPERAT
2   sql_column      OPER_ID                 OPERAT.OPER_ID              D_INTEGER NOT NULL
3   sql_column      OPER_NO                 OPERAT.OPER_NO              VARCHAR(10) NOT NULL
4   sql_column      OPER_NAME               OPERAT.OPER_NAME            VARCHAR(40)
...
N   sql_generator   GEN_OPERAT_ID
N+1 sql_trigger     OPERAT_BI
N+2 sql_table       FIB$FIELDS_INFO
...

-- refs (trigger -> table)
id  kind            name_text       file_id  start_line  start_col
--  --------------- --------------- -------- ----------- ---------
N+1 sql_table_ref   OPERAT          ...      234         3
```

---

## 3. Queries the graphing tool will want

### 3.1. All tables in the SQL DB

```sql
SELECT name, qualified_name, start_line
FROM   symbols
WHERE  kind = 'sql_table'
ORDER  BY name;
```

### 3.2. All columns of a table (with their types)

```sql
SELECT c.name, c.signature
FROM   symbols c
JOIN   symbols t ON t.id = c.parent_id
WHERE  t.name = :table_name
  AND  c.kind = 'sql_table'
  AND  c.kind = 'sql_column'
ORDER  BY c.start_line;
```

### 3.3. Triggers attached to a table

```sql
SELECT t.name AS trigger_name, t.start_line
FROM   symbols t
JOIN   refs r  ON r.kind = 'sql_table_ref'
JOIN   symbols tbl ON tbl.name = r.name_text AND tbl.kind = 'sql_table'
WHERE  tbl.name = :table_name
  AND  t.kind = 'sql_trigger';
```

### 3.4. All custom domains used in a table

```sql
SELECT DISTINCT d.name, d.qualified_name
FROM   symbols c
JOIN   symbols t ON t.id = c.parent_id
JOIN   symbols d ON d.kind = 'sql_domain'
                AND c.signature LIKE d.name || '%'
WHERE  t.name = :table_name;
```

---

## 4. Graph rendering — what to show, how

### Node styling per SQL kind

| Kind           | Recommended shape   | Color hint     | Notes                  |
|----------------|---------------------|----------------|------------------------|
| `sql_table`    | Box                 | Steel blue     | Show pk-icon in corner |
| `sql_column`   | Inside-table label  | Inherits table | Type chip on hover     |
| `sql_index`    | Small diamond       | Lighter blue   | Edge -> indexed table  |
| `sql_trigger`  | Hexagon             | Orange         | Edge -> attached table |
| `sql_generator`| Cylinder            | Dark gray      |                        |
| `sql_view`     | Box w/ dashed border| Steel blue     |                        |
| `sql_procedure`| Rounded box         | Olive          |                        |
| `sql_exception`| Triangle            | Red            |                        |
| `sql_domain`   | Tag                 | Olive-yellow   | Used as type qualifier |

### Edge styling per ref kind

| Edge kind            | Style                         |
|----------------------|-------------------------------|
| `sql_table_ref` (trigger or index → table) | Solid arrow         |
| `sql_column_ref` (planned, Tier 3)         | Thin grey line      |
| Cross-DB ORM binding (planned, Tier 3)      | Dashed colored line |

---

## 5. Tier 2 — live Firebird snapshot (PLANNED)

`drag-lint fb-snapshot --connection <FireDAC-connstr> --db drag-lint-sql.sqlite`

Adds these tables to `drag-lint-sql.sqlite`:

```sql
CREATE TABLE fb_relations (
  id, name, sql_table_symbol_id, owner, system_flag, snapshot_at
);

CREATE TABLE fb_columns (
  id, relation_id, name, position, field_source, field_type,
  field_length, field_scale, field_precision, nullable,
  default_value, sql_column_symbol_id, snapshot_at
);

CREATE TABLE fb_field_info (   -- mirrors FIB$FIELDS_INFO
  id, field_name, table_name, caption, format_mask, edit_mask,
  visible, read_only, alignment, width, fib_version, snapshot_at
);

CREATE TABLE fb_datasets (     -- mirrors FIB$DATASETS_INFO
  id, ds_id, description, select_sql, update_sql, insert_sql,
  delete_sql, refresh_sql, name_generator, key_field,
  update_table_name, conditions, fib_version, snapshot_at
);

CREATE TABLE fb_enum_values (  -- mirrors FIB$ENUMVALUES
  id, enum_name, value_code, value_label, snapshot_at
);
```

`snapshot_at` is a Unix timestamp so multiple snapshots can coexist for
drift detection over time.

Cross-link to the Tier 1 sql_* symbols by name:
`fb_relations.sql_table_symbol_id` and `fb_columns.sql_column_symbol_id`
are nullable FKs into the `symbols` table.

### Graphing queries unlocked

```sql
-- Show every UI form whose Delphi class binds via FIB$DATASETS_INFO
SELECT d.description, d.update_table_name
FROM   fb_datasets d
WHERE  d.ds_id = :ds_id;

-- Diff: column type in MS*.SQL vs live FB
SELECT s.qualified_name, s.signature AS ddl_type, c.field_type AS live_type
FROM   symbols s
JOIN   fb_columns c ON c.sql_column_symbol_id = s.id
WHERE  s.signature NOT LIKE '%' || c.field_type || '%';

-- Enum code -> human-readable label
SELECT enum_name, value_code, value_label
FROM   fb_enum_values
WHERE  enum_name = :enum_name;
```

---

## 6. Tier 3 — Delphi ↔ SQL ORM linker (PLANNED)

`drag-lint link-orm --db drag-lint.sqlite --db drag-lint-sql.sqlite`

The Micronite codebase uses a naming convention enforced by DB-RAD's
generator:

- File `uXXX.PAS` contains class `TXXX`
- Class `TXXX` is the ORM for SQL table `XXX`
- Class fields named `FYYY` map to columns named `YYY`

The linker walks both DBs and emits `orm_links` rows:

```sql
CREATE TABLE orm_links (
  id, delphi_symbol_id, delphi_db_index,
       sql_symbol_id,    sql_db_index,
  confidence REAL,        -- 1.0 exact, 0.9 F-prefix strip, 0.7 fuzzy
  link_kind TEXT,         -- 'class_to_table' | 'field_to_column' | 'iface_to_table'
  evidence TEXT           -- 'naming_convention_T_strip' / 'naming_convention_F_strip'
);
```

`delphi_db_index` / `sql_db_index` track which `--db` each end came
from — same cross-DB pattern as the rest of v0.40.5.

### Graphing queries unlocked

```sql
-- Bipartite Delphi -> SQL
SELECT d_class.qualified_name AS delphi,
       sql_t.qualified_name   AS sql_table,
       l.confidence
FROM   orm_links l
JOIN   symbols d_class ON d_class.id = l.delphi_symbol_id
JOIN   symbols sql_t   ON sql_t.id   = l.sql_symbol_id
WHERE  l.link_kind = 'class_to_table';

-- "Which forms display SQL column OPER_NO?"
SELECT f.qualified_name AS form, count(*) AS uses
FROM   refs r
JOIN   symbols f ON f.id = r.symbol_id
JOIN   orm_links l ON l.delphi_symbol_id = r.symbol_id
JOIN   symbols sql_c ON sql_c.id = l.sql_symbol_id
WHERE  sql_c.name = 'OPER_NO'
  AND  l.link_kind = 'field_to_column'
GROUP  BY f.qualified_name;

-- "ALTER COLUMN cascade impact"
SELECT DISTINCT delphi.qualified_name
FROM   symbols sql_c
JOIN   orm_links l ON l.sql_symbol_id = sql_c.id
JOIN   symbols delphi ON delphi.id = l.delphi_symbol_id
WHERE  sql_c.name = :column_name AND sql_c.kind = 'sql_column';
```

---

## 7. JSON contract additions for the graph emitter

When the graph exporter emits SQL symbols, each node gains these
fields beyond the basic `id/label/kind/file/line/col/layer/db_index`:

```json
{
  "id":         "OPERAT.OPER_NO",
  "label":      "OPER_NO",
  "kind":       "sql_column",
  "parent_id":  "OPERAT",
  "sql_type":   "VARCHAR(10) NOT NULL",
  "is_pk":      false,                    // populated when Tier 2 fb_columns row exists
  "is_fk":      false,
  "nullable":   false,                    // derived from signature, fallback to fb_columns
  "db_index":   1
}
```

For `sql_table` nodes:

```json
{
  "id":         "OPERAT",
  "label":      "OPERAT",
  "kind":       "sql_table",
  "child_count":  18,                     // number of sql_column children
  "trigger_count": 2,                     // count of sql_table_ref refs from triggers
  "domain_signatures": ["D_INTEGER","D_VARCHAR40"],  // optional, useful for grouping
  "orm_class":  "TOPERAT",                // populated when Tier 3 link exists
  "db_index":   1
}
```

When Tier 3 ships, an additional edge kind appears:

```json
{ "src": "Foo.TOperat",          "src_db": 0,
  "dst": "OPERAT",               "dst_db": 1,
  "kind": "orm_class_to_table",
  "confidence": 1.0,
  "cross_db": true }
```

---

## 8. In-repo file references (drag-lint)

- `src/parser/DRagLint.Parser.Sql.pas` — Firebird DDL extractor (v0.40.5)
- `src/core/DRagLint.Core.Model.pas` — new `TSymbolKind` values
  `skSqlTable` ... `skSqlConstraint`
- `src/cli/DRagLint.CLI.pas` — `TFirebirdSqlParser` added to `TIndexer.Create`
- (planned, Tier 2) `src/sql/DRagLint.Sql.FbSnapshot.pas` —
  `RDB$RELATIONS` / `FIB$FIELDS_INFO` reader
- (planned, Tier 3) `src/sql/DRagLint.Sql.OrmLinker.pas` —
  cross-DB class/table matcher
