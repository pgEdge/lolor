/*-------------------------------------------------------------------------
 *
 * pg_lolor.h
 *	  large object logical replication
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  contrib/pg_lolor/pg_lolor.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_LOLOR_LARGEOBJECT_H
#define PG_LOLOR_LARGEOBJECT_H

#include "storage/large_object.h"
#include "utils/acl.h"

/*
 * The extension and the schema holding its tables cannot share a name:
 * PostgreSQL reserves the "pg_" prefix for system schemas, so the schema
 * drops the prefix.  Both are needed, because the cleanup trigger has to
 * recognise DROP EXTENSION by one and DROP SCHEMA by the other.
 */
#define EXTENSION_NAME					"pg_lolor"
#define EXTENSION_SCHEMA				"lolor"
#define PG_LOLOR_LARGEOBJECT_CATALOG		"pg_largeobject"
#define PG_LOLOR_LARGEOBJECT_PKEY			"pg_largeobject_pkey"
#define PG_LOLOR_LARGEOBJECT_METADATA		"pg_largeobject_metadata"
#define PG_LOLOR_LARGEOBJECT_METADATA_PKEY	"pg_largeobject_metadata_pkey"
#define PG_LOLOR_LARGEOBJECT_DESCRIPTION	"pg_largeobject_description"
#define PG_LOLOR_LARGEOBJECT_DESCRIPTION_PKEY "pg_largeobject_description_pkey"

/*
 * Layout of a pg_lolor-assigned large object OID: the low PG_LOLOR_NODEID_BITS hold
 * pg_lolor.node and the rest hold the generated OID, so that concurrent creation
 * on different nodes cannot collide.  The GUC bound is derived from the
 * encoding rather than written out separately, since the two must agree.
 * Changing these changes the on-disk OID encoding.
 */
#define PG_LOLOR_NODEID_BITS				4
#define PG_LOLOR_OID_BITS					28
#define PG_LOLOR_MAX_NODE_ID				((1 << PG_LOLOR_NODEID_BITS) - 1)

/* pg_lolor.c */
extern int32 pg_lolor_node_id;
extern Oid	get_PG_LOLOR_LargeObjectRelationId(void);
extern Oid	get_PG_LOLOR_LargeObjectLOidPNIndexId(void);
extern Oid	get_PG_LOLOR_LargeObjectMetadataRelationId(void);
extern Oid	get_PG_LOLOR_LargeObjectMetadataOidIndexId(void);
extern Oid	get_PG_LOLOR_LargeObjectDescriptionRelationId(void);
extern Oid	get_PG_LOLOR_LargeObjectDescriptionIndexId(void);
extern Oid	get_PG_LOLOR_LargeObjectDescriptionRelationIdIfExists(void);

/* pg_lolor_largeobject.c */
extern Oid	PG_LOLOR_LargeObjectCreate(Oid loid);
extern void PG_LOLOR_LargeObjectDrop(Oid loid);
extern bool PG_LOLOR_LargeObjectExists(Oid loid);
extern Oid	PG_LOLOR_GetNewOidWithIndex(Relation relation, Oid indexId,
										AttrNumber oidcolumn);

/* inversion stuff in pg_lolor_inv_api.c */
extern void pg_lolor_close_lo_relation(bool isCommit);
extern Oid	pg_lolor_inv_create(Oid lobjId);
extern LargeObjectDesc *pg_lolor_inv_open(Oid lobjId, int flags, MemoryContext mcxt);
extern void pg_lolor_inv_close(LargeObjectDesc *obj_desc);
extern int	pg_lolor_inv_drop(Oid lobjId);
extern int64 pg_lolor_inv_seek(LargeObjectDesc *obj_desc, int64 offset, int whence);
extern int64 pg_lolor_inv_tell(LargeObjectDesc *obj_desc);
extern int	pg_lolor_inv_read(LargeObjectDesc *obj_desc, char *buf, int nbytes);
extern int	pg_lolor_inv_write(LargeObjectDesc *obj_desc, const char *buf, int nbytes);
extern void pg_lolor_inv_truncate(LargeObjectDesc *obj_desc, int64 len);

/* pg_lolor_fsstubs.c */

#ifndef repalloc0_array
#define repalloc0(pointer, oldsize, size) \
	memset((char *) repalloc(pointer, size) + oldsize, 0, (size - oldsize))

#define repalloc0_array(pointer, type, oldcount, count) \
	((type *) repalloc0(pointer, sizeof(type) * (oldcount), sizeof(type) * (count)))
#endif

/*
 * Cleanup LOs at xact commit/abort
 */
extern void AtEOXact_PG_LOLOR_LargeObject(bool isCommit);
extern void AtEOSubXact_PG_LOLOR_LargeObject(bool isCommit, SubTransactionId mySubid,
											 SubTransactionId parentSubid);
AclResult	pg_lolor_largeobject_aclcheck_snapshot(Oid lobj_oid, Oid roleid, AclMode mode,
												   Snapshot snapshot);

extern Datum pg_lolor_lo_create(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_import(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_export(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_import_with_oid(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_open(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_close(PG_FUNCTION_ARGS);
extern Datum pg_lolor_loread(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lowrite(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_lseek(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_creat(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_tell(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_unlink(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_truncate(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_lseek64(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_tell64(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_truncate64(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_from_bytea(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_get(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_get_fragment(PG_FUNCTION_ARGS);
extern Datum pg_lolor_lo_put(PG_FUNCTION_ARGS);

/* pg_lolor_migrate.c */
extern Datum pg_lolor_migrate_storage(PG_FUNCTION_ARGS);

#endif							/* PG_LOLOR_LARGEOBJECT_H */
