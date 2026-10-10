# contrib/lolor/Makefile

MODULE_big = lolor

EXTENSION = lolor
DATA = lolor--1.0.sql \
	   lolor--1.0--1.2.1.sql lolor--1.2.1--1.2.2.sql \
	   lolor--1.2.2--1.2.3.sql lolor--1.2.3--1.3.0.sql
PGFILEDESC = "lolor - drop in large objects replacement for logical replication"

OBJS = src/lolor.o src/lolor_fsstubs.o src/lolor_inv_api.o src/lolor_largeobject.o

REGRESS = lolor
# The drop guard is an object_access_hook, so lolor has to be preloaded and the
# regression suite can only run against a server that preloads it.  Run it in a
# temporary instance configured that way instead of against whatever server
# pg_config points at; this also keeps the suite's cluster-global test roles out
# of any shared server.
REGRESS_OPTS = --temp-instance=./tmp_check --temp-config=regress.conf
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
