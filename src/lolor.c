/*-------------------------------------------------------------------------
 * lolor.c
 *	  PostgreSQL definitions for Large Objects for logical replication.
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2023, PostgreSQL Global Development Group
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
#include "commands/event_trigger.h"
#include "executor/spi.h"
#include "nodes/parsenodes.h"
#include "nodes/value.h"
#include "nodes/print.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/rel.h"
#include "utils/lsyscache.h"

#include "lolor.h"

PG_MODULE_MAGIC;

int32 lolor_node_id = 0;

void	_PG_init(void);

/* keep Oids of the large object catalog. */
Oid	LOLOR_LargeObjectRelationId = InvalidOid;
Oid	LOLOR_LargeObjectLOidPNIndexId = InvalidOid;
Oid	LOLOR_LargeObjectMetadataRelationId = InvalidOid;
Oid	LOLOR_LargeObjectMetadataOidIndexId = InvalidOid;

PG_FUNCTION_INFO_V1(lolor_on_drop_extension);

Oid
get_lobj_table_oid(const char *table)
{
	Oid			reloid;
	Oid			nspoid;

	nspoid = get_namespace_oid(EXTENSION_NAME, false);
	reloid = get_relname_relid(table, nspoid);
	if (reloid == InvalidOid)
		elog(ERROR, "cache lookup failed for relation %s.%s",
			 EXTENSION_NAME, table);

	return reloid;
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
							1,
							16,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);

	/* gather info of large object tables from lolor extension */
	LOLOR_LargeObjectRelationId =
			get_lobj_table_oid(LOLOR_LARGEOBJECT_CATALOG);
	LOLOR_LargeObjectLOidPNIndexId =
			get_lobj_table_oid(LOLOR_LARGEOBJECT_PKEY);
	LOLOR_LargeObjectMetadataRelationId =
			get_lobj_table_oid(LOLOR_LARGEOBJECT_METADATA);
	LOLOR_LargeObjectMetadataOidIndexId =
			get_lobj_table_oid(LOLOR_LARGEOBJECT_METADATA_PKEY);

	/* register transaction callbacks for cleanup. */
	RegisterXactCallback(lolor_xact_callback, NULL);
	RegisterSubXactCallback(lolor_subxact_callback, NULL);
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
 *	drop the origial PostgreSQL functions because the PostgreSQL
 *	system depends on them. But we can get around that with
 *	renaming (which makes no sense).
 */
Datum
lolor_on_drop_extension(PG_FUNCTION_ARGS)
{
	EventTriggerData   *trigdata;
	DropStmt		   *dropstmt;
	ListCell		   *lc;
	bool				has_lolor_objs = false;

	/* Make sure we are called as an event trigger */
	if (!CALLED_AS_EVENT_TRIGGER(fcinfo))
		elog(ERROR, "not fired by event trigger manager");

	/* Make sure we have a parsetree and that this is for a DROP EXTENSION */
	trigdata = (EventTriggerData *) fcinfo->context;
	if (trigdata->parsetree == NULL)
	{
		elog(LOG, "lo_on_drop_extension(): parsetree = NULL");
		PG_RETURN_NULL();
	}

	/*
	 * Check that this is DROP EXTENSION lolor
	 */
	if (!IsA(trigdata->parsetree, DropStmt))
	{
		elog(WARNING, "lo_on_drop_extension(): not a DropStmt");
		PG_RETURN_NULL();
	}
	dropstmt = (DropStmt *)trigdata->parsetree;
	if (dropstmt->removeType != OBJECT_EXTENSION)
	{
		elog(WARNING, "lo_on_drop_extension(): not a DropStmt for extension");
		PG_RETURN_NULL();
	}
	foreach(lc, dropstmt->objects)
	{
		Node *objname = (Node *) lfirst(lc);
		
		if (strcmp(strVal(objname), "lolor") == 0)
		{
			has_lolor_objs = true;
			break;
		}
	}
	if (!has_lolor_objs)
		PG_RETURN_NULL();

	/*
	 * OK, this is DROP EXTENSION lolor. Rename our own
	 * functions out of the way (they will later be dropped by the
	 * DROP EXTENSION itself, and rename the original PostgreSQL
	 * functions back to what they were.
	 */
	SPI_connect();

	SPI_execute("ALTER FUNCTION pg_catalog.lo_open(oid, int4)"
				" RENAME TO lo_open_to_drop", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_open_orig(oid, int4)"
				" RENAME TO lo_open", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_close(int4)"
				" RENAME TO lo_close_to_drop", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_close_orig(int4)"
				" RENAME TO lo_close", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_creat(integer)"
				" RENAME TO lo_creat_to_drop", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_creat_orig(integer)"
				" RENAME TO lo_creat", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_create(oid)"
				" RENAME TO lo_create_to_drop", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_create_orig(oid)"
				" RENAME TO lo_create", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.loread(integer, integer)"
				" RENAME TO loread_to_drop", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.loread_orig(integer, integer)"
				" RENAME TO loread", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lowrite(integer, bytea)"
				" RENAME TO lowrite_to_drop", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lowrite_orig(integer, bytea)"
				" RENAME TO lowrite", false, 0);


	SPI_execute("ALTER FUNCTION pg_catalog.lo_export(oid, text)"
				" RENAME TO lo_export_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_export_orig(oid, text)"
				" RENAME TO lo_export;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_from_bytea(oid, bytea)"
				" RENAME TO lo_from_bytea_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_from_bytea_orig(oid, bytea)"
				" RENAME TO lo_from_bytea;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_get(oid)"
				" RENAME TO lo_get_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_get_orig(oid)"
				" RENAME TO lo_get;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_get(oid, bigint, integer)"
				" RENAME TO lo_get_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_get_orig(oid, bigint, integer)"
				" RENAME TO lo_get;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_import(text)"
				" RENAME TO lo_import_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_import_orig(text)"
				" RENAME TO lo_import;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_import(text, oid)"
				" RENAME TO lo_import_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_import_orig(text, oid)"
				" RENAME TO lo_import;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_lseek(integer, integer, integer)"
				" RENAME TO lo_lseek_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_lseek_orig(integer, integer, integer)"
				" RENAME TO lo_lseek;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer)"
				" RENAME TO lo_lseek64_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_lseek64_orig(integer, bigint, integer)"
				" RENAME TO lo_lseek64;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_put(oid, bigint, bytea)"
				" RENAME TO lo_put_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_put_orig(oid, bigint, bytea)"
				" RENAME TO lo_put;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_tell(integer)"
				" RENAME TO lo_tell_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_tell_orig(integer)"
				" RENAME TO lo_tell;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_tell64(integer)"
				" RENAME TO lo_tell64_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_tell64_orig(integer)"
				" RENAME TO lo_tell64;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_truncate(integer, integer)"
				" RENAME TO lo_truncate_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_truncate_orig(integer, integer)"
				" RENAME TO lo_truncate;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_truncate64(integer, bigint)"
				" RENAME TO lo_truncate64_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_truncate64_orig(integer, bigint)"
				" RENAME TO lo_truncate64;", false, 0);

	SPI_execute("ALTER FUNCTION pg_catalog.lo_unlink(oid)"
				" RENAME TO lo_unlink_to_drop;", false, 0);
	SPI_execute("ALTER FUNCTION pg_catalog.lo_unlink_orig(oid)"
				" RENAME TO lo_unlink;", false, 0);

	SPI_finish();

	PG_RETURN_NULL();
}
