# builds, rebuilds and the make interface on a small project
mkdir -p models/staging models/marts tests/sub macros seeds
printf 'id,customer_id,amount\n1,1,10.5\n2,1,20\n3,2,5\n' > seeds/orders.csv
printf 'id,name\n1,ann\n2,bob\n' > seeds/customers.csv
printf 'k,v\na,1\n' > "$www/remote.csv"
echo "create macro cents(x) as (x * 100)::int;" > macros/cents.sql
echo "create macro not_null(t, c) as table from query_table(t) where columns(c) is null;" > macros/tests.sql
echo "from read_csv('seeds/orders.csv')" > models/raw_orders.sql
echo "select id, customer_id, cents(amount) as amount_cents from raw_orders" > models/staging/orders.sql
echo "from 'seeds/customers.csv'" > models/staging/customers.sql
echo "from staging.customers" > models/customers.sql
echo "from read_csv('seeds/*.csv', union_by_name = true)" > models/seeds.sql
echo "from read_csv('$url/remote.csv')" > models/remote.sql
echo "select count(*) as n from remote" > models/remote_count.sql
cat > models/marts/revenue.sql <<'SQL'
with orders as (from staging.orders)
select c.name, sum(orders.amount_cents) as total, staging.customers.id
from orders join staging.customers c on c.id = orders.customer_id
join staging.customers on staging.customers.id = c.id
group by all;
SQL
cat > models/marts/shadow.sql <<'SQL'
-- the inner customers is the model, and early reads the model raw_orders, not the later cte
with customers as (from customers where id > 0),
     early as (from raw_orders),
     raw_orders as (from early),
     tree as (with recursive tree as (select 1 as n union all select n + 1 from tree where n < 3) from tree)
select c.name, count(*) as n, getenv('REGION') as region
from customers c, raw_orders, (select max(n) from tree) group by all
SQL
echo "from marts.revenue where total < 0" > tests/revenue_positive.sql
echo "from not_null('marts.revenue', 'id')" > tests/revenue_ids.sql
echo "from remote where v < 0" > tests/remote_ok.sql
echo "from remote_count where n <> (select count(*) from remote)" > tests/sub/remote_count.sql
export REGION=eu
all="build/customers.parquet build/marts/revenue.parquet build/marts/shadow.parquet build/raw_orders.parquet \
build/remote.parquet build/remote_count.parquet build/seeds.parquet build/staging/customers.parquet \
build/staging/orders.parquet"
tests="test/remote_ok test/revenue_ids test/revenue_positive test/sub/remote_count"

t "clean build" "$all $tests" all test
t "no-op" ""
t "no-op test run" "$tests" test
is "row counts" "$(q "from 'build/marts/revenue.parquet' select string_agg(name || total::int, ' ' order by name)")" "ann3050 bob500"
echo "from read_csv('seeds/orders.csv') where id > 0" > models/raw_orders.sql
t "upstream edit" "build/marts/revenue.parquet build/marts/shadow.parquet build/raw_orders.parquet build/staging/orders.parquet"
echo "-- a comment" >> models/raw_orders.sql
t "comment edit" "build/marts/revenue.parquet build/marts/shadow.parquet build/raw_orders.parquet build/staging/orders.parquet"
touch seeds/customers.csv
t "seed edit" "build/customers.parquet build/marts/revenue.parquet build/marts/shadow.parquet build/seeds.parquet build/staging/customers.parquet"
printf 'id,extra\n9,x\n' > seeds/extra.csv
t "new file matching a glob" "build/seeds.parquet"
rm seeds/extra.csv
t "file matching a glob removed" "build/seeds.parquet"
t "env change" "build/marts/shadow.parquet" REGION=us
t "env unchanged" "" REGION=us
t "env unset" "build/marts/shadow.parquet" REGION=
t "env reverted" "build/marts/shadow.parquet"
printf 'k,v\na,1\nb,2\n' > "$www/remote.csv"
t "remote change rebuilds its dependents" "build/remote.parquet build/remote_count.parquet"
t "remote unchanged" ""
t "remote unchanged leaves its dependents" "$tests" test
echo "create macro cents(x) as (x * 100)::bigint;" > macros/cents.sql
t "macro edit" "$all"
echo "-- nothing yet" > macros/new.sql
t "new macro" "$all"
rm macros/new.sql
t "deleted macro file" "$all"
t "single target" "" build/marts/revenue.parquet
touch models/staging/orders.sql
t "single target rebuilds only its own dependencies" "build/marts/revenue.parquet build/staging/orders.parquet" \
  build/marts/revenue.parquet
