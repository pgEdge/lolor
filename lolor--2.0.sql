/* contrib/lolor/lolor--2.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION lolor" to load this file. \quit

-- Giving the large object catalogs a replica identity makes the (patched)
-- server log their changes for logical decoding.  They are created without
-- one, like all catalogs, and use their primary keys once they have one.
--
-- ALTER TABLE refuses to touch a system catalog unless allow_system_table_mods
-- is on.  The SET clause turns it on for the duration of the call only, and
-- only works for a superuser, so only a superuser can use this function (it is
-- also not executable by anybody else).  For the same reason the extension is
-- deliberately not marked as trusted.
--
-- The function is idempotent.  Call it again where the setting got lost, for
-- instance after pg_upgrade, which creates extensions without running this
-- script.
CREATE FUNCTION lolor.set_replica_identity(enable boolean)
	RETURNS void
	LANGUAGE plpgsql VOLATILE STRICT
	SET allow_system_table_mods = on
	SET search_path = pg_catalog
	AS $$
DECLARE
	identity text := CASE WHEN enable THEN 'DEFAULT' ELSE 'NOTHING' END;
BEGIN
	EXECUTE format('ALTER TABLE pg_catalog.pg_largeobject REPLICA IDENTITY %s',
				   identity);
	EXECUTE format('ALTER TABLE pg_catalog.pg_largeobject_metadata REPLICA IDENTITY %s',
				   identity);
END
$$;

REVOKE ALL ON FUNCTION lolor.set_replica_identity(boolean) FROM PUBLIC;

-- True if the server is logging changes to the large object catalogs.
CREATE FUNCTION lolor.replication_enabled()
	RETURNS boolean
	LANGUAGE sql STABLE PARALLEL SAFE
	SET search_path = pg_catalog
	AS $$
		SELECT coalesce(bool_and(relreplident <> 'n'), false)
		FROM pg_class
		WHERE oid IN ('pg_catalog.pg_largeobject'::regclass,
					  'pg_catalog.pg_largeobject_metadata'::regclass)
	$$;

-- There is no uninstall script, so use an event trigger to switch logging off
-- again when the extension is dropped.  It has to be written in C: only a C
-- trigger sees the statement, and so can tell which extension is being
-- dropped.  All it does is call lolor.set_replica_identity(false).
CREATE FUNCTION lolor.on_drop_extension()
	RETURNS event_trigger
	AS 'MODULE_PATHNAME', 'lolor_on_drop_extension'
	LANGUAGE C VOLATILE;

CREATE EVENT TRIGGER lolor_on_drop_extension
	ON ddl_command_start WHEN tag IN ('DROP EXTENSION')
	EXECUTE FUNCTION lolor.on_drop_extension();
ALTER EVENT TRIGGER lolor_on_drop_extension ENABLE ALWAYS;

SELECT lolor.set_replica_identity(true);
