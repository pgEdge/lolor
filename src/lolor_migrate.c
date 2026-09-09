/*-------------------------------------------------------------------------
 *
 * lolor_migrate.c
 *	  Relocate large objects between PostgreSQL's native catalog storage
 *	  (pg_catalog.pg_largeobject{,_metadata}) and lolor's replicated user
 *	  tables (lolor.pg_largeobject{,_metadata}).
 *
 * lolor's tables are created with exactly the same column layout as the
 * catalogs they stand in for (see lolor--1.0.sql).  That equivalence is what
 * lets the rest of this extension cast their tuples to Form_pg_largeobject
 * and friends, and it is what makes migration a plain tuple copy between two
 * relations rather than a decode/re-encode through the large object API.
 *
 * Everything beyond the tuple copy is the bookkeeping that only the real
 * catalogs participate in:
 *
 *	- pg_shdepend rows for the owner and for ACL grantees, so that DROP ROLE,
 *	  REASSIGN OWNED and DROP OWNED keep seeing the objects.
 *	- pg_description comments, which have nowhere to live while an object sits
 *	  in lolor storage and are parked in lolor.pg_largeobject_description for
 *	  the duration.
 *
 * Removal of the native objects goes through performMultipleDeletions() --
 * the same path DROP does -- so shared dependencies, comments and security
 * labels are cleaned up by core rather than by hand.
 *
 * The layout equivalence is verified at run time instead of assumed, so a
 * future PostgreSQL release that changes either catalog yields a clear error
 * rather than silent corruption.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  contrib/lolor/src/lolor_migrate.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/detoast.h"
#include "access/genam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/objectaccess.h"
#include "catalog/objectaddress.h"
#include "catalog/pg_largeobject.h"
#include "catalog/pg_largeobject_metadata.h"
#include "commands/comment.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#include "lolor.h"

/*
 * How many objects to hand to performMultipleDeletions() at a time.  Bounds
 * the memory used by the ObjectAddresses array on databases holding a very
 * large number of large objects.
 */
#define MIGRATE_DELETE_CHUNK	1000

/*
 * How many conflicting OIDs to name in the pre-flight error before
 * summarising the remainder.
 */
#define MIGRATE_MAX_REPORTED_CONFLICTS	10

PG_FUNCTION_INFO_V1(lolor_migrate_storage);

/*
 * The four relations involved in one migration, plus the indexes needed to
 * probe the destination.  "src" is where the objects live now, "dst" is where
 * they are going.
 */
typedef struct MigrateRels
{
	bool		to_native;		/* lolor -> pg_catalog when true */

	Relation	src_meta;
	Relation	dst_meta;
	Oid			src_meta_idx;
	Oid			dst_meta_idx;

	Relation	src_data;
	Relation	dst_data;
	Oid			src_data_idx;
	Oid			dst_data_idx;

	Relation	desc_rel;		/* lolor.pg_largeobject_description */
	Oid			desc_idx;
} MigrateRels;

/*
 * Confirm that two relations have interchangeable on-disk tuple layouts.
 *
 * lolor's tables are expected to mirror the catalogs exactly.  Rather than
 * trusting that across PostgreSQL major versions, check it every time: a
 * mismatch means the extension was built against a different catalog
 * definition than the server is running, and copying tuples would corrupt
 * data.
 */
