/*-------------------------------------------------------------------------
 * pg_lolor.c
 *	  PostgreSQL definitions for Large Objects for logical replication.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  contrib/pg_lolor/pg_lolor.c
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
#include "catalog/namespace.h"
#include "catalog/pg_extension.h"
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

#include "pg_lolor.h"

PG_MODULE_MAGIC;

int32		pg_lolor_node_id = 0;

void		_PG_init(void);

/* keep Oids of the large object catalog. */
static Oid	PG_LOLOR_LargeObjectRelationId = InvalidOid;
static Oid	PG_LOLOR_LargeObjectLOidPNIndexId = InvalidOid;
static Oid	PG_LOLOR_LargeObjectMetadataRelationId = InvalidOid;
static Oid	PG_LOLOR_LargeObjectMetadataOidIndexId = InvalidOid;
static Oid	PG_LOLOR_LargeObjectDescriptionRelationId = InvalidOid;
static Oid	PG_LOLOR_LargeObjectDescriptionIndexId = InvalidOid;

PG_FUNCTION_INFO_V1(pg_lolor_on_drop_extension);

static Oid
get_lobj_table_oid_extended(const char *table, bool missing_ok)
{
	Oid			reloid;
	Oid			nspoid;

	nspoid = get_namespace_oid(EXTENSION_SCHEMA, false);
	reloid = get_relname_relid(table, nspoid);
	if (reloid == InvalidOid && !missing_ok)
		elog(ERROR, "cache lookup failed for relation %s.%s",
			 EXTENSION_SCHEMA, table);

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
 * The shared library is replaced before CREATE EXTENSION or ALTER EXTENSION
 * UPDATE runs, so a backend can execute this code against a schema in which
 * lolor.pg_largeobject_description does not exist yet.  Paths reached during
 * ordinary large object activity have to tolerate that.
 */
Oid
get_PG_LOLOR_LargeObjectDescriptionRelationIdIfExists(void)
{
	return get_lobj_table_oid_extended(PG_LOLOR_LARGEOBJECT_DESCRIPTION, true);
}

Oid
get_PG_LOLOR_LargeObjectRelationId()
{
	if (!OidIsValid(PG_LOLOR_LargeObjectRelationId))
		PG_LOLOR_LargeObjectRelationId = get_lobj_table_oid(PG_LOLOR_LARGEOBJECT_CATALOG);

	return PG_LOLOR_LargeObjectRelationId;
}

Oid
get_PG_LOLOR_LargeObjectLOidPNIndexId()
{
	if (!OidIsValid(PG_LOLOR_LargeObjectLOidPNIndexId))
		PG_LOLOR_LargeObjectLOidPNIndexId = get_lobj_table_oid(PG_LOLOR_LARGEOBJECT_PKEY);

	return PG_LOLOR_LargeObjectLOidPNIndexId;
}

Oid
get_PG_LOLOR_LargeObjectMetadataRelationId()
{
	if (!OidIsValid(PG_LOLOR_LargeObjectMetadataRelationId))
		PG_LOLOR_LargeObjectMetadataRelationId = get_lobj_table_oid(PG_LOLOR_LARGEOBJECT_METADATA);

	return PG_LOLOR_LargeObjectMetadataRelationId;
}

Oid
get_PG_LOLOR_LargeObjectMetadataOidIndexId()
{
	if (!OidIsValid(PG_LOLOR_LargeObjectMetadataOidIndexId))
		PG_LOLOR_LargeObjectMetadataOidIndexId = get_lobj_table_oid(PG_LOLOR_LARGEOBJECT_METADATA_PKEY);

	return PG_LOLOR_LargeObjectMetadataOidIndexId;
}

/*
 * lolor.pg_largeobject_description parks COMMENT ON LARGE OBJECT text while an
 * object lives in pg_lolor storage, where there is no catalog entry for a comment
 * to hang off.  See pg_lolor_migrate.c.
 */
Oid
get_PG_LOLOR_LargeObjectDescriptionRelationId()
{
	if (!OidIsValid(PG_LOLOR_LargeObjectDescriptionRelationId))
		PG_LOLOR_LargeObjectDescriptionRelationId =
			get_lobj_table_oid(PG_LOLOR_LARGEOBJECT_DESCRIPTION);

	return PG_LOLOR_LargeObjectDescriptionRelationId;
}

Oid
get_PG_LOLOR_LargeObjectDescriptionIndexId()
{
	if (!OidIsValid(PG_LOLOR_LargeObjectDescriptionIndexId))
		PG_LOLOR_LargeObjectDescriptionIndexId =
			get_lobj_table_oid(PG_LOLOR_LARGEOBJECT_DESCRIPTION_PKEY);

	return PG_LOLOR_LargeObjectDescriptionIndexId;
}

static void
pg_lolor_xact_callback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_COMMIT:
		case XACT_EVENT_PARALLEL_COMMIT:
		case XACT_EVENT_PREPARE:
			AtEOXact_PG_LOLOR_LargeObject(true);
			break;
		case XACT_EVENT_ABORT:
		case XACT_EVENT_PARALLEL_ABORT:
			AtEOXact_PG_LOLOR_LargeObject(false);
			break;
		default:
			break;
	}
}

