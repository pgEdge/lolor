# contrib/pg_lolor/Makefile

MODULE_big = pg_lolor
OBJS = \
	$(WIN32RES) \
	pg_lolor.o \
	pg_lolor_fsstubs.o \
	pg_lolor_inv_api.o \
	pg_lolor_largeobject.o \
	pg_lolor_migrate.o

EXTENSION = pg_lolor
DATA = pg_lolor--1.0.sql
PGFILEDESC = "pg_lolor - large objects stored in regular tables"

REGRESS = pg_lolor
TAP_TESTS = 1

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_lolor
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
