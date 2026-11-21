DUCKDB ?= duckdb
BUILD  ?= tables
PORT   ?= 9494
, := ,

self   := $(lastword $(MAKEFILE_LIST))
tree   := $(shell find models tests ! -path '* *' \( -type d -o -name '*.sql' \) 2>/dev/null)
dirs   := $(filter-out %.sql,$(tree))
db     := $(DUCKDB) -init /dev/null -bail -list -noheader
run     = $(db) -cmd '.output /dev/null' $(macros:%=-cmd '.read %') -cmd '.output' -c
views   = $(foreach d,$^,$($d.view))
by      = $($@.by)
src     = $(if $(by),$(@:$(BUILD)/%=models/%@$(by).sql),$<)
sql     = $$(awk '{s = s $$0 "\n"} END {sub(/[;[:space:]]+$$/, "", s); printf "%s", s}' $(src))
flags   = $(if $(findstring =,$(firstword $(MAKEFLAGS))),,$(firstword -$(MAKEFLAGS)))
quiet   = $(findstring s,$(flags))
page   := $(dir $(self))inspect.html
commit := $(shell git describe --always --dirty 2>/dev/null)
recheck = $(if $(filter-out FORCE,$?)$(findstring B,$(flags)),,$(if $($@.sources),$(run),$(db) -c) "$$FRESH" 2>/dev/null ||)

all:
clean: ; rm -rf $(BUILD)
.PHONY: all test shell inspect clean FORCE
.DELETE_ON_ERROR:

ifneq ($(filter-out clean,$(or $(MAKECMDGOALS),all)),)
$(if $(wildcard $(BUILD)/plan.mk),,$(shell mkdir -p $(BUILD) && touch -t 200001010000 $(BUILD)/plan.mk))
include $(BUILD)/plan.mk
endif

all: $(models)
test: $(tests)
.PHONY: $(tests)

$(BUILD)/plan.mk: $(self) $(tree) $(wildcard macros)
	@mkdir -p $(@D) && $(db) -c "$$PLAN" > $@

$(BUILD)/%.parquet: models/%.sql $(wildcard macros) $(macros)
	@$(recheck) { mkdir -p $(@D) && $(run) "$$PRELUDE" -c "copy ($(sql)$$WRITE"; }

$(filter-out %.parquet,$(models)): $(wildcard macros) $(macros)
	@ulimit -S -n $$(ulimit -H -n); $(recheck) { rm -rf $@.tmp $@.old && \
	  mkdir -p $(@D) && $(run) "$$PRELUDE" -c "copy ($(sql)$$WRITE" && for f in $@.tmp/*/*; do \
	  mv "$$f" "$${f%/*}/data.parquet"; done && { mv $@ $@.old 2>/dev/null; \
	  mv $@.tmp $@ && rm -rf $@.old; }; } || { rm -rf $@.tmp; exit 1; }

$(tests): test/%: tests/%.sql $(macros)
	@$(run) "$$PRELUDE" -c "$$ASSERT ($(sql)$$PASS"

shell inspect: export VIEWS = $(foreach m,$(models),$(if $(wildcard $m),$($m.view)))
shell:
	@$(DUCKDB) $(macros:%=-cmd '.read %') -cmd "$$VIEWS"

# cat gives duckdb its input, so that it stays, with no prompt, until that ends
inspect: $(page)
	@t=$$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n'); u="file://$(abspath $(page))#$(PORT):$$t"; \
	  g=$$($(db) -cmd 'create temp table s0 as from duckdb_settings()' \
	  -cmd '.output /dev/null' $(macros:%=-cmd '.read %') -cmd '.output' -c "$$GLOBAL"); \
	  { sleep 1; xdg-open "$$u" || echo "$$BROWSE" | osascript - "$$u"; } >/dev/null 2>&1 & \
	  cat | $(DUCKDB) $(macros:%=-cmd '.read %') -cmd "$$g" -cmd '.output /dev/null' -cmd "attach ':memory:' as plan; use plan" \
	  -cmd "$$PLAN" -cmd "use memory; $$VIEWS" -cmd "from quack_serve('quack:localhost:$(PORT)', token := '$$t')" \
	  -cmd "call enable_logging('QueryLog', storage := 'stdout')" -cmd '.output' -cmd ".print open $$u" | \
	  awk -v w=$$(tput cols 2>/dev/null || echo 999) "$$LOG"

$(page):
	$(if $(DUCKDB_MK),curl -sSfL --create-dirs -o $@ https://raw.githubusercontent.com/ltrgoddard/duckdb.mk/$(DUCKDB_MK)/$(@F),\
	  $(error put inspect.html from duckdb.mk beside $(self)))

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
    filename as file, content,
    unnest(regexp_extract(filename, '^(models|tests)/(.+?)(?:@(\w+))?\.sql$$', ['kind', 'stem', 'col'])),
    json_serialize_sql(content, skip_null := true, skip_empty := true)::json as ast
  from read_text(['models/**/*.sql', 'tests/**/*.sql'])
);