t "single target is up to date" "" build/marts/shadow.parquet
t "single test builds what it needs" "test/revenue_ids" test/revenue_ids
t "nested test" "test/sub/remote_count" test/sub/remote_count
touch models/raw_orders.sql && touch build/.before
is "dry run builds nothing" "$($MAKE -n >/dev/null && find build -name '*.parquet' -newer build/.before)" ""
t "after a dry run" "build/marts/revenue.parquet build/marts/shadow.parquet build/raw_orders.parquet build/staging/orders.parquet"
t "always make" "$all" -B
echo "from marts.revenue where total > 0" > tests/fails.sql
t "failing test" "!tests/fails.sql: 2 failing rows" test
t "failing test shows examples" "!rows, e.g. [{'name': " test
rm tests/fails.sql
echo "select error('boom') from raw_orders" > models/broken.sql && echo "from broken" > models/after_broken.sql
t "broken model" "!boom"
t "keep going past a broken model" "$tests" -k all test
rm models/broken.sql models/after_broken.sql
mv models/customers.sql .
t "deleted dependency" "!shadow.parquet] Error"
mv customers.sql models
t "restored dependency" ""
echo "from 'build/customers.parquet'" > models/by_path.sql
t "reference by path" "build/by_path.parquet"
echo "create table lookup as select 1 as k;" > macros/lookup.sql && echo "from lookup" > models/uses_lookup.sql
t "table from a macro" "$all build/by_path.parquet build/uses_lookup.parquet"
rm macros/lookup.sql
t "deleted macro" "!lookup does not exist"; rm models/uses_lookup.sql
is "shell" "$(printf ".mode list\n.headers off\nselect count(*) from marts.revenue, staging.orders;" | $MAKE -s shell)" 6
is "shell has macros" "$(printf ".mode list\n.headers off\nselect cents(1.5);" | $MAKE -s shell)" 150
touch models/customers.sql
t "silent" "" -s
touch models/customers.sql
t "not silent with an s in a variable" "build/by_path.parquet build/customers.parquet build/marts/shadow.parquet" X=s
rm -r build
t "parallel" "$all build/by_path.parquet $tests" -j8 all test
t "parallel no-op" "" -j8
is "row count" "$(q "select count(*) from 'build/seeds.parquet'")" 5
is "fingerprint stored" "$(q "select count(*) from parquet_kv_metadata('build/remote.parquet') where decode(key) = 'duckdb.mk'")" 1
kv() { q "select decode(value) from parquet_kv_metadata('$1') where decode(key) = '$2'"; }
is "sql stored" "$(kv build/customers.parquet sql)" "from staging.customers"
is "no commit outside git" "$(kv build/customers.parquet commit)" ""
git init -q && git add models && git -c user.name=t -c user.email=t commit -qm m
touch models/customers.sql && $MAKE -s DUCKDB="$DUCKDB" build/customers.parquet
is "commit stored" "$(kv build/customers.parquet commit)" "$(git describe --always --dirty)"
rm -rf .git
t "BUILD" "build/elsewhere/customers.parquet build/elsewhere/staging/customers.parquet" \
  BUILD=build/elsewhere build/elsewhere/customers.parquet
t "clean" "" clean
is "clean removes the build" "$(ls | xargs)" "Makefile duckdb.mk macros models seeds tests"
t "clean without a plan" "" clean
t "clean and build" "$all build/by_path.parquet $tests" clean all test