static void
validate_layout(Relation a, Relation b, int expected_natts)
{
	TupleDesc	da = RelationGetDescr(a);
	TupleDesc	db = RelationGetDescr(b);
	int			i;

	if (da->natts != db->natts || da->natts != expected_natts)
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("incompatible large object storage layout"),
				 errdetail("Relation \"%s\" has %d columns and \"%s\" has %d; %d expected.",
						   RelationGetRelationName(a), da->natts,
						   RelationGetRelationName(b), db->natts,
						   expected_natts)));

	for (i = 0; i < da->natts; i++)
	{
		Form_pg_attribute aa = TupleDescAttr(da, i);
		Form_pg_attribute ab = TupleDescAttr(db, i);

		if (aa->attisdropped || ab->attisdropped)
			ereport(ERROR,
					(errcode(ERRCODE_DATATYPE_MISMATCH),
					 errmsg("incompatible large object storage layout"),
					 errdetail("Column %d of \"%s\" or \"%s\" is dropped.",
							   i + 1, RelationGetRelationName(a),
							   RelationGetRelationName(b))));

		if (aa->atttypid != ab->atttypid ||
			aa->attlen != ab->attlen ||
			aa->attbyval != ab->attbyval ||
			aa->attalign != ab->attalign ||
			aa->attndims != ab->attndims)
			ereport(ERROR,
					(errcode(ERRCODE_DATATYPE_MISMATCH),
					 errmsg("incompatible large object storage layout"),
					 errdetail("Column %d differs between \"%s\" and \"%s\".",
							   i + 1, RelationGetRelationName(a),
							   RelationGetRelationName(b)),
					 errhint("The lolor extension was built against a different "
							 "PostgreSQL catalog definition than this server uses.")));
	}
}

/*
 * Flatten any toasted or short-header varlena in a deformed tuple.
 *
 * heap_form_tuple() copies whatever pointer it is handed, so an external
 * datum belonging to the source relation's TOAST table would otherwise be
 * carried into the destination as a dangling reference once the source row is
 * removed.  lolor.pg_largeobject is an ordinary table with a TOAST table of
 * its own, and a full LOBLKSIZE page of incompressible data can be pushed out
 * of line there, so this is reachable in practice rather than theoretical.
 *
 * detoast_attr() returns its argument untouched when the datum is already a
 * plain 4-byte-header varlena, so this is cheap in the common case.
 */
static void
flatten_varlenas(TupleDesc desc, Datum *values, const bool *nulls)
{
	int			i;

	for (i = 0; i < desc->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(desc, i);

		if (nulls[i] || att->attbyval || att->attlen != -1)
			continue;

		values[i] = PointerGetDatum(
			detoast_attr((struct varlena *) DatumGetPointer(values[i])));
	}
}

/*
 * Does "loid" already have a metadata row in rel?
 */
static bool
metadata_exists(Relation rel, Oid indexId, Oid loid)
{
	ScanKeyData skey[1];
	SysScanDesc scan;
	bool		found;

	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_metadata_oid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(loid));

	scan = systable_beginscan(rel, indexId, true, NULL, 1, skey);
	found = HeapTupleIsValid(systable_getnext(scan));
	systable_endscan(scan);

	return found;
}

/*
 * Pre-flight OID conflict check.
 *
 * Runs before anything is written so that a conflict leaves both stores
 * untouched.  Reports the offending OIDs rather than merely their existence,
 * because resolving a conflict means acting on specific objects.
 */
static void
check_oid_conflicts(MigrateRels *rels)
{
	SysScanDesc scan;
	HeapTuple	tup;
	StringInfoData buf;
	int64		nconflicts = 0;

	initStringInfo(&buf);

	scan = systable_beginscan(rels->src_meta, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Oid			loid;
		bool		isnull;

		CHECK_FOR_INTERRUPTS();

		loid = DatumGetObjectId(heap_getattr(tup,
											 Anum_pg_largeobject_metadata_oid,
											 RelationGetDescr(rels->src_meta),
											 &isnull));
		Assert(!isnull);

		if (!metadata_exists(rels->dst_meta, rels->dst_meta_idx, loid))
			continue;

		if (nconflicts < MIGRATE_MAX_REPORTED_CONFLICTS)
			appendStringInfo(&buf, "%s%u", nconflicts > 0 ? ", " : "", loid);
		nconflicts++;
	}
	systable_endscan(scan);

	if (nconflicts == 0)
	{
		pfree(buf.data);
		return;
	}

	if (nconflicts > MIGRATE_MAX_REPORTED_CONFLICTS)
		appendStringInfo(&buf, " and " INT64_FORMAT " more",
						 nconflicts - MIGRATE_MAX_REPORTED_CONFLICTS);

	ereport(ERROR,
			(errcode(ERRCODE_DUPLICATE_OBJECT),
			 errmsg_plural("%lld large object already exists in the destination storage",
						   "%lld large objects already exist in the destination storage",
						   (unsigned long) nconflicts,
						   (long long) nconflicts),
			 errdetail("Conflicting OID(s): %s.", buf.data),
			 errhint("Remove or rename the conflicting large objects and retry; "
					 "nothing has been migrated.")));
}

