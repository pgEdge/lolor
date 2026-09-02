/*-------------------------------------------------------------------------
 * lolor_utility.c
 *	  ProcessUtility_hook implementation for lolor extension.
 *	  Supports ALTER, COMMENT, GRANT, and REVOKE on large objects.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	contrib/lolor/src/lolor_utility.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/genam.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "catalog/catalog.h"
#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/objectaccess.h"
#include "catalog/objectaddress.h"
#include "catalog/pg_authid.h"
#include "catalog/pg_class.h"
#include "catalog/pg_largeobject.h"
#include "catalog/pg_largeobject_metadata.h"
#include "catalog/pg_shdepend.h"
#include "commands/comment.h"
#include "commands/event_trigger.h"
#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "tcop/utility.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/syscache.h"

#include "lolor.h"

static ProcessUtility_hook_type prev_ProcessUtility_hook = NULL;

static void lolor_alter_large_object_owner(AlterOwnerStmt *stmt, QueryCompletion *qc);
static void lolor_comment_large_object(CommentStmt *stmt, QueryCompletion *qc);
static void lolor_grant_large_object(GrantStmt *stmt, QueryCompletion *qc);
static bool lolor_is_installed(void);
static bool lolor_role_is_referenced(Oid roleid);
static AclMode lolor_string_to_privilege(const char *privname);
static AclMode lolor_restrict_and_check_grant(bool is_grant, AclMode avail_goptions,
											  bool all_privs, AclMode privileges,
											  Oid objectId, Oid grantorId,
											  Oid ownerId, Acl *old_acl,
											  const char *objname);
static Acl *lolor_merge_acl_with_grant(Acl *old_acl, bool is_grant,
									   bool grant_option, DropBehavior behavior,
									   List *grantees, AclMode privileges,
									   Oid grantorId, Oid ownerId);

static void lolor_ProcessUtility(PlannedStmt *pstmt,
								 const char *queryString,
								 bool readOnlyTree,
								 ProcessUtilityContext context,
								 ParamListInfo params,
								 QueryEnvironment *queryEnv,
								 DestReceiver *dest,
								 QueryCompletion *qc);

PG_FUNCTION_INFO_V1(lolor_cleanup_dependencies);

/*
 * Initialize ProcessUtility hook.
 */
void
lolor_utility_init(void)
{
	prev_ProcessUtility_hook = ProcessUtility_hook;
	ProcessUtility_hook = lolor_ProcessUtility;
}

/*
 * Teardown ProcessUtility hook.
 */
void
lolor_utility_fini(void)
{
	ProcessUtility_hook = prev_ProcessUtility_hook;
}

/*
 * Check if the lolor extension is installed in the current database.
 */
static bool
lolor_is_installed(void)
{
	Oid			nspoid = get_namespace_oid(EXTENSION_NAME, true);

	if (!OidIsValid(nspoid))
		return false;
	if (get_relname_relid(LOLOR_LARGEOBJECT_METADATA, nspoid) == InvalidOid)
		return false;
	return true;
}

/*
 * Record a shared dependency on a role for lolor.pg_largeobject_metadata.
 *
 * To avoid catalog bloat in pg_shdepend, we record at most ONE entry per role
 * across all large objects owned by or granted to that role.
 */
void
lolor_record_role_dependency(Oid roleid)
{
	Relation	sdepRel;
	ScanKeyData key[4];
	SysScanDesc scan;
	HeapTuple	tup;
	bool		found = false;
	Oid			metaRelId;

	if (!OidIsValid(roleid) || roleid == ACL_ID_PUBLIC ||
		IsPinnedObject(AuthIdRelationId, roleid))
		return;

	if (!lolor_is_installed())
		return;

	metaRelId = get_LOLOR_LargeObjectMetadataRelationId();
	if (!OidIsValid(metaRelId))
		return;

	sdepRel = table_open(SharedDependRelationId, RowExclusiveLock);

	ScanKeyInit(&key[0],
				Anum_pg_shdepend_dbid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(MyDatabaseId));
	ScanKeyInit(&key[1],
				Anum_pg_shdepend_classid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(RelationRelationId));
	ScanKeyInit(&key[2],
				Anum_pg_shdepend_objid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(metaRelId));
	ScanKeyInit(&key[3],
				Anum_pg_shdepend_objsubid,
				BTEqualStrategyNumber, F_INT4EQ,
				Int32GetDatum(0));

	scan = systable_beginscan(sdepRel, SharedDependDependerIndexId, true,
							  NULL, 4, key);
	while ((tup = systable_getnext(scan)) != NULL)
	{
		Form_pg_shdepend shForm = (Form_pg_shdepend) GETSTRUCT(tup);

		if (shForm->refclassid == AuthIdRelationId && shForm->refobjid == roleid)
		{
			found = true;
			break;
		}
	}
	systable_endscan(scan);

	if (!found)
	{
		ObjectAddress depender,
					referenced;

		depender.classId = RelationRelationId;
		depender.objectId = metaRelId;
		depender.objectSubId = 0;

		referenced.classId = AuthIdRelationId;
		referenced.objectId = roleid;
		referenced.objectSubId = 0;

		recordSharedDependencyOn(&depender, &referenced, SHARED_DEPENDENCY_OWNER);
	}

	table_close(sdepRel, RowExclusiveLock);
}

