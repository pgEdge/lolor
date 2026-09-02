/*-------------------------------------------------------------------------
 *
 * oldloutils.c
 *	  Routines to read and migrate from PostgreSQL native large object
 *	  storage (pg_catalog.pg_largeobject, pg_catalog.pg_largeobject_metadata).
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  contrib/lolor/src/oldloutils.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "access/detoast.h"
#include "access/genam.h"
#include "access/htup_details.h"
#include "access/sysattr.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/pg_largeobject.h"
#include "catalog/pg_largeobject_metadata.h"
#include "commands/comment.h"
#include "libpq/libpq-fs.h"
#include "miscadmin.h"
#include "utils/acl.h"
#include "utils/fmgroids.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif

#include "lolor.h"

static Relation oldlo_heap_r = NULL;
static Relation oldlo_index_r = NULL;

static void oldlo_getdatafield(Form_pg_largeobject tuple,
							   bytea **pdatafield,
							   int *plen,
							   bool *pfreeit);

/*
 * Open native pg_largeobject and its index, if not already done in current xact.
 */
void
oldlo_open_lo_relation(void)
{
	ResourceOwner currentOwner;

	if (oldlo_heap_r && oldlo_index_r)
		return;

	currentOwner = CurrentResourceOwner;
	CurrentResourceOwner = TopTransactionResourceOwner;

	if (oldlo_heap_r == NULL)
		oldlo_heap_r = table_open(LargeObjectRelationId, RowExclusiveLock);
	if (oldlo_index_r == NULL)
		oldlo_index_r = index_open(LargeObjectLOidPNIndexId, RowExclusiveLock);

	CurrentResourceOwner = currentOwner;
}

/*
 * Clean up native relation references at main transaction end.
 */
void
oldlo_close_lo_relation(bool isCommit)
{
	if (oldlo_heap_r || oldlo_index_r)
	{
		if (isCommit)
		{
			ResourceOwner currentOwner;

			currentOwner = CurrentResourceOwner;
			CurrentResourceOwner = TopTransactionResourceOwner;

			if (oldlo_index_r)
				index_close(oldlo_index_r, NoLock);
			if (oldlo_heap_r)
				table_close(oldlo_heap_r, NoLock);

			CurrentResourceOwner = currentOwner;
		}
		oldlo_heap_r = NULL;
		oldlo_index_r = NULL;
	}
}

/*
 * Check if a large object exists in native storage with the given snapshot.
 */
bool
oldlo_exists(Oid loid, Snapshot snapshot)
{
	Relation	pg_lo_meta;
	ScanKeyData skey[1];
	SysScanDesc sd;
	HeapTuple	tuple;
	bool		retval = false;

	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_metadata_oid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(loid));

	pg_lo_meta = table_open(LargeObjectMetadataRelationId,
							AccessShareLock);

	sd = systable_beginscan(pg_lo_meta,
							LargeObjectMetadataOidIndexId, true,
							snapshot, 1, skey);

	tuple = systable_getnext(sd);
	if (HeapTupleIsValid(tuple))
		retval = true;

	systable_endscan(sd);

	table_close(pg_lo_meta, AccessShareLock);

	return retval;
}

/*
 * Check access permissions on a native large object.
 */
AclResult
oldlo_aclcheck(Oid loid, Oid roleid, AclMode mode, Snapshot snapshot)
{
	return pg_largeobject_aclcheck_snapshot(loid, roleid, mode, snapshot);
}

/*
 * Check ownership of a native large object.
 */
bool
oldlo_ownercheck(Oid lobjId, Oid roleid)
{
	Relation	rel;
	ScanKeyData entry[1];
	SysScanDesc scan;
	HeapTuple	tuple;
	bool		isnull;
	Oid			ownerId;

	if (superuser_arg(roleid))
		return true;

	rel = table_open(LargeObjectMetadataRelationId, AccessShareLock);
	ScanKeyInit(&entry[0],
				Anum_pg_largeobject_metadata_oid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(lobjId));

	scan = systable_beginscan(rel,
							  LargeObjectMetadataOidIndexId, true,
							  NULL, 1, entry);

	tuple = systable_getnext(scan);
	if (!HeapTupleIsValid(tuple))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("large object metadata with OID %u does not exist", lobjId)));

	ownerId = DatumGetObjectId(heap_getattr(tuple,
											Anum_pg_largeobject_metadata_lomowner,
											RelationGetDescr(rel),
											&isnull));
	Assert(!isnull);

	systable_endscan(scan);
	table_close(rel, AccessShareLock);

	return has_privs_of_role(roleid, ownerId);
}

