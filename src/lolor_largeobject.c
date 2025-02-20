/*-------------------------------------------------------------------------
 *
 * lolor_largeobject.c
 *	  routines to support manipulation of the pg_largeobject relation
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  contrib/lolor/src/lolor_largeobject.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/htup_details.h"
#include "access/sysattr.h"
#include "access/table.h"
#include "catalog/catalog.h"
#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/pg_largeobject.h"
#include "catalog/pg_largeobject_metadata.h"
#include "miscadmin.h"
#include "utils/acl.h"
#include "utils/fmgroids.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#include "lolor.h"

/*
 * Parameters to determine when to emit a log message in
 * LOLOR_GetNewOidWithIndex()
 */
#define GETNEWOID_LOG_THRESHOLD 1000000
#define GETNEWOID_LOG_MAX_INTERVAL 128000000

/* Parameters to determine new unique Oid. */
#define MAX_NODEID_BITS 4
#define MAX_OID_BITS 28

/*
 * Create a large object having the given LO identifier.
 *
 * We create a new large object by inserting an entry into
 * pg_largeobject_metadata without any data pages, so that the object
 * will appear to exist with size 0.
 */
Oid
LOLOR_LargeObjectCreate(Oid loid)
{
	Relation	pg_lo_meta;
	HeapTuple	ntup;
	Oid			loid_new;
	Datum		values[Natts_pg_largeobject_metadata];
	bool		nulls[Natts_pg_largeobject_metadata];

	pg_lo_meta = table_open(LOLOR_LargeObjectMetadataRelationId,
							RowExclusiveLock);

	/*
	 * Insert metadata of the largeobject
	 */
	memset(values, 0, sizeof(values));
	memset(nulls, false, sizeof(nulls));

	if (OidIsValid(loid))
		loid_new = loid;
	else
		loid_new = LOLOR_GetNewOidWithIndex(pg_lo_meta,
									  LOLOR_LargeObjectMetadataOidIndexId,
									  Anum_pg_largeobject_metadata_oid);

	values[Anum_pg_largeobject_metadata_oid - 1] = ObjectIdGetDatum(loid_new);
	values[Anum_pg_largeobject_metadata_lomowner - 1]
		= ObjectIdGetDatum(GetUserId());
	nulls[Anum_pg_largeobject_metadata_lomacl - 1] = true;

	ntup = heap_form_tuple(RelationGetDescr(pg_lo_meta),
						   values, nulls);

	CatalogTupleInsert(pg_lo_meta, ntup);

	heap_freetuple(ntup);

	table_close(pg_lo_meta, RowExclusiveLock);

	return loid_new;
}

/*
 * Drop a large object having the given LO identifier.  Both the data pages
 * and metadata must be dropped.
 */
void
LOLOR_LargeObjectDrop(Oid loid)
{
	Relation	pg_lo_meta;
	Relation	pg_largeobject;
	ScanKeyData skey[1];
	SysScanDesc scan;
	HeapTuple	tuple;

	pg_lo_meta = table_open(LOLOR_LargeObjectMetadataRelationId,
							RowExclusiveLock);

	pg_largeobject = table_open(LOLOR_LargeObjectRelationId,
								RowExclusiveLock);

	/*
	 * Delete an entry from pg_largeobject_metadata
	 */
	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_metadata_oid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(loid));

	scan = systable_beginscan(pg_lo_meta,
							  LOLOR_LargeObjectMetadataOidIndexId, true,
							  NULL, 1, skey);

	tuple = systable_getnext(scan);
	if (!HeapTupleIsValid(tuple))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("large object %u does not exist", loid)));

	CatalogTupleDelete(pg_lo_meta, &tuple->t_self);

	systable_endscan(scan);

	/*
	 * Delete all the associated entries from pg_largeobject
	 */
	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_loid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(loid));

	scan = systable_beginscan(pg_largeobject,
							  LOLOR_LargeObjectLOidPNIndexId, true,
							  NULL, 1, skey);
	while (HeapTupleIsValid(tuple = systable_getnext(scan)))
	{
		CatalogTupleDelete(pg_largeobject, &tuple->t_self);
	}

	systable_endscan(scan);

	table_close(pg_largeobject, RowExclusiveLock);

	table_close(pg_lo_meta, RowExclusiveLock);
}