select error(file || ':' || coalesce(len(string_split(left(content, (ast->>'position')::int), chr(10))) || ':', '')
  || ' ' || coalesce(ast->>'error_message', 'expected one SELECT statement'))
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
from src, (from json_tree(src.ast))
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

select error(s.file || ': no model ' || r.schema || '.' || r.name)
from ref as r
join src as s using (target)
where r.schema in (select schema from src where kind = 'models')
  and (r.schema, r.name) not in (select (schema, name) from src where kind = 'models');

create table str as
select target, v->>'table_name' as s
from node
where v->>'type' = 'BASE_TABLE'
union
select target, unnest(if(
  a->>'function_name' = 'list_value',
  json_extract_string(a, '$$.children[*].value.value') || json_extract_string(a, '$$.arguments[*].expression.literal.text'),
  [coalesce(a->>'$$.value.value', a->>'$$.literal.text', if(
    a->>'function_name' = '||' and coalesce(a->>'$$.children[0].function_name', a->>'$$.arguments[0].expression.function_name') = 'getenv',
    '$$(' || coalesce(a->>'$$.children[0].children[0].value.value', a->>'$$.arguments[0].expression.arguments[0].expression.literal.text')
      || ')' || coalesce(a->>'$$.children[1].value.value', a->>'$$.arguments[1].expression.literal.text'), null))]
))
from (select target, unnest(json_extract(v, '$$.function.children[*]') || json_extract(v, '$$.function.arguments[*].expression')) as a from node where v->>'type' = 'TABLE_FUNCTION');

create table pat as
select
  target, s,
  replace(replace(replace(replace(replace(s, '.', '\.'), '**/', '%'), '*', '[^/]*'), '?', '[^/]'), '%', '(.*/)?') as re
from str
where regexp_full_match(s, '[\w./~=-]*[*?][\w./*?~=-]*');

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
join src as m on m.kind = 'models' and starts_with(s.s || '/', m.target || '/')
union
select s.target, m.target
from str as s
join src as m on m.kind = 'models' and lower(s.s) = m.schema || '.' || m.name
union
select g.target, m.target
from pat as g
join src as m on m.kind = 'models' and m.target <> g.target and regexp_full_match(replace(m.out, '/*/', '/' || m.col || '=_/'), g.re);

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
  where regexp_matches(s, '^[a-z][a-z0-9+.-]*://|^\$$\(')
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
union select s, target from str where regexp_full_match(s, '[\w./*?~=-]+\.\w+')
  and lower(s) not in (select schema || '.' || name from src)
union select x, target from vol where k = 'sources';

