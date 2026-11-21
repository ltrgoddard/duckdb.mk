# Development

The Makefile at the repository root is for work on duckdb.mk itself. The
[example project](../example/) includes the checkout's `duckdb.mk`, so it
runs the code as it is.

## Tests

```sh
make test
make test S="build deps"
```

The end-to-end tests in `test/` run in parallel against real `make` and
`duckdb` executables. Set `MAKE` and `DUCKDB` to try other versions; `S`
selects suites.

The tests cover rebuilds, dependency resolution, errors, partitioned models,
the inspector, and remote sources over HTTP and S3. Larger cases exercise a
pipeline over millions of generated rows and a random 300-model project
checked against an independent model of its dependency graph.

## Benchmarks

```sh
make bench
make bench REFS="v0.2.0 v0.3.0"
```

Benchmarks time the working copy against earlier versions.

## Releases

From a clean working tree:

```sh
make release V=v1.2.3
```

This updates the version pins in the documentation, commits, tags and pushes.
Check the documented requirements and run `make test` before releasing.