/*
 * Fetch the parked comment for loid from lolor.pg_largeobject_description,
 * or NULL when the object has none.  Caller owns the returned string.
 */
static char *
fetch_parked_comment(MigrateRels *rels, Oid loid)
{
	Relation	rel = rels->desc_rel;
	TupleDesc	desc = RelationGetDescr(rel);
	ScanKeyData skey[1];
	SysScanDesc scan;
	HeapTuple	tup;
	char	   *result = NULL;

	ScanKeyInit(&skey[0], 1, BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(loid));

	scan = systable_beginscan(rel, rels->desc_idx, true, NULL, 1, skey);

	tup = systable_getnext(scan);
	if (HeapTupleIsValid(tup))
	{
		bool		isnull;
		Datum		d = heap_getattr(tup, 2, desc, &isnull);

		if (!isnull)
			result = TextDatumGetCString(d);
	}

	systable_endscan(scan);

	return result;
}

/*
 * Park a comment for loid in lolor.pg_largeobject_description.
 */
static void
park_comment(MigrateRels *rels, Oid loid, const char *comment)
{
	Relation	rel = rels->desc_rel;
	HeapTuple	tup;
	Datum		values[2];
	bool		nulls[2];

	values[0] = ObjectIdGetDatum(loid);
	values[1] = CStringGetTextDatum(comment);
	nulls[0] = false;
	nulls[1] = false;

	tup = heap_form_tuple(RelationGetDescr(rel), values, nulls);
	CatalogTupleInsert(rel, tup);
	heap_freetuple(tup);
}

/*
 * Remove every row from lolor.pg_largeobject_description.
 */
static void
clear_parked_comments(MigrateRels *rels)
{
	Relation	rel = rels->desc_rel;
	SysScanDesc scan;
	HeapTuple	tup;

	scan = systable_beginscan(rel, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		CHECK_FOR_INTERRUPTS();
		CatalogTupleDelete(rel, &tup->t_self);
	}
	systable_endscan(scan);
}

/*
 * Copy every metadata row from src_meta to dst_meta, carrying ownership,
 * ACLs and comments across the storage boundary.
 *
 * Returns the number of objects copied.
 */
