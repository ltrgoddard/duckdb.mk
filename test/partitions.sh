# partitioned models: one data.parquet per value, rebuilds, references and failures
mkdir -p models/eog tests
echo "select range % 3 as cell, range as v from range(10)" > models/eog/detections@cell.sql
echo "select cell, count(*) as n from eog.detections group by all" > models/counts.sql
echo "select count(*) as n from read_parquet('build/eog/detections/*/data.parquet')" > models/glob.sql
echo "from eog.detections where cell not between 0 and 2" > tests/cells.sql
all="build/counts.parquet build/eog/detections build/glob.parquet"
files() { (cd build/eog/detections && find . -type f | sort | xargs); }
cells() { q "select string_agg(distinct cell, ' ' order by cell) from '$1'"; }

t "build" "$all test/cells" all test
is "one data.parquet per value" "$(files)" "./cell=0/data.parquet ./cell=1/data.parquet ./cell=2/data.parquet"
is "partition column in the files" "$(cells 'build/eog/detections/cell=1/data.parquet')" 1
is "recursive glob reads the column" "$(cells 'build/eog/detections/**/*.parquet')" "0 1 2"
is "fingerprint in every file" "$(q "select count(*) || ' ' || count(distinct value)
  from parquet_kv_metadata('build/eog/detections/*/data.parquet') where decode(key) = 'duckdb.mk'")" "3 1"
is "reference by name" "$(q "select string_agg(cell || ':' || n, ' ' order by cell) from 'build/counts.parquet'")" \
  "0:4 1:3 2:3"
is "reference by glob" "$(deps build/glob.parquet)" "FORCE build/eog/detections"
is "shell" "$(printf '.mode list\n.headers off\nselect count(*) from eog.detections;' | $MAKE -s shell)" 10
t "no-op" ""
t "no-op test run" "test/cells" test
echo "select range % 2 as cell, range as v from range(10)" > models/eog/detections@cell.sql
t "edit" "$all"
is "stale partitions removed" "$(files)" "./cell=0/data.parquet ./cell=1/data.parquet"
is "dependents read the new partitions" "$(q "select count(*) from 'build/counts.parquet'")" 2
echo "-- a comment" >> models/eog/detections@cell.sql
t "comment edit" "$all"
t "single target" "" build/eog/detections
t "always make" "$all" -B

echo "select if(range = 3000000, error('late'), range % 5) as cell from range(4000000)" > models/eog/detections@cell.sql
t "error midway" "!late"
is "error keeps the last good output" "$(files)" "./cell=0/data.parquet ./cell=1/data.parquet"
is "error leaves no temporary files" "$(ls build/eog)" detections
echo "select 1 as cell where false" > models/eog/detections@cell.sql
t "no rows" "!build/eog/detections: 0 files for 0 partitions"
is "no rows keeps the last good output" "$(files)" "./cell=0/data.parquet ./cell=1/data.parquet"
echo "select range as cell from range(2)" > models/eog/detections@cell.sql
t "recovered" "$all"

echo "select 1" > models/eog/detections.sql
t "duplicate across a suffix" "!duplicate model eog.detections: models/eog/detections.sql, models/eog/detections@cell.sql"
rm models/eog/detections.sql
echo "select 1 as a" > "models/x@a@b.sql"
t "two suffixes" "!models/x@a@b.sql: use only"; rm "models/x@a@b.sql"
echo "select 1 as a" > "tests/x@a.sql"
t "suffix on a test" "!tests/x@a.sql: use only"; rm "tests/x@a.sql"
t "fixed" ""
