export RADIUS ?= 250

DUCKDB_MK = v0.2.0
include .duckdb.mk/$(DUCKDB_MK)/duckdb.mk
.duckdb.mk/%/duckdb.mk:
	curl -sSfL --create-dirs -o $@ \
	  https://raw.githubusercontent.com/ltrgoddard/duckdb.mk/$*/duckdb.mk

curl = curl -sSf --retry 3 --retry-all-errors --create-dirs -A duckdb.mk-example -o $@

data/cb_2023_us_county_20m.zip:
	$(curl) https://www2.census.gov/geo/tiger/GENZ2023/shp/$(@F)

data/cb_2023_us_county_20m.shp: data/cb_2023_us_county_20m.zip
	unzip -oqDDd data $<

data/plumes.json:
	$(curl) 'https://api.carbonmapper.org/api/v1/catalog/plumes/annotated?limit=10000&bbox=-109.05&bbox=31.33&bbox=-103&bbox=37'

data/osm.json: queries/osm.overpassql
	$(curl) --data-urlencode data@$< https://overpass.kumi.systems/api/interpreter
