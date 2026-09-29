/*-------------------------------------------------------------------------
 * lolor.c
 *	  PostgreSQL definitions for Large Objects for logical replication.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	contrib/lolor/src/lolor.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "miscadmin.h"
#include "fmgr.h"
#include "access/xact.h"
#include "access/genam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "catalog/dependency.h"
#include "catalog/namespace.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_extension.h"
#include "catalog/pg_namespace.h"
#include "catalog/pg_type.h"
#include "commands/event_trigger.h"
#include "commands/extension.h"
#include "executor/spi.h"
#include "nodes/parsenodes.h"
#include "nodes/value.h"
#include "nodes/print.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/inval.h"
#include "utils/guc.h"
#include "utils/rel.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"

#include "lolor.h"

PG_MODULE_MAGIC;

int32 lolor_node_id = 0;
static bool lolor_allow_unsafe_drop = false;

static object_access_hook_type prev_object_access_hook = NULL;

void	_PG_init(void);
static void lolor_object_access(ObjectAccessType access, Oid classId,
								Oid objectId, int subId, void *arg);

/* keep Oids of the large object catalog. */
static Oid	LOLOR_LargeObjectRelationId = InvalidOid;
static Oid	LOLOR_LargeObjectLOidPNIndexId = InvalidOid;
static Oid	LOLOR_LargeObjectMetadataRelationId = InvalidOid;
static Oid	LOLOR_LargeObjectMetadataOidIndexId = InvalidOid;
static Oid	LOLOR_LargeObjectDescriptionRelationId = InvalidOid;
static Oid	LOLOR_LargeObjectDescriptionIndexId = InvalidOid;

PG_FUNCTION_INFO_V1(lolor_on_drop_extension);

static Oid
get_lobj_table_oid_extended(const char *table, bool missing_ok)
{
	Oid			reloid;
	Oid			nspoid;

	nspoid = get_namespace_oid(EXTENSION_NAME, false);
	reloid = get_relname_relid(table, nspoid);
	if (reloid == InvalidOid && !missing_ok)
		elog(ERROR, "cache lookup failed for relation %s.%s",
			 EXTENSION_NAME, table);

	return reloid;
}

static Oid
get_lobj_table_oid(const char *table)
{
	return get_lobj_table_oid_extended(table, false);
}

/*
 * Same, but returns InvalidOid when the relation is absent.
 *
 * The shared library is replaced before ALTER EXTENSION UPDATE runs, so a
 * backend can execute newer code against an older schema in which
 * lolor.pg_largeobject_description does not exist yet.  Paths reached during
 * ordinary large object activity have to tolerate that.
 */
Oid
get_LOLOR_LargeObjectDescriptionRelationIdIfExists(void)
{
	return get_lobj_table_oid_extended(LOLOR_LARGEOBJECT_DESCRIPTION, true);
}

Oid
get_LOLOR_LargeObjectRelationId()
{
	if (!OidIsValid(LOLOR_LargeObjectRelationId))
		LOLOR_LargeObjectRelationId = get_lobj_table_oid(LOLOR_LARGEOBJECT_CATALOG);

	return LOLOR_LargeObjectRelationId;
}

Oid
get_LOLOR_LargeObjectLOidPNIndexId()
{
	if (!OidIsValid(LOLOR_LargeObjectLOidPNIndexId))
		LOLOR_LargeObjectLOidPNIndexId = get_lobj_table_oid(LOLOR_LARGEOBJECT_PKEY);

	return LOLOR_LargeObjectLOidPNIndexId;
}

Oid
get_LOLOR_LargeObjectMetadataRelationId()
{
	if (!OidIsValid(LOLOR_LargeObjectMetadataRelationId))
		LOLOR_LargeObjectMetadataRelationId = get_lobj_table_oid(LOLOR_LARGEOBJECT_METADATA);

	return LOLOR_LargeObjectMetadataRelationId;
}

Oid
get_LOLOR_LargeObjectMetadataOidIndexId()
{
	if (!OidIsValid(LOLOR_LargeObjectMetadataOidIndexId))
		LOLOR_LargeObjectMetadataOidIndexId = get_lobj_table_oid(LOLOR_LARGEOBJECT_METADATA_PKEY);

	return LOLOR_LargeObjectMetadataOidIndexId;
}

/*
 * lolor.pg_largeobject_description parks COMMENT ON LARGE OBJECT text while an
 * object lives in lolor storage, where there is no catalog entry for a comment
 * to hang off.  See lolor_migrate.c.
 */
