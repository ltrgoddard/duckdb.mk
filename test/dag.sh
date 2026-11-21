# the mermaid flowchart each run writes to tables/dag.mmd
mkdir -p models/s tests data && printf 'id\n1\n' > data/x.csv
echo "from read_csv('data/x.csv')" > models/a.sql
echo "from a, read_csv('http://example.org/it''s#\$1.csv')" > models/s/Up.sql
echo "from read_csv('data/*.csv') where getenv('X') is null" > models/glob.sql
echo "select 1 as id" > models/lone.sql
echo "from lookup" > models/macro.sql
echo "from s.up where id < 0" > tests/t.sql
echo "select 1 as id where false" > tests/none.sql
is "flowchart" "$($MAKE -sn DUCKDB="$DUCKDB" >/dev/null; cat tables/dag.mmd)" 'flowchart LR
  n10{{"test/t"}}
  n1[("data/*.csv")]
  n2[("data/x.csv")]
  n3[("http://example.org/it'"'"'s#$1.csv")]
  n4["main.a"]
  n5["main.glob"]
  n6["main.lone"]
  n7["main.macro"]
  n8["s.up"]
  n9{{"test/none"}}
  n1 --> n5
  n2 --> n4
  n3 --> n8
  n4 --> n8
  n8 --> n10'
