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
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/sysattr.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/pg_largeobject.h"
#include "catalog/pg_largeobject_metadata.h"
#include "commands/comment.h"
#include "commands/vacuum.h"
#include "executor/tuptable.h"
#include "libpq/libpq-fs.h"
#include "miscadmin.h"
#include "nodes/lockoptions.h"
#include "storage/bufmgr.h"
#include "utils/acl.h"
#include "utils/fmgroids.h"
#include "utils/hsearch.h"
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
	oldlo_close_lo_relation(false);

	return inv_drop(lobjId);
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

		CHECK_FOR_INTERRUPTS();

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

/*
 * Helper: collect OIDs from physical end of pg_catalog.pg_largeobject
 * backwards to the beginning.
 */
static List *
lolor_collect_oids_reverse(int max_count)
{
	Relation	lo_rel;
	BlockNumber nblocks;
	BlockNumber blk;
	List	   *oid_list = NIL;
	HTAB	   *seen_oids;
	HASHCTL		ctl;
	Snapshot	snapshot;

	memset(&ctl, 0, sizeof(ctl));
	ctl.keysize = sizeof(Oid);
	ctl.entrysize = sizeof(Oid);
	ctl.hcxt = CurrentMemoryContext;
	seen_oids = hash_create("lolor_migrate_reverse_oids",
							1024,
							&ctl,
							HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	snapshot = GetActiveSnapshot();

	lo_rel = table_open(LargeObjectRelationId, AccessShareLock);
	nblocks = RelationGetNumberOfBlocks(lo_rel);

	/* Scan blocks backwards from the last block down to 0 */
	for (blk = (nblocks > 0 ? nblocks - 1 : InvalidBlockNumber); blk != InvalidBlockNumber; blk--)
	{
		Buffer		buf;
		Page		page;
		OffsetNumber maxoff;
		OffsetNumber off;

		CHECK_FOR_INTERRUPTS();

		buf = ReadBuffer(lo_rel, blk);
		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);

		if (!PageIsNew(page))
		{
			maxoff = PageGetMaxOffsetNumber(page);
			for (off = maxoff; off >= FirstOffsetNumber; off = OffsetNumberPrev(off))
			{
				ItemId		itemid = PageGetItemId(page, off);

				if (ItemIdIsNormal(itemid))
				{
					HeapTupleHeader tuphdr = (HeapTupleHeader) PageGetItem(page, itemid);
					HeapTupleData tup;

					tup.t_len = ItemIdGetLength(itemid);
					ItemPointerSet(&(tup.t_self), blk, off);
					tup.t_tableOid = LargeObjectRelationId;
					tup.t_data = tuphdr;

					if (HeapTupleSatisfiesVisibility(&tup, snapshot, buf))
					{
						bool		isnull;
						Datum		d;

						d = heap_getattr(&tup, Anum_pg_largeobject_loid,
										 RelationGetDescr(lo_rel), &isnull);
						if (!isnull)
						{
							Oid			loid = DatumGetObjectId(d);
							bool		found;

							hash_search(seen_oids, &loid, HASH_ENTER, &found);
							if (!found)
							{
								oid_list = lappend_oid(oid_list, loid);
								if (max_count > 0 && list_length(oid_list) >= max_count)
								{
									UnlockReleaseBuffer(buf);
									goto done_scan;
								}
							}
						}
					}
				}
			}
		}

		UnlockReleaseBuffer(buf);

		if (blk == 0)
			break;
	}

	/*
	 * Also sweep pg_largeobject_metadata for any empty (0-page) large objects
	 * that have no rows in pg_largeobject.
	 */
	if (max_count <= 0 || list_length(oid_list) < max_count)
	{
		Relation	meta_rel;
		SysScanDesc mscan;
		HeapTuple	mtup;

		meta_rel = table_open(LargeObjectMetadataRelationId, AccessShareLock);
		mscan = systable_beginscan(meta_rel, LargeObjectMetadataOidIndexId, true,
								   NULL, 0, NULL);
		while (HeapTupleIsValid(mtup = systable_getnext(mscan)))
		{
			Form_pg_largeobject_metadata form = (Form_pg_largeobject_metadata) GETSTRUCT(mtup);
			Oid			loid = form->oid;
			bool		found;

			CHECK_FOR_INTERRUPTS();

			hash_search(seen_oids, &loid, HASH_ENTER, &found);
			if (!found)
			{
				oid_list = lappend_oid(oid_list, loid);
				if (max_count > 0 && list_length(oid_list) >= max_count)
					break;
			}
		}
		systable_endscan(mscan);
		table_close(meta_rel, AccessShareLock);
	}

done_scan:
	hash_destroy(seen_oids);
	table_close(lo_rel, AccessShareLock);

	return oid_list;
}


/*
 * Helper: collect OIDs in forward catalog order from
 * pg_catalog.pg_largeobject_metadata.
 */
static List *
lolor_collect_oids_forward(int max_count)
{
	Relation	meta_rel;
	SysScanDesc scan;
	HeapTuple	tup;
	List	   *oid_list = NIL;

	meta_rel = table_open(LargeObjectMetadataRelationId, AccessShareLock);
	scan = systable_beginscan(meta_rel, LargeObjectMetadataOidIndexId, true,
							  NULL, 0, NULL);

	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_largeobject_metadata form = (Form_pg_largeobject_metadata) GETSTRUCT(tup);
		Oid			loid = form->oid;

		oid_list = lappend_oid(oid_list, loid);
		if (max_count > 0 && list_length(oid_list) >= max_count)
			break;
	}

	systable_endscan(scan);
	table_close(meta_rel, AccessShareLock);

	return oid_list;
}