Oid
get_LOLOR_LargeObjectDescriptionRelationId()
{
	if (!OidIsValid(LOLOR_LargeObjectDescriptionRelationId))
		LOLOR_LargeObjectDescriptionRelationId =
			get_lobj_table_oid(LOLOR_LARGEOBJECT_DESCRIPTION);

	return LOLOR_LargeObjectDescriptionRelationId;
}

Oid
get_LOLOR_LargeObjectDescriptionIndexId()
{
	if (!OidIsValid(LOLOR_LargeObjectDescriptionIndexId))
		LOLOR_LargeObjectDescriptionIndexId =
			get_lobj_table_oid(LOLOR_LARGEOBJECT_DESCRIPTION_PKEY);

	return LOLOR_LargeObjectDescriptionIndexId;
}

static void
lolor_xact_callback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_COMMIT:
		case XACT_EVENT_PARALLEL_COMMIT:
		case XACT_EVENT_PREPARE:
			AtEOXact_LOLOR_LargeObject(true);
			break;
		case XACT_EVENT_ABORT:
		case XACT_EVENT_PARALLEL_ABORT:
			AtEOXact_LOLOR_LargeObject(false);
			break;
		default:
			break;
	}
}

static void
lolor_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
						 SubTransactionId parentSubid, void *arg)
{
	switch (event)
	{
		case SUBXACT_EVENT_COMMIT_SUB:
			AtEOSubXact_LOLOR_LargeObject(true, mySubid, parentSubid);
			break;
		case SUBXACT_EVENT_ABORT_SUB:
			AtEOSubXact_LOLOR_LargeObject(false, mySubid, parentSubid);
			break;
		default:
			break;
	}
}

/*
 * For the sake of performance, make it simple
 */
static void
relcache_invalidate_callback(Datum arg, Oid reloid)
{
	LOLOR_LargeObjectRelationId = InvalidOid;
	LOLOR_LargeObjectLOidPNIndexId = InvalidOid;
	LOLOR_LargeObjectMetadataRelationId = InvalidOid;
	LOLOR_LargeObjectMetadataOidIndexId = InvalidOid;
	LOLOR_LargeObjectDescriptionRelationId = InvalidOid;
	LOLOR_LargeObjectDescriptionIndexId = InvalidOid;
}

/*
 * Entry point for this module.
 */
void
_PG_init(void)
{
	/*
	 * The drop guard below is an object_access_hook.  A hook installed by a
	 * library loaded on demand exists only in the backend that loaded it, and
	 * the guard has to hold in every backend and worker, so insist on being
	 * preloaded.  This also makes a missing or broken library fail at startup
	 * rather than at the first lo_open().
	 */
	if (!process_shared_preload_libraries_in_progress)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("lolor must be loaded via \"shared_preload_libraries\"")));

	DefineCustomIntVariable("lolor.node",
							"Unique id of current node.",
							NULL,
							&lolor_node_id,
							0,
							0,
							LOLOR_MAX_NODE_ID,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);

	DefineCustomBoolVariable("lolor.allow_unsafe_drop",
							 "Allows dropping lolor while it is enabled or still holds large objects.",
							 NULL,
							 &lolor_allow_unsafe_drop,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	/* register transaction callbacks for cleanup. */
	RegisterXactCallback(lolor_xact_callback, NULL);
	RegisterSubXactCallback(lolor_subxact_callback, NULL);

	/*
	 * Something may change object ID accidentially (REINDEX is a good example).
	 * So, it is necessary to invalidate cache of Oids.
	 */
	CacheRegisterRelcacheCallback(relcache_invalidate_callback, (Datum) 0);

	prev_object_access_hook = object_access_hook;
	object_access_hook = lolor_object_access;
}

/*
 * lolor_extension_owner
 *
 *	Owner of the installed lolor extension, or InvalidOid when it is not
 *	installed.
 */
static Oid
lolor_extension_owner(void)
{
	Relation	rel;
	ScanKeyData skey[1];
	SysScanDesc scan;
	HeapTuple	tup;
	Oid			owner = InvalidOid;

	rel = table_open(ExtensionRelationId, AccessShareLock);

	ScanKeyInit(&skey[0],
				Anum_pg_extension_extname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(EXTENSION_NAME));

	scan = systable_beginscan(rel, ExtensionNameIndexId, true, NULL, 1, skey);

	tup = systable_getnext(scan);
	if (HeapTupleIsValid(tup))
		owner = ((Form_pg_extension) GETSTRUCT(tup))->extowner;

	systable_endscan(scan);
	table_close(rel, AccessShareLock);

	return owner;
}

/*
 * lolor_storage_drop_check
 *
 *	Refuse to delete lolor.pg_largeobject_metadata while it holds rows.
 *
 *	The lolor tables are members of the extension, and members are deleted
 *	before the extension itself, so this is the last moment at which the
 *	contents can still be counted.
 */
