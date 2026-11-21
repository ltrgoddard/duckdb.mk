# a realistic pipeline over millions of generated rows: wells, production, prices, flaring and ownership
mkdir -p macros models/raw models/staging models/core models/marts tests
cat > macros/generate.sql <<'SQL'
-- a deterministic number in [0, 1) for a key and a salt
create macro rnd(k, salt) as (hash(k, salt) % 1000000) / 1000000.0;
create macro pick(k, salt, xs) as xs[1 + (hash(k, salt) % len(xs))::int];
-- barrels of oil equivalent
create macro boe(oil_bbl, gas_mcf) as (oil_bbl + gas_mcf / 6)::decimal(18, 2);
-- rows of a table where a column is null
create macro nulls(t, c) as table from query_table(t) where columns(c) is null;
SQL
cat > models/raw/operators.sql <<'SQL'
-- 500 operators, most after the first 20 owned by an earlier one
select
  range as id,
  'operator ' || range as name,
  if(range >= 20 and rnd(range, 'owned') < 0.7, floor(rnd(range, 'parent') * range)::bigint, null) as parent_id
from range(500)
SQL
cat > models/raw/wells.sql <<'SQL'
-- 40,000 wells spudded over four years, with Arps decline parameters
select
  range as id,
  floor(rnd(range, 'operator') * 500)::bigint as operator_id,
  pick(range, 'basin', ['Permian', 'Bakken', 'Eagle Ford', 'Marcellus', 'Haynesville', 'DJ', 'Anadarko', 'San Juan'])
    as basin,
  date '2019-01-01' + floor(rnd(range, 'spud') * 1461)::int as spud_date,
  1000 + rnd(range, 'qi') * 9000 as qi,
  0.05 + rnd(range, 'di') * 0.25 as di,
  0.5 + rnd(range, 'gor') * 4 as gor
from range(40000)
SQL
cat > models/raw/production.sql <<'SQL'
-- monthly volumes from first production to the end of 2023, with a few unreported months
with months as (
  select (date '2019-01-01' + to_months(range::int))::date as month
  from range(60)
),

volumes as (
  select
    w.id as well_id,
    m.month,
    w.gor,
    w.qi / pow(1 + 0.8 * w.di * datediff('month', date_trunc('month', w.spud_date), m.month), 1 / 0.8) as oil
  from raw.wells as w
  join months as m on m.month >= date_trunc('month', w.spud_date)
)

select
  well_id,
  month,
  if(rnd(well_id, month::varchar) < 0.01, null, oil::decimal(18, 2)) as oil_bbl,
  (oil * gor)::decimal(18, 2) as gas_mcf
from volumes
SQL
cat > models/raw/prices.sql <<'SQL'
-- weekday oil and gas prices with a yearly cycle
select
  day::date as day,
  round(70 + 15 * sin(2 * pi() * dayofyear(day) / 365), 2) as oil_usd,
  round(3 + cos(2 * pi() * dayofyear(day) / 365), 3) as gas_usd
from range(date '2018-12-01', date '2024-01-01', interval 1 day) as t(day)
where dayofweek(day) between 1 and 5
SQL
cat > models/raw/flaring.sql <<'SQL'
-- 300,000 satellite flare detections attributed to wells
select
  range as id,
  floor(rnd(range, 'well') * 40000)::bigint as well_id,
  timestamp '2019-01-01' + to_seconds(floor(rnd(range, 'at') * 157766400)::bigint) as detected,
  (1 + rnd(range, 'volume') * 500)::decimal(18, 1) as volume_mcf
from range(300000)
SQL
cat > models/staging/production.sql <<'SQL'
select
  well_id,
  month,
  coalesce(oil_bbl, 0) as oil_bbl,
  gas_mcf,
  boe(coalesce(oil_bbl, 0), gas_mcf) as boe
from raw.production
SQL
cat > models/core/ownership.sql <<'SQL'
-- each operator's ultimate owner and how far up the tree it is
with recursive chain as (
  select id, id as owner, parent_id, 0 as depth
  from raw.operators
  union all
  select chain.id, o.id, o.parent_id, chain.depth + 1
  from chain
  join raw.operators as o on o.id = chain.parent_id
)

select id as operator_id, owner as ultimate_id, depth
from chain
where parent_id is null
SQL
cat > models/core/well_months.sql <<'SQL'
with p as (from staging.production),

wells as (
  select wells.id, wells.basin, wells.operator_id, o.ultimate_id
  from raw.wells as wells
  join core.ownership as o using (operator_id)
)

select
  p.*,
  wells.basin,
  wells.operator_id,
  wells.ultimate_id,
  sum(p.boe) over (partition by p.well_id order by p.month rows unbounded preceding) as cum_boe,
  avg(p.boe) over (partition by p.well_id order by p.month rows 2 preceding) as boe_3m,
  rank() over (partition by wells.basin, p.month order by p.boe desc) as basin_rank