static int64
copy_metadata(MigrateRels *rels)
{
	TupleDesc	srcdesc = RelationGetDescr(rels->src_meta);
	TupleDesc	dstdesc = RelationGetDescr(rels->dst_meta);
	CatalogIndexState indstate;
	SysScanDesc scan;
	HeapTuple	tup;
	int64		count = 0;
	MemoryContext tmpcxt;
	MemoryContext oldcxt;

	/*
	 * Each iteration allocates: the detoasted page or ACL from
	 * flatten_varlenas(), the formed tuple, index scratch from the catalog
	 * insert, and any comment text.  CurrentMemoryContext is not reset for
	 * the duration of a function call, so on a database with millions of
	 * large objects those allocations would accumulate until the backend ran
	 * out of memory -- aborting an all-or-nothing migration.  Give each row
	 * its own context and reset it.
	 */
	tmpcxt = AllocSetContextCreate(CurrentMemoryContext,
								   "lolor migrate metadata",
								   ALLOCSET_DEFAULT_SIZES);

	indstate = CatalogOpenIndexes(rels->dst_meta);

	scan = systable_beginscan(rels->src_meta, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Datum		values[Natts_pg_largeobject_metadata];
		bool		nulls[Natts_pg_largeobject_metadata];
		HeapTuple	newtup;
		Oid			loid;
		Oid			owner;

		CHECK_FOR_INTERRUPTS();

		oldcxt = MemoryContextSwitchTo(tmpcxt);

		heap_deform_tuple(tup, srcdesc, values, nulls);
		flatten_varlenas(srcdesc, values, nulls);

		loid = DatumGetObjectId(values[Anum_pg_largeobject_metadata_oid - 1]);
		owner = DatumGetObjectId(values[Anum_pg_largeobject_metadata_lomowner - 1]);

		newtup = heap_form_tuple(dstdesc, values, nulls);
		CatalogTupleInsertWithInfo(rels->dst_meta, newtup, indstate);
		heap_freetuple(newtup);

		if (rels->to_native)
		{
			/*
			 * Record the shared dependencies the catalog is expected to have.
			 * Note the owner is recorded directly rather than creating the
			 * object as the current user and transferring it afterwards, so
			 * pg_shdepend never passes through a wrong intermediate state.
			 */
			recordDependencyOnOwner(LargeObjectRelationId, loid, owner);

			if (!nulls[Anum_pg_largeobject_metadata_lomacl - 1])
				recordDependencyOnNewAcl(LargeObjectRelationId, loid, 0, owner,
										 DatumGetAclP(values[Anum_pg_largeobject_metadata_lomacl - 1]));

			/* Restore any comment parked on the way into lolor storage. */
			{
				char	   *comment = fetch_parked_comment(rels, loid);

				if (comment != NULL)
				{
					CreateComments(loid, LargeObjectRelationId, 0, comment);
					pfree(comment);
				}
			}

			InvokeObjectPostCreateHook(LargeObjectRelationId, loid, 0);
		}
		else
		{
			/*
			 * lolor's tables are ordinary tables, so a comment has nowhere to
			 * attach while the object lives there.  Park it so the round trip
			 * back to native storage is lossless.  The pg_description row
			 * itself is removed by performMultipleDeletions() later.
			 */
			char	   *comment = GetComment(loid, LargeObjectRelationId, 0);

			if (comment != NULL)
				park_comment(rels, loid, comment);
		}

		MemoryContextSwitchTo(oldcxt);
		MemoryContextReset(tmpcxt);

		count++;
	}
	systable_endscan(scan);

	CatalogCloseIndexes(indstate);
	MemoryContextDelete(tmpcxt);
	CommandCounterIncrement();

	return count;
}

/*
 * Copy every data page from src_data to dst_data.
 *
 * Page numbers are carried across verbatim, so a sparse large object stays
 * sparse: there is no re-chunking, no offset arithmetic and therefore no
 * dependence on LOBLKSIZE or on the 2 GB boundary.
 *
 * Returns the number of pages copied.
 */
static int64
copy_data_pages(MigrateRels *rels)
{
	TupleDesc	srcdesc = RelationGetDescr(rels->src_data);
	TupleDesc	dstdesc = RelationGetDescr(rels->dst_data);
	CatalogIndexState indstate;
	SysScanDesc scan;
	HeapTuple	tup;
	int64		count = 0;
	MemoryContext tmpcxt;
	MemoryContext oldcxt;

	/* One row per page, so this is the loop that runs millions of times. */
	tmpcxt = AllocSetContextCreate(CurrentMemoryContext,
								   "lolor migrate pages",
								   ALLOCSET_DEFAULT_SIZES);

	indstate = CatalogOpenIndexes(rels->dst_data);

	scan = systable_beginscan(rels->src_data, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Datum		values[Natts_pg_largeobject];
		bool		nulls[Natts_pg_largeobject];
		HeapTuple	newtup;

		CHECK_FOR_INTERRUPTS();

		oldcxt = MemoryContextSwitchTo(tmpcxt);

		heap_deform_tuple(tup, srcdesc, values, nulls);
		flatten_varlenas(srcdesc, values, nulls);

		newtup = heap_form_tuple(dstdesc, values, nulls);
		CatalogTupleInsertWithInfo(rels->dst_data, newtup, indstate);

		MemoryContextSwitchTo(oldcxt);
		MemoryContextReset(tmpcxt);

		count++;
	}
	systable_endscan(scan);

	CatalogCloseIndexes(indstate);
	MemoryContextDelete(tmpcxt);
	CommandCounterIncrement();

	return count;
}

