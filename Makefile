# for work on duckdb.mk itself, not for a project that uses it:
#   make test [S="suite ..."]     the end-to-end tests
#   make bench [REFS="ref ..."]   the working copy timed against earlier versions
#   make release V=v1.2.3         name V in the docs, commit, tag and push
pins := README.md docs/REFERENCE.md docs/SKILL.md
bare := env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL

test: ; @$(bare) test/run $(S)
bench: ; @$(bare) test/bench $(REFS)
release:
	@test -n "$(V)" || { echo "give the version: make release V=v1.2.3"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "commit first"; exit 1; }
	sed -i.bak -E 's/(DUCKDB_MK = |install duckdb.mk )v[0-9.]+/\1$(V)/' $(pins)
	rm $(pins:=.bak)
	git commit -qam "$(V)" && git tag $(V) && git push origin main $(V)
.PHONY: test bench release