/*
 * Helper to check if a role is still referenced in lolor.pg_largeobject_metadata,
 * either as an owner (lomowner) or within an ACL (lomacl).
 */
static bool
lolor_role_is_referenced(Oid roleid)
{
	Relation	metaRel;
	TableScanDesc scan;
	HeapTuple	tup;
	bool		found = false;

	metaRel = table_open(get_LOLOR_LargeObjectMetadataRelationId(), AccessShareLock);
	scan = table_beginscan_catalog(metaRel, 0, NULL);

	while ((tup = heap_getnext(scan, ForwardScanDirection)) != NULL)
	{
		Form_pg_largeobject_metadata meta = (Form_pg_largeobject_metadata) GETSTRUCT(tup);
		Datum		aclDatum;
		bool		isNull;

		if (meta->lomowner == roleid)
		{
			found = true;
			break;
		}

		aclDatum = heap_getattr(tup, Anum_pg_largeobject_metadata_lomacl,
								RelationGetDescr(metaRel), &isNull);
		if (!isNull)
		{
			Acl		   *acl = DatumGetAclP(aclDatum);
			int			nmembers;
			Oid		   *members;

			nmembers = aclmembers(acl, &members);
			for (int i = 0; i < nmembers; i++)
			{
				if (members[i] == roleid)
				{
					found = true;
					break;
				}
			}
			if (members)
				pfree(members);
			if (found)
				break;
		}
	}

	table_endscan(scan);
	table_close(metaRel, AccessShareLock);

	return found;
}

/*
 * SQL-callable function: lolor.cleanup_dependencies()
 *
 * Removes pg_shdepend records on lolor.pg_largeobject_metadata for roles
 * that no longer own or have privileges on any lolor large objects.
 * Returns the number of dependency entries removed.
 */
Datum
lolor_cleanup_dependencies(PG_FUNCTION_ARGS)
{
	Relation	sdepRel;
	ScanKeyData key[4];
	SysScanDesc scan;
	HeapTuple	tup;
	int			deleted_count = 0;
	Oid			metaRelId;
	List	   *roles_to_check = NIL;
	ListCell   *lc;

	if (!lolor_is_installed())
		PG_RETURN_INT32(0);

	metaRelId = get_LOLOR_LargeObjectMetadataRelationId();
	sdepRel = table_open(SharedDependRelationId, RowExclusiveLock);

	ScanKeyInit(&key[0],
				Anum_pg_shdepend_dbid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(MyDatabaseId));
	ScanKeyInit(&key[1],
				Anum_pg_shdepend_classid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(RelationRelationId));
	ScanKeyInit(&key[2],
				Anum_pg_shdepend_objid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(metaRelId));
	ScanKeyInit(&key[3],
				Anum_pg_shdepend_objsubid,
				BTEqualStrategyNumber, F_INT4EQ,
				Int32GetDatum(0));

	scan = systable_beginscan(sdepRel, SharedDependDependerIndexId, true,
							  NULL, 4, key);
	while ((tup = systable_getnext(scan)) != NULL)
	{
		Form_pg_shdepend shForm = (Form_pg_shdepend) GETSTRUCT(tup);

		if (shForm->refclassid == AuthIdRelationId)
			roles_to_check = lappend_oid(roles_to_check, shForm->refobjid);
	}
	systable_endscan(scan);

	foreach(lc, roles_to_check)
	{
		Oid			roleid = lfirst_oid(lc);

		if (!lolor_role_is_referenced(roleid))
		{
			SysScanDesc dropscan;
			HeapTuple	droptup;

			dropscan = systable_beginscan(sdepRel, SharedDependDependerIndexId, true,
										  NULL, 4, key);
			while ((droptup = systable_getnext(dropscan)) != NULL)
			{
				Form_pg_shdepend shForm = (Form_pg_shdepend) GETSTRUCT(droptup);

				if (shForm->refclassid == AuthIdRelationId &&
					shForm->refobjid == roleid)
				{
					CatalogTupleDelete(sdepRel, &droptup->t_self);
					deleted_count++;
				}
			}
			systable_endscan(dropscan);
		}
	}

	table_close(sdepRel, RowExclusiveLock);

	PG_RETURN_INT32(deleted_count);
}