static void
pg_lolor_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
						  SubTransactionId parentSubid, void *arg)
{
	switch (event)
	{
		case SUBXACT_EVENT_COMMIT_SUB:
			AtEOSubXact_PG_LOLOR_LargeObject(true, mySubid, parentSubid);
			break;
		case SUBXACT_EVENT_ABORT_SUB:
			AtEOSubXact_PG_LOLOR_LargeObject(false, mySubid, parentSubid);
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
	PG_LOLOR_LargeObjectRelationId = InvalidOid;
	PG_LOLOR_LargeObjectLOidPNIndexId = InvalidOid;
	PG_LOLOR_LargeObjectMetadataRelationId = InvalidOid;
	PG_LOLOR_LargeObjectMetadataOidIndexId = InvalidOid;
	PG_LOLOR_LargeObjectDescriptionRelationId = InvalidOid;
	PG_LOLOR_LargeObjectDescriptionIndexId = InvalidOid;
}

/*
 * Entry point for this module.
 */
void
_PG_init(void)
{
	DefineCustomIntVariable("pg_lolor.node",
							"Unique id of current node.",
							NULL,
							&pg_lolor_node_id,
							0,
							0,
							PG_LOLOR_MAX_NODE_ID,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);

	/* register transaction callbacks for cleanup. */
	RegisterXactCallback(pg_lolor_xact_callback, NULL);
	RegisterSubXactCallback(pg_lolor_subxact_callback, NULL);

	/*
	 * Something may change object ID accidentially (REINDEX is a good
	 * example). So, it is necessary to invalidate cache of Oids.
	 */
	CacheRegisterRelcacheCallback(relcache_invalidate_callback, (Datum) 0);
}

/*
 * pg_lolor_extension_owner
 *
 *	Owner of the installed pg_lolor extension, or InvalidOid when it is not
 *	installed.
 */
static Oid
pg_lolor_extension_owner(void)
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
 * pg_lolor_is_being_dropped
 *
 *	Decide whether the DDL about to run will remove the pg_lolor extension.
 *
 *	DROP EXTENSION is the obvious spelling, but the extension also goes away
 *	through DROP SCHEMA lolor CASCADE and DROP OWNED BY <extension owner>,
 *	which reach it by dependency cascade rather than by naming it.  Missing one
 *	is not cosmetic: the large objects would be destroyed along with the pg_lolor
 *	tables and the renamed pg_catalog functions never restored, leaving a
 *	database with no working lo_open().
 */
static bool
pg_lolor_is_being_dropped(Node *parsetree)
{
	ListCell   *lc;

	if (IsA(parsetree, DropStmt))
	{
		DropStmt   *stmt = (DropStmt *) parsetree;
		const char *target;

		/*
		 * DROP EXTENSION and DROP SCHEMA both name the object with a bare
		 * String, so one loop covers both once the name to look for has been
		 * chosen.  The two differ: see EXTENSION_SCHEMA in pg_lolor.h.
		 *
		 * Only CASCADE reaches the extension through the schema: a plain DROP
		 * SCHEMA is RESTRICT and cannot remove a schema that still holds the
		 * extension's tables.  Acting on it would run the whole migration and
		 * take the storage locks before PostgreSQL rejected the command.
		 */
		if (stmt->removeType == OBJECT_EXTENSION)
			target = EXTENSION_NAME;
		else if (stmt->removeType == OBJECT_SCHEMA &&
				 stmt->behavior == DROP_CASCADE)
			target = EXTENSION_SCHEMA;
		else
			return false;

		foreach(lc, stmt->objects)
		{
			Node	   *objname = (Node *) lfirst(lc);

			if (IsA(objname, String) &&
				strcmp(strVal(objname), target) == 0)
				return true;
		}

		return false;
	}

	if (IsA(parsetree, DropOwnedStmt))
	{
		DropOwnedStmt *stmt = (DropOwnedStmt *) parsetree;
		Oid			extowner = pg_lolor_extension_owner();

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
 * pg_lolor_on_drop_extension
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
pg_lolor_on_drop_extension(PG_FUNCTION_ARGS)
{
	EventTriggerData *trigdata;

	/* Make sure we are called as an event trigger */
	if (!CALLED_AS_EVENT_TRIGGER(fcinfo))
		elog(ERROR, "not fired by event trigger manager");

	trigdata = (EventTriggerData *) fcinfo->context;
	if (trigdata->parsetree == NULL)
	{
		elog(LOG, "pg_lolor_on_drop_extension(): parsetree = NULL");
		PG_RETURN_NULL();
	}

	/*
	 * The trigger is registered for several command tags, so most invocations
	 * are for drops that have nothing to do with pg_lolor.  Let them proceed.
	 */
	if (!pg_lolor_is_being_dropped(trigdata->parsetree))
		PG_RETURN_NULL();

	/*
	 * The pg_lolor extension is going away.
	 *
	 * First, migrate any large objects stored in pg_lolor tables back to
	 * native PostgreSQL storage.  This must happen while pg_lolor is still
	 * enabled so the _orig functions (native LO API) are available. The event
	 * trigger fires on ddl_command_start, so pg_lolor tables still exist and
	 * are readable at this point.
	 *
	 * Then rename our replacement functions out of the way and restore the
	 * original PostgreSQL function names.  The drop itself will then remove
	 * the pg_lolor schema and its objects.
	 *
	 * Guard the migrate_to_native() call with a pg_proc check: the shared
	 * library is loaded before the extension's SQL objects exist, so the
	 * function may legitimately be absent.
	 */
	SPI_connect();

	if (SPI_execute("SELECT 1 FROM pg_proc p "
					"JOIN pg_namespace n ON n.oid = p.pronamespace "
					"WHERE n.nspname = '" EXTENSION_SCHEMA "' "
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
					(errmsg("pg_lolor: failed to migrate large objects back to native storage")));
	}

	SPI_execute("SELECT CASE WHEN lolor.is_enabled() "
				"THEN lolor.disable() ELSE true END",
				false, 0);

	SPI_finish();

	PG_RETURN_NULL();
}