/*
 * lolor_migrate: SQL function to batch-migrate native large objects to lolor.
 *
 * Parameters:
 *   arg0: n (int4, default NULL = all)
 *   arg1: skip_locked (bool, default true)
 *   arg2: strict_from_end_to_start (bool, default false)
 *   arg3: run_vacuum (bool, default false)
 *
 * Returns: int64 (number of objects migrated)
 */
PG_FUNCTION_INFO_V1(lolor_migrate);

Datum
lolor_migrate(PG_FUNCTION_ARGS)
{
	int			max_count = -1;
	bool		skip_locked = true;
	bool		strict_from_end_to_start = false;
	bool		run_vacuum = false;
	int64		migrated_count = 0;
	List	   *candidate_oids = NIL;
	ListCell   *lc;

	/* Only superusers can migrate large objects */
	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("lolor.migrate() requires superuser privileges")));

	if (get_LOLOR_LargeObjectMetadataRelationId() == InvalidOid ||
		get_LOLOR_LargeObjectRelationId() == InvalidOid)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("lolor extension tables are not accessible")));

	if (PG_NARGS() > 0 && !PG_ARGISNULL(0))
	{
		max_count = PG_GETARG_INT32(0);
		if (max_count < 0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("lolor.migrate() batch size must not be negative")));
	}
	if (PG_NARGS() > 1 && !PG_ARGISNULL(1))
		skip_locked = PG_GETARG_BOOL(1);
	if (PG_NARGS() > 2 && !PG_ARGISNULL(2))
		strict_from_end_to_start = PG_GETARG_BOOL(2);
	if (PG_NARGS() > 3 && !PG_ARGISNULL(3))
		run_vacuum = PG_GETARG_BOOL(3);

	if (max_count == 0)
		PG_RETURN_INT64(0);

	while (true)
	{
		int			batch_limit;
		int64		batch_migrated = 0;

		CHECK_FOR_INTERRUPTS();

		if (max_count > 0)
			batch_limit = max_count - (int) migrated_count;
		else
			batch_limit = 10000;

		/* 1. Collect candidate OIDs */
		if (strict_from_end_to_start)
			candidate_oids = lolor_collect_oids_reverse(batch_limit);
		else
			candidate_oids = lolor_collect_oids_forward(batch_limit);

		if (candidate_oids == NIL)
			break;

		/* 2. Lock and migrate each candidate */
		foreach(lc, candidate_oids)
		{
			Oid			loid = lfirst_oid(lc);
			Relation	native_meta;
			ScanKeyData skey[1];
			SysScanDesc scan;
			HeapTuple	tuple;
			ItemPointerData ctid;
			TM_Result	tm_result;
			TM_FailureData tmfd;
			TupleTableSlot *slot;
			LockWaitPolicy wait_policy = skip_locked ? LockWaitSkip : LockWaitBlock;

			CHECK_FOR_INTERRUPTS();

			native_meta = table_open(LargeObjectMetadataRelationId, RowExclusiveLock);

			ScanKeyInit(&skey[0],
						Anum_pg_largeobject_metadata_oid,
						BTEqualStrategyNumber, F_OIDEQ,
						ObjectIdGetDatum(loid));

			scan = systable_beginscan(native_meta, LargeObjectMetadataOidIndexId, true,
									  NULL, 1, skey);
			tuple = systable_getnext(scan);
			if (!HeapTupleIsValid(tuple))
			{
				systable_endscan(scan);
				table_close(native_meta, RowExclusiveLock);
				continue;
			}

			ctid = tuple->t_self;
			systable_endscan(scan);

			slot = table_slot_create(native_meta, NULL);
			tm_result = table_tuple_lock(native_meta, &ctid,
										 GetActiveSnapshot(), slot,
										 GetCurrentCommandId(false),
										 LockTupleExclusive,
										 wait_policy, 0, &tmfd);
			ExecDropSingleTupleTableSlot(slot);
			table_close(native_meta, RowExclusiveLock);

			if (tm_result != TM_Ok)
				continue;

			if (oldlo_migrate_one(loid))
			{
				migrated_count++;
				batch_migrated++;
				if (max_count > 0 && migrated_count >= max_count)
					break;
			}
		}

		list_free(candidate_oids);

		/* Stop if no progress was made in this batch (all locked/skipped) */
		if (batch_migrated == 0)
			break;

		if (max_count > 0 && migrated_count >= max_count)
			break;
	}

	/* 3. Handle run_vacuum if requested */
	if (run_vacuum && migrated_count > 0)
	{
		VacuumParams params;
		BufferAccessStrategy bstrategy;

		memset(&params, 0, sizeof(params));
		params.options = VACOPT_VACUUM;
		params.truncate = VACOPTVALUE_ENABLED;
		params.index_cleanup = VACOPTVALUE_AUTO;
		params.freeze_min_age = -1;
		params.freeze_table_age = -1;
		params.multixact_freeze_min_age = -1;
		params.multixact_freeze_table_age = -1;
#if PG_VERSION_NUM >= 180000
		params.log_vacuum_min_duration = -1;
#else
		params.log_min_duration = -1;
#endif

		bstrategy = GetAccessStrategy(BAS_VACUUM);

		{
			Relation vac_lo = table_open(LargeObjectRelationId, ShareUpdateExclusiveLock);
			table_relation_vacuum(vac_lo, &params, bstrategy);
			table_close(vac_lo, ShareUpdateExclusiveLock);
		}

		{
			Relation vac_meta = table_open(LargeObjectMetadataRelationId, ShareUpdateExclusiveLock);
			table_relation_vacuum(vac_meta, &params, bstrategy);
			table_close(vac_meta, ShareUpdateExclusiveLock);
		}

		FreeAccessStrategy(bstrategy);
	}


	PG_RETURN_INT64(migrated_count);
}

