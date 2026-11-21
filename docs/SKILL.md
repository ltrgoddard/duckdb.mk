---
name: duckdb-mk
description: Build, change and verify DuckDB pipelines using duckdb.mk.
  Use for projects whose Makefile includes duckdb.mk, or when the user
  asks to set up a duckdb.mk project.
---

# duckdb.mk pipelines

## Overview

duckdb.mk is a short Makefile that builds a DuckDB project. Each `.sql` file
under `models/` holds one `SELECT` statement and becomes one Parquet table
under `tables/`. duckdb.mk parses every query with DuckDB itself, finds the
tables, files, URLs and environment variables that it reads, and gives Make
the dependency graph. There is no configuration file and no `ref()`: a query
refers to another model by its name.

Use SQL models for transformations and Make rules for other processing.
Follow the project's existing tools and conventions; avoid adding a framework
for work that DuckDB and Make already handle.

The inspector (`make inspect`) shows queries as steps and lets a reviewer
inspect intermediate results. Small models, literal source paths and leading
SQL comments make that review easier.

## Before you start

1. Find the version. The Makefile sets `DUCKDB_MK` to a tag or a branch. The
   full interface for that version is in its `REFERENCE.md`:
   `https://raw.githubusercontent.com/ltrgoddard/duckdb.mk/<DUCKDB_MK>/docs/REFERENCE.md`
   (at the top of the repository up to v0.2.0).
   Read it when this skill does not answer a question.
2. Check the DuckDB version with `duckdb --version`. duckdb.mk needs 1.4.1 or
   later. DuckDB 2.0 rejects `x -> x + 1` lambdas by default; write
   `lambda x: x + 1`, which works from 1.4. When an agent runs it, DuckDB 2.0
   prints a notice and gives errors as JSON: add `-no-agent` to your own
   `duckdb` commands for the usual output. duckdb.mk's output is not
   affected.
3. Read the existing models, tests and macros before you add any. Follow the
   project's schemas and names.

## Project layout

| Path              | Contents                                                  |
| ----------------- | --------------------------------------------------------- |
| `Makefile`        | The `include` of duckdb.mk, variables and rules for inputs |
| `models/**/*.sql` | One `SELECT` per file; each builds one table              |
| `tests/**/*.sql`  | One `SELECT` per file; a test fails if it returns rows    |
| `macros/*.sql`    | Any SQL, run before every model, test and shell           |
| `data/`           | Downloaded inputs, by convention                          |
| `tables/`         | Built tables and the generated plan                       |

Names come from paths. `models/census/counties.sql` builds
`tables/census/counties.parquet`, the table `census.counties`. A file at the
top of `models/` is in the schema `main`. Deeper directories do not change the
name: `models/a/b/c.sql` is `a.c`. Use only letters, digits, `_`, `-` and `/`
in paths.

Commit `Makefile`, `models/`, `tests/`, `macros/` and any query files. Put
`tables/`, `data/` and `.duckdb.mk/` in `.gitignore`.

## Set up a new project

```make
# variables that queries read with getenv() must be exported
export RADIUS ?= 250

DUCKDB_MK = v0.3.0
include .duckdb.mk/$(DUCKDB_MK)/duckdb.mk
.duckdb.mk/%/duckdb.mk:
	curl -sSfL --create-dirs -o $@ \
	  https://raw.githubusercontent.com/ltrgoddard/duckdb.mk/$*/duckdb.mk

# rules for inputs that DuckDB cannot fetch go after the include
data/plants.csv:
	curl -sSf --create-dirs -o $@ https://example.org/plants.csv
```

Use the latest tag from the releases page unless the user names a version.
The SQL and commit stored in each table need v0.3.0 or later. The inspector
needs DuckDB 2.0 or later; consult the pinned version's reference for its
inspector interface.
Define extra targets after the `include`, so that `all` stays the default.

## Model constraints