static void
lolor_storage_drop_check(Oid relid)
{
	Oid			nspoid;
	Oid			extoid;
	Relation	rel;
	SysScanDesc scan;
	int64		count = 0;

	/* Fast exit for the usual case: some table that is not ours. */
	nspoid = get_namespace_oid(EXTENSION_NAME, true);
	if (!OidIsValid(nspoid) ||
		get_relname_relid(LOLOR_LARGEOBJECT_METADATA, nspoid) != relid)
		return;

	/* A same-named table in a squatted schema is not ours either. */
	extoid = get_extension_oid(EXTENSION_NAME, true);
	if (!OidIsValid(extoid) ||
		getExtensionOfObject(RelationRelationId, relid) != extoid)
		return;

	/* The dropper already holds AccessExclusiveLock. */
	rel = table_open(relid, NoLock);
	scan = systable_beginscan(rel, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(systable_getnext(scan)))
		count++;
	systable_endscan(scan);
	table_close(rel, NoLock);

	if (count > 0)
		ereport(ERROR,
				(errcode(ERRCODE_DEPENDENT_OBJECTS_STILL_EXIST),
				 errmsg_plural("cannot drop lolor storage while it holds %lld large object",
							   "cannot drop lolor storage while it holds %lld large objects",
							   count, (long long) count),
				 errhint("Run lolor.migrate_to_native() first, or set lolor.allow_unsafe_drop to discard them.")));
}

/*
 * lolor_extension_drop_check
 *
 *	Refuse to delete the extension while the native large object functions
 *	are still parked under their *_orig names: the drop would take lolor's
 *	replacements with it and leave pg_catalog without any lo_open() at all.
 *	The probe is the one lolor.is_enabled() uses.
 */
static void
lolor_extension_drop_check(Oid extoid)
{
	Oid			argtypes[2] = {OIDOID, INT4OID};

	if (extoid != get_extension_oid(EXTENSION_NAME, true))
		return;

	if (SearchSysCacheExists3(PROCNAMEARGSNSP,
							  CStringGetDatum("lo_open_orig"),
							  PointerGetDatum(buildoidvector(argtypes, 2)),
							  ObjectIdGetDatum(PG_CATALOG_NAMESPACE)))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("cannot drop extension \"%s\" while it is enabled",
						EXTENSION_NAME),
				 errdetail("The native large object functions are still parked under their *_orig names."),
				 errhint("Run lolor.disable() first.")));
}

/*
 * lolor_object_access
 *
 *	Guard every path that removes lolor: DROP EXTENSION, DROP SCHEMA CASCADE,
 *	DROP OWNED BY and anything else that reaches the extension by dependency.
 *
 *	The event trigger migrates the large objects out and restores the native
 *	functions before the drop, but an event trigger can be disabled, and the
 *	drop usually runs in a different backend from the migration, so a flag
 *	set by the migration would not be visible to it.  Check the catalog state
 *	at the moment of deletion instead, from whichever process performs it.
 *	lolor.allow_unsafe_drop skips both checks.
 */
static void
lolor_object_access(ObjectAccessType access, Oid classId, Oid objectId,
					int subId, void *arg)
{
	if (access == OAT_DROP && !lolor_allow_unsafe_drop)
	{
		/* subId != 0 is a column being dropped, not the table. */
		if (classId == RelationRelationId && subId == 0)
			lolor_storage_drop_check(objectId);
		else if (classId == ExtensionRelationId)
			lolor_extension_drop_check(objectId);
	}

	if (prev_object_access_hook)
		prev_object_access_hook(access, classId, objectId, subId, arg);
}

/*
 * lolor_is_being_dropped
 *
 *	Decide whether the DDL about to run will remove the lolor extension.
 *
 *	DROP EXTENSION is the obvious spelling, but the extension also goes away
 *	through DROP SCHEMA lolor CASCADE and DROP OWNED BY <extension owner>,
 *	which reach it by dependency cascade rather than by naming it.  Missing one
 *	is not cosmetic: the large objects would be destroyed along with the lolor
 *	tables and the renamed pg_catalog functions never restored, leaving a
 *	database with no working lo_open().
 */
