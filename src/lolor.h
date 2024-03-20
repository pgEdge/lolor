/*-------------------------------------------------------------------------
 *
 * lolor.h
 *	  large object logical replication
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2023, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef LOLOR_LARGEOBJECT_H
#define LOLOR_LARGEOBJECT_H

#include "storage/large_object.h"
#include "utils/acl.h"

#define EXTENSION_NAME					"lolor"
#define LOLOR_LARGEOBJECT_CATALOG		"pg_largeobject"
#define LOLOR_LARGEOBJECT_PKEY			"pg_largeobject_pkey"
#define LOLOR_LARGEOBJECT_METADATA		"pg_largeobject_metadata"
#define LOLOR_LARGEOBJECT_METADATA_PKEY	"pg_largeobject_metadata_pkey"

/* lolor.c */
extern int32 lolor_node_id;
extern Oid  LOLOR_LargeObjectRelationId;
extern Oid	LOLOR_LargeObjectLOidPNIndexId;
extern Oid	LOLOR_LargeObjectMetadataRelationId;
extern Oid	LOLOR_LargeObjectMetadataOidIndexId;

extern Oid get_lobj_table_oid(const char *table);

/* lolor_largeobject.c */
extern Oid	LOLOR_LargeObjectCreate(Oid loid);
extern void LOLOR_LargeObjectDrop(Oid loid);
extern bool LOLOR_LargeObjectExists(Oid loid);
extern Oid LOLOR_GetNewOidWithIndex(Relation relation, Oid indexId,
									AttrNumber oidcolumn);

/* inversion stuff in lolor_inv_api.c */
extern void lolor_close_lo_relation(bool isCommit);
extern Oid	lolor_inv_create(Oid lobjId);
extern LargeObjectDesc *lolor_inv_open(Oid lobjId, int flags, MemoryContext mcxt);
extern void lolor_inv_close(LargeObjectDesc *obj_desc);
extern int	lolor_inv_drop(Oid lobjId);
extern int64 lolor_inv_seek(LargeObjectDesc *obj_desc, int64 offset, int whence);
extern int64 lolor_inv_tell(LargeObjectDesc *obj_desc);
extern int	lolor_inv_read(LargeObjectDesc *obj_desc, char *buf, int nbytes);
extern int	lolor_inv_write(LargeObjectDesc *obj_desc, const char *buf, int nbytes);
extern void lolor_inv_truncate(LargeObjectDesc *obj_desc, int64 len);

/* lolor_fsstubs.c */

/*
 * Cleanup LOs at xact commit/abort
 */
extern void AtEOXact_LOLOR_LargeObject(bool isCommit);
extern void AtEOSubXact_LOLOR_LargeObject(bool isCommit, SubTransactionId mySubid,
									SubTransactionId parentSubid);
AclResult lolor_largeobject_aclcheck_snapshot(Oid lobj_oid, Oid roleid, AclMode mode,
								 Snapshot snapshot);

extern Datum lolor_lo_create(PG_FUNCTION_ARGS);
extern Datum lolor_lo_import(PG_FUNCTION_ARGS);
extern Datum lolor_lo_export(PG_FUNCTION_ARGS);
extern Datum lolor_lo_import_with_oid(PG_FUNCTION_ARGS);
extern Datum lolor_lo_open(PG_FUNCTION_ARGS);
extern Datum lolor_lo_close(PG_FUNCTION_ARGS);
extern Datum lolor_loread(PG_FUNCTION_ARGS);
extern Datum lolor_lowrite(PG_FUNCTION_ARGS);
extern Datum lolor_lo_lseek(PG_FUNCTION_ARGS);
extern Datum lolor_lo_creat(PG_FUNCTION_ARGS);
extern Datum lolor_lo_tell(PG_FUNCTION_ARGS);
extern Datum lolor_lo_unlink(PG_FUNCTION_ARGS);
extern Datum lolor_lo_truncate(PG_FUNCTION_ARGS);
extern Datum lolor_lo_lseek64(PG_FUNCTION_ARGS);
extern Datum lolor_lo_tell64(PG_FUNCTION_ARGS);
extern Datum lolor_lo_truncate64(PG_FUNCTION_ARGS);
extern Datum lolor_lo_from_bytea(PG_FUNCTION_ARGS);
extern Datum lolor_lo_get(PG_FUNCTION_ARGS);
extern Datum lolor_lo_get_fragment(PG_FUNCTION_ARGS);
extern Datum lolor_lo_put(PG_FUNCTION_ARGS);

#endif							/* LOLOR_LARGEOBJECT_H */
