# contrib/lolor/Makefile

MODULE_big = lolor

EXTENSION = lolor
DATA = lolor--2.0.sql
PGFILEDESC = "lolor - large objects for logical replication"

OBJS = src/lolor.o

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