/*
 * Handle ALTER LARGE OBJECT <oid> OWNER TO <new_owner>
 */
static void
lolor_alter_large_object_owner(AlterOwnerStmt *stmt, QueryCompletion *qc)
{
	Oid			loid = oidparse(stmt->object);
	Oid			new_ownerId = get_rolespec_oid(stmt->newowner, false);
	Relation	rel;
	ScanKeyData skey[1];
	SysScanDesc scan;
	HeapTuple	tuple;
	Form_pg_largeobject_metadata form;
	Oid			old_ownerId;
	Datum		values[Natts_pg_largeobject_metadata];
	bool		nulls[Natts_pg_largeobject_metadata];
	bool		replaces[Natts_pg_largeobject_metadata];
	Datum		aclDatum;
	bool		isNull;
	HeapTuple	newtup;
	ObjectAddress address;

	if (!LOLOR_LargeObjectExists(loid))
	{
		if (oldlo_exists(loid, NULL))
		{
			if (!oldlo_migrate_one(loid))
				ereport(ERROR,
						(errcode(ERRCODE_UNDEFINED_OBJECT),
						 errmsg("large object %u does not exist", loid)));
		}
		else
		{
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_OBJECT),
					 errmsg("large object %u does not exist", loid)));
		}
	}

	rel = table_open(get_LOLOR_LargeObjectMetadataRelationId(), RowExclusiveLock);

	ScanKeyInit(&skey[0],
				Anum_pg_largeobject_metadata_oid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(loid));

	scan = systable_beginscan(rel, get_LOLOR_LargeObjectMetadataOidIndexId(), true,
							  NULL, 1, skey);
	tuple = systable_getnext(scan);
	if (!HeapTupleIsValid(tuple))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("large object %u does not exist", loid)));

	form = (Form_pg_largeobject_metadata) GETSTRUCT(tuple);
	old_ownerId = form->lomowner;

	if (!superuser())
	{
		if (!has_privs_of_role(GetUserId(), old_ownerId))
			aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_LARGEOBJECT, psprintf("%u", loid));
		check_can_set_role(GetUserId(), new_ownerId);
	}

	if (old_ownerId != new_ownerId)
	{
		memset(values, 0, sizeof(values));
		memset(nulls, false, sizeof(nulls));
		memset(replaces, false, sizeof(replaces));

		values[Anum_pg_largeobject_metadata_lomowner - 1] = ObjectIdGetDatum(new_ownerId);
		replaces[Anum_pg_largeobject_metadata_lomowner - 1] = true;

		aclDatum = heap_getattr(tuple, Anum_pg_largeobject_metadata_lomacl,
								RelationGetDescr(rel), &isNull);
		if (!isNull)
		{
			Acl		   *old_acl = DatumGetAclP(aclDatum);
			Acl		   *new_acl = aclnewowner(old_acl, old_ownerId, new_ownerId);

			values[Anum_pg_largeobject_metadata_lomacl - 1] = PointerGetDatum(new_acl);
			replaces[Anum_pg_largeobject_metadata_lomacl - 1] = true;
		}

		newtup = heap_modify_tuple(tuple, RelationGetDescr(rel), values, nulls, replaces);
		CatalogTupleUpdate(rel, &newtup->t_self, newtup);

		lolor_record_role_dependency(new_ownerId);
	}

	systable_endscan(scan);
	table_close(rel, RowExclusiveLock);

	InvokeObjectPostAlterHook(LargeObjectRelationId, loid, 0);
	CommandCounterIncrement();

	ObjectAddressSet(address, LargeObjectRelationId, loid);
	EventTriggerCollectSimpleCommand(address, InvalidObjectAddress, (Node *) stmt);

	if (qc)
		SetQueryCompletion(qc, CMDTAG_ALTER_LARGE_OBJECT, 0);
}