/*
 * LOLOR_LargeObjectExists
 *
 * We don't use the system cache for large object metadata, for fear of
 * using too much local memory.
 *
 * This function always scans the system catalog using an up-to-date snapshot,
 * so it should not be used when a large object is opened in read-only mode
 * (because large objects opened in read only mode are supposed to be viewed
 * relative to the caller's snapshot, whereas in read-write mode they are
 * relative to a current snapshot).
 */
bool
LOLOR_LargeObjectExists(Oid loid)
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

	pg_lo_meta = table_open(LOLOR_LargeObjectMetadataRelationId,
							AccessShareLock);

	sd = systable_beginscan(pg_lo_meta,
							LOLOR_LargeObjectMetadataOidIndexId, true,
							NULL, 1, skey);

	tuple = systable_getnext(sd);
	if (HeapTupleIsValid(tuple))
		retval = true;

	systable_endscan(sd);

	table_close(pg_lo_meta, AccessShareLock);

	return retval;
}

/*
 * LOLOR_GetNewOidWithIndex
 *		Generate a new OID that is unique within the given relation.
 *
 * The lower 4 bits contains the lolor_node_id. The 2^28 bits consist of Oid
 * returned from GetNewObjectId and adjusted to remain within the range.
 *
 * See comments for GetNewOidWithIndex() for more details.
 */
Oid
LOLOR_GetNewOidWithIndex(Relation relation, Oid indexId, AttrNumber oidcolumn)
{
	Oid			newOid;
	SysScanDesc scan;
	ScanKeyData key;
	bool		collides;
	uint64		retries = 0;
	uint64		retries_before_log = GETNEWOID_LOG_THRESHOLD;

	/* Check that GUC lolor.node is set */
	if (lolor_node_id == 0)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("value for lolor.node is not set")));

	/* Generate new OIDs until we find one not in the table */
	do
	{
		CHECK_FOR_INTERRUPTS();

		newOid = GetNewObjectId();

		/*
		 * Keep the range within 1..2^28. Restart from start on overflow and see
		 * if any of the Oids are avaialbe.
		 */
		newOid = newOid % (1 << MAX_OID_BITS);
		if (newOid == 0)
			newOid = 1;

		newOid = (newOid << MAX_NODEID_BITS) | lolor_node_id;

		if (IsBootstrapProcessingMode())
			return newOid;

		ScanKeyInit(&key,
					oidcolumn,
					BTEqualStrategyNumber, F_OIDEQ,
					ObjectIdGetDatum(newOid));

		/* see notes above about using SnapshotAny */
		scan = systable_beginscan(relation, indexId, true,
								  SnapshotAny, 1, &key);

		collides = HeapTupleIsValid(systable_getnext(scan));

		systable_endscan(scan);

		/*
		 * Log that we iterate more than GETNEWOID_LOG_THRESHOLD but have not
		 * yet found OID unused in the relation. Then repeat logging with
		 * exponentially increasing intervals until we iterate more than
		 * GETNEWOID_LOG_MAX_INTERVAL. Finally repeat logging every
		 * GETNEWOID_LOG_MAX_INTERVAL unless an unused OID is found. This
		 * logic is necessary not to fill up the server log with the similar
		 * messages.
		 */
		if (retries >= retries_before_log)
		{
			ereport(LOG,
					(errmsg("still searching for an unused OID in relation \"%s\"",
							RelationGetRelationName(relation)),
					 errdetail_plural("OID candidates have been checked %llu time, but no unused OID has been found yet.",
									  "OID candidates have been checked %llu times, but no unused OID has been found yet.",
									  retries,
									  (unsigned long long) retries)));

			/*
			 * Double the number of retries to do before logging next until it
			 * reaches GETNEWOID_LOG_MAX_INTERVAL.
			 */
			if (retries_before_log * 2 <= GETNEWOID_LOG_MAX_INTERVAL)
				retries_before_log *= 2;
			else
				retries_before_log += GETNEWOID_LOG_MAX_INTERVAL;
		}

		retries++;
	} while (collides);

	/*
	 * If at least one log message is emitted, also log the completion of OID
	 * assignment.
	 */
	if (retries > GETNEWOID_LOG_THRESHOLD)
	{
		ereport(LOG,
				(errmsg_plural("new OID has been assigned in relation \"%s\" after %llu retry",
							   "new OID has been assigned in relation \"%s\" after %llu retries",
							   retries,
							   RelationGetRelationName(relation), (unsigned long long) retries)));
	}

	return newOid;
}