/*
 * Extract data field from a native pg_largeobject tuple, detoasting if needed.
 */
static void
oldlo_getdatafield(Form_pg_largeobject tuple,
				   bytea **pdatafield,
				   int *plen,
				   bool *pfreeit)
{
	bytea	   *datafield;
	int			len;
	bool		freeit;

	datafield = &(tuple->data);
	freeit = false;
	if (VARATT_IS_EXTENDED(datafield))
	{
		datafield = (bytea *)
			detoast_attr((struct varlena *) datafield);
		freeit = true;
	}
	len = VARSIZE(datafield) - VARHDRSZ;
	if (len < 0 || len > LOBLKSIZE)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("pg_largeobject entry for OID %u, page %d has invalid data field size %d",
						tuple->loid, tuple->pageno, len)));
	*pdatafield = datafield;
	*plen = len;
	*pfreeit = freeit;
}

/*
 * Determine size of a native large object.
 */
uint64
oldlo_getsize(LargeObjectDesc *obj_desc)
{
	uint64		lastbyte = 0;
	ScanKeyData skey[1];
	SysScanDesc sd;
	HeapTuple	tuple;

	Assert(obj_desc);

	oldlo_open_lo_relation();

	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_loid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(obj_desc->id));

	sd = systable_beginscan_ordered(oldlo_heap_r, oldlo_index_r,
									obj_desc->snapshot, 1, skey);

	tuple = systable_getnext_ordered(sd, BackwardScanDirection);
	if (HeapTupleIsValid(tuple))
	{
		Form_pg_largeobject data;
		bytea	   *datafield;
		int			len;
		bool		pfreeit;

		if (HeapTupleHasNulls(tuple))
			elog(ERROR, "null field found in pg_largeobject");
		data = (Form_pg_largeobject) GETSTRUCT(tuple);
		oldlo_getdatafield(data, &datafield, &len, &pfreeit);
		lastbyte = (uint64) data->pageno * LOBLKSIZE + len;
		if (pfreeit)
			pfree(datafield);
	}

	systable_endscan_ordered(sd);

	return lastbyte;
}

/*
 * Seek within a native large object.
 */
int64
oldlo_seek(LargeObjectDesc *obj_desc, int64 offset, int whence)
{
	int64		newoffset;

	Assert(obj_desc);

	switch (whence)
	{
		case SEEK_SET:
			newoffset = offset;
			break;
		case SEEK_CUR:
			newoffset = obj_desc->offset + offset;
			break;
		case SEEK_END:
			newoffset = oldlo_getsize(obj_desc) + offset;
			break;
		default:
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("invalid whence setting: %d", whence)));
			newoffset = 0;
			break;
	}

	if (newoffset < 0 || newoffset > MAX_LARGE_OBJECT_SIZE)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg_internal("invalid large object seek target: " INT64_FORMAT,
								 newoffset)));

	obj_desc->offset = newoffset;
	return newoffset;
}

/*
 * Return current offset within a native large object.
 */
int64
oldlo_tell(LargeObjectDesc *obj_desc)
{
	Assert(obj_desc);
	return obj_desc->offset;
}

/*
 * Read from a native large object.
 */
