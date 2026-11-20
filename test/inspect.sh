# the inspector: plan.mk beside it (make's plan, and what make inspect adds) and the
# files it links, with nothing built for it
cp -R "$here/inspect" . && printf 'export REGION = north\ninclude duckdb.mk\n' > Makefile
mkdir -p models/s/deep tests macros data && printf 'id,k\n1,a\n2,b\n' > data/x.csv
echo "-- Rows.
select *, getenv('REGION') as r, getenv('SECRET') as s from read_csv('data/x.csv')" > models/s/a.sql
echo "from s.a" > 'models/s/deep/Part@k.sql'
echo "with a as (from s.part) from a, read_csv('http://example.org/x.csv')" > models/top.sql
echo "from 'build/s/deep/Part/*/data.parquet' union all from top" > models/late.sql
echo "from top where id < 0" > tests/t.sql
echo "create macro twice(x) as x * 2;" > macros/m.sql
# pl <start>: the values of the lines of the inspector's plan.mk that start so, sorted
pl() { awk -v k="$1 " 'index($0, k) == 1 { print substr($0, length(k) + 1) }' build/inspect/plan.mk | sort | paste -sd' ' -; }

export SECRET=hush
t "nothing is built" "" -s inspect
is "no table, no file but the source" "$(pl 'inspect.files +=')" 'data/x.csv'
is "a node's file and column" "$(pl 'build/s/deep/Part.file :=') $(pl 'build/s/deep/Part.by :=') $(pl 'test/t.file :=')" \
  'models/s/deep/Part@k.sql k tests/t.sql'
is "a cte hides no model it does not name" "$(pl 'build/top.parquet:')" 'FORCE build/s/deep/Part'
is "a glob of a model and a model" "$(pl 'build/late.parquet:')" 'FORCE build/s/deep/Part build/top.parquet'
is "a test reads" "$(pl 'test/t:')" 'build/top.parquet'
is "sources" "$(pl 'build/top.parquet.sources +=') $(pl 'build/s/a.parquet:')" 'http://example.org/x.csv FORCE data/x.csv'
is "variables read" "$(pl 'build/s/a.parquet.env +=')" 'REGION SECRET'
is "the makefile's values" "$(pl 'REGION :=') [$(pl 'SECRET :=')]" 'north []'
is "none from the environment" "$(grep -c hush build/inspect/plan.mk)" 0
is "the command line's values" "$($MAKE -s DUCKDB="$DUCKDB" inspect SECRET=open REGION=south; pl 'REGION :=') $(pl 'SECRET :=')" \
  'south open'
is "macros" "$(pl 'inspect.macros +=')" 'macros/m.sql'
is "the title" "$(pl 'inspect.title :=')" "$(basename "$PWD")"
is "the page" "$(ls build/inspect | xargs)" 'files index.html plan.mk'

$MAKE -s DUCKDB="$DUCKDB" build/s/a.parquet build/s/deep/Part > /dev/null
t "the built tables are linked" "" -s inspect INSPECT_HIDE='^top$$'
is "files" "$(cd build/inspect/files && find . -type f | sort | xargs)" \
  './build/s/a.parquet ./build/s/deep/Part/k=a/data.parquet ./build/s/deep/Part/k=b/data.parquet ./data/x.csv ./macros/m.sql ./models/late.sql ./models/s/a.sql ./models/s/deep/Part@k.sql ./models/top.sql ./tests/t.sql'
is "the tables and sources in the plan" "$(pl 'inspect.files +=')" \
  'build/s/a.parquet build/s/deep/Part/k=a/data.parquet build/s/deep/Part/k=b/data.parquet data/x.csv'
is "a hidden model's files are not linked" "$($MAKE -s DUCKDB="$DUCKDB" inspect INSPECT_HIDE='^s\.a$$'; pl 'inspect.files +=')" \
  'build/s/a.parquet build/s/deep/Part/k=a/data.parquet build/s/deep/Part/k=b/data.parquet'
$MAKE -s DUCKDB="$DUCKDB" inspect INSPECT_HIDE='^top$$'
is "a link, not a copy" "$(find build/s/a.parquet -links 2 | wc -l | xargs)" 1
is "what to hide, as make writes it" "$(pl 'inspect.hide :=')" '^top$$'
is "a table from other sql is stale" "$(echo >> models/s/a.sql; $MAKE -s DUCKDB="$DUCKDB" inspect; \
  pl 'build/s/a.parquet.stale :=') [$(pl 'build/s/deep/Part.stale :=')]" 'true []'
rm -r build/s/deep
t "a table that has gone is unlinked" "" -s inspect
is "files left" "$(pl 'inspect.files +=') $(ls build/inspect/files/build/s | xargs)" \
  'build/s/a.parquet data/x.csv a.parquet'
is "it does not read itself" "$(echo "from 'build/**/*.parquet'" > models/all.sql; \
  $MAKE -s DUCKDB="$DUCKDB" inspect 2>&1; pl 'inspect.files +=')" 'build/s/a.parquet data/x.csv'
is "another directory" "$($MAKE -s DUCKDB="$DUCKDB" inspect INSPECT=site/i; ls site/i | xargs)" \
  'files index.html plan.mk'