/*
 * Handle COMMENT ON LARGE OBJECT <oid> IS <comment>
 */
static void
lolor_comment_large_object(CommentStmt *stmt, QueryCompletion *qc)
{
	Oid			loid = oidparse(stmt->object);
	bool		in_lolor = LOLOR_LargeObjectExists(loid);
	bool		in_native = !in_lolor && oldlo_exists(loid, NULL);
	ObjectAddress address;

	if (!in_lolor && !in_native)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("large object %u does not exist", loid)));

	if (!superuser())
	{
		if (in_lolor)
		{
			if (!lolor_object_ownercheck(get_LOLOR_LargeObjectMetadataRelationId(),
										 loid, GetUserId()))
				aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_LARGEOBJECT, psprintf("%u", loid));
		}
		else
		{
			if (!oldlo_ownercheck(loid, GetUserId()))
				aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_LARGEOBJECT, psprintf("%u", loid));
		}
	}

	CreateComments(loid, LargeObjectRelationId, 0, stmt->comment);

	ObjectAddressSet(address, LargeObjectRelationId, loid);
	EventTriggerCollectSimpleCommand(address, InvalidObjectAddress, (Node *) stmt);

	if (qc)
		SetQueryCompletion(qc, CMDTAG_COMMENT, 0);
}

/*
 * Restrict privileges to what the grantor can actually grant/revoke,
 * and emit standard PostgreSQL warnings.
 */
static AclMode
lolor_restrict_and_check_grant(bool is_grant, AclMode avail_goptions, bool all_privs,
							   AclMode privileges, Oid objectId, Oid grantorId,
							   Oid ownerId, Acl *old_acl, const char *objname)
{
	AclMode		this_privileges;
	AclMode		whole_mask = ACL_ALL_RIGHTS_LARGEOBJECT;

	if (avail_goptions == ACL_NO_RIGHTS)
	{
		if (aclmask(old_acl, grantorId, ownerId,
					whole_mask | ACL_GRANT_OPTION_FOR(whole_mask),
					ACLMASK_ANY) == ACL_NO_RIGHTS)
		{
			aclcheck_error(ACLCHECK_NO_PRIV, OBJECT_LARGEOBJECT, objname);
		}
	}

	this_privileges = privileges & ACL_OPTION_TO_PRIVS(avail_goptions);
	if (is_grant)
	{
		if (this_privileges == 0)
		{
			ereport(WARNING,
					(errcode(ERRCODE_WARNING_PRIVILEGE_NOT_GRANTED),
					 errmsg("no privileges were granted for \"%s\"", objname)));
		}
		else if (!all_privs && this_privileges != privileges)
		{
			ereport(WARNING,
					(errcode(ERRCODE_WARNING_PRIVILEGE_NOT_GRANTED),
					 errmsg("not all privileges were granted for \"%s\"", objname)));
		}
	}
	else
	{
		if (this_privileges == 0)
		{
			ereport(WARNING,
					(errcode(ERRCODE_WARNING_PRIVILEGE_NOT_REVOKED),
					 errmsg("no privileges could be revoked for \"%s\"", objname)));
		}
		else if (!all_privs && this_privileges != privileges)
		{
			ereport(WARNING,
					(errcode(ERRCODE_WARNING_PRIVILEGE_NOT_REVOKED),
					 errmsg("not all privileges could be revoked for \"%s\"", objname)));
		}
	}

	return this_privileges;
}

/*
 * Merge privileges with existing ACL.
 */
static Acl *
lolor_merge_acl_with_grant(Acl *old_acl, bool is_grant,
						   bool grant_option, DropBehavior behavior,
						   List *grantees, AclMode privileges,
						   Oid grantorId, Oid ownerId)
{
	unsigned	modechg = is_grant ? ACL_MODECHG_ADD : ACL_MODECHG_DEL;
	ListCell   *j;
	Acl		   *new_acl = old_acl;

	foreach(j, grantees)
	{
		AclItem		aclitem;
		Acl		   *newer_acl;

		aclitem.ai_grantee = lfirst_oid(j);

		if (is_grant && grant_option && aclitem.ai_grantee == ACL_ID_PUBLIC)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_GRANT_OPERATION),
					 errmsg("grant options can only be granted to roles")));

		aclitem.ai_grantor = grantorId;

		ACLITEM_SET_PRIVS_GOPTIONS(aclitem,
								   (is_grant || !grant_option) ? privileges : ACL_NO_RIGHTS,
								   (!is_grant || grant_option) ? privileges : ACL_NO_RIGHTS);

		newer_acl = aclupdate(new_acl, &aclitem, modechg, ownerId, behavior);

		pfree(new_acl);
		new_acl = newer_acl;
	}

	return new_acl;
}

