EXTENSION = pg_stat_delta
DATA = sql/pg_stat_delta--0.1.0.sql
FUNCTION_SQL = sql/pg_stat_database_delta.sql \
               sql/pg_stat_user_tables_delta.sql \
               sql/pg_stat_user_indexes_delta.sql \
               sql/pg_statio_user_tables_delta.sql \
               sql/pg_statio_user_indexes_delta.sql \
               sql/pg_stat_wal_delta.sql \
               sql/pg_stat_io_delta.sql \
               sql/pg_stat_user_functions_delta.sql
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Keep one complete, reviewable installation script for version 0.1.0.
# It is tracked, so make clean must not remove it.
all install: $(DATA)

sql/pg_stat_delta--0.1.0.sql: $(FUNCTION_SQL)
	cat $^ > $@
