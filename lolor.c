/*
 *	PostgreSQL definitions for Large Objects for logical replication.
 *
 *	contrib/lolor/lolor.c
 *
 */

#include "postgres.h"

#include "fmgr.h"
#include "commands/event_trigger.h"
#include "executor/spi.h"
#include "nodes/parsenodes.h"
#include "nodes/print.h"
#include "utils/builtins.h"
#include "utils/rel.h"

PG_MODULE_MAGIC;


/*
 * Function forward declarations
 */
PG_FUNCTION_INFO_V1(lolor_lo_open);
PG_FUNCTION_INFO_V1(lolor_lo_close);
PG_FUNCTION_INFO_V1(lolor_on_drop_extension);

/*
 * lolor_lo_open - large object open
 */
Datum
lolor_lo_open(PG_FUNCTION_ARGS)
{
	Datum	lobjId = PG_GETARG_DATUM(0);
	Datum	mode = PG_GETARG_DATUM(1);

	elog(LOG, "PGLOTEST - lo_open(%u,0x%x)", 
		 DatumGetObjectId(lobjId), DatumGetInt32(mode));
	return DirectFunctionCall2(be_lo_open, lobjId, mode);
}

/*
 * lolor_lo_close - large object close
 */
Datum
lolor_lo_close(PG_FUNCTION_ARGS)
{
	Datum	lobjFd = PG_GETARG_DATUM(0);

	elog(LOG, "PGLOTEST - lo_close(%d)",
		 DatumGetInt32(lobjFd));
	return DirectFunctionCall1(be_lo_close, lobjFd);
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
		String *objname = (String *)lfirst(lc);
		
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

	SPI_finish();

	PG_RETURN_NULL();
}