/*
 * Remove the native large objects that have just been copied into lolor.
 *
 * performMultipleDeletions() is the same path DROP takes, so pg_shdepend,
 * pg_description and pg_seclabel rows go away with the objects instead of
 * being left behind for someone to discover later.
 */
static void
drop_native_objects(MigrateRels *rels)
{
	SysScanDesc scan;
	HeapTuple	tup;
	ObjectAddresses *addrs;
	int			pending = 0;

	addrs = new_object_addresses();

	scan = systable_beginscan(rels->src_meta, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		ObjectAddress obj;
		bool		isnull;

		CHECK_FOR_INTERRUPTS();

		obj.classId = LargeObjectRelationId;
		obj.objectId = DatumGetObjectId(heap_getattr(tup,
													 Anum_pg_largeobject_metadata_oid,
													 RelationGetDescr(rels->src_meta),
													 &isnull));
		obj.objectSubId = 0;
		Assert(!isnull);

		add_exact_object_address(&obj, addrs);

		if (++pending >= MIGRATE_DELETE_CHUNK)
		{
			performMultipleDeletions(addrs, DROP_CASCADE,
									 PERFORM_DELETION_INTERNAL |
									 PERFORM_DELETION_QUIETLY);
			free_object_addresses(addrs);
			addrs = new_object_addresses();
			pending = 0;
		}
	}
	systable_endscan(scan);

	if (pending > 0)
		performMultipleDeletions(addrs, DROP_CASCADE,
								 PERFORM_DELETION_INTERNAL |
								 PERFORM_DELETION_QUIETLY);

	free_object_addresses(addrs);
	CommandCounterIncrement();
}

/*
 * Delete every row of an ordinary lolor storage table.
 */
static void
truncate_lolor_table(Relation rel)
{
	SysScanDesc scan;
	HeapTuple	tup;

	scan = systable_beginscan(rel, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		CHECK_FOR_INTERRUPTS();
		CatalogTupleDelete(rel, &tup->t_self);
	}
	systable_endscan(scan);
}

/*
 * lolor.migrate_storage(to_native boolean) returns bigint
 *
 * Moves every large object from one storage to the other and returns the
 * number of objects moved.  The whole move is one transaction: on any error
 * nothing has changed in either store.
 *
 * This is the mechanism only.  Policy -- who may run it, and how it interacts
 * with logical replication -- lives in the SQL wrappers, which are the
 * supported entry points.
 */