int
oldlo_read(LargeObjectDesc *obj_desc, char *buf, int nbytes)
{
	int			nread = 0;
	int64		n;
	int64		off;
	int			len;
	int32		pageno = (int32) (obj_desc->offset / LOBLKSIZE);
	uint64		pageoff;
	ScanKeyData skey[2];
	SysScanDesc sd;
	HeapTuple	tuple;

	Assert(obj_desc);
	Assert(buf != NULL);

	if ((obj_desc->flags & IFS_RDLOCK) == 0)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied for large object %u",
						obj_desc->id)));

	if (nbytes <= 0)
		return 0;

	oldlo_open_lo_relation();

	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_loid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(obj_desc->id));

	ScanKeyInit(&skey[1],
				Anum_pg_largeobject_pageno,
				BTGreaterEqualStrategyNumber, F_INT4GE,
				Int32GetDatum(pageno));

	sd = systable_beginscan_ordered(oldlo_heap_r, oldlo_index_r,
									obj_desc->snapshot, 2, skey);

	while ((tuple = systable_getnext_ordered(sd, ForwardScanDirection)) != NULL)
	{
		Form_pg_largeobject data;
		bytea	   *datafield;
		bool		pfreeit;

		if (HeapTupleHasNulls(tuple))
			elog(ERROR, "null field found in pg_largeobject");
		data = (Form_pg_largeobject) GETSTRUCT(tuple);

		pageoff = ((uint64) data->pageno) * LOBLKSIZE;
		if (pageoff > obj_desc->offset)
		{
			n = pageoff - obj_desc->offset;
			n = (n <= (nbytes - nread)) ? n : (nbytes - nread);
			MemSet(buf + nread, 0, n);
			nread += n;
			obj_desc->offset += n;
		}

		if (nread < nbytes)
		{
			Assert(obj_desc->offset >= pageoff);
			off = (int) (obj_desc->offset - pageoff);
			Assert(off >= 0 && off < LOBLKSIZE);

			oldlo_getdatafield(data, &datafield, &len, &pfreeit);
			if (len > off)
			{
				n = len - off;
				n = (n <= (nbytes - nread)) ? n : (nbytes - nread);
				Assert(n > 0 && n <= nbytes - nread && n <= len - off);
				memcpy(buf + nread, VARDATA(datafield) + off, n);
				nread += n;
				obj_desc->offset += n;
			}
			if (pfreeit)
				pfree(datafield);
		}

		if (nread >= nbytes)
			break;
	}

	systable_endscan_ordered(sd);

	return nread;
}

/*
 * Drop a native large object and its dependencies.
 */
int
oldlo_drop(Oid lobjId)
{
	ObjectAddress object;

	oldlo_close_lo_relation(false);

	object.classId = LargeObjectRelationId;
	object.objectId = lobjId;
	object.objectSubId = 0;
	performDeletion(&object, DROP_CASCADE, PERFORM_DELETION_SKIP_ORIGINAL);

	LargeObjectDrop(object.objectId);

	CommandCounterIncrement();

	return 1;
}

/*
 * Migrate a single large object on-the-fly from native storage to lolor storage.
 *
 * Copies metadata and data pages, records owner dependency on lolor relation,
 * preserves comments if present, and removes the native copy.
 */
