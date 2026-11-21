# the inspector: make serve, a duckdb that the page queries over quack, with
# the plan, a view on each built table and the macros; and the steps in words
# that the page's words section makes of a query
if [[ $($DUCKDB -init /dev/null -list -noheader -c "select version() >= 'v2'") != true ]]; then
  echo "ok   the inspector needs duckdb 2.0 (skipped)"; return 0
fi
cp "$here/inspect.html" . && printf 'export REGION = north\ninclude duckdb.mk\n' > Makefile
mkdir -p models/s tests macros data bin && printf 'id,k\n1,a\n2,b\n' > data/x.csv
echo "-- Rows.
select *, getenv('REGION') as r from read_csv('data/x.csv')" > models/s/a.sql
echo "from s.a where id > 1" > models/top.sql
echo "from top where id < 0" > tests/t.sql
echo "create macro twice(x) as x * 2;" > macros/m.sql
$MAKE -s DUCKDB="$DUCKDB" tables/s/a.parquet > /dev/null

# serve on a free port, with stdin held open for duckdb's shell, and a
# browser that notes the url that it is given
printf '#!/bin/sh\necho "$1" > opened\n' > bin/xdg-open && chmod +x bin/xdg-open
port=$((20000 + RANDOM % 20000)) && mkfifo in
PATH=$PWD/bin:$PATH $MAKE -s DUCKDB="$DUCKDB" PORT=$port serve < in > out 2>&1 &
exec 3> in
for n in {1..100}; do grep -q '^open ' out && break; sleep 0.1; done
url=$(sed -n 's/^open //p' out) tok=${url##*:}
sq() {
  $DUCKDB -init /dev/null -list -noheader -c "from quack_query('quack:localhost:$port', \$\$$1\$\$, token := '${2-$tok}')" 2>&1
}
is "the url of the page, with duckdb's port" "${url%:*}" "file://$(pwd -P)/inspect.html#$port"
is "the plan" "$(sq "select string_agg(target, ' ' order by target) from plan.main.src")" \
  'tables/s/a.parquet tables/top.parquet test/t'
is "a view on each built table, and the macros" "$(sq "select twice(id) from s.a order by id")" '2
4'
is "no view on a table not built" "$(sq "select count(*) from duckdb_views() where view_name = 'top'")" 0
is "the variables, as make has them" "$(sq "select r from s.a limit 1")" north
is "a wrong token" "$(sq "select 1" wrong | grep -c 'Authentication failed')" 1
for n in {1..20}; do [[ -s opened ]] && break; sleep 0.1; done
is "the browser is given the url" "$(cat opened)" "$url"
exec 3>&-; wait
is "duckdb stops with its shell" "$(sq "select 1" | grep -c 'Authentication failed\|^1$')" 0
is "a local copy fetches no page" \
  "$(rm inspect.html; $MAKE -s DUCKDB="$DUCKDB" serve 2>&1 < /dev/null | grep -c 'put inspect.html')" 1

# the page's words section, by node if there is one: each query's steps, a
# line each, by depth, with their lines below them
command -v node > /dev/null || { echo "ok   words needs node (skipped)"; return 0; }
{ sed -n '/^\/\/ words ---/,/^\/\/ page ---/p' "$here/inspect.html"; echo 'export {explain, text}'; } > words.mjs
cat > q.sql <<'EOF'
select a, count(*) n, sum(x) filter (where y > 1) t from s.a where a is not null and b in (1, 2) group by a having n > 1 order by n desc limit 5
with c as (from top where id < 0), d as (select id, max(v) m from c group by all) from d left join c using (id) where m between 1 and 3
select * exclude (k) from 'tables/s/a.parquet' as f, unnest([1, 2]) u(v) qualify row_number() over (partition by f.k order by v desc) = 1
select x like '%a', x not like 'a%', coalesce(a, b, 0) z, case when x > 1 then 'big' else 'small' end s, j->>'$.k', date_trunc('month', d) from read_csv('data/x.csv')
from (values (1, 'a'), (2, 'b')) v(n, s) where exists (from top where top.id = v.n) and n not in (select id from top)
select distinct on (a) a, lag(b) over (order by c) p, sum(b) over () t, avg(b) over (partition by a order by c rows between 2 preceding and current row) m from s.a
from s.a semi join top on s.a.id = top.id union all select 1, 2 order by 1
EOF
cat > show.mjs <<EOF
import {explain, text} from "./words.mjs"
import {readFileSync} from "fs"
const ref = n => ({"s.a": "s.a", top: "top", "tables/s/a.parquet": "s.a"})[n.toLowerCase()] ?? null
for (const {ast} of JSON.parse(readFileSync(0, "utf8")))
  for (const s of explain(ast.statements[0].node, ref))
    console.log("  ".repeat(s.depth) + text(s.text) + (s.lines ?? []).map(l => "\n" + "  ".repeat(s.depth + 1) + "- " + text(l)).join(""))
EOF
steps=$($DUCKDB -init /dev/null -json -c "select json_serialize_sql(q, skip_null := true, skip_empty := true) ast from read_csv('q.sql', header = false, delim = '\t', quote = '', columns = {'q': 'varchar'})" | node show.mjs 2>&1)
is "steps in words" "$steps" "$(cat <<'EOF'
Start from s.a
Keep the rows where:
  - a has a value
  - and b is either 1 or 2
Group the rows by a
Keep the groups where n > 1
Return:
  - a
  - n: the number of rows
  - t: the total of x among the rows where y > 1
Sort by n descending
Keep the first 5 rows
Make table c:
  Start from top
  Keep the rows where id < 0
Make table d:
  Start from c
  Group the rows by each column that is not a total
  Return:
    - id
    - m: the highest v
Then:
  Start from d
  Join c where it has the same id, keeping the rows with no match
  Keep the rows where m is from 1 to 3
Start from s.a as f
Make a row for each of [1, 2], as v
Return:
  - every column but k
Keep the first row of each f.k, in order of v descending
Read the CSV file at data/x.csv
Return:
  - x ends with 'a'
  - x does not start with 'a'
  - z: a, else b, else 0
  - s: 'big' if x > 1, else 'small'
  - the k in j
  - d to the month
Make table A:
  Start from top
  Keep the rows where top.id = v.n
Make table B:
  Start from top
  Return:
    - id
Then:
  Start from a 2-row table written by hand
    - n: 1, s: 'a'
    - n: 2, s: 'b'
  Keep the rows where:
    - there are rows in A
    - and n is not in B
Start from s.a
For the first row of each a, return:
  - a
  - p: the previous b in order of c
  - t: the total of b across all the rows
  - m: the mean of b within each a in order of c, from 2 rows before to this row
Take the rows of:
  Start from s.a
  Keep the rows with a match in top, where s.a.id = top.id
Add the rows of:
  Make one row of:
    - 1
    - 2
Sort by 1
EOF
)"
# each step's query, as duckdb gives it back: the sql of its rows
cat > sql.mjs <<EOF
import {explain} from "./words.mjs"
import {readFileSync} from "fs"
for (const {ast} of JSON.parse(readFileSync(0, "utf8")))
  for (const s of explain(ast.statements[0].node)) console.log(JSON.stringify({q: s.query}))
EOF
$DUCKDB -init /dev/null -json -c "select json_serialize_sql(q, skip_null := true, skip_empty := true) ast from read_csv('q.sql', header = false, delim = '\t', quote = '', columns = {'q': 'varchar'})" | node sql.mjs > steps.json
is "each step's query, back as sql" "$($DUCKDB -init /dev/null -list -noheader -c "
  select count(*) filter (where try(json_deserialize_sql(q::json)) is null) from read_json('steps.json')")" 0
is "a step's sql" "$($DUCKDB -init /dev/null -list -noheader -c "
  select json_deserialize_sql(q::json) from read_json('steps.json') limit 1 offset 2")" \
  'SELECT a FROM s.a WHERE ((a IS NOT NULL) AND (b IN (1, 2))) GROUP BY a'
