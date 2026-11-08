DUCKDB ?= duckdb
BUILD  ?= build

self   := $(lastword $(MAKEFILE_LIST))
tree   := $(shell find models tests ! -path '* *' \( -type d -o -name '*.sql' \) 2>/dev/null)
dirs   := $(filter-out %.sql,$(tree))
macros := $(sort $(wildcard macros/*.sql))
db     := $(DUCKDB) -init /dev/null -bail -list -noheader
run    := $(db) -cmd '.output /dev/null' $(macros:%=-cmd '.read %') -cmd '.output' -c
views   = $(foreach d,$^,$($d.view))
by      = $($@.by)
src     = $(if $(by),$(@:$(BUILD)/%=models/%@$(by).sql),$<)
flags   = $(if $(findstring =,$(firstword $(MAKEFLAGS))),,$(firstword -$(MAKEFLAGS)))
quiet   = $(findstring s,$(flags))
recheck = $(if $(filter-out FORCE,$?)$(findstring B,$(flags)),,$(run) "$$FRESH" 2>/dev/null ||)

all:
clean: ; rm -rf $(BUILD)
.PHONY: all test shell clean FORCE
.DELETE_ON_ERROR:

ifneq ($(filter-out clean,$(or $(MAKECMDGOALS),all)),)
$(if $(wildcard $(BUILD)/plan.mk),,$(shell mkdir -p $(BUILD) && touch -t 200001010000 $(BUILD)/plan.mk))
include $(BUILD)/plan.mk
endif

all: $(models)
test: $(tests)
.PHONY: $(tests)

$(BUILD)/plan.mk: $(self) $(tree)
	@mkdir -p $(@D) && $(db) -c "$$PLAN" > $@

$(BUILD)/%.parquet: models/%.sql $(wildcard macros) $(macros)
	@$(recheck) { mkdir -p $(@D) && $(run) "$$MATERIALISE"; }

$(filter-out %.parquet,$(models)): $(wildcard macros) $(macros)
	@ulimit -S -n $$(ulimit -H -n); $(recheck) { rm -rf $@.tmp $@.old && \
	  mkdir -p $(@D) && $(run) "$$MATERIALISE" && for f in $@.tmp/*/*; do \
	  mv "$$f" "$${f%/*}/data.parquet"; done && { mv $@ $@.old 2>/dev/null; \
	  mv $@.tmp $@ && rm -rf $@.old; }; } || { rm -rf $@.tmp; exit 1; }

$(tests): test/%: tests/%.sql $(macros)
	@$(run) "$$ASSERT"

shell: export VIEWS = $(views)
shell: $(models)
	@$(DUCKDB) $(macros:%=-cmd '.read %') -cmd "$$VIEWS"

define PLAN
create table src as
select
  *,
  if(kind = 'models', '$(BUILD)/' || stem || if(col = '', '.parquet', ''), 'test/' || stem) as target,
  target || if(col = '', '', '/*/data.parquet') as out,
  lower(if(stem like '%/%', split_part(stem, '/', 1), 'main')) as schema,
  lower(parse_filename(stem)) as name
from (
  select
    filename as file,
    unnest(regexp_extract(filename, '^(models|tests)/(.+?)(?:@(\w+))?\.sql$$', ['kind', 'stem', 'col'])),
    json_serialize_sql(content, skip_null := true, skip_empty := true)::json as ast
  from read_text(['models/**/*.sql', 'tests/**/*.sql'])
);

select error(file || ': ' || coalesce(ast->>'error_message', 'expected one SELECT statement'))
from src
where json_array_length(ast, '$$.statements') is distinct from 1;

select error(file || ': use only letters, digits, _ - and / in names, and one @column suffix in models')
from src
where not regexp_full_match(file, '[\w/-]+\.sql|models/[\w/-]+@\w+\.sql');

select error('duplicate model ' || schema || '.' || name || ': ' || string_agg(file, ', ' order by file))
from src
where kind = 'models'
group by schema, name
having count(*) > 1;

create table node as
select target, id, path, fullkey as loc, value as v
from src, json_tree(ast)
where json_extract_string(value, '$$.type') in ('BASE_TABLE', 'TABLE_FUNCTION')
  or json_extract_string(value, '$$.function_name') = 'getenv'
  or path like '%.cte_map.map';

create table cte as
select
  target, id, path, loc,
  regexp_replace(path, 'cte_map\.map$$', '') as scope,
  lower(v->>'key') as name,
  coalesce(v->>'$$.value.query.node.type', v->>'$$.value.query_node.type') = 'RECURSIVE_CTE_NODE' as rec
from node
where path like '%.cte_map.map';

create table ref as
select target, loc, lower(v->>'schema_name') as schema, lower(v->>'table_name') as name
from node
where v->>'type' = 'BASE_TABLE';

create table str as
select target, v->>'table_name' as s
from node
where v->>'type' = 'BASE_TABLE'
union
select target, unnest(if(
  a->>'function_name' = 'list_value',
  json_extract_string(a, '$$.children[*].value.value') || json_extract_string(a, '$$.arguments[*].expression.literal.text'),
  [coalesce(a->>'$$.value.value', a->>'$$.literal.text')]
))
from (select target, coalesce(v->'$$.function.children[0]', v->'$$.function.arguments[0].expression') as a from node where v->>'type' = 'TABLE_FUNCTION');

create table pat as
select
  target, s,
  replace(replace(replace(replace(replace(s, '.', '\.'), '**/', '%'), '*', '[^/]*'), '?', '[^/]'), '%', '(.*/)?') as re
from str
where regexp_full_match(s, '[\w./~-]*[*?][\w./*?~-]*');

create table edge as
select r.target, m.target as dep
from ref as r
left join src as m
  on m.kind = 'models'
  and m.schema = coalesce(r.schema, 'main')
  and m.name = r.name
where not regexp_matches(r.name, '[./]')
  and (r.schema is not null or not exists (
    from cte as c
    where c.target = r.target
      and c.name = r.name
      and starts_with(r.loc, c.scope)
      and not exists (
        from cte as d
        where d.target = c.target
          and d.path = c.path
          and starts_with(r.loc, d.loc || '.')
          and (d.id < c.id or d.id = c.id and not c.rec)
      )
  ))
union
select s.target, m.target
from str as s
join src as m on m.kind = 'models' and s.s = m.target
union
select s.target, m.target
from str as s
join src as m on m.kind = 'models' and lower(s.s) = m.schema || '.' || m.name
union
select g.target, m.target
from pat as g
join src as m on m.kind = 'models' and m.target <> g.target and regexp_full_match(m.out, g.re);

with recursive reach(target, dep) as (
  from edge
  union
  select r.target, e.dep
  from reach as r
  join edge as e on e.target = r.dep
)
select error('dependency cycle: ' || string_agg(distinct target, ' ' order by target))
from reach
where target = dep
having count(*) > 0;

create table vol as
from (
  select target, 'sources' as k, s as x
  from str
  where regexp_matches(s, '^[a-z][a-z0-9+.-]*://')
  union
  select target, 'sources', s
  from pat
  union
  select target, 'env', coalesce(v->>'$$.children[0].value.value', v->>'$$.arguments[0].expression.literal.text')
  from node
  where v->>'function_name' = 'getenv'
)
where target not like 'test/%'
  and not regexp_matches(x, '\s');

create table arc as
select dep as d, target as t from edge where dep is not null
union select s, target from str where regexp_full_match(s, '[\w./*?~-]+\.\w+')
union select x, target from vol where k = 'sources';

create table vert as
select n, 'n' || row_number() over (order by n) as id, coalesce(any_value(s), '[("' || replace(n, '"', '#quot;') || '")]') as s
from (
  select target, if(kind = 'models', '["' || schema || '.' || name || '"]', '{{"' || target || '"}}') from src
  union all select unnest([d, t]), null from arc
) as a(n, s)
group by n;

copy (
  select line from (
    select 0, 'flowchart LR'
    union all select 1, '  ' || id || s from vert
    union all select 2, '  ' || a.id || ' --> ' || b.id from arc join vert as a on a.n = d join vert as b on b.n = t
  ) as l(k, line)
  order by k, line
) to '$(BUILD)/dag.mmd' (format csv, header false, quote '', escape '');

select distinct line
from (
  select kind || ' += ' || target from src
  union all
  select format(
    '{0}.view := create schema if not exists "{1}"; create view "{1}"."{2}" as from ''{3}'';',
    target, schema, name, out
  )
  from src
  where kind = 'models'
  union all
  select target || ': ' || coalesce(dep, '$$(dirs)') from edge
  union all
  select target || ': ' || if(regexp_matches(s, '[*?]') or not contains(s, '/'), '$$(wildcard ' || s || ')', s)
  from str
  where regexp_full_match(s, '[\w./*?~-]+\.\w+')
    and not starts_with(s, '$(BUILD)/')
  union all
  select target || ': FORCE' from vol
  union all
  select unnest([target || ': ' || file, target || '.by := ' || col]) from src where col <> ''
  union all
  select target || '.' || k || ' += ' || replace(replace(replace(x, '''', ''''''), '$$', '$$$$'), '#', '\#')
  from vol
) as t(line)
order by line;
endef

define PRELUDE
$(views)
set variable sql = (select content from read_text('$(src)'));
set variable fp = md5(concat_ws(
  chr(10),
  getvariable('sql'),
  (
    select string_agg(concat_ws(' ', filename, size, last_modified), chr(10) order by filename)
    from read_blob(regexp_extract_all('$($@.sources)', '\S+'))
  ),
  (
    select string_agg(n || '=' || coalesce(getenv(n), ''), chr(10) order by n)
    from unnest(regexp_extract_all('$($@.env)', '\S+')) as t(n)
  )
));
endef

define FRESH
$(PRELUDE)
select error('stale')
where getvariable('fp') is distinct from (
  select string_agg(distinct decode(value), '')
  from parquet_kv_metadata('$@$(if $(by),/*/data.parquet)')
  where decode(key) = 'duckdb.mk'
);
endef

define MATERIALISE
$(PRELUDE)
set partitioned_write_max_open_files = 1e9;
copy (from query(getvariable('sql'))) to '$@$(if $(by),.tmp)' (format parquet, write_partition_columns true,
  $(if $(by),partition_by "$(by)",use_tmp_file true), kv_metadata {'duckdb.mk': getvariable('fp')});
$(if $(by),$(ONE))
$(if $(quiet),,select format('{}: {:,} rows', '$@', count(*)) from '$(if $(by),$@.tmp/*/*.parquet,$@)';)
endef

define ONE
select error(format('{}: {:,} files for {:,} partitions, expected one each', '$@', count(*), count(distinct parse_dirpath(file))))
from glob('$@.tmp/*/*')
having count(*) = 0 or count(*) > count(distinct parse_dirpath(file));
endef

define ASSERT
$(PRELUDE)
select error(format('{}: {:,} failing rows, e.g. {}', '$<', count(*), min(t, 3)))
from query(getvariable('sql')) as t
having count(*) > 0;
$(if $(quiet),,select '$@: pass';)
endef

export PLAN FRESH MATERIALISE ASSERT
