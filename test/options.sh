# PARQUET passes writer options, for every model or a target's; every string
# argument of a table function is a dependency, not only the first; a file
# named by a variable and a literal is checked as the variable is
mkdir -p models/g macros && echo "select range id from range(5000)" > models/g/a.sql
echo "select range id from range(5000)" > models/b.sql
echo "create macro pair(x, y) as table from query_table(x) union all from query_table(y);" > macros/pair.sql
echo "from pair('g.a', 'main.b')" > models/c.sql
rg() { q "select max(row_group_num_rows) || ' ' || any_value(compression) from parquet_metadata('$1')"; }
printf 'PARQUET = compression zstd\ntables/g/%%: PARQUET += , row_group_size 4096\n' >> Makefile
t "options" "tables/g/a.parquet tables/b.parquet tables/c.parquet"
is "global option" "$(rg tables/b.parquet)" "5000 ZSTD"
is "target option" "$(rg tables/g/a.parquet)" "4096 ZSTD"
is "every argument a dependency" "$(deps tables/c.parquet)" "tables/b.parquet tables/g/a.parquet"

mkdir -p in other && printf 'id\n1\n' > in/x.csv && printf 'id\n1\n2\n' > other/x.csv
echo "from read_csv(getenv('DIR') || '/x.csv')" > models/d.sql
export DIR=in
t "a file below a variable" "tables/d.parquet"
is "its place, for make to fill in" "$(sed -n 's/^tables\/d.parquet.sources += //p' tables/plan.mk)" '$(DIR)/x.csv'
t "no-op" ""
printf 'id\n1\n2\n3\n' > in/x.csv
t "the file changes" "tables/d.parquet"
t "the variable changes" "tables/d.parquet" DIR=other