set variable globs = (
  select coalesce(list(distinct p), []) || ['$(BUILD)/.none']
  from (
    select out from src where kind = 'models' and col <> ''
    union all select s from pat
  ) as t(p)
  where not regexp_matches(p, '^[/~]|\.\./')
);
create table found as
select m.target as t, f.file as x
from glob(getvariable('globs')) as f
join (select target, out as re from src where col <> '' union all select target, re from pat) as m
  on if(m.target in (select target from src where col <> ''), f.file glob m.re, regexp_full_match(f.file, m.re));

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
  select target || ': ' || if(regexp_matches(s, '[*?=]') or not contains(s, '/'), '$$(wildcard ' || s || ')', s)
  from str
  where regexp_full_match(s, '[\w./*?~=-]+\.\w+')
    and not (starts_with(s, '$(BUILD)/') and (regexp_matches(s, '[*?]')
      or exists (from src as m where starts_with(s || '/', m.target || '/'))))
    and lower(s) not in (select schema || '.' || name from src)
  union all
  select target || ': FORCE' from vol
  union all
  select target || ': ' || file from src
  union all
  select target || '.by := ' || col from src where col <> ''
  union all
  select target || '.' || k || ' += ' || replace(replace(replace(x, '''', ''''''), '$$', if(x like '$$(%', '$$', '$$$$')), '#', '\#')
  from (select target, k, x from vol union all select t, 'files', x from found)
  union all
  select 'macros += ' || file from glob('macros/*.sql')
) as t(line)
order by line;
endef

# a url, sent to the default browser as it is, on macOS: open, and open
# location, drop a file url's fragment
define BROWSE
use framework "AppKit"
use scripting additions
on run {u}
  set ws to current application's NSWorkspace's sharedWorkspace()
  set https to current application's NSURL's URLWithString:"https:"
  tell application ((ws's URLForApplicationToOpenURL:https)'s |path|() as text)
    open location u
  end tell
end run
endef

# a set in the macros is the session's, and the page's is another: each that
# they change, made global
define GLOBAL
select coalesce(string_agg(format('set global {} = ''{}'';', name,
  replace(value, '''', '''''')), ' '), '') from (select name, value
  from duckdb_settings() where scope = 'LOCAL' except select name, value from s0)
endef

# duckdb's log of the page's queries, a line each, cut to the terminal's
# width, less quack's own; a line that is not of the log, as it is
define LOG
!n && !/\tQueryLog\t/ { print; fflush(); next }
{ s = s " " $$0; n += gsub(/"/, "&") }
n % 2 == 0 {
  sub(/^.*\tQueryLog\t[A-Z]+\t"?/, "", s); sub(/"$$/, "", s)
  gsub(/""/, "\"", s); gsub(/[ \t]+/, " ", s)
  if (s !~ /^SELECT quack_/) { print substr(s, 1, w); fflush() }
  s = ""; n = 0
}
endef

define FP
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

define PRELUDE
$(views)
$(FP)
set partitioned_write_max_open_files = 1e9;
endef

define FRESH
$(FP)
select error('stale')
where getvariable('fp') is distinct from (
  select string_agg(distinct decode(value), '')
  from parquet_kv_metadata('$@$(if $(by),/*/data.parquet)')
  where decode(key) = 'duckdb.mk'
);
endef

define WRITE

) to '$@$(if $(by),.tmp)' (format parquet, write_partition_columns true, $(if $(PARQUET),$(PARQUET)$(,))
  $(if $(by),partition_by "$(by)",use_tmp_file true), kv_metadata {
  'duckdb.mk': getvariable('fp'), 'sql': getvariable('sql'), 'commit': '$(commit)'});
$(if $(by),$(ONE))
$(if $(quiet),,select format('{}: {:,} rows', '$@', count(*)) from '$(if $(by),$@.tmp/*/*.parquet,$@)';)
endef

define ONE
select error(format('{}: {:,} files for {:,} partitions, expected one each', '$@', count(*), count(distinct parse_dirpath(file))))
from glob('$@.tmp/*/*')
having count(*) = 0 or count(*) > count(distinct parse_dirpath(file));
endef

define ASSERT
select error(format('{}: {:,} failing rows, e.g. {}', '$<', count(*), min(t, 3))) from
endef

define PASS

) as t having count(*) > 0;
$(if $(quiet),,select '$@: pass';)
endef

export PLAN PRELUDE FRESH WRITE ASSERT PASS BROWSE LOG GLOBAL
