# duckdb.mk

"DuckDB and Make are all you need!"

duckdb.mk is a minimal, highly opinionated build system for local DuckDB
projects, inspired by [dbt](https://www.getdbt.com/) and implemented as a short
Makefile. Write interlinked `SELECT` queries in an organised directory of SQL
files; duckdb.mk parses them into a dependency graph using DuckDB's
`json_serialize_sql` function and builds a corresponding directory of Parquet
tables.

DuckDB and Make are both wonderful 'Swiss army knife' tools -- together, they
make it extremely easy to build multi-stage data pipelines querying local and
external sources, e.g. for research or analytical dashboards. duckdb.mk is a
formalisation of an *ad hoc* approach that I've developed over many years of
working on data journalism and research projects at NGOs.

See [`example/`](example/) for a duckdb.mk project that analyses methane
emissions using public data and [REFERENCE.md](REFERENCE.md) for the full
interface.

## Compared with other tools

- [dbt](https://www.getdbt.com/) with
  [dbt-duckdb](https://github.com/duckdb/dbt-duckdb): a Python install, project
  and profile configuration, and `ref()` in each query. It has many more
  features, such as incremental models, snapshots and generated documentation.
- [SQLMesh](https://github.com/SQLMesh/sqlmesh): also infers dependencies
  from SQL, and adds plans, virtual environments and column-level lineage. It
  is a larger Python framework.
- A hand-written Makefile: works well, but you maintain each dependency by
  hand. duckdb.mk generates those rules from the SQL.

## Quick start

You need [DuckDB](https://duckdb.org) 1.4.1 or later, GNU Make 3.81 or later
(the version that ships with macOS works) and `curl`.

Include this snippet at the top of your Makefile to install duckdb.mk v0.1.1
on next build; set `DUCKDB_MK` to a newer tag, or `main`, to upgrade. Then
write a `SELECT` query as a .sql file under `models/` and run `make` to
generate a table.

```make
DUCKDB_MK = v0.1.1
include .duckdb.mk/$(DUCKDB_MK)/duckdb.mk
.duckdb.mk/%/duckdb.mk:
	curl -sSfL --create-dirs -o $@ \
	  https://raw.githubusercontent.com/ltrgoddard/duckdb.mk/$*/duckdb.mk
```

### Example

Two models, one referring to the other by name:

```sql
-- models/staging/orders.sql
select * from read_csv('data/orders.csv')

-- models/revenue.sql
select customer, sum(amount) as total
from staging.orders
group by customer
```

```console
$ make
build/staging/orders.parquet: 3 rows
build/revenue.parquet: 2 rows
$ make
make: Nothing to be done for `all'.
```

## How it works

duckdb.mk implements the four features that represent 99% of my own dbt use:

- Individual `SELECT` queries map one-to-one to output tables
- A query in one file can refer to the output table from another
- Tables are rebuilt like Make targets, including their dependencies
- Settings can be controlled through project-level variables

Unlike dbt, duckdb.mk requires no configuration or hand-maintained metadata:
table and schema names are derived from filenames and directories, while
internal references are resolved automatically (no need for dbt's
`ref("model")`).

This project does not aim to implement the 'full fat' features of dbt like
incremental rebuilds, automated documentation and tight integration with remote
data warehouses. It's aimed at individual data engineers and small teams who
want to build neat, reproducible data pipelines that run on a single machine.

## How to use it

duckdb.mk is delivered as a single ~250-line file, which is mostly SQL.
The recommended way to deploy it is to `include` it in your project's existing
Makefile, alongside variable definitions and additional targets for things
DuckDB can't do (e.g. downloading and extracting complex source data). For
simple projects using only DuckDB features and passing variables at build time,
the file can be renamed to `Makefile` and used directly.

SQL queries representing tables are stored in a `models/` directory, with
subdirectories representing (and naming) schemas. Each table definition is a
.sql file containing a single `SELECT` statement, which can refer freely to
other schemas and tables in the collection by name.

Tests are stored in `tests/` and macros -- SQL run before every model statement
-- in `macros/`. Built Parquet tables are stored in `build/` organised by
schema. `data/` is conventionally used for downloaded source data, but this
location is optional and sources are often remote.

Build tables in the normal Make way, by running `make
build/schema/table.parquet`. duckdb.mk will take care of dependencies,
including checking modification dates of local and remote resources to save on
full rebuilds and ensure fresh data when needed. Each run also writes the
dependency graph to `build/dag.mmd` as a [Mermaid](https://mermaid.js.org)
flowchart.

## Development

`./test.sh` runs the end-to-end tests in `test/` in parallel against real `make`
and `duckdb` executables (set `MAKE` and `DUCKDB` to try others). They cover
rebuilds, dependency resolution, errors, remote sources over HTTP and S3, a
pipeline over millions of generated rows and a random 300-model project checked
against an independent model of its dependency graph. `./bench.sh [git ref ...]`
times the working copy against earlier versions.

Contributions -- bug fixes, ergonomics, new features -- are encouraged. Please
file an issue in the first instance.
