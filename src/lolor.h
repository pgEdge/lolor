/*-------------------------------------------------------------------------
 *
 * lolor.h
 *	  Large objects for logical replication.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef LOLOR_H
#define LOLOR_H

#include "postgres.h"

#include "catalog/pg_largeobject.h"

/*
 * lolor relies on a patched server that provides LargeObjectNewOid_hook and
 * that logically logs the large object catalogs once they have a replica
 * identity.  The patch defines this macro, so fail early and clearly when
 * building against an unpatched server.
 */
#ifndef LARGEOBJECT_NEWOID_HOOK
#error "lolor requires a PostgreSQL server patched with the lolor core patch (see patches/)"
#endif

/*
 * Layout of the OIDs generated for new large objects:
 *
 *		[ counter : LOLOR_COUNTER_BITS ][ node id : LOLOR_NODE_ID_BITS ]
 *
 * The node id occupies the low bits, so two nodes with different lolor.node
 * values can never generate the same OID, whatever their counters do.
 */
#define LOLOR_NODE_ID_BITS		4
#define LOLOR_COUNTER_BITS		28
#define LOLOR_MAX_NODE_ID		((1 << LOLOR_NODE_ID_BITS) - 1)

StaticAssertDecl(LOLOR_NODE_ID_BITS + LOLOR_COUNTER_BITS == 32,
				 "lolor OIDs must use exactly the 32 bits of an Oid");

/* value of the lolor.node GUC; 0 means "not set" */
extern int	lolor_node_id;

#endif							/* LOLOR_H */
