# the release: the docs name the latest tag where they pin a version, so that
# a project that copies the snippet fetches a version that there is
tag=$(git -C "$here" describe --tags --abbrev=0 2>/dev/null) ||
  { echo "ok   the pins need the tags (skipped)"; return 0; }
is "the docs pin the latest tag" "$(cd "$here" && grep -ohE \
  '(DUCKDB_MK = |install duckdb.mk )v[0-9.]+' README.md docs/*.md | sort -u)" \
  "DUCKDB_MK = $tag
install duckdb.mk $tag"
