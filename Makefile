# contrib/lolor/Makefile

MODULE_big = lolor

EXTENSION = lolor
DATA = lolor--1.0.sql \
	   lolor--1.0--1.2.1.sql lolor--1.2.1--1.2.2.sql
PGFILEDESC = "lolor - drop in large objects replacement for logical replication"

OBJS = src/lolor.o src/lolor_fsstubs.o src/lolor_inv_api.o src/lolor_largeobject.o

REGRESS = lolor
TAP_TESTS = 1

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/lolor
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
