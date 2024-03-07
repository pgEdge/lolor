# contrib/lobj_replacement/Makefile

MODULES = lobj_replacement

EXTENSION = lobj_replacement
DATA = lobj_replacement--1.0.sql
PGFILEDESC = "lobj_replacement - drop in large-objects replacement for logical replication"

REGRESS = lobj_replacement

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/lobj_replacement
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
