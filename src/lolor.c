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
#include "catalog/namespace.h"
#include "catalog/pg_extension.h"
#include "commands/event_trigger.h"
#include "commands/extension.h"
#include "executor/spi.h"
#include "nodes/parsenodes.h"
#include "nodes/value.h"
#include "nodes/print.h"
#include "access/genam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "utils/acl.h"
#include "utils/fmgroids.h"
#include "utils/builtins.h"
#include "utils/inval.h"
#include "utils/guc.h"
#include "utils/rel.h"
#include "utils/lsyscache.h"

#include "lolor.h"

PG_MODULE_MAGIC;

int32 lolor_node_id = 0;

void	_PG_init(void);

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
 * backend can be executing 1.4.0 code against a 1.3.0 schema in which
 * lolor.pg_largeobject_description does not exist yet.  Paths that run during
 * ordinary large object activity have to tolerate that rather than fail.
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

	/* register transaction callbacks for cleanup. */
	RegisterXactCallback(lolor_xact_callback, NULL);
	RegisterSubXactCallback(lolor_subxact_callback, NULL);

	/*
	 * Something may change object ID accidentially (REINDEX is a good example).
	 * So, it is necessary to invalidate cache of Oids.
	 */
	CacheRegisterRelcacheCallback(relcache_invalidate_callback, (Datum) 0);
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
 * lolor_is_being_dropped
 *
 *	Decide whether the DDL that is about to run will remove the lolor
 *	extension.
 *
 *	DROP EXTENSION is the obvious spelling, but the extension also goes away
 *	through DROP SCHEMA lolor CASCADE and through DROP OWNED BY <extension
 *	owner>.  Those reach the extension by dependency cascade rather than by a
 *	DropStmt that names it, so each has to be recognised here.  Missing one is
 *	not cosmetic: the large objects would be destroyed along with the lolor
 *	tables and the renamed pg_catalog functions would never be restored,
 *	leaving a database with no working lo_open().
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
		 * a bare String, so one loop covers both.  The extension and its
		 * schema share a name, which is enforced by lolor.control.
		 *
		 * Only CASCADE reaches the extension through the schema: a plain DROP
		 * SCHEMA is RESTRICT, which cannot remove a schema that still holds
		 * the extension's tables.  Acting on it would run the whole migration
		 * and take the storage locks before PostgreSQL rejected the command
		 * and rolled all of it back.
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
	 * are for drops that have nothing to do with lolor.  Say nothing and let
	 * them proceed.
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
		 * propagates and aborts the drop.  This is intentional: losing
		 * large objects silently is worse than a failed DROP.  The user
		 * must resolve the conflict and retry.
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
