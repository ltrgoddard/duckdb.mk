# a random 300-model project checked against a python oracle: edges, results and incremental rebuilds
python3 - <<'PY'
import os, random
random.seed(int(os.environ.get('SEED', 7)))
n, mod = 300, 1000003
models = [(f's{random.randrange(4)}' if random.random() < 0.6 else 'main', f'm{i}') for i in range(n)]
target = lambda i: 'build/' + ('' if models[i][0] == 'main' else models[i][0] + '/') + models[i][1] + '.parquet'
deps, value = {}, {}
for i, (schema, name) in enumerate(models):
    os.makedirs('models' if schema == 'main' else f'models/{schema}', exist_ok=True)
    deps[i] = sorted(random.sample(range(i), min(i, random.choice([0, 1, 2, 3, 4]))))
    refs = []
    for d in deps[i]:
        s, m = models[d]
        refs.append(random.choice([
            f'{s}.{m}', f'"{s.upper()}"."{m.upper()}"', f"query_table('{s}.{m}')", f"'{target(d)}'",
            f'(select * from {s}.{m})', f'lateral (select n from {s}.{m})',
        ] + ([m] if s == 'main' else [])))
    # ctes named after models that are not dependencies shadow them
    decoys = [models[j][1] for j in random.sample(range(n), 3) if models[j][0] == 'main' and j not in deps[i]]
    ctes = [f'{m} as (select 0 as n)' for m in decoys]
    parts = [f'select n from {r}' for r in refs] + [f'select n from {m}' for m in decoys]
    body = 'select ((1 + coalesce(sum(n), 0)) % {})::bigint as n from ({})'.format(mod, ' union all '.join(parts) or 'select 0 as n')
    with open(f'models/{"" if schema == "main" else schema + "/"}{name}.sql', 'w') as f:
        f.write((f'with {", ".join(ctes)}\n' if ctes else '') + body + '\n')
    value[i] = (1 + sum(value[d] for d in deps[i])) % mod
with open('expected_edges', 'w') as f:
    f.writelines(sorted(f'{target(i)}: {target(d)}\n' for i in deps for d in deps[i]))
with open('expected_values', 'w') as f:
    f.writelines(sorted(f'{target(i)} {value[i]}\n' for i in value))
with open('dependents', 'w') as f:
    for i in range(n):
        seen, todo = {i}, [i]
        while todo:
            j = todo.pop()
            for k in range(j + 1, n):
                if j in deps[k] and k not in seen:
                    seen.add(k); todo.append(k)
        f.write(target(i) + ' ' + ' '.join(sorted(map(target, seen))) + '\n')
PY
all=$(cut -d' ' -f1 expected_values | xargs)
dependents() { for m; do grep "^$m " dependents | cut -d' ' -f2-; done | xargs -n1 | sort -u | xargs; }

is "plan edges" "$(deps >/dev/null; grep -E '^build/.*\.parquet: build/' build/plan.mk | sort)" "$(cat expected_edges)"
lim="set memory_limit = '300MB'; set max_temp_directory_size = '0B'"
is "plan in 300 MB" "$(rm build/plan.mk; $MAKE -s DUCKDB="$DUCKDB -cmd \"$lim\"" build/plan.mk 2>&1)" ""
is "no other prerequisites" "$(grep -E '^build/.*\.parquet: ' build/plan.mk | grep -vE ': (build/|\$\(wildcard )')" ""
t "parallel build" "$all" -j4
is "values" "$(q "select concat_ws(' ', filename, n) from read_parquet('build/**/*.parquet', filename = true) order by 1")" \
  "$(cat expected_values)"
t "no-op" "" -j4
first=$(find models -name m0.sql) && touch "$first"
t "touch the first model" "$(dependents "$(sed 's/^models/build/; s/sql$/parquet/' <<<"$first")")" -j4
picked=$(xargs -n1 <<<"$all" | awk 'NR % 60 == 17' | xargs)
for m in $picked; do touch "$(sed 's/^build/models/; s/parquet$/sql/' <<<"$m")"; done
t "touch five models" "$(dependents $picked)" -j4
t "no-op again" "" -j4
