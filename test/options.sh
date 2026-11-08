# PARQUET passes writer options, for every model or a target's; every string
# argument of a table function is a dependency, not only the first
mkdir -p models/g macros && echo "select range id from range(5000)" > models/g/a.sql
echo "select range id from range(5000)" > models/b.sql
echo "create macro pair(x, y) as table from query_table(x) union all from query_table(y);" > macros/pair.sql
echo "from pair('g.a', 'main.b')" > models/c.sql
rg() { q "select max(row_group_num_rows) || ' ' || any_value(compression) from parquet_metadata('$1')"; }
printf 'PARQUET = compression zstd\nbuild/g/%%: PARQUET += , row_group_size 4096\n' >> Makefile
t "options" "build/g/a.parquet build/b.parquet build/c.parquet"
is "global option" "$(rg build/b.parquet)" "5000 ZSTD"
is "target option" "$(rg build/g/a.parquet)" "4096 ZSTD"
is "every argument a dependency" "$(deps build/c.parquet)" "build/b.parquet build/g/a.parquet"