static AclMode
lolor_string_to_privilege(const char *privname)
{
	if (strcmp(privname, "select") == 0)
		return ACL_SELECT;
	if (strcmp(privname, "update") == 0)
		return ACL_UPDATE;
	ereport(ERROR,
			(errcode(ERRCODE_INVALID_GRANT_OPERATION),
			 errmsg("invalid privilege type \"%s\" for large object", privname)));
	return 0;
}

/*
 * Handle GRANT and REVOKE on LARGE OBJECT
 */
static void
lolor_grant_large_object(GrantStmt *stmt, QueryCompletion *qc)
{
	ListCell   *cell;
	List	   *grantee_ids = NIL;
	bool		all_privs;
	AclMode		privileges = ACL_NO_RIGHTS;
	InternalGrant istmt;

	/* Parse grantees */
	foreach(cell, stmt->grantees)
	{
		RoleSpec   *grantee = (RoleSpec *) lfirst(cell);
		Oid			grantee_uid;

		switch (grantee->roletype)
		{
			case ROLESPEC_PUBLIC:
				grantee_uid = ACL_ID_PUBLIC;
				break;
			default:
				grantee_uid = get_rolespec_oid(grantee, false);
				break;
		}
		grantee_ids = lappend_oid(grantee_ids, grantee_uid);
	}

	/* Parse privileges */
	if (stmt->privileges == NIL)
	{
		all_privs = true;
		privileges = ACL_NO_RIGHTS;
	}
	else
	{
		all_privs = false;
		foreach(cell, stmt->privileges)
		{
			AccessPriv *privnode = (AccessPriv *) lfirst(cell);
			AclMode		priv;

			if (privnode->cols)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_GRANT_OPERATION),
						 errmsg("column privileges are only valid for relations")));

			if (privnode->priv_name == NULL)
				elog(ERROR, "AccessPriv node must specify privilege or columns");

			priv = lolor_string_to_privilege(privnode->priv_name);
			privileges |= priv;
		}
	}

	istmt.is_grant = stmt->is_grant;
	istmt.objtype = stmt->objtype;
	istmt.objects = NIL;
	istmt.all_privs = all_privs;
	istmt.privileges = privileges;
	istmt.col_privs = NIL;
	istmt.grantees = grantee_ids;
	istmt.grant_option = stmt->grant_option;
	istmt.grantor = stmt->grantor;
	istmt.behavior = stmt->behavior;

	/* For each target large object */
	foreach(cell, stmt->objects)
	{
		Oid			loid = oidparse((Node *) lfirst(cell));
		Relation	rel;
		ScanKeyData skey[1];
		SysScanDesc scan;
		HeapTuple	tuple;
		Form_pg_largeobject_metadata form;
		Oid			ownerId;
		Datum		aclDatum;
		bool		isNull;
		Acl		   *old_acl;
		Oid			grantorId;
		AclMode		avail_goptions;
		AclMode		this_privileges;
		Acl		   *new_acl;
		Datum		values[Natts_pg_largeobject_metadata];
		bool		nulls[Natts_pg_largeobject_metadata];
		bool		replaces[Natts_pg_largeobject_metadata];
		HeapTuple	newtup;
		char		objname[NAMEDATALEN];

		if (!LOLOR_LargeObjectExists(loid))
		{
			if (oldlo_exists(loid, NULL))
			{
				if (!oldlo_migrate_one(loid))
					ereport(ERROR,
							(errcode(ERRCODE_UNDEFINED_OBJECT),
							 errmsg("large object %u does not exist", loid)));
			}
			else
			{
				ereport(ERROR,
						(errcode(ERRCODE_UNDEFINED_OBJECT),
						 errmsg("large object %u does not exist", loid)));
			}
		}

		istmt.objects = lappend_oid(istmt.objects, loid);

		rel = table_open(get_LOLOR_LargeObjectMetadataRelationId(), RowExclusiveLock);

		ScanKeyInit(&skey[0],
					Anum_pg_largeobject_metadata_oid,
					BTEqualStrategyNumber, F_OIDEQ,
					ObjectIdGetDatum(loid));

		scan = systable_beginscan(rel, get_LOLOR_LargeObjectMetadataOidIndexId(), true,
								  NULL, 1, skey);
		tuple = systable_getnext(scan);
		if (!HeapTupleIsValid(tuple))
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_OBJECT),
					 errmsg("large object %u does not exist", loid)));

		form = (Form_pg_largeobject_metadata) GETSTRUCT(tuple);
		ownerId = form->lomowner;

		aclDatum = heap_getattr(tuple, Anum_pg_largeobject_metadata_lomacl,
								RelationGetDescr(rel), &isNull);
		if (isNull)
			old_acl = acldefault(OBJECT_LARGEOBJECT, ownerId);
		else
			old_acl = DatumGetAclPCopy(aclDatum);

		select_best_grantor(stmt->grantor, privileges, old_acl, ownerId,
							&grantorId, &avail_goptions);

		snprintf(objname, sizeof(objname), "large object %u", loid);
		this_privileges = lolor_restrict_and_check_grant(stmt->is_grant, avail_goptions,
														 all_privs, privileges,
														 loid, grantorId,
														 ownerId, old_acl, objname);

		new_acl = lolor_merge_acl_with_grant(old_acl, stmt->is_grant,
											 stmt->grant_option, stmt->behavior,
											 grantee_ids, this_privileges,
											 grantorId, ownerId);

		memset(values, 0, sizeof(values));
		memset(nulls, false, sizeof(nulls));
		memset(replaces, false, sizeof(replaces));

		values[Anum_pg_largeobject_metadata_lomacl - 1] = PointerGetDatum(new_acl);
		replaces[Anum_pg_largeobject_metadata_lomacl - 1] = true;

		newtup = heap_modify_tuple(tuple, RelationGetDescr(rel), values, nulls, replaces);
		CatalogTupleUpdate(rel, &newtup->t_self, newtup);

		if (stmt->is_grant)
		{
			ListCell   *gc;

			foreach(gc, grantee_ids)
			{
				Oid			uid = lfirst_oid(gc);

				lolor_record_role_dependency(uid);
			}
		}

		systable_endscan(scan);
		table_close(rel, RowExclusiveLock);

		CommandCounterIncrement();
	}

	EventTriggerCollectGrant(&istmt);

	if (qc)
		SetQueryCompletion(qc, stmt->is_grant ? CMDTAG_GRANT : CMDTAG_REVOKE, 0);
}