bool
oldlo_migrate_one(Oid lobjId)
{
	Relation	native_meta;
	Relation	lolor_meta;
	Relation	native_data;
	Relation	lolor_data;
	ScanKeyData skey[1];
	SysScanDesc scan;
	HeapTuple	tuple;
	Oid			ownerId;
	Datum		aclDatum;
	bool		isNull;
	Datum		mvalues[Natts_pg_largeobject_metadata];
	bool		mnulls[Natts_pg_largeobject_metadata];
	HeapTuple	new_meta_tup;
	CatalogIndexState indstate;
	char	   *comment;

	oldlo_close_lo_relation(false);

	/*
	 * 1. Read metadata from native catalog.
	 */
	native_meta = table_open(LargeObjectMetadataRelationId, RowExclusiveLock);

	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_metadata_oid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(lobjId));

	scan = systable_beginscan(native_meta,
							  LargeObjectMetadataOidIndexId, true,
							  NULL, 1, skey);

	tuple = systable_getnext(scan);
	if (!HeapTupleIsValid(tuple))
	{
		systable_endscan(scan);
		table_close(native_meta, RowExclusiveLock);
		return false;
	}

	ownerId = ((Form_pg_largeobject_metadata) GETSTRUCT(tuple))->lomowner;
	aclDatum = heap_getattr(tuple,
							Anum_pg_largeobject_metadata_lomacl,
							RelationGetDescr(native_meta),
							&isNull);

	/*
	 * 2. Insert metadata into lolor.pg_largeobject_metadata.
	 */
	lolor_meta = table_open(get_LOLOR_LargeObjectMetadataRelationId(), RowExclusiveLock);

	memset(mvalues, 0, sizeof(mvalues));
	memset(mnulls, false, sizeof(mnulls));

	mvalues[Anum_pg_largeobject_metadata_oid - 1] = ObjectIdGetDatum(lobjId);
	mvalues[Anum_pg_largeobject_metadata_lomowner - 1] = ObjectIdGetDatum(ownerId);
	if (isNull)
	{
		mnulls[Anum_pg_largeobject_metadata_lomacl - 1] = true;
	}
	else
	{
		struct varlena *acl_copy = PG_DETOAST_DATUM_COPY(aclDatum);
		Acl		   *acl = (Acl *) acl_copy;
		int			nmembers;
		Oid		   *members;

		mvalues[Anum_pg_largeobject_metadata_lomacl - 1] = PointerGetDatum(acl_copy);
		nmembers = aclmembers(acl, &members);
		for (int i = 0; i < nmembers; i++)
			lolor_record_role_dependency(members[i]);
		if (members)
			pfree(members);
	}

	new_meta_tup = heap_form_tuple(RelationGetDescr(lolor_meta), mvalues, mnulls);
	CatalogTupleInsert(lolor_meta, new_meta_tup);
	heap_freetuple(new_meta_tup);

	if (!isNull)
		pfree(DatumGetPointer(mvalues[Anum_pg_largeobject_metadata_lomacl - 1]));

	systable_endscan(scan);
	table_close(native_meta, RowExclusiveLock);
	table_close(lolor_meta, RowExclusiveLock);

	/*
	 * 3. Copy all data pages from native pg_largeobject to lolor.pg_largeobject.
	 */
	native_data = table_open(LargeObjectRelationId, RowExclusiveLock);
	lolor_data = table_open(get_LOLOR_LargeObjectRelationId(), RowExclusiveLock);
	indstate = CatalogOpenIndexes(lolor_data);

	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_loid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(lobjId));

	scan = systable_beginscan(native_data,
							  LargeObjectLOidPNIndexId, true,
							  NULL, 1, skey);

	while (HeapTupleIsValid(tuple = systable_getnext(scan)))
	{
		Form_pg_largeobject olddata = (Form_pg_largeobject) GETSTRUCT(tuple);
		bytea	   *datafield;
		int			len;
		bool		pfreeit;
		Datum		dvalues[Natts_pg_largeobject];
		bool		dnulls[Natts_pg_largeobject];
		HeapTuple	new_data_tup;

		oldlo_getdatafield(olddata, &datafield, &len, &pfreeit);

		memset(dvalues, 0, sizeof(dvalues));
		memset(dnulls, false, sizeof(dnulls));

		dvalues[Anum_pg_largeobject_loid - 1] = ObjectIdGetDatum(olddata->loid);
		dvalues[Anum_pg_largeobject_pageno - 1] = Int32GetDatum(olddata->pageno);
		dvalues[Anum_pg_largeobject_data - 1] = PointerGetDatum(datafield);

		new_data_tup = heap_form_tuple(RelationGetDescr(lolor_data), dvalues, dnulls);
		CatalogTupleInsertWithInfo(lolor_data, new_data_tup, indstate);
		heap_freetuple(new_data_tup);

		if (pfreeit)
			pfree(datafield);
	}

	systable_endscan(scan);
	CatalogCloseIndexes(indstate);
	table_close(lolor_data, RowExclusiveLock);
	table_close(native_data, RowExclusiveLock);

	/*
	 * 4. Record owner dependency on lolor.pg_largeobject_metadata.
	 */
	lolor_record_role_dependency(ownerId);

	/*
	 * 5. Save comment if any, then drop native object via inv_drop().
	 */
	comment = GetComment(lobjId, LargeObjectRelationId, 0);

	inv_drop(lobjId);

	if (comment != NULL)
	{
		CreateComments(lobjId, LargeObjectRelationId, 0, comment);
		pfree(comment);
	}

	CommandCounterIncrement();

	return true;
}
