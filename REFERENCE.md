# duckdb.mk reference

## Requirements

- GNU Make 3.81 or later
- The `duckdb` CLI, version 1.4 or later

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
| `BUILD`  | `build`  | Output directory            |
| `PARQUET` | none    | Extra Parquet writer options, e.g. `compression zstd, row_group_size 10000` |
| `INSPECT` | `$(BUILD)/inspect` | Directory of the inspector's page |
| `INSPECT_HIDE` | none | Regular expression of the models and tests that the inspector leaves out |

Set them before the `include` or on the command line. `PARQUET` can also be
set for one model or a group of them with a target-specific variable:
`build/geo/%: PARQUET = row_group_size 10000`. A changed option does not
rebuild a model: run `make -B` on the models it applies to.

## Targets

| Target                   | Action                                               |
| ------------------------ | ---------------------------------------------------- |
| `all` (default)          | Build every model                                    |
| `$(BUILD)/<path>.parquet` | Build one model and its dependencies                |
| `$(BUILD)/<path>`        | Build one partitioned model and its dependencies     |
| `test`                   | Build the models that tests need, then run all tests |
| `test/<path>`            | Run one test                                         |
| `shell`                  | Build every model, then open DuckDB with macros and a view per model |
| `inspect`                | Write the inspector's page to `$(INSPECT)`; build nothing |
| `serve`                  | Write the page, then serve it on port 8000           |
| `clean`                  | Remove `$(BUILD)`                                    |

Standard Make flags apply: `-j` builds in parallel, `-s` hides row counts and
test passes, `-n` shows what would run.

Every run also writes the dependency graph to `$(BUILD)/dag.mmd` as a
[Mermaid](https://mermaid.js.org) flowchart of models, tests and sources.

## Names

- `models/<path>.sql` builds `$(BUILD)/<path>.parquet`.
- `models/<path>@<column>.sql` builds the directory `$(BUILD)/<path>`, with
  one file for each value of the column (see below).
- The schema is the first directory under `models/`, or `main` for files at the
  top level. The table name is the filename without .sql. Deeper directories
  do not change either: `models/a/b/c.sql` is `a.c`. A `@<column>` suffix
  does not change them: `models/eog/detections@cell.sql` is `eog.detections`.
- Names are lowercased. Two models with the same schema and name are an error.
- Paths may contain only letters, digits, `_`, `-` and `/`, and a model may
  end in one `@<column>` suffix. Files with spaces are ignored by Make and
  rejected by the plan.

## Partitioned models

A partitioned model writes one Parquet file for each value of its column:

```
models/eog/detections@cell.sql
build/eog/detections/cell=0/data.parquet
build/eog/detections/cell=1/data.parquet
```

- Each file contains the column, so a read of
  `'build/eog/detections/*/data.parquet'` returns it without
  `hive_partitioning`. Directory names hold the values as DuckDB writes them:
  percent-encoded, with `__HIVE_DEFAULT_PARTITION__` for null.
- Refer to the model by name (`from eog.detections`) or with a glob over its
  files, such as `'build/eog/detections/*/data.parquet'` or
  `'build/**/*.parquet'`. A path to one partition, such as
  `'build/eog/detections/cell=1/data.parquet'`, is not a dependency.
- Every file stores the fingerprint. The build writes to `$(BUILD)/<path>.tmp`
  and then replaces the directory, so a failed build keeps the previous
  partitions and a rebuild leaves no stale ones.
- A model that returns no rows fails, as DuckDB writes no files for it.

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

## Dependencies

duckdb.mk parses every model and test with `json_serialize_sql`. A file depends
on:

| In the SQL                           | Dependency                              |
| ------------------------------------ | --------------------------------------- |
| `schema.table` or `table`            | The matching model (`main` if no schema) |
| `'build/x.parquet'` or `'schema.table'` as a string | The matching model       |
| A local file path, e.g. `'data/x.csv'` or `sqlite_scan('data/x.db', 't')` | That file; a Make rule can create it |
| A bare filename, e.g. `'x.csv'`      | `$(wildcard ...)` of it                 |
| A glob, e.g. `'data/*.csv'`          | `$(wildcard ...)` of it; checked on every run |
| A glob in `$(BUILD)`, e.g. `'build/marts/*.parquet'` | Every model it matches; checked on every run |
| `http://`, `s3://` and other URLs    | Checked on every run (see below)        |
| `getenv('NAME')`                     | Checked on every run (see below)        |
| Anything in `macros/`                | Every model and test                    |

Strings count where DuckDB reads them as sources: as a table name
(`from 'data/x.csv'`) or as an argument of a table function, alone or in
a list (`read_csv(['a.csv', 'b.csv'])`). A URL built at run time, such as
`'https://example.org/?key=' || getenv('KEY')`, is not checked, but the
variable is. A path in `$(BUILD)` depends only on the model that writes it.

CTE names shadow models of the same name within their scope, following
DuckDB's rules. A table name that matches no model or CTE (e.g. one created in
a macro) depends on the `models/` and `tests/` directories, so adding a model
updates the plan.

Dependency cycles are an error.

## Rebuilds

