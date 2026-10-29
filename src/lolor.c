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
#include "lib/stringinfo.h"
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

/*
 * Close large object descriptors at end of transaction.
 *
 * The commit-side work runs on the pre-commit events, before the commit
 * record is written, where core does its own AtEOXact_LargeObject(true).
 * After the commit record any error is a PANIC, since the transaction can no
 * longer abort; before it, an error is an ordinary abort.
 */
static void
lolor_xact_callback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_PRE_COMMIT:
		case XACT_EVENT_PARALLEL_PRE_COMMIT:
		case XACT_EVENT_PRE_PREPARE:
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
 * lolor_namespace_oid
 *
 *	OID of the lolor schema; it exists whenever the extension does.
 */
static Oid
lolor_namespace_oid(void)
{
	return get_namespace_oid(EXTENSION_NAME, false);
}

/*
 * lolor_schema_owner
 *
 *	Owner of the lolor schema, or InvalidOid when it does not exist.  It is
 *	the extension owner unless someone ran ALTER SCHEMA lolor OWNER TO.
 */
static Oid
lolor_schema_owner(void)
{
	Oid			nspoid = get_namespace_oid(EXTENSION_NAME, true);
	HeapTuple	tup;
	Oid			owner;

	if (!OidIsValid(nspoid))
		return InvalidOid;

	tup = SearchSysCache1(NAMESPACEOID, ObjectIdGetDatum(nspoid));
	if (!HeapTupleIsValid(tup))
		return InvalidOid;
	owner = ((Form_pg_namespace) GETSTRUCT(tup))->nspowner;
	ReleaseSysCache(tup);

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

	/*
	 * From the hook the dropper already holds AccessExclusiveLock; from the
	 * event trigger nothing is locked yet.  AccessShareLock is right for
	 * both.
	 */
	rel = table_open(relid, AccessShareLock);
	scan = systable_beginscan(rel, InvalidOid, false, NULL, 0, NULL);
	while (HeapTupleIsValid(systable_getnext(scan)))
		count++;
	systable_endscan(scan);
	table_close(rel, AccessShareLock);

	if (count > 0)
		ereport(ERROR,
				(errcode(ERRCODE_DEPENDENT_OBJECTS_STILL_EXIST),
				 errmsg_plural("cannot drop lolor storage while it holds %lld large object",
							   "cannot drop lolor storage while it holds %lld large objects",
							   (unsigned long) count, (long long) count),
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
static bool
lolor_orig_functions_present(void)
{
	Oid			argtypes[2] = {OIDOID, INT4OID};

	return SearchSysCacheExists3(PROCNAMEARGSNSP,
								 CStringGetDatum("lo_open_orig"),
								 PointerGetDatum(buildoidvector(argtypes, 2)),
								 ObjectIdGetDatum(PG_CATALOG_NAMESPACE));
}

static void
lolor_extension_drop_check(Oid extoid)
{
	if (extoid != get_extension_oid(EXTENSION_NAME, true))
		return;

	if (lolor_orig_functions_present())
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("cannot drop extension \"%s\" while it is enabled",
						EXTENSION_NAME),
				 errdetail("The native large object functions are still parked under their *_orig names."),
				 errhint("Run lolor.disable() first.")));
}

/*
 * lolor_own_table
 *
 *	Is relid one of the extension's two tables?  A same-named table in a
 *	squatted schema is not.
 */
static bool
lolor_own_table(Oid relid)
{
	Oid			nspoid;
	Oid			extoid;

	nspoid = get_namespace_oid(EXTENSION_NAME, true);
	if (!OidIsValid(nspoid) ||
		(get_relname_relid(LOLOR_LARGEOBJECT_METADATA, nspoid) != relid &&
		 get_relname_relid(LOLOR_LARGEOBJECT_CATALOG, nspoid) != relid))
		return false;

	extoid = get_extension_oid(EXTENSION_NAME, true);
	return OidIsValid(extoid) &&
		getExtensionOfObject(RelationRelationId, relid) == extoid;
}

/*
 * lolor_replication_drop_check
 *
 *	Refuse to remove lolor while its tables are replicated.
 *
 *	Dropping a table out from under a publication, a subscription or a spock
 *	replication set does not fail; what fails is everything afterwards.  The
 *	other side keeps sending rows for a table this node no longer has and its
 *	apply worker errors for good, or a subscription goes with DROP OWNED BY
 *	and leaves its slot behind holding WAL.  Name the memberships and let the
 *	operator take the tables out first.
 *
 *	With spock the memberships are kept on the provider, so on a subscriber
 *	the tables show only in local_sync_status, as synchronized through a
 *	subscription; a table added to a set after the initial sync has no row
 *	there.
 *
 *	The event trigger calls this for its message, before anything is renamed;
 *	the object access hook enforces it, since the trigger can be disabled or
 *	skipped with event_triggers off, and a table can be dropped on its own
 *	once taken out of the extension.  The hook runs before any object is
 *	deleted, so the memberships are still there to be found.
 */
static void
lolor_replication_drop_check(void)
{
	StringInfoData query;
	int			ret;
	bool		isnull;
	Datum		members;

	initStringInfo(&query);
	appendStringInfo(&query,
					 "SELECT pg_catalog.string_agg(what, ', ' ORDER BY what) FROM ("
					 " SELECT 'publication ' || pg_catalog.quote_ident(p.pubname) AS what"
					 "   FROM pg_catalog.pg_publication_rel pr"
					 "   JOIN pg_catalog.pg_publication p ON p.oid = pr.prpubid"
					 "   JOIN pg_catalog.pg_class c ON c.oid = pr.prrelid"
					 "  WHERE c.relnamespace = %u"
					 " UNION"
					 " SELECT 'publication ' || pg_catalog.quote_ident(p.pubname)"
					 "   FROM pg_catalog.pg_publication_namespace pn"
					 "   JOIN pg_catalog.pg_publication p ON p.oid = pn.pnpubid"
					 "  WHERE pn.pnnspid = %u"
					 " UNION"
					 " SELECT 'subscription ' || pg_catalog.quote_ident(s.subname)"
					 "   FROM pg_catalog.pg_subscription_rel sr"
					 "   JOIN pg_catalog.pg_subscription s ON s.oid = sr.srsubid"
					 "   JOIN pg_catalog.pg_class c ON c.oid = sr.srrelid"
					 "  WHERE c.relnamespace = %u",
					 lolor_namespace_oid(), lolor_namespace_oid(),
					 lolor_namespace_oid());

	/* spock keeps its own catalog; look only when it is installed. */
	if (OidIsValid(get_extension_oid("spock", true)))
		appendStringInfo(&query,
						 " UNION"
						 " SELECT 'replication set ' || pg_catalog.quote_ident(rs.set_name)"
						 "   FROM spock.replication_set_table rst"
						 "   JOIN spock.replication_set rs ON rs.set_id = rst.set_id"
						 "   JOIN pg_catalog.pg_class c ON c.oid = rst.set_reloid"
						 "  WHERE c.relnamespace = %u"
						 " UNION"
						 " SELECT 'subscription ' || pg_catalog.quote_ident(s.sub_name)"
						 "   FROM spock.local_sync_status l"
						 "   JOIN spock.subscription s ON s.sub_id = l.sync_subid"
						 "  WHERE l.sync_nspname = %s",
						 lolor_namespace_oid(),
						 quote_literal_cstr(EXTENSION_NAME));

	appendStringInfoString(&query, ") x");

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed");

	ret = SPI_execute(query.data, true, 1);
	if (ret != SPI_OK_SELECT || SPI_processed != 1)
		elog(ERROR, "could not look up replication memberships: %s",
			 SPI_result_code_string(ret));

	members = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
							1, &isnull);
	if (!isnull)
	{
		char	   *list = TextDatumGetCString(members);

		ereport(ERROR,
				(errcode(ERRCODE_DEPENDENT_OBJECTS_STILL_EXIST),
				 errmsg("cannot drop lolor while its tables are replicated"),
				 errdetail("The lolor tables are part of %s.", list),
				 errhint("Remove them from the replication set, publication or subscription first.")));
	}

	SPI_finish();
	pfree(query.data);
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
		{
			if (lolor_own_table(objectId))
				lolor_replication_drop_check();
			lolor_storage_drop_check(objectId);
		}
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
 *	through DROP SCHEMA lolor CASCADE and DROP OWNED BY the extension or
 *	schema owner, which reach it by dependency cascade rather than by naming
 *	it.  Missing one
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
		Oid			nspowner = lolor_schema_owner();

		if (!OidIsValid(extowner))
			return false;

		/*
		 * The extension goes with its owner.  It also goes with the schema's
		 * owner, when ALTER SCHEMA lolor OWNER TO moved the schema to another
		 * role, but only under CASCADE: a plain DROP OWNED cannot remove a
		 * schema that still holds the extension and is rejected anyway.
		 */
		foreach(lc, stmt->roles)
		{
			RoleSpec   *rolespec = lfirst_node(RoleSpec, lc);
			Oid			roleid = get_rolespec_oid(rolespec, true);

			if (roleid == extowner ||
				(OidIsValid(nspowner) && roleid == nspowner &&
				 stmt->behavior == DROP_CASCADE))
				return true;
		}

		return false;
	}

	return false;
}

