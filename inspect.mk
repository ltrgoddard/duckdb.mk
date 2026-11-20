# the inspector, optional: include this after duckdb.mk. `make inspect`
# serves a page that shows each model and test, its lineage as the plan has
# it, and its sql, run in the browser a clause at a time over the tables as
# make last built them. nothing is built for it: a model with no table shows
# as not built.
#
#   INSPECT       where the page goes, a static site: $(BUILD)/inspect
#   INSPECT_ENV   the variables whose values the page's getenv() gives; the
#                 others are empty there. the values are in inspect.json
#   INSPECT_HIDE  a regex of the models and tests to leave out
#   INSPECT_JS    a module of the project's own for the page (inspect.js)
#   PORT          the port that `make inspect` serves on: 8000
#
# $(INSPECT)/files holds, by its path, each built table and each file in the
# project that a model not left out names: a hard link, or a copy on another
# disk
INSPECT ?= $(BUILD)/inspect
PORT    ?= 8000
inspect := $(addprefix $(dir $(lastword $(MAKEFILE_LIST)))inspect/,\
  index.html inspect.js db.js sql.js plan.js dag.js rows.js)

inspect: $(INSPECT)/inspect.json
	python3 -m http.server -d $(INSPECT) $(PORT)
.PHONY: inspect

$(INSPECT)/inspect.json: $(inspect) $(INSPECT_JS) FORCE
	@mkdir -p $(@D) && cp $(inspect) $(@D) && rm -f $(@D)/project.js \
	  $(if $(INSPECT_JS),&& cp $(INSPECT_JS) $(@D)/project.js) && \
	  $(db) -cmd '.output /dev/null' -c "$$PLAN" -cmd '.output' \
	  -c "$$INSPECT_SQL" > $@.ls && rm -rf $(@D)/files && \
	  while IFS= read -r f; do t="$(@D)/files/$$f" && \
	  mkdir -p "$$(dirname "$$t")" && { ln -f "$$f" "$$t" 2>/dev/null || \
	  cp "$$f" "$$t"; }; done < $@.ls && rm $@.ls

# the plan's tables as inspect.json; the files to link, a line each
define INSPECT_SQL
create table item as
select *, if(kind = 'tests', target, if(schema = 'main', '', schema || '.') || name) as id
from src
join read_text(['models/**/*.sql', 'tests/**/*.sql']) on filename = file;
set variable globs = (
  select list(distinct p)
  from (
    select out from src where kind = 'models'
    union all
    select d from arc join item on target = t where '$(INSPECT_HIDE)' = '' or not regexp_matches(id, '$(INSPECT_HIDE)')
  ) as t(p)
  where not regexp_matches(p, '^[/~]|\.\./|://')
);
set variable files = (
  select coalesce(list(distinct file order by file), [])
  from glob(getvariable('globs'))
  where not starts_with(file, '$(INSPECT)/')
);
copy (
  select
    '$(notdir $(CURDIR))' as title,
    '$(INSPECT_HIDE)' as hide,
    '$(INSPECT_JS)' <> '' as ext,
    getvariable('files') as files,
    (
      select map_from_entries(coalesce(list((k, getenv(k))), []))
      from unnest(regexp_extract_all('$(INSPECT_ENV)', '\S+')) as t(k)
    ) as env,
    (
      select coalesce(list({file: filename, sql: content} order by filename), [])
      from read_text(['macros/*.sql', 'models/**/*.sql'])
      where filename like 'macros/%'
    ) as macros,
    (
      select list({
        id: id,
        test: kind = 'tests',
        file: file,
        sql: content,
        target: target,
        out: out,
        "by": nullif(col, ''),
        reads: (select coalesce(list(distinct m.id order by m.id), []) from edge join item as m on m.target = dep where edge.target = n.target),
        sources: (select coalesce(list(distinct d order by d), []) from arc where t = n.target and d not in (select target from src) and not regexp_matches(d, '^$(BUILD)/.*[*?]')),
        env: (select coalesce(list(distinct x order by x), []) from vol where vol.target = n.target and k = 'env')
      } order by file)
      from item as n
    ) as nodes
) to '$@' (format json);
select unnest(getvariable('files'));
endef
export INSPECT_SQL
