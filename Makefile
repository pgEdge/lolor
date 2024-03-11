# contrib/lolor/Makefile

MODULES = lolor

EXTENSION = lolor
DATA = lolor--1.0.sql
PGFILEDESC = "lolor - drop in large objects replacement for logical replication"

REGRESS = lolor

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