**Write exactly one `SELECT` statement in each file.** The plan rejects
`CREATE`, `INSERT`, `SET` and more than one statement. When you split a
script, each `create table ... as` becomes a model, and so does each view and
each temporary table that a later statement reads; each `create macro` goes
in `macros/`; a `set variable` becomes a one-row CTE. A `PIVOT` must list
its values, because DuckDB cannot serialise one that finds them in the data:

```sql
pivot generation on fuel in ('gas', 'coal') using sum(mwh) group by plant
```

**Refer to other models by name.** Write `from census.counties`, or
`from matches` for a model in `main`. A misspelled table in a model schema
stops the plan (`no model census.countys`). The reference creates a
dependency on that model. A CTE with the same name hides the
model inside its scope, as in DuckDB.

**Use source paths that can be tracked.** duckdb.mk finds a source only where DuckDB
reads a string as one: a table name (`from 'data/x.csv'`) or an argument of a
table function (`read_csv('data/*.csv')`, `read_parquet(['a', 'b'])`). A path
built at run time, such as `'data/' || year || '.csv'`, is not a dependency,
is not checked for changes and is not shown in the inspector. When a path
must change, put the changing part in an environment variable, first, with
the rest after it as one literal: `read_csv(getenv('RAW') || '/x.csv')`.
duckdb.mk then checks that file as well as the variable.

**Use a suffix for partitioned models.** `models/eog/detections@cell.sql`
builds one file for each value of `cell` under `tables/eog/detections/` and
keeps the name `eog.detections`. A partitioned model that returns no rows
fails.

**Keep macros small.** Every file in `macros/` runs before every model and
test, and a change to one rebuilds everything. Use macros for shared
functions (`create macro`) and for `install` and `load` of extensions. A
macro cannot read a model: DuckDB 2.0 looks up a macro's tables when it
creates the macro, before any model has a view. Join the table in the model,
or give a table macro the table's name (see the tests below).

## Conventions for reviewable models

Use these as defaults, following the project's needs and existing style.

**Start every model with a description.** The leading `--` comment is the
model's description in the inspector. A line that holds only `--` separates
a longer note from it:

```sql
-- each plume and the nearest mapped facility within RADIUS metres, if any
--
-- facilities are matched on a bounding box first, then on distance.
select ...
```

**Keep models small and named for what they hold.** Give a table its own model
when a reviewer would want to see its rows: a cleaned source, a join, an
aggregate. Use CTEs for short local steps inside one model. A chain of many
CTEs is harder to review than two or three models.

**Fetch remote data in a separate model where practical.** Joining remote
sources directly to other models is supported, but each rebuild or inspector
edit may fetch the data again. A separate source model lets downstream
queries reuse the built table.

**Select columns explicitly in final tables.** `select *` passes upstream
changes through silently. Name the columns that a published table promises.

**Cast deliberately.** `try_cast` turns unparseable values into nulls without
an error. Use `cast` where bad input should stop the build. Where `try_cast`
is necessary, add a test that counts the values it lost.

**Give an order where the result depends on it.** Each table is a file that
DuckDB reads with several threads, so rows have no fixed order between
builds. Write the `order by` in `row_number() over (...)`, `first(x order
by ...)`, `list(x order by ...)` and before a `limit`.

## Write tests

A test is a query that returns the rows that break a rule. Name each test for
its rule, such as `tests/matches_unique.sql`:

```sql
select id from matches group by id having count(*) > 1
```

Write a test for each assumption that the pipeline depends on:

- The key (grain) of every table is unique.
- Key columns are not null.
- Values are in their expected range (`where kg_h < 0`).
- Row counts agree between models that must agree, such as a model and its
  source after a left join.
- Values lost by `try_cast` are below a threshold that you state.

For rules that repeat, define table macros in `macros/tests.sql`:

```sql
-- rows where any column matching the pattern p is null
create macro nulls(t, p) as table
  from query_table(t)
  except all from query_table(t) where columns(p) is not null;
-- values of k that occur more than once
create macro dupes(t, k) as table
  select k, count(*) as n from query_table(t) group by all having n > 1;
```