A model is rebuilt when Make finds a dependency newer than its output. A model
that reads a URL, a glob or an environment variable is also checked on every
run: its output stores a fingerprint of the SQL, the size and modification time
of each URL and each file matching each glob, and each variable's value in the
Parquet metadata. If the fingerprint matches, the model is not rebuilt, and
nothing that depends on it is either. Checking a URL costs a `HEAD` request;
one from a server that sends no `Last-Modified` header is compared by size
alone. A remote glob costs only the bucket listing, with no request for each
object: on DuckDB 1.5.5 against CloudFerro S3, the fingerprint of a glob of
9,565 objects (6.7 GB) took 4.7 s. A glob over a large mirror needs no pointer
file.

Outputs are written to a temporary file or directory and moved into place, so
a failed or interrupted build leaves the previous output, and the next run
tries again.

Each output also stores, under the keys `sql` and `commit`, the SQL that
built it and `git describe --always --dirty` (empty outside a git
repository). Neither is part of the fingerprint. To see what built a table:

```sql
select decode(key), decode(value) from parquet_kv_metadata('build/x.parquet')
```

### Track an external run

A model can read the output of a run outside duckdb.mk through an environment
variable. This needs no extra code:

```sql
-- models/gem/plants.sql
select * from read_csv(getenv('RAW_URI') || '/plants.csv')
```

```make
build/gem/%: export RAW_URI = s3://bucket/gem/2026-11-01
```

The target-specific `export` sets the variable for each model in `build/gem/`.
duckdb.mk checks its value on every run and rebuilds the models that read it
when it changes. The path built at run time is not fingerprinted, only the
variable: point the variable at a new run, and do not change the files of an
old one.

## Output

Each built model prints `<target>: <n> rows`. Each passing test prints
`test/<path>: pass`. A failing test prints its row count and its three
smallest rows as examples, and stops Make.

## Errors

The plan stops with a message for:

- A file that does not parse, or is not exactly one `SELECT` statement
  (DuckDB cannot yet serialise `PIVOT`, even in a subquery: pivot with
  aggregate `filter` clauses instead)
- A path with characters other than letters, digits, `_`, `-` and `/`, except
  for one `@<column>` suffix on a model
- A duplicate model name
- A dependency cycle

## Include in a Makefile

```make
# visible to getenv('NAME')
export NAME ?= value
# a branch or tag
DUCKDB_MK = v0.2.0
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

## Inspector

`make serve` shows the project as a page: its models and tests, their
dependencies as the plan has them, and each query as steps that run in the
browser. `make inspect` writes the page and does not serve it. Make fetches
the page, one HTML file, at the version in `DUCKDB_MK`, the first time. With a
local copy of `duckdb.mk`, put the repository's `inspect/` directory beside
it.

The page builds no model. Each run writes `inspect.json` from the plan and
links into `$(INSPECT)/files` every built table and every local file that a
model names, by hard link, or by copy on another filesystem. A model without
a table shows as not built, and its SQL and steps can still be read.
`$(INSPECT)` is a static site. To publish it, set `INSPECT` to a directory of
a site, such as `site/inspect`. To build before each write, and to write on
each `make`:

```make
inspect: $(models)
all: inspect
```

- A model's leading `--` comment is its description. A line that holds only
  `--` separates a note from it.
- A query shows as steps in words or as its SQL, as last chosen. A click on
  a step or a clause runs the query to it and marks it in both.
- A test shows the rows that fail it.
- A model whose table stores SQL that differs from its file is in italics,
  and its page says to rebuild it: its rows are from the earlier version.
- `getenv` returns a variable's value in the page only if the Makefile or
  the `make` command line sets it. A value from the shell's environment,
  where secrets are, is never written to `inspect.json`, and is an empty
  string in the page. So is a target-specific value.
- `INSPECT_HIDE` leaves the matching models and tests out of the list and
  the graph, and does not link the files that only they name. Their tables
  are still linked, because the steps of other models read them: a hidden
  table in a published page can be downloaded by its path.
- Macros run in the browser in file order. A statement that fails there,
  such as a setting or an extension that DuckDB-Wasm lacks, is skipped with
  a warning in the console.
- A step that reads a URL works only if the server allows cross-origin
  requests. Files outside the project, and paths built at run time, are not
  linked.
- The page loads DuckDB-Wasm and
  [sql-formatter](https://github.com/sql-formatter-org/sql-formatter) from
  jsDelivr at fixed versions, so the first load needs a network connection.
  DuckDB-Wasm has about 4 GB of memory and one thread.

## Steps that DuckDB cannot do

A Make rule can run another program between two models. This example uses
Bricolage, a SQLite extension that runs LLM research agents:

```sql
-- models/candidates.sql
select company from read_csv('data/companies.csv') where parent is null

-- models/resolved.sql
select * from sqlite_scan('data/research.db', 'company_parent')
```

```make
data/research.db: build/candidates.parquet jobs/company_parent.sql
	rm -f $@.tmp
	BRIC_AUTO=0 sqlite3 $@.tmp -cmd '.load ext/bric' < jobs/company_parent.sql
	$(DUCKDB) -c "attach '$@.tmp' as r (type sqlite); \
	  insert into r.candidates select * from '$<'"
	sqlite3 $@.tmp -cmd '.load ext/bric' 'select bric_process(6)'
	mv $@.tmp $@
```

`resolved` names `data/research.db`, a path with a directory, so the plan
makes that file a dependency and Make runs the rule after it builds
`candidates`. The job file creates the job's tables, including `candidates`;
with `BRIC_AUTO=0`, loading the extension starts no background workers.
`bric_process` returns when every key is done, and `sqlite3` exits with an
error if a key used up its attempts. Make then stops before `resolved` and
keeps the previous `data/research.db`.
