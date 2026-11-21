# duckdb.mk recipes

These examples combine SQL models with ordinary Make rules. Add the rules
after `include duckdb.mk` (or the versioned include in your Makefile).
See the [reference](REFERENCE.md#dependencies) for dependency rules.

## Run another program between models

This small example records the checksum of a built table. It uses Python's
standard library to hash the Parquet file, then reads the result in a second
model. The same arrangement works for a separate analysis or conversion tool.

Create `models/orders.sql`:

```sql
select * from (values (1, 20), (2, 35)) as orders(id, amount)
```

Create `scripts/checksum.py`:

```python
import csv
import hashlib
import sys

checksum = hashlib.sha256()
with open(sys.argv[1], 'rb') as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b''):
        checksum.update(chunk)
writer = csv.writer(sys.stdout)
writer.writerow(['path', 'sha256'])
writer.writerow([sys.argv[1], checksum.hexdigest()])
```

Add this rule to the Makefile:

```make
data/orders-checksum.csv: tables/orders.parquet scripts/checksum.py
	@mkdir -p $(@D)
	python3 scripts/checksum.py $< > $@.tmp
	mv $@.tmp $@
```

Create `models/checksums.sql`:

```sql
select * from read_csv('data/orders-checksum.csv')
```

Run `make`. It builds `orders`, runs the script, then builds `checksums`.
The source path in `checksums.sql` supplies the dependency on the custom
rule. Editing either `orders.sql` or the script causes the checksum to be
written again. If the script fails, Make stops before replacing the CSV or
building the downstream model.

## Track an external run

Use an environment variable to select the output directory of another
pipeline:

```sql
-- models/gem/plants.sql
select * from read_csv(getenv('RAW_URI') || '/plants.csv')
```

```make
tables/gem/%: export RAW_URI = s3://bucket/gem/2026-11-01
```

The target-specific `export` sets `RAW_URI` for models in `tables/gem/`.
On every run, duckdb.mk checks the variable's value and the size and
modification time of the resulting source file. Changing the directory or
the source rebuilds the models that read it.

Keep the variable first and the rest of the path in one literal, as above.
Other expressions that construct paths at run time are not tracked.