```sql
-- tests/plants_keys.sql
from nulls('main.plants', '_id$')
```

Give the table name with its schema (`'main.plants'`, not `'plants'`), so
that duckdb.mk sees the dependency. Do not write `where columns(p) is null`:
DuckDB joins the expanded conditions with `AND`, so it finds rows where every
matched column is null, not any. Write one rule in each test file: a failing
test shows its three smallest rows, which can all be from one rule.

## Inputs that DuckDB cannot fetch

Write a Make rule that creates the file, and name the file in a model. A
literal path with a directory is a dependency, so Make runs the rule first.
Write to a temporary file and move it into place, so that a failed run keeps
the previous input:

```make
data/osm.json: queries/osm.overpassql
	curl -sSf --create-dirs -o $@.tmp --data-urlencode data@$< \
	  https://overpass-api.de/api/interpreter
	mv $@.tmp $@
```

A rule can also run another program between two models: depend on the
upstream table (`tables/x.parquet`) and write a file that a downstream model
reads. The rule runs again each time the upstream table is written.

## Variables and secrets

A model reads a variable with `getenv('NAME')`. duckdb.mk checks the value on
every run and rebuilds the models that read it when it changes. Export the
variable in the Makefile (`export NAME ?= value`), or set it for a group of
models with a target-specific export:

```make
tables/gem/%: export RAW_URI = s3://bucket/gem/2026-11-01
```

Never put a credential in a model or a macro. Leave credentials in the shell's
environment and create DuckDB secrets from them in a macro if needed.

## Build and verify

After changing a pipeline, build and test the affected models, inspect the
results and report what was verified:

1. **Build.** Run `make`. Each table prints `<target>: <n> rows`. Compare
   each count with the intended grain and filters. Unexpected growth after
   a join can reveal duplicate keys; an unexpectedly empty result can reveal
   a bad filter or join condition.
2. **Test.** Run `make test`. A failing test prints its row count and three
   example rows, and stops.
3. **Look at the rows.** Query a table directly:
   `duckdb -c "summarize from 'tables/matches.parquet'"`, or open `make shell`
   for a view of every built model. Check null counts, ranges and distinct values
   for the columns that you changed.
4. **Check what built a table.** Each table stores the SQL that built it and
   the git commit:
   `duckdb -c "select decode(key), decode(value) from parquet_kv_metadata('tables/x.parquet')"`.
5. **Hand over for review.** Name the changed models and relevant results.
   Point to useful steps in `make inspect`, and mention anything you could
   not build or test.

To rebuild one table, `touch` its model's file and run `make`.
`make -B` rebuilds a target and everything it depends on.

## Common problems

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| `Only SELECT statements can be serialized to json` | A model or test holds `CREATE`, `SET` or another statement, or a `PIVOT` with no `in` list | Move setup into `macros/`; keep one `SELECT` per file; list the pivot's values |
| `Table with name x does not exist` for every model, at a line of a macro | A macro reads a model | Join the table in the model, or pass its name to a table macro |
| `expected one SELECT statement` | More than one statement in a file | Split it into models |
| A table is not rebuilt after an edit | The edit fell in the same second as the build; Make 3.81 compares whole seconds | `touch` the model's file and run `make`; the inspector says to rebuild it |
| A model runs before its input exists | The path is built at run time | Write the path as a literal, or use `getenv` |
| `Table with name x does not exist` in a test macro | The name passed to `query_table` has no schema | Pass `'main.x'` or `'schema.x'` |
| `Deprecated lambda arrow` | DuckDB 2.0 rejects `->` lambdas | Write `lambda x: ...` |
| `Too many open files` | A partitioned model has more values than the open-file limit on DuckDB 1.x | Partition on a coarser column, or use DuckDB 2.0 |

## Reference

- `REFERENCE.md` at the project's version: every variable, target, rule and
  error.
- The example project, `example/` in the duckdb.mk repository: a complete
  pipeline with remote sources, macros, a variable and tests.
