EXTENSION = pg_stat_delta
DATA = sql/pg_stat_delta--0.1.0.sql
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
