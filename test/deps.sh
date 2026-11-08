# dependency resolution: the plan's edges for each kind of reference, checked against a build
mkdir -p models/s models/Up models/deep/er/est models/cte tests data
cat >> Makefile <<'MK'
data/made.csv: ; printf 'id\n1\n' > $@
MK
printf 'id\n1\n' > data/x.csv && printf 'id\n2\n' > data/y.csv && printf 'id\n3\n' > bare.csv
echo "select 1 as id" > models/base.sql
echo "select 2 as id" > models/s/other.sql
echo "select 3 as id" > models/Up/Mixed.sql
echo "select 4 as id" > models/deep/er/est/leaf.sql
echo "select 5 as id" > models/my-model.sql
echo "select 6 as id" > models/a.sql
echo "select 7 as id" > models/range.sql
d() { echo "$2" > "models/$1.sql"; }
e() { is "$1" "$(deps "build/$2.parquet")" "$3"; }
v() { deps >/dev/null && sed -n "s|^$1 += ||p" build/plan.mk | xargs; }

d subquery "from base where id in (from s.other) and exists (from up.mixed)"
e "subqueries" subquery "build/Up/Mixed.parquet build/base.parquet build/s/other.parquet"
d setop "from base union all from \"S\".\"OTHER\" except from deep.leaf"
e "set operations and quoted names" setop "build/base.parquet build/deep/er/est/leaf.parquet build/s/other.parquet"
d quoted "from \"my-model\", \"Up\".\"Mixed\""
e "hyphens and capitals" quoted "build/Up/Mixed.parquet build/my-model.parquet"
d lateral "from base b, lateral (from s.other o where o.id > b.id)"
e "lateral join" lateral "build/base.parquet build/s/other.parquet"
d joins "from base join s.other using (id) left join up.mixed m on m.id = base.id asof join deep.leaf l on l.id >= base.id"
e "join kinds" joins "build/Up/Mixed.parquet build/base.parquet build/deep/er/est/leaf.parquet build/s/other.parquet"
d scalar "select (select max(id) from base) as m, (select count(*) from s.other) as c"
e "scalar subqueries" scalar "build/base.parquet build/s/other.parquet"
d window "select id, row_number() over w as n from base window w as (order by id) qualify id not in (from s.other)"
e "window and qualify" window "build/base.parquet build/s/other.parquet"
d catalog "from memory.main.base"
e "catalog-qualified" catalog "build/base.parquet"
d summarize "from (summarize base)"
e "summarize" summarize "build/base.parquet"
d functions "from range(3) as r, a, range"
e "table function and model of the same name" functions "build/a.parquet build/range.parquet"
d strings "from read_parquet(['build/base.parquet', 'build/s/other.parquet']) union all from query_table('Deep.Leaf')"
e "strings naming models" strings "\$(wildcard Deep.Leaf) build/base.parquet build/deep/er/est/leaf.parquet build/s/other.parquet"
d path "from 'build/Up/Mixed.parquet'"
e "model by path" path "build/Up/Mixed.parquet"
d files "select id from read_csv('data/x.csv') union all from 'bare.csv' union all from read_csv('data/made.csv')"
e "local files" files "\$(wildcard bare.csv) data/made.csv data/x.csv"
d glob "from read_csv('data/*.csv')"
e "globs" glob "\$(wildcard data/*.csv) FORCE"
d rglob "select count(*) as n from read_parquet('build/**/*.parquet', union_by_name = true)"
e "recursive glob" rglob "FORCE $(find models -name '*.sql' ! -name rglob.sql |
  sed 's/^models/build/; s/sql$/parquet/' | sort | xargs)"
d sglob "select count(*) as n from read_parquet(['build/s/*.parquet', 'build/?.parquet'])"
e "globs over models" sglob "FORCE build/a.parquet build/s/other.parquet"
d args "from read_csv('data/x.csv', columns = {'id': 'int'}, dateformat = '%d.%m.%Y')"
e "named arguments" args "data/x.csv"
d sqlite "from sqlite_scan('data/x.db', 't')"
e "sqlite_scan" sqlite "data/x.db"
d later "from read_csv('data/x.csv', names = ['s.other'], nullstr = 'y.z')"
e "only the path argument" later "data/x.csv"
d macro "from lookup"
e "table created in a macro" macro "\$(dirs)"
d system "select count(*) as n from information_schema.tables"
e "system table" system "\$(dirs)"
d env "select getenv('A') as a, getenv('B' || 'C') as bc"
e "environment" env "FORCE"
is "environment variables" "$(v build/env.parquet.env)" "A"
d url "from read_csv(['http://h/a.csv', 'https://h/b.csv?x=1&\$y=2'])"
is "urls" "$(v build/url.parquet.sources)" "http://h/a.csv https://h/b.csv?x=1&\$\$y=2"
d template "from read_json('https://h/api?key=' || getenv('KEY'))"
is "url templates" "$(v build/template.parquet.sources)" ""

d cte/shadow "with a as (select 1 as id) from a"
e "cte shadows a model" cte/shadow ""
d cte/self "with a as (from a) from a"
e "cte reads the model it shadows" cte/self "build/a.parquet"
d cte/recursive "with recursive a as (select 1 as id union all select id + 1 from a where id < 3) from a"
e "recursive cte" cte/recursive ""
d cte/outer "select * from (with a as (select 1 as id) from a), a"
e "cte scope ends with its query" cte/outer "build/a.parquet"
d cte/inner "with a as (select 1 as id) from base where id in (from a)"
e "cte visible in subqueries" cte/inner "build/base.parquet"
d cte/chain "with x as (from base), a as (from x) from a"
e "cte reads an earlier cte" cte/chain "build/base.parquet"
d cte/later "with x as (from a), a as (select 1 as id) from x"
e "cte reads a model named like a later cte" cte/later "build/a.parquet"
d cte/schema "with base as (select 1 as id) from main.base"
e "schema bypasses ctes" cte/schema "build/base.parquet"
d cte/case "with A as (select 1 as id) from a"
e "cte names are case-insensitive" cte/case ""
d cte/materialized "with a as materialized (from base) from a union all from a"
e "materialized cte" cte/materialized "build/base.parquet"
d cte/mixed "with recursive t as (select 1 as id union all select id + 1 from t where id < 3), a as (from t) from a"
e "recursive cte read by a cte" cte/mixed ""
d cte/nested "with a as (with base as (select 9 as id) from base) from a join base using (id)"
e "nested cte" cte/nested "build/base.parquet"

echo "from base where id < 0" > tests/t.sql
is "test" "$(deps test/t)" "build/base.parquet"
is "views" "$(grep -c '\.view := ' build/plan.mk)" "$(($(find models -name '*.sql' | wc -l)))"
is "view names" "$(grep -oE '"(main"."my-model|up"."mixed|deep"."leaf)" as' build/plan.mk | sort | paste -sd' ' -)" \
  '"deep"."leaf" as "main"."my-model" as "up"."mixed" as'

rm models/url.sql models/template.sql models/sqlite.sql
echo "create table lookup as select 1 as id;" > macros.sql && mkdir macros && mv macros.sql macros/lookup.sql
t "everything builds" "$(find models -name '*.sql' | sed 's/^models/build/; s/sql$/parquet/') test/t" -j4 all test A=1