static bool
lolor_is_being_dropped(Node *parsetree)
{
	ListCell   *lc;

	if (IsA(parsetree, DropStmt))
	{
		DropStmt   *stmt = (DropStmt *) parsetree;

		/*
		 * DROP EXTENSION lolor and DROP SCHEMA lolor both name the object with
		 * a bare String, so one loop covers both; the extension and its schema
		 * share a name, which lolor.control enforces.
		 *
		 * Only CASCADE reaches the extension through the schema: a plain DROP
		 * SCHEMA is RESTRICT and cannot remove a schema that still holds the
		 * extension's tables.  Acting on it would run the whole migration and
		 * take the storage locks before PostgreSQL rejected the command.
		 */
		if (stmt->removeType != OBJECT_EXTENSION &&
			(stmt->removeType != OBJECT_SCHEMA ||
			 stmt->behavior != DROP_CASCADE))
			return false;

		foreach(lc, stmt->objects)
		{
			Node	   *objname = (Node *) lfirst(lc);

			if (IsA(objname, String) &&
				strcmp(strVal(objname), EXTENSION_NAME) == 0)
				return true;
		}

		return false;
	}

	if (IsA(parsetree, DropOwnedStmt))
	{
		DropOwnedStmt *stmt = (DropOwnedStmt *) parsetree;
		Oid			extowner = lolor_extension_owner();

		if (!OidIsValid(extowner))
			return false;

		foreach(lc, stmt->roles)
		{
			RoleSpec   *rolespec = lfirst_node(RoleSpec, lc);

			if (get_rolespec_oid(rolespec, true) == extowner)
				return true;
		}

		return false;
	}

	return false;
}

/*
 * lolor_on_drop_extension
 *
 * 	In order to be a drop-in replacement for the PostgreSQL built
 * 	in large object access functions, we must replace them with
 * 	our own ones. We do that in the extension's install script
 * 	by renaming the build-in ones to <funcname>_orig and then
 * 	creating our versions of them. The PostgreSQL system has no
 * 	mechanism to invoke a cleanup or uninstall script on DROP
 * 	EXTENSION. We therefore must do the cleanup in an event trigger.
 *	However only C-Language event triggers that fire on
 *	ddl_command_start have access to the list of object that get
 *	dropped.
 *
 *	We cannot drop our own functions here as the dependencies of
 *	the extension itself won't allow that. Likewise we cannot
 *	drop the original PostgreSQL functions because the PostgreSQL
 *	system depends on them. But we can get around that with
 *	renaming (which makes no sense).
 */
Datum
lolor_on_drop_extension(PG_FUNCTION_ARGS)
{
	EventTriggerData   *trigdata;

	/* Make sure we are called as an event trigger */
	if (!CALLED_AS_EVENT_TRIGGER(fcinfo))
		elog(ERROR, "not fired by event trigger manager");

	trigdata = (EventTriggerData *) fcinfo->context;
	if (trigdata->parsetree == NULL)
	{
		elog(LOG, "lolor_on_drop_extension(): parsetree = NULL");
		PG_RETURN_NULL();
	}

	/*
	 * The trigger is registered for several command tags, so most invocations
	 * are for drops that have nothing to do with lolor.  Let them proceed.
	 */
	if (!lolor_is_being_dropped(trigdata->parsetree))
		PG_RETURN_NULL();

	/*
	 * The lolor extension is going away.
	 *
	 * First, migrate any large objects stored in lolor tables back to
	 * native PostgreSQL storage.  This must happen while lolor is still
	 * enabled so the _orig functions (native LO API) are available.
	 * The event trigger fires on ddl_command_start, so lolor tables
	 * still exist and are readable at this point.
	 *
	 * Then rename our replacement functions out of the way and restore
	 * the original PostgreSQL function names.  The drop itself will then
	 * remove the lolor schema and its objects.
	 *
	 * Guard the migrate_to_native() call with a pg_proc check so that
	 * upgrades from versions < 1.3.0 (where the function does not exist)
	 * do not fail.
	 */
	SPI_connect();

	if (SPI_execute("SELECT 1 FROM pg_proc p "
					 "JOIN pg_namespace n ON n.oid = p.pronamespace "
					 "WHERE n.nspname = 'lolor' "
					 "AND p.proname = 'migrate_to_native'",
					 true, 1) == SPI_OK_SELECT &&
		SPI_processed > 0)
	{
		/*
		 * If migrate_to_native() fails (e.g. OID conflict), the ERROR
		 * propagates and aborts the drop.  This is intentional: losing large
		 * objects silently is worse than a failed DROP.  The user must
		 * resolve the conflict and retry.
		 */
		if (SPI_execute("SELECT lolor.migrate_to_native()", false, 0) != SPI_OK_SELECT)
			ereport(ERROR,
					(errmsg("lolor: failed to migrate large objects back to native storage")));
	}

	SPI_execute("SELECT CASE WHEN lolor.is_enabled() "
				"THEN lolor.disable() ELSE true END",
				false, 0);

	SPI_finish();

	PG_RETURN_NULL();
}
