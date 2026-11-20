# the inspector: inspect.json and the files it links, with nothing built for it
cp -R "$here/inspect" . && printf 'export REGION = north\ninclude duckdb.mk\n' > Makefile
mkdir -p models/s/deep tests macros data && printf 'id,k\n1,a\n2,b\n' > data/x.csv
echo "-- Rows.
select *, getenv('REGION') as r, getenv('SECRET') as s from read_csv('data/x.csv')" > models/s/a.sql
echo "from s.a" > 'models/s/deep/Part@k.sql'
echo "with a as (from s.part) from a, read_csv('http://example.org/x.csv')" > models/top.sql
echo "from 'build/s/deep/Part/*/data.parquet' union all from top" > models/late.sql
echo "from top where id < 0" > tests/t.sql
echo "create macro twice(x) as x * 2;" > macros/m.sql
j() { q "select $1 from 'build/inspect/inspect.json'"; }
node() { j "list_filter(nodes, lambda n: n.id = '$1')[1].$2"; }

export SECRET=hush
t "nothing is built" "" -s inspect
is "no table, no file but the source" "$(j files)" '[data/x.csv]'
is "ids" "$(j 'list_transform(nodes, lambda n: n.id)')" '[late, s.a, s.part, top, test/t]'
is "a model's file, target and column" "$(node s.part file) $(node s.part target) $(node s.part out) $(node s.part '"by"')" \
  'models/s/deep/Part@k.sql build/s/deep/Part build/s/deep/Part/*/data.parquet k'
is "a cte hides no model it does not name" "$(node top reads)" '[s.part]'
is "a glob of a model and a model" "$(node late reads)" '[s.part, top]'
is "a glob of a model is no source" "$(node late sources)" '[]'
is "a test reads" "$(node test/t reads)" '[top]'
is "sources" "$(node top sources) $(node s.a sources)" "['http://example.org/x.csv'] [data/x.csv]"
is "variables read" "$(node s.a env)" '[REGION, SECRET]'
is "the makefile's values" "$(j env)" "{'REGION': north}"
is "none from the environment" "$(grep -c hush build/inspect/inspect.json)" 0
is "the command line's values" "$($MAKE -s DUCKDB="$DUCKDB" inspect SECRET=open REGION=south; j env)" \
  "{'REGION': south, 'SECRET': open}"
is "macros" "$(j 'macros[1].file')" 'macros/m.sql'
is "the page" "$(ls build/inspect | xargs)" \
  'files index.html inspect.js inspect.json'

$MAKE -s DUCKDB="$DUCKDB" build/s/a.parquet build/s/deep/Part > /dev/null
t "the built tables are linked" "" -s inspect INSPECT_HIDE='^top$$'
is "files" "$(cd build/inspect/files && find . -type f | sort | xargs)" \
  './build/s/a.parquet ./build/s/deep/Part/k=a/data.parquet ./build/s/deep/Part/k=b/data.parquet ./data/x.csv'
is "the same files" "$(j files)" \
  "[build/s/a.parquet, 'build/s/deep/Part/k=a/data.parquet', 'build/s/deep/Part/k=b/data.parquet', data/x.csv]"
is "a hidden model's files are not linked" "$($MAKE -s DUCKDB="$DUCKDB" inspect INSPECT_HIDE='^s\.a$$'; j files)" \
  "[build/s/a.parquet, 'build/s/deep/Part/k=a/data.parquet', 'build/s/deep/Part/k=b/data.parquet']"
$MAKE -s DUCKDB="$DUCKDB" inspect INSPECT_HIDE='^top$$'
is "a link, not a copy" "$(find build/s/a.parquet -links 2 | wc -l | xargs)" 1
is "what to hide" "$(j hide)" '^top$'
rm -r build/s/deep
t "a table that has gone is unlinked" "" -s inspect
is "files left" "$(j files) $(ls build/inspect/files/build/s | xargs)" \
  '[build/s/a.parquet, data/x.csv] a.parquet'
is "it does not read itself" "$(echo "from 'build/**/*.parquet'" > models/all.sql; \
  $MAKE -s DUCKDB="$DUCKDB" inspect 2>&1; j files)" '[build/s/a.parquet, data/x.csv]'
is "another directory" "$($MAKE -s DUCKDB="$DUCKDB" inspect INSPECT=site/i; ls site/i | xargs)" \
  'files index.html inspect.js inspect.json'