/*
 * lolor_on_drop_extension
 *
 *	The install script replaces the pg_catalog large object functions by
 *	renaming the built-in ones to <funcname>_orig and creating ours under
 *	the original names.  PostgreSQL has no uninstall script, so the renames
 *	are undone here, from an event trigger on ddl_command_start, which is
 *	the only kind that still sees the command before anything is dropped.
 *
 *	Only the function names are restored.  Objects still in lolor storage
 *	are not migrated here: moving data from inside a DROP is fragile, and
 *	the object access hook refuses the drop while any remain, so the user
 *	runs lolor.migrate_to_native() first.
 */
Datum
lolor_on_drop_extension(PG_FUNCTION_ARGS)
{
	EventTriggerData *trigdata;

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
	 * lolor.allow_unsafe_drop means drop no matter what: the object access
	 * hook lets the extension go, and nothing is checked or renamed here
	 * either.  Say so if that leaves the native names parked.
	 */
	if (lolor_allow_unsafe_drop)
	{
		if (lolor_orig_functions_present())
			ereport(WARNING,
					(errmsg("lolor.allow_unsafe_drop is on: the native large object function names are not restored"),
					 errhint("Rename the pg_catalog.lo_*_orig functions back by hand, or run lolor.disable() before the drop.")));
		PG_RETURN_NULL();
	}

	/*
	 * Replication first: while the tables are replicated the migration that
	 * would empty them is refused as well, so that is the blocker to name.
	 */
	lolor_replication_drop_check();

	/*
	 * The hook refuses the drop while lolor storage holds objects, but only
	 * when the table itself is deleted, after this trigger has run.  Check it
	 * here too, with the hook's own message, so that a refused drop renames
	 * nothing and names the real blocker.
	 */
	lolor_storage_drop_check(get_LOLOR_LargeObjectMetadataRelationId());

	SPI_connect();
	/*
	 * disable() renames the native functions back.  That has the same
	 * requirements whether the user calls it or the drop does: no other
	 * session may be connected, because a renamed function keeps its OID and
	 * other sessions keep calling the previous implementation, and it has to
	 * run from a client session.  Check them here first, under the drop's own
	 * name, so that the refusal says what was refused.  A disabled lolor
	 * renames nothing, so the check only applies while it is enabled.  The
	 * helper exists from 1.3.0; dropping an older installed version runs that
	 * version's disable(), which has no such requirement.
	 */
	if (SPI_execute("SELECT 1 FROM pg_proc p "
					"JOIN pg_namespace n ON n.oid = p.pronamespace "
					"WHERE n.nspname = 'lolor' "
					"AND p.proname = '_require_no_other_sessions'",
					true, 1) == SPI_OK_SELECT &&
		SPI_processed > 0)
		SPI_execute("SELECT CASE WHEN lolor.is_enabled() THEN "
					"lolor._require_no_other_sessions("
					"'drop the lolor extension') END",
					false, 0);

	SPI_execute("SELECT CASE WHEN lolor.is_enabled() "
				"THEN lolor.disable() ELSE true END",
				false, 0);
	SPI_finish();

	PG_RETURN_NULL();
}