/*
 * ProcessUtility hook function.
 */
static void
lolor_ProcessUtility(PlannedStmt *pstmt,
					 const char *queryString,
					 bool readOnlyTree,
					 ProcessUtilityContext context,
					 ParamListInfo params,
					 QueryEnvironment *queryEnv,
					 DestReceiver *dest,
					 QueryCompletion *qc)
{
	Node	   *parsetree = pstmt->utilityStmt;

	if (lolor_is_installed())
	{
		if (IsA(parsetree, AlterOwnerStmt))
		{
			AlterOwnerStmt *stmt = (AlterOwnerStmt *) parsetree;

			if (stmt->objectType == OBJECT_LARGEOBJECT)
			{
				lolor_alter_large_object_owner(stmt, qc);
				return;
			}
		}
		else if (IsA(parsetree, CommentStmt))
		{
			CommentStmt *stmt = (CommentStmt *) parsetree;

			if (stmt->objtype == OBJECT_LARGEOBJECT)
			{
				lolor_comment_large_object(stmt, qc);
				return;
			}
		}
		else if (IsA(parsetree, GrantStmt))
		{
			GrantStmt  *stmt = (GrantStmt *) parsetree;

			if (stmt->objtype == OBJECT_LARGEOBJECT)
			{
				lolor_grant_large_object(stmt, qc);
				return;
			}
		}
	}

	if (prev_ProcessUtility_hook)
		(*prev_ProcessUtility_hook) (pstmt, queryString, readOnlyTree,
									 context, params, queryEnv,
									 dest, qc);
	else
		standard_ProcessUtility(pstmt, queryString, readOnlyTree,
								context, params, queryEnv,
								dest, qc);
}