from p
join wells on wells.id = p.well_id
SQL
cat > models/core/revenue.sql <<'SQL'
-- revenue at the last prices quoted on or before the first of each month
select p.well_id, p.month, pr.day as priced_on, (p.oil_bbl * pr.oil_usd + p.gas_mcf * pr.gas_usd)::decimal(18, 2) as usd
from staging.production as p
asof join raw.prices as pr on pr.day <= p.month
SQL
cat > models/marts/basins.sql <<'SQL'
select basin, year(month) as year, grouping(basin, year(month)) as level, sum(boe) as boe, count(distinct well_id) as wells
from core.well_months
group by rollup (basin, year(month))
SQL
cat > models/marts/top_owners.sql <<'SQL'
-- the five largest ultimate owners in each basin
select basin, ultimate_id, sum(boe) as boe
from core.well_months
group by basin, ultimate_id
qualify row_number() over (partition by basin order by sum(boe) desc, ultimate_id) <= 5
SQL
cat > models/marts/flaring.sql <<'SQL'
-- flared gas as a share of all gas, by well and month
with flares as (
  select well_id, date_trunc('month', detected)::date as month, sum(volume_mcf) as flared_mcf, count(*) as detections
  from raw.flaring
  group by all
)

select f.*, p.gas_mcf, f.flared_mcf / (coalesce(p.gas_mcf, 0) + f.flared_mcf) as intensity
from flares as f
left join staging.production as p using (well_id, month)
SQL
cat > models/marts/decline.sql <<'SQL'
-- fitted exponential decline for each well with six or more reported months
select well_id, basin, count(*) as months, round(regr_slope(ln(oil_bbl), t), 9) as slope, round(regr_r2(ln(oil_bbl), t), 9) as r2
from (
  select *, row_number() over (partition by well_id order by month) - 1 as t
  from core.well_months
  where oil_bbl > 0
)
group by all
having count(*) >= 6
SQL
cat > models/marts/report.sql <<'SQL'
-- one JSON document per basin
select
  basin,
  to_json({
    years: (select list({year: year, boe: round(boe)} order by year) from marts.basins as b where b.basin = t.basin and level = 0),
    owners: (select list(ultimate_id order by boe desc) from marts.top_owners as o where o.basin = t.basin),
    revenue: (select round(sum(usd)) from core.revenue join raw.wells on id = well_id where wells.basin = t.basin)
  }) as doc
from (select distinct basin from raw.wells) as t
SQL
echo "select * from (select (select sum(boe) from staging.production) as a, (select sum(boe) from core.well_months) as b,
  (select boe from marts.basins where level = 3) as c) where abs(a - b) > 1e-6 * a or abs(a - c) > 1e-6 * a" \
  > tests/conservation.sql
echo "from core.ownership join raw.operators on id = ultimate_id where parent_id is not null" > tests/owners_are_roots.sql
echo "select id from raw.operators except select operator_id from core.ownership" > tests/owners_complete.sql
echo "from core.revenue where priced_on > month or month - priced_on > 3" > tests/prices_recent.sql
echo "select basin from marts.top_owners group by basin having count(*) <> 5" > tests/five_owners.sql
echo "from marts.flaring where intensity not between 0 and 1" > tests/intensity.sql
echo "from marts.decline where slope >= 0 or r2 < 0.8" > tests/declining.sql
echo "from nulls('core.well_months', 'ultimate_id')" > tests/owned.sql
echo "from marts.report where json_array_length(doc->'owners') <> 5 or json_array_length(doc->'years') <> 5" \
  > tests/report.sql

models=$(find models -name '*.sql' | sed 's/^models/tables/; s/sql$/parquet/' | sort | xargs)
tests=$(ls tests | sed 's/^/test\//; s/\.sql$//' | xargs)
t "build" "$models $tests" -j4 all test
is "wells" "$(q "select count(*) from 'tables/raw/wells.parquet'")" 40000
is "production rows" "$(q "select count(*) from 'tables/raw/production.parquet'")" \
  "$(q "select sum(60 - datediff('month', date '2019-01-01', spud_date)) from 'tables/raw/wells.parquet'")"
is "flares" "$(q "select sum(detections) from 'tables/marts/flaring.parquet'")" 300000
is "well months are unique" "$(q "select count(*) = count(distinct (well_id, month)) from 'tables/core/well_months.parquet'")" true
is "ownership" "$(q "select concat_ws(' ', operator_id, ultimate_id, depth) from 'tables/core/ownership.parquet' order by 1")" \
  "$(q "copy (select id, parent_id from 'tables/raw/operators.parquet') to '/dev/stdout' (header false)" | python3 -c "
import sys
parent = dict(line.strip().split(',') for line in sys.stdin)
top = lambda i, d=0: top(parent[i], d + 1) if parent[i] else (i, d)
print(*sorted(' '.join((i, *map(str, top(i)))) for i in parent), sep='\n')")"
checksum() { for f in tables/marts/*.parquet; do q "select md5(string_agg(t::varchar, ',' order by t::varchar)) from '$f' as t"; done; }
before=$(checksum)
t "rebuild everything serially" "$models" -B -j1
is "builds are deterministic" "$(checksum)" "$before"
is "shell" "$(printf '.mode list\n.headers off\nselect count(*) from marts.report;' | $MAKE -s shell)" 8

echo "-- a comment" >> models/raw/prices.sql
t "price edit" "tables/core/revenue.parquet tables/marts/report.parquet tables/raw/prices.parquet"
echo "-- a comment" >> models/raw/flaring.sql
t "flaring edit" "tables/marts/flaring.parquet tables/raw/flaring.parquet"
echo "-- a comment" >> models/core/ownership.sql
t "ownership edit" "tables/core/ownership.parquet tables/core/well_months.parquet tables/marts/basins.parquet \
tables/marts/decline.parquet tables/marts/report.parquet tables/marts/top_owners.parquet"
t "tests after edits" "$tests" test
