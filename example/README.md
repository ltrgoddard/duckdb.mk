# Example: methane plumes and oil and gas infrastructure

This project matches methane plumes over New Mexico from
[Carbon Mapper](https://carbonmapper.org/) to the nearest oil and gas facility
in [OpenStreetMap](https://www.openstreetmap.org/), and summarises the matches
by facility type and county. All inputs are fetched live from public sources.

## Run it

From this directory, with the [required tools](../docs/REFERENCE.md#requirements)
installed:

```sh
make             # fetch the data and build every table
make test        # check emissions and match uniqueness
make inspect     # explore the queries and results (DuckDB 2.0+)
```

The first run takes a few minutes. The Makefile uses this checkout's
`duckdb.mk`. Downloaded inputs stay in `data/`; delete that directory to fetch
them again. The county-code model reads its URL directly and checks it for
changes on each build.

## Follow a plume through the project

In the inspector, open `main.matches`. Each row is a methane plume with its
nearest mapped facility within 250 metres, if one was found. Unmatched plumes
stay in the table with null facility columns. A nearby facility is a spatial
match, not evidence that it caused the emission.

Follow the dependencies back to `carbonmapper.plumes` and `osm.facilities`
to see the source records. In `matches`, click through the query's join and
ranking steps to see how candidate facilities become one match per plume.

Then open the two summaries:

| Model | Result |
| ----- | ------ |
| `summary.by_kind` | Plume counts and median emission rates by facility type, including unmatched plumes |
| `summary.by_county` | Plume counts, matched counts and total emission rates by county |

You can also query the built tables directly:

```sh
make shell
```

```sql
select * from summary.by_county;
```

## Change the search radius

```sh
make RADIUS=100
make test RADIUS=100
```

This reduces the search radius from 250 to 100 metres. duckdb.mk detects the
changed environment variable and rebuilds `matches` and its two summaries;
the source models do not depend on the radius. There may be fewer matches,
but unmatched plumes remain in the results. Inspect the rebuilt project with
`make inspect RADIUS=100` so queries use the same radius.

The match first filters facilities through a fixed bounding box, then checks
the distance. The radius is suitable for comparing nearby facilities; raising
it beyond that box would also require changing the query.

## Files

| Path | Purpose |
| ---- | ------- |
| `Makefile` | Sets `RADIUS` and fetches inputs into `data/` |
| `queries/osm.overpassql` | OpenStreetMap query |
| `macros/` | Loads the spatial extension and defines `metres()` |
| `models/census/` | County codes and boundaries |
| `models/carbonmapper/` | Methane plumes within New Mexico |
| `models/osm/` | Mapped oil and gas facilities |
| `models/matches.sql` | Nearest facility for each plume |
| `models/summary/` | Results by facility type and county |
| `tests/` | Non-negative emissions and unique plume matches |

The inspector shows the dependency graph. Each build also writes it to
`tables/dag.mmd` in Mermaid format.
