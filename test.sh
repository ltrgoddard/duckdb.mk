#!/usr/bin/env bash
# end-to-end tests for duckdb.mk: ./test.sh [suite ...] runs test/<suite>.sh, or every suite,
# in parallel, each in a fresh project; set DUCKDB and MAKE to test other executables
cd "$(dirname "$0")" && here=$PWD tmp=$(mktemp -d) start=$SECONDS pids=()
export DUCKDB=${DUCKDB:-duckdb} MAKE=${MAKE:-make} LC_ALL=C
mkdir "$tmp/www"; python3 test/server.py "$tmp/www" > "$tmp/requests" 2>&1 & server=$!
trap 'kill $server; wait $server 2>/dev/null; rm -rf "$tmp"' EXIT
until read -r HTTP S3 < "$tmp/requests"; do kill -0 $server || exit; sleep 0.1; done 2>/dev/null
[[ $($MAKE --version) == *" 3."* ]] && nap=1 || nap=0 # make 3.81 has one-second mtime resolution

# t <label> <want> [make args]: want lists the targets that should be made, or is !fragment of an expected error
t() {
  local label=$1 want=$2 out got; shift 2
  out=$($MAKE DUCKDB="$DUCKDB" "$@" 2>&1); sleep $nap
  got=$(grep -oE '^(build|test)/[^:]+' <<<"$out" | sort | xargs)
  [[ $want == !* ]] || want=$(xargs -n1 <<<"$want" | sort | xargs)
  if [[ $want == !* && $out == *"${want#!}"* || $want != !* && $got == "$want" ]]; then echo "ok   $label"
  else echo "FAIL $label: want [$want] got [$got]"; sed 's/^/     /' <<<"$out"; fi
}

# is <label> <got> <want>: compare two strings, showing lines wanted (<) and got (>) if they differ
is() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"
  else echo "FAIL $1"; diff <(echo "$3") <(echo "$2") | grep '^[<>]' | head -20 | sed 's/^/     /'; fi
}

# deps <target>: the prerequisites the plan gives a target but its own file, sorted
deps() {
  $MAKE -s DUCKDB="$DUCKDB" build/plan.mk >/dev/null; sleep $nap; sed -n "s|^$1: ||p" build/plan.mk | grep -vE "^(models|tests)/" | sort | xargs
}

# q <sql>: run a query in the project and print the rows
q() {
  $DUCKDB -init /dev/null -bail -list -noheader -c "$1" 2>&1
}

# requests: the "<method> <path> <status>" requests for this suite's files since the last call
requests() {
  local seen=$(cat "$tmp/$suite.seen" 2>/dev/null || echo 1) n=$(($(wc -l < "$tmp/requests")))
  sed -n "$((seen + 1)),${n}p" "$tmp/requests" | sed -n "s# /$suite/# /#p"; echo "$n" > "$tmp/$suite.seen"
}

suites=("$@") && [[ $suites ]] || suites=($(ls test/*.sh | xargs -n1 basename | sed 's/\.sh$//'))
for suite in "${suites[@]}"; do
  mkdir "$tmp/$suite" "$tmp/www/$suite" && (
    cd "$tmp/$suite" && cp "$here/duckdb.mk" . && echo "include duckdb.mk" > Makefile
    www=$tmp/www/$suite url=http://127.0.0.1:$HTTP/$suite s=$SECONDS
    source "$here/test/$suite.sh" || echo "FAIL $suite: stopped with status $?"
    echo "---- $suite: $((SECONDS - s))s"
  ) > "$tmp/$suite.log" 2>&1 & pids+=($!)
done
wait "${pids[@]}"

for suite in "${suites[@]}"; do cat "$tmp/$suite.log"; done | tee "$tmp/all"
fails=$(grep -c '^FAIL' "$tmp/all")
echo "$(grep -c '^ok' "$tmp/all") passed, $fails failed in $((SECONDS - start))s"
exit $((fails > 0))
