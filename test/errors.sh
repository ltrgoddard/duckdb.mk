# plan errors, build failures and what they leave behind
mkdir -p models/s tests
echo "select 1 as id" > models/ok.sql
t "valid project" "build/ok.parquet"

try() { echo "$2" > "models/$1.sql"; t "$3" "!$4"; rm "models/$1.sql"; }
try bad "SELEC 1" "parse error" 'models/bad.sql:1: syntax error at or near'
try bad $'select 1,\n  2 +\nfrom ok' "parse error's line" 'models/bad.sql:3: syntax error at or near'
try bad "select 1; select 2" "two statements" "models/bad.sql: expected one SELECT statement"
try bad "-- only a comment" "no statement" "models/bad.sql: expected one SELECT statement"
try bad "" "empty file" "models/bad.sql: expected one SELECT statement"
try bad "create table x as select 1" "not a select" "models/bad.sql: Only SELECT statements"
try bad "pivot ok on id" "pivot statement" "models/bad.sql: Only SELECT statements"
try bad "from main.nope" "a name that is no model" "models/bad.sql: no model main.nope"
try self "from self" "self reference" "dependency cycle: build/self.parquet"
echo "from b" > models/a.sql && echo "from a" > models/b.sql
t "cycle" "!dependency cycle: build/a.parquet build/b.parquet"
echo "from c" > models/b.sql && echo "select * from s.d" > models/c.sql && echo "from a" > models/s/d.sql
t "long cycle" "!dependency cycle: build/a.parquet build/b.parquet build/c.parquet build/s/d.parquet"
echo "from ok" > models/s/d.sql
t "cycle broken" "build/a.parquet build/b.parquet build/c.parquet build/s/d.parquet"
rm models/a.sql models/b.sql models/c.sql models/s/d.sql
mkdir -p models/s/sub && echo "select 1" > models/s/Ok.sql && echo "select 2" > models/s/sub/oK.sql
t "duplicate name across case and depth" "!duplicate model s.ok: models/s/Ok.sql, models/s/sub/oK.sql"
rm -r models/s/sub models/s/Ok.sql
echo "select 1" > "models/bad name.sql"
t "space in a name" "!models/bad name.sql: use only"; rm "models/bad name.sql"
echo "select 1" > "models/bad.name.sql"
t "dot in a name" "!models/bad.name.sql: use only"; rm "models/bad.name.sql"
echo "select 1" > "models/café.sql"
t "non-ascii name" "!.sql: use only"; rm "models/café.sql"
echo "select 1" > "tests/bad name.sql"
t "space in a test name" "!tests/bad name.sql: use only"; rm "tests/bad name.sql"
t "fixed" ""

echo "from missing" > models/orphan.sql
t "missing table" "!Table with name missing does not exist"
printf -- '-- its own lines\nselect id,\n  nope\nfrom ok;\n\n' > models/orphan.sql
t "an error's line in the file" "!LINE 3:   nope"
printf 'select id\nfrom ok\nwhere nope' > tests/orphan.sql
t "an error's line in a test" "!LINE 3: where nope" test; rm tests/orphan.sql
echo "from read_csv('data/missing.csv')" > models/orphan.sql
t "missing file" "!No rule to make target"
rm models/orphan.sql

echo "select range as id from range(3)" > models/ok.sql
t "rebuild" "build/ok.parquet"
before=$(q "select string_agg(id, ' ') from 'build/ok.parquet'")
echo "select if(range = 2, error('boom'), range) as id from range(3)" > models/ok.sql
t "runtime error" "!boom"
is "runtime error keeps the last good output" "$(q "select string_agg(id, ' ') from 'build/ok.parquet'")" "$before"
t "runtime error is retried" "!boom"
echo "select if(range = 3000000, error('late'), range) as id from range(4000000)" > models/ok.sql
t "error midway through writing" "!late"
is "error midway keeps the last good output" "$(q "select string_agg(id, ' ') from 'build/ok.parquet'")" "$before"
is "error midway leaves no temporary files" "$(find build -type f ! -name '*.parquet' ! -name plan.mk ! -name dag.mmd)" ""
echo "select if(range = 3000000, error('late'), range) as id from range(4000000)" > models/new.sql
t "new model fails midway" "!late"
is "failed new model leaves no output" "$(find build -name 'new*')" ""
rm models/new.sql
printf 'select 1 as id -- a comment; \n ;\n\n' > models/ok.sql
t "recovered, with a final semicolon and comment" "build/ok.parquet"

echo "from ok where id > 0" > tests/fails.sql
t "failing test" "!tests/fails.sql: 1 failing rows, e.g. [{'id': 1}]" test
echo "select range as n from range(1000)" > tests/fails.sql
t "failing test examples" "!tests/fails.sql: 1,000 failing rows, e.g. [{'n': 0}, {'n': 1}, {'n': 2}]" test
echo "select range as n, 'row ' || range as label from range(10000000) order by n desc" > tests/fails.sql
t "failing test over ten million rows" "!10,000,000 failing rows, e.g. [{'n': 0, 'label': row 0}, {'n': 1," test
echo "from nothing" > tests/fails.sql
t "broken test" "!Table with name nothing does not exist" test
rm tests/fails.sql

touch models/ok.sql
t "missing duckdb" "!/nonexistent/duckdb" DUCKDB=/nonexistent/duckdb
