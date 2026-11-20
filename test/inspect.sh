# the inspector: make's plan.mk linked beside it, and the files it links, with nothing
# built for it
cp -R "$here/inspect" . && printf 'export REGION = north\ninclude duckdb.mk\n' > Makefile
mkdir -p models/s/deep tests macros data && printf 'id,k\n1,a\n2,b\n' > data/x.csv
echo "-- Rows.
select *, getenv('REGION') as r, getenv('SECRET') as s from read_csv('data/x.csv')" > models/s/a.sql
echo "from s.a" > 'models/s/deep/Part@k.sql'
echo "with a as (from s.part) from a, read_csv('http://example.org/x.csv')" > models/top.sql
echo "from 'build/s/deep/Part/*/data.parquet' union all from top" > models/late.sql
echo "from top where id < 0" > tests/t.sql
echo "create macro twice(x) as x * 2;" > macros/m.sql
# pl <start>: the values of the lines of the plan beside the page that start so, sorted
pl() { awk -v k="$1 " 'index($0, k) == 1 { print substr($0, length(k) + 1) }' build/inspect/plan.mk | sort | paste -sd' ' -; }
ls_files() { (cd build/inspect/files && find . -type f | sort | xargs); }

export SECRET=hush
t "nothing is built" "" -s inspect
is "the page" "$(ls build/inspect | xargs)" 'files index.html plan.mk'
is "make's plan, linked" "$(find build/plan.mk -links 2 | wc -l | xargs)" 1
is "the sql and the source" "$(ls_files)" \
  './data/x.csv ./macros/m.sql ./models/late.sql ./models/s/a.sql ./models/s/deep/Part@k.sql ./models/top.sql ./tests/t.sql'
is "macros, in the plan" "$(pl 'macros +=')" 'macros/m.sql'
is "each node's file, in the plan" "$(pl 'test/t:') $(pl 'build/s/deep/Part:')" \
  'build/top.parquet tests/t.sql build/s/a.parquet models/s/deep/Part@k.sql'
is "no partition before a build" "[$(pl 'build/s/deep/Part.files +=')]" '[]'
is "no variable's value" "$(grep -c 'north\|hush' build/inspect/plan.mk)" 0

$MAKE -s DUCKDB="$DUCKDB" build/s/a.parquet build/s/deep/Part > /dev/null
t "the built tables are linked" "" -s inspect
is "files" "$(ls_files)" \
  './build/s/a.parquet ./build/s/deep/Part/k=a/data.parquet ./build/s/deep/Part/k=b/data.parquet ./data/x.csv ./macros/m.sql ./models/late.sql ./models/s/a.sql ./models/s/deep/Part@k.sql ./models/top.sql ./tests/t.sql'
is "a link, not a copy" "$(find build/s/a.parquet -links 2 | wc -l | xargs)" 1
is "a partitioned table's files, in the plan" "$(pl 'build/s/deep/Part.files +=')" \
  'build/s/deep/Part/k=a/data.parquet build/s/deep/Part/k=b/data.parquet'
is "the files of a glob that a model reads" "$(pl 'build/late.parquet.files +=')" \
  'build/s/deep/Part/k=a/data.parquet build/s/deep/Part/k=b/data.parquet'
rm -r build/s/deep
t "a table that has gone is unlinked" "" -s inspect
is "files left" "$(ls build/inspect/files/build/s | xargs) [$(pl 'build/s/deep/Part.files +=')]" 'a.parquet []'
is "it does not read itself" "$(echo "from 'build/**/*.parquet'" > models/all.sql; \
  $MAKE -s DUCKDB="$DUCKDB" inspect 2>&1; pl 'build/all.parquet.files +=')" 'build/s/a.parquet'
is "another directory" "$($MAKE -s DUCKDB="$DUCKDB" inspect INSPECT=site/i; ls site/i | xargs)" \
  'files index.html plan.mk'
