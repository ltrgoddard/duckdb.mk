# duckdb.mk reference

- [Setup](#requirements): requirements, [Makefile](#include-in-a-makefile) and [project layout](#project-layout)
- [Commands](#targets) and [variables](#variables)
- [Models](#names): names and [partitions](#partitioned-models)
- [Dependencies](#dependencies) and [rebuilds](#rebuilds)
- [Output](#output) and [errors](#errors)
- [Inspector](#inspector) and [agent skill](#agent-skill)

## Requirements

- GNU Make 3.81 or later
- The `duckdb` CLI, version 1.4.1 or later
- `curl` to fetch duckdb.mk and the inspector
- DuckDB 2.0 or later for the inspector

See also [recipes](RECIPES.md) and [development](DEVELOPMENT.md).

## Include in a Makefile

```make
# visible to getenv('NAME')
export NAME ?= value
# a branch or tag
DUCKDB_MK = v0.3.1
include .duckdb.mk/$(DUCKDB_MK)/duckdb.mk
.duckdb.mk/%/duckdb.mk:
	curl -sSfL --create-dirs -o $@ \
	  https://raw.githubusercontent.com/ltrgoddard/duckdb.mk/$*/duckdb.mk

data/x.csv:           # rules for inputs DuckDB cannot fetch
	curl -o $@ https://example.org/x.csv
```

Define extra targets after the `include` so that `all` stays the default.
Make downloads `.duckdb.mk/$(DUCKDB_MK)/duckdb.mk` once; delete that directory
to update a branch. Tags are listed on the [releases page](https://github.com/ltrgoddard/duckdb.mk/releases).
A local copy also works: `include duckdb.mk`.

## Project layout

| Path                | Role                                                  |
| ------------------- | ----------------------------------------------------- |
| `models/**/*.sql`   | One `SELECT` statement per file, built to Parquet     |
| `tests/**/*.sql`    | One `SELECT` statement per file, failing if it returns rows |
| `macros/*.sql`      | Any SQL, run before every model, test and shell       |
| `$(BUILD)/`         | Output tables and the generated `plan.mk`             |

All directories are optional. Run `make` from the project root.

## Variables

| Variable | Default  | Meaning                     |
| -------- | -------- | --------------------------- |
| `DUCKDB` | `duckdb` | DuckDB executable           |
| `BUILD`  | `tables` | Output directory            |
| `PARQUET` | none    | Extra Parquet writer options, e.g. `compression zstd, row_group_size 10000` |
| `PORT`   | `9494`   | Port of the inspector's DuckDB |

Set them before the `include` or on the command line. `PARQUET` can also be
set for one model or a group of them with a target-specific variable:
`tables/geo/%: PARQUET = row_group_size 10000`. A changed option does not
rebuild a model: run `make -B` on the models it applies to.

## Targets

| Target                   | Action                                               |
| ------------------------ | ---------------------------------------------------- |
| `all` (default)          | Build every model                                    |
| `$(BUILD)/<path>.parquet` | Build one model and its dependencies                |
| `$(BUILD)/<path>`        | Build one partitioned model and its dependencies     |
| `test`                   | Build the models that tests need, then run all tests |
| `test/<path>`            | Run one test                                         |
| `shell`                  | Open DuckDB with the macros and a view of each built model; build nothing |
| `query`                  | Run the query in `Q` as `shell` would, print CSV; build nothing |
| `inspect`                | Open the inspector and log its queries; build nothing |
| `clean`                  | Remove `$(BUILD)`                                    |

Standard Make flags apply: `-j` builds in parallel, and `-s` hides row counts
and test passes.

Every run also writes the dependency graph to `$(BUILD)/dag.mmd` as a
[Mermaid](https://mermaid.js.org) flowchart of models, tests and sources.

## Names

The first directory under `models/` names the schema; files directly in
`models/` use `main`. The filename names the table. Deeper directories and
partition suffixes do not change the SQL name.

| Model file | SQL name | Output (default `BUILD`) |
| ---------- | -------- | ------------------------ |
| `models/orders.sql` | `main.orders` | `tables/orders.parquet` |
| `models/staging/orders.sql` | `staging.orders` | `tables/staging/orders.parquet` |
| `models/a/b/c.sql` | `a.c` | `tables/a/b/c.parquet` |
| `models/eog/detections@cell.sql` | `eog.detections` | `tables/eog/detections/` |

Names are lowercased. Two models with the same schema and table name are an
error. Paths may contain letters, digits, `_`, `-` and `/`, with one
`@<column>` suffix for a partitioned model. Files with spaces are ignored by
Make and rejected by the plan.

## Partitioned models

A partitioned model writes one Parquet file for each value of its column:

```
models/eog/detections@cell.sql
tables/eog/detections/cell=0/data.parquet
tables/eog/detections/cell=1/data.parquet
```

- Each file contains the column, so a read of
  `'tables/eog/detections/*/data.parquet'` returns it without
  `hive_partitioning`. Directory names hold the values as DuckDB writes them:
  percent-encoded, with `__HIVE_DEFAULT_PARTITION__` for null.
- Refer to the model by name (`from eog.detections`), with a glob over its
  files, such as `'tables/eog/detections/*/data.parquet'` or
  `'tables/**/*.parquet'`, or by the path of one partition, such as
  `'tables/eog/detections/cell=1/data.parquet'`.
- Every file stores the fingerprint. The build writes to `$(BUILD)/<path>.tmp`
  and then replaces the directory, so a failed build keeps the previous
  partitions and a rebuild leaves no stale ones.
- A model that returns no rows fails, as DuckDB writes no files for it.

<details>
<summary>Partition writer limits on DuckDB 1.x</summary>

DuckDB starts a second file for a partition when it closes the partition's
file before the last row. DuckDB 1.4 and 1.5 keep at most
`partitioned_write_max_open_files` files open (100 by default); sorting by the
column does not prevent a split with more than one thread, and the flush
threshold does not cause one. duckdb.mk sets the limit to 10^9 and raises the
shell's soft limit on open files to the hard limit, so DuckDB 1.x holds one
open file for each value until the write ends. With more values than the hard
limit (`ulimit -Hn`), the build fails with `Too many open files`. DuckDB 2.0
writes one file for each value without this limit. If a partition gets more
than one file, the build fails with `<target>: <n> files for <m> partitions,
expected one each`.

</details>

## Dependencies

duckdb.mk parses every model and test with `json_serialize_sql`. A file depends
on:

| In the SQL                           | Dependency                              |
| ------------------------------------ | --------------------------------------- |
| `schema.table` or `table`            | The matching model (`main` if no schema) |
| `'tables/x.parquet'` or `'schema.table'` as a string | The matching model       |
| Another path in `$(BUILD)`, e.g. `'tables/solve.csv'` | That file; a Make rule can create it |
| A local file path, e.g. `'data/x.csv'` or `sqlite_scan('data/x.db', 't')` | That file; a Make rule can create it |
| A bare filename, e.g. `'x.csv'`      | `$(wildcard ...)` of it                 |
| A glob, e.g. `'data/*.csv'`          | `$(wildcard ...)` of it; checked on every run |
| A glob in `$(BUILD)`, e.g. `'tables/marts/*.parquet'` | Every model it matches; checked on every run |
| `http://`, `s3://` and other URLs    | Checked on every run (see below)        |
| `getenv('NAME')`                     | Checked on every run (see below)        |
| `getenv('NAME') \|\| '/x.csv'`, a variable then a literal | The variable and the resulting file or glob; checked on every run |
| Anything in `macros/`                | Every model and test                    |

### Source paths

Strings count where DuckDB reads them as sources: as a table name
(`from 'data/x.csv'`) or as an argument of a table function, alone or in
a list (`read_csv(['a.csv', 'b.csv'])`). A URL built at run time, such as
`'https://example.org/?key=' || getenv('KEY')`, is not checked, but the
variable is. The one path built at run time that is checked is a variable
followed by one literal.

A path or a glob is a dependency if it has only letters, digits and
`_ . / ~ - =`, and a path must also end in an extension. DuckDB reads a path
with other characters, such as a space, but Make does not know it. A path
outside the project is a dependency like any other.

### Explicit dependencies

Add dependencies that the SQL does not reveal after the `include`:

```make
tables/b.parquet: tables/a.parquet
```

Model `b` then has a view of `a`, just as if its SQL had named it.

### Macros and name resolution

A macro cannot read a model. DuckDB 2.0 looks up each table that a macro
names when the macro is created, and no model has a view then. Give the
table's name to a table macro as an argument (`query_table(t)`), or join the
table in the model.

CTE names shadow models of the same name within their scope, following
DuckDB's rules. A table name that matches no model or CTE (e.g. one created in
a macro) depends on the `models/` and `tests/` directories, so adding a model
updates the plan.

Dependency cycles are an error.

## Rebuilds

### Local dependencies

Make rebuilds a model when a dependency is newer than its output. Changes to
macros rebuild every model and test. To force a rebuild, use `make -B`,
optionally with a target.

### URLs, globs and environment variables

These are checked on every run. Each output stores a fingerprint in its
Parquet metadata containing:

- The model's SQL.
- The size and modification time of each URL and each file matching a glob.
- The value of each environment variable read by the model.

If the fingerprint matches, the model is not rebuilt. This check alone does
not trigger downstream rebuilds.

A URL check costs a `HEAD` request. If the server sends no `Last-Modified`
header, only the size is compared. A remote glob uses a bucket listing,
without a request for each object.

See [tracking an external run](RECIPES.md#track-an-external-run) for a
variable that selects a source directory.

### Failed builds

Outputs are written to a temporary file or directory and moved into place.
A failed or interrupted build leaves the previous output, and the next run
tries again.

### Build metadata

Each output also stores the SQL that built it under `sql`, and
`git describe --always --dirty` under `commit` (empty outside a Git
repository). These provenance fields are separate from the fingerprint;
a new commit alone does not trigger a rebuild.

```sql
select decode(key), decode(value) from parquet_kv_metadata('tables/x.parquet')
```

## Output

Each built model prints `<target>: <n> rows`. Each passing test prints
`test/<path>: pass`. A failing test prints its row count and its three
smallest rows as examples, and stops Make.

## Errors

The plan stops with a message for:

- A file that does not parse (`models/x.sql:3: syntax error ...`, with the
  line), or is not exactly one `SELECT` statement. `PIVOT` and `UNPIVOT`
  count as one, but a `PIVOT` must list its values (`on fuel in ('gas',
  'coal')`): without the list, DuckDB cannot serialise it
- A path with characters other than letters, digits, `_`, `-` and `/`, except
  for one `@<column>` suffix on a model
- A duplicate model name
- A name `schema.table` where the schema has models and none is `table`
  (`models/x.sql: no model census.countys`)
- A dependency cycle

An error in a build or a test is DuckDB's own. Its `LINE` is the line of the
model's or test's file.

## Inspector

`make inspect` opens a page showing the project's models, tests and
dependencies, with each query broken into readable steps.
It needs DuckDB 2.0 or later. Make fetches the page, one HTML file,
`inspect.html`, at the version in `DUCKDB_MK`, the first time. With a local
copy of `duckdb.mk` and no `DUCKDB_MK`, put the repository's `inspect.html`
beside it: Make fetches nothing, and stops if it is not there.

### Using the inspector

Press Ctrl+C or Ctrl+D in the terminal to stop it. For a shell on the same
built tables, run `make shell` in another terminal.

The page builds no model. Each query runs in DuckDB, with its extensions, its
memory and the environment of `make`. A model without a table shows as not
built, and its SQL and steps can still be read.

### Descriptions and query steps

- A model's leading `--` comment is its description. A line that holds only
  `--` separates a note from it.
- Switch between readable steps and SQL; the page remembers the choice.
  Click a step or clause to run the query up to that point. The selection
  is highlighted in both views. Steps come from DuckDB's parsed SQL:
  `json_serialize_sql` supplies the syntax tree, and `json_deserialize_sql`
  turns the selected portion back into a query.
- A query's CTEs and subqueries are tables that it makes first, each a step
  named by its CTE or alias (else a letter). Click such a name in a step to
  go to the step that makes it. When that step is selected, the steps that
  read its table are marked.
- Each of these tables has an address, the node's address followed by
  `:` and its name, which selects its step. The back button returns to the
  step before.
- In the list, a node's tables show below it while the pointer is on it or
  while it is open. The filter also finds a node by the name of one of its
  tables.
- In a node's lineage, its tables are dashed boxes between the models that
  they read and the node.

### Editing SQL

- The SQL can be changed in place. The Run button, or Ctrl+Enter (Cmd+Enter
  on macOS), runs it: the steps and the rows are then those of the changed
  SQL. Revert goes back to the file's SQL. Only one `select` statement can
  run.
- Running an edit also updates downstream models. DuckDB
  computes the changed model and its downstream models once, in dependency
  order, and holds them as tables in memory. This can take as long as rebuilding
  those models. Each affected node says `Recomputed from edit to` and
  the changed model's name before its row count. A model that fails shows
  its error; dependent nodes report that failure. A model
  that reads a table by its path, not its name, does not see the change.
- Edits and recomputed tables stay in memory until `make inspect` stops.
  They survive a page reload; source files and built tables are unchanged.

### Results and limits

- A test shows the rows that fail it.
- A model whose table stores SQL that differs from its file says to
  rebuild it when it is opened: its rows are from the earlier version.
- A step that depends on an enclosing query, such as a correlated subquery
  or a `lateral` join, cannot run alone. The page explains this when selected.

### Connection

`make inspect` starts DuckDB with the macros, a view of each built model (as
`make shell` does) and the plan, in a database named `plan`. A setting
that the macros change with `set` is made global, so that the page's
connection has it too. DuckDB serves
them on `localhost:$(PORT)` over its
[Quack](https://duckdb.org/docs/current/quack/overview) protocol, with a
random token for each run. Make then opens the page in the default browser
as `file://.../inspect.html#<port>:<token>`, and prints that address
in case the browser does not open it. The terminal then shows each query
that the page runs, on one line, cut to the terminal's width. Edits are
stored in `plan.main.draft`, and recomputed tables in `plan.live`.

The page does not change: it reads the port and the token from its address.
It loads the [Quack client](https://github.com/tobilg/quack-protocol) from
jsDelivr, so the first load needs a network connection. On macOS, Make sends
the address to the browser with AppleScript, as
`open` drops the part after `#` from a file's address.

## Agent skill

[`SKILL.md`](SKILL.md) tells a coding agent how to build, test and hand over a
duckdb.mk project. To install it for Claude Code in a project:

```sh
curl -sSfL --create-dirs -o .claude/skills/duckdb-mk/SKILL.md \
  https://raw.githubusercontent.com/ltrgoddard/duckdb.mk/main/docs/SKILL.md
```
