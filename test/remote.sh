# remote sources over HTTP and S3: reads, fingerprints and the requests they cost
mkdir -p models/http models/s3 tests
bumps=0
bump() { python3 -c "import os, sys, time; os.utime(sys.argv[1], (time.time() + $((bumps += 5)),) * 2)" "$1"; } # a later Last-Modified
printf 'k,v\na,1\nb,2\n' > "$www/a.csv" && printf 'k,v\nc,3\n' > "$www/b.csv"
printf '[{"k": "a", "v": [1, 2]}, {"k": "b", "v": [3]}]' > "$www/a.json"
printf 'k,v\nx,1\n' > "$www/bare.csv" && cp "$www/bare.csv" "$www/nohead.csv"
q "copy (select range as id, range % 97 as g from range(2000000)) to '$www/big.parquet' (row_group_size 100000)" >/dev/null

echo "from read_csv('$url/a.csv')" > models/http/csv.sql
echo "select k, unnest(v) as v from read_json('$url/a.json')" > models/http/json.sql
echo "select g, count(*) as n from '$url/big.parquet' where id % 2 = 0 group by g" > models/http/parquet.sql
echo "from read_csv(['$url/a.csv', '$url/b.csv'], filename = true)" > models/http/list.sql
echo "select content from read_text('$url/b.csv')" > models/http/text.sql
echo "from read_csv('$url/bare/bare.csv')" > models/http/bare.sql
echo "from read_csv('$url/nohead/nohead.csv')" > models/http/nohead.sql
echo "from read_csv('$url/a.csv?\$limit=5&x=''#')" > models/http/dollar.sql
echo "from read_csv('$url/' || getenv('FILE'))" > models/http/template.sql
echo "select sum(n) as n from http.parquet" > models/http/downstream.sql
echo "from http.list where v is null" > tests/list_complete.sql
http="tables/http/bare.parquet tables/http/csv.parquet tables/http/dollar.parquet tables/http/downstream.parquet \
tables/http/json.parquet tables/http/list.parquet tables/http/nohead.parquet tables/http/parquet.parquet \
tables/http/template.parquet tables/http/text.parquet"
export FILE=a.csv

t "http build" "$http test/list_complete" -j4 all test
is "http csv" "$(q "select string_agg(k || v, ' ' order by k) from 'tables/http/csv.parquet'")" "a1 b2"
is "http json" "$(q "select string_agg(k || v, ' ' order by k, v) from 'tables/http/json.parquet'")" "a1 a2 b3"
is "http parquet" "$(q "select n::bigint from 'tables/http/downstream.parquet'")" 1000000
is "http list" "$(q "select count(distinct filename) from 'tables/http/list.parquet'")" 2
is "http text" "$(q "select content from 'tables/http/text.parquet'" | head -1)" "k,v"
is "parquet over http reads ranges" "$(requests | grep -c '^GET /big.parquet 200')" 0
t "http no-op" ""
is "no-op only asks for headers" "$(requests | grep -v nohead | grep -vc '^HEAD')" 0
printf 'k,v\na,1\nb,2\nc,3\n' > "$www/a.csv" && bump "$www/a.csv"
t "http change" "tables/http/csv.parquet tables/http/dollar.parquet tables/http/list.parquet"
is "http change reads the new data" "$(q "select count(*) from 'tables/http/list.parquet'")" 4
bump "$www/b.csv"
t "http touch" "tables/http/list.parquet tables/http/text.parquet"
bump "$www/big.parquet"
t "http touch rebuilds dependents" "tables/http/downstream.parquet tables/http/parquet.parquet"
export FILE=b.csv
t "url template follows its variable" "tables/http/template.parquet"
t "url template unchanged" ""
is "url template reads the right file" "$(q "select string_agg(k, ' ') from 'tables/http/template.parquet'")" "c"
printf 'k,v\ny,1\n' > "$www/bare.csv" && bump "$www/bare.csv"
t "no Last-Modified: same size is unchanged" ""
printf 'k,v\nyy,1\n' > "$www/bare.csv"
t "no Last-Modified: new size rebuilds" "tables/http/bare.parquet"
printf 'k,v\nxy,2\n' > "$www/nohead.csv" && bump "$www/nohead.csv"
t "no HEAD" "tables/http/nohead.parquet"
t "no HEAD no-op" ""
mv "$www/b.csv" "$www/gone.csv"
t "missing remote" "!404" tables/http/text.parquet
is "missing remote keeps the last good output" "$(q "select count(*) from 'tables/http/text.parquet'")" 1
mv "$www/gone.csv" "$www/b.csv"
t "remote back is unchanged" "" tables/http/text.parquet

[[ $S3 == - ]] && { echo "skip s3: pip install 'moto[server]' to run"; return; }
bucket=duckdb-mk-$RANDOM
boto() { python3 -c "import boto3; boto3.client('s3', endpoint_url='http://127.0.0.1:$S3', region_name='us-east-1',
  aws_access_key_id='k', aws_secret_access_key='s').$1"; }
boto "create_bucket(Bucket='$bucket')"
mkdir -p macros && cat > macros/s3.sql <<SQL
create secret (type s3, key_id 'k', secret 's', region 'us-east-1', endpoint '127.0.0.1:$S3', url_style 'path', use_ssl false);
SQL
s3() { q "$(cat macros/s3.sql) $1" >/dev/null; }
s3 "copy (select range as id, 'a' as part from range(10)) to 's3://$bucket/one.parquet';
    copy (select range as id, range % 3 as part from range(30)) to 's3://$bucket/hive' (format parquet, partition_by part);
    copy (select 1 as id) to 's3://$bucket/csv/1.csv'"
echo "from 's3://$bucket/one.parquet'" > models/s3/one.sql
echo "select part, count(*) as n from read_parquet('s3://$bucket/hive/*/*.parquet', hive_partitioning = true) group by part" \
  > models/s3/hive.sql
echo "select count(*) as n from read_csv('s3://$bucket/csv/*.csv')" > models/s3/glob.sql
s3only="tables/s3/glob.parquet tables/s3/hive.parquet tables/s3/one.parquet"
t "s3 build" "$http $s3only" -j4
is "s3 hive partitions" "$(q "select string_agg(part || ':' || n, ' ' order by part) from 'tables/s3/hive.parquet'")" \
  "0:10 1:10 2:10"
t "s3 no-op" ""
s3 "copy (select 2 as id) to 's3://$bucket/csv/2.csv'"
t "s3 new object matching a glob" "tables/s3/glob.parquet"
is "s3 glob reads it" "$(q "select n from 'tables/s3/glob.parquet'")" 2
s3 "copy (select range as id, 'b' as part from range(20)) to 's3://$bucket/one.parquet'"
t "s3 object replaced" "tables/s3/one.parquet"
boto "delete_object(Bucket='$bucket', Key='csv/2.csv')"
t "s3 object deleted" "tables/s3/glob.parquet"
t "s3 no-op again" ""
