# the inspector: the plan written beside it as make's is, and the files it links, with
# nothing built for it
cp -R "$here/inspect" . && printf 'export REGION = north\ninclude duckdb.mk\n' > Makefile
mkdir -p models/s/deep tests macros data && printf 'id,k\n1,a\n2,b\n' > data/x.csv
echo "-- Rows.
select *, getenv('REGION') as r, getenv('SECRET') as s from read_csv('data/x.csv')" > models/s/a.sql
echo "from s.a" > 'models/s/deep/Part@k.sql'
echo "with a as (from s.part) from a, read_csv('http://example.org/x.csv')" > models/top.sql
echo "from 'tables/s/deep/Part/*/data.parquet' union all from top" > models/late.sql
touch data/z.shp data/z.shx data/z.dbf data/z.zip && echo "from st_read('data/z.shp')" > models/shape.sql
echo "from top where id < 0" > tests/t.sql
echo "create macro twice(x) as x * 2;" > macros/m.sql
# pl <start>: the values of the lines of the plan beside the page that start so, sorted
pl() { awk -v k="$1 " 'index($0, k) == 1 { print substr($0, length(k) + 1) }' tables/inspect/plan.mk | sort | paste -sd' ' -; }
ls_files() { (cd tables/inspect/files && find . -type f | sort | xargs); }

export SECRET=hush
t "nothing is built" "" -s inspect
is "the page" "$(ls tables/inspect | xargs)" 'files index.html plan.mk'
is "make's plan is not written again" "$(find tables/plan.mk -newer tables/inspect/index.html | wc -l | xargs)" 0
is "the sql, the source, and a shapefile with the files beside it" "$(ls_files)" \
  './data/x.csv ./data/z.dbf ./data/z.shp ./data/z.shx ./macros/m.sql ./models/late.sql ./models/s/a.sql ./models/s/deep/Part@k.sql ./models/shape.sql ./models/top.sql ./tests/t.sql'
rm data/z.* models/shape.sql
is "macros, in the plan" "$(pl 'macros +=')" 'macros/m.sql'
is "each node's file, in the plan" "$(pl 'test/t:') $(pl 'tables/s/deep/Part:')" \
  'tables/top.parquet tests/t.sql models/s/deep/Part@k.sql tables/s/a.parquet'
is "no partition before a build" "[$(pl 'tables/s/deep/Part.files +=')]" '[]'
is "no variable's value" "$(grep -c 'north\|hush' tables/inspect/plan.mk)" 0

$MAKE -s DUCKDB="$DUCKDB" tables/s/a.parquet tables/s/deep/Part > /dev/null
t "the built tables are linked" "" -s inspect
is "files" "$(ls_files)" \
  './data/x.csv ./macros/m.sql ./models/late.sql ./models/s/a.sql ./models/s/deep/Part@k.sql ./models/top.sql ./tables/s/a.parquet ./tables/s/deep/Part/k=a/data.parquet ./tables/s/deep/Part/k=b/data.parquet ./tests/t.sql'
is "a link, not a copy" "$(find tables/s/a.parquet -links 2 | wc -l | xargs)" 1
is "a partitioned table's files, in the plan" "$(pl 'tables/s/deep/Part.files +=')" \
  'tables/s/deep/Part/k=a/data.parquet tables/s/deep/Part/k=b/data.parquet'
is "the files of a glob that a model reads" "$(pl 'tables/late.parquet.files +=')" \
  'tables/s/deep/Part/k=a/data.parquet tables/s/deep/Part/k=b/data.parquet'
rm -r tables/s/deep
t "a table that has gone is unlinked" "" -s inspect
is "files left" "$(ls tables/inspect/files/tables/s | xargs) [$(pl 'tables/s/deep/Part.files +=')]" 'a.parquet []'
is "it does not read itself" "$(echo "from 'tables/**/*.parquet'" > models/all.sql; \
  $MAKE -s DUCKDB="$DUCKDB" inspect 2>&1; pl 'tables/all.parquet.files +=')" 'tables/s/a.parquet'
is "a local copy fetches no page" "$(rm -r inspect; $MAKE -s DUCKDB="$DUCKDB" inspect 2>&1 | grep -c 'put the inspect directory')" 1
cp -R "$here/inspect" .
is "another directory" "$($MAKE -s DUCKDB="$DUCKDB" inspect INSPECT=site/i; ls site/i | xargs)" \
  'files index.html plan.mk'