Datum
lolor_migrate_storage(PG_FUNCTION_ARGS)
{
	bool		to_native = PG_GETARG_BOOL(0);
	MigrateRels rels;
	Relation	native_meta;
	Relation	native_data;
	Relation	lolor_meta;
	Relation	lolor_data;
	Oid			lolor_meta_id;
	Oid			lolor_data_id;
	int64		nobjects;
	int64		npages;

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to migrate large object storage")));

	memset(&rels, 0, sizeof(rels));
	rels.to_native = to_native;

	lolor_meta_id = get_LOLOR_LargeObjectMetadataRelationId();
	lolor_data_id = get_LOLOR_LargeObjectRelationId();

	/*
	 * Lock both stores against concurrent large object activity for the whole
	 * migration.
	 *
	 * ShareRowExclusiveLock rather than RowExclusiveLock: ordinary large
	 * object reads and writes take RowExclusiveLock (see open_lo_relation()
	 * in lolor_inv_api.c), and RowExclusiveLock does not conflict with
	 * itself.  A concurrent lo_write() could therefore commit between the
	 * point where this migration copies a page and the point where it removes
	 * the source rows, and the write would be lost without trace.
	 * ShareRowExclusiveLock conflicts with RowExclusiveLock and with itself,
	 * so large object writers wait and two migrations serialise.
	 *
	 * The locks are always taken in the same order regardless of direction,
	 * so that two migrations running opposite ways cannot deadlock against
	 * each other.
	 */
	native_meta = table_open(LargeObjectMetadataRelationId, ShareRowExclusiveLock);
	native_data = table_open(LargeObjectRelationId, ShareRowExclusiveLock);
	lolor_meta = table_open(lolor_meta_id, ShareRowExclusiveLock);
	lolor_data = table_open(lolor_data_id, ShareRowExclusiveLock);

	rels.desc_rel = table_open(get_LOLOR_LargeObjectDescriptionRelationId(),
							   ShareRowExclusiveLock);
	rels.desc_idx = get_LOLOR_LargeObjectDescriptionIndexId();

	if (to_native)
	{
		rels.src_meta = lolor_meta;
		rels.src_data = lolor_data;
		rels.dst_meta = native_meta;
		rels.dst_data = native_data;

		rels.src_meta_idx = get_LOLOR_LargeObjectMetadataOidIndexId();
		rels.src_data_idx = get_LOLOR_LargeObjectLOidPNIndexId();
		rels.dst_meta_idx = LargeObjectMetadataOidIndexId;
		rels.dst_data_idx = LargeObjectLOidPNIndexId;
	}
	else
	{
		rels.src_meta = native_meta;
		rels.src_data = native_data;
		rels.dst_meta = lolor_meta;
		rels.dst_data = lolor_data;

		rels.src_meta_idx = LargeObjectMetadataOidIndexId;
		rels.src_data_idx = LargeObjectLOidPNIndexId;
		rels.dst_meta_idx = get_LOLOR_LargeObjectMetadataOidIndexId();
		rels.dst_data_idx = get_LOLOR_LargeObjectLOidPNIndexId();
	}

	/* Never copy tuples between relations whose layouts might differ. */
	validate_layout(rels.src_meta, rels.dst_meta,
					Natts_pg_largeobject_metadata);
	validate_layout(rels.src_data, rels.dst_data,
					Natts_pg_largeobject);

	/* Refuse before writing anything if the destination already has the OIDs. */
	check_oid_conflicts(&rels);

	nobjects = copy_metadata(&rels);
	npages = copy_data_pages(&rels);

	if (to_native)
	{
		truncate_lolor_table(rels.src_data);
		truncate_lolor_table(rels.src_meta);
		clear_parked_comments(&rels);
		CommandCounterIncrement();
	}
	else
	{
		drop_native_objects(&rels);
	}

	/*
	 * Close the relcache references but keep the locks until the caller's
	 * transaction ends.  Passing the lock mode here would release them at
	 * once, re-opening the window this function is meant to close: between
	 * that release and the commit, another session could take
	 * RowExclusiveLock and write to a large object that has already been
	 * relocated, and that write would disappear when this transaction's
	 * emptying of the source store became visible.
	 */
	table_close(rels.desc_rel, NoLock);
	table_close(lolor_data, NoLock);
	table_close(lolor_meta, NoLock);
	table_close(native_data, NoLock);
	table_close(native_meta, NoLock);

	ereport(NOTICE,
			(errmsg("migrated " INT64_FORMAT " large object(s), " INT64_FORMAT " data page(s), to %s storage",
					nobjects, npages, to_native ? "native" : "lolor")));

	PG_RETURN_INT64(nobjects);
}
