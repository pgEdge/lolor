/* contrib/lobj_replacement/lobj_replacement--1.1.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION lobj_replacement" to load this file. \quit

-- Replace lo_open()
ALTER FUNCTION pg_catalog.lo_open(Oid, int4)
	RENAME TO lo_open_orig;
CREATE FUNCTION pg_catalog.lo_open(Oid, int4)
	RETURNS pg_catalog.int4
	AS 'MODULE_PATHNAME', 'lobj_replacement_lo_open'
	LANGUAGE C STRICT VOLATILE;

-- Replace lo_close()
ALTER FUNCTION pg_catalog.lo_close(int4)
	RENAME TO lo_close_orig;
CREATE FUNCTION pg_catalog.lo_close(int4)
	RETURNS pg_catalog.int4
	AS 'MODULE_PATHNAME', 'lobj_replacement_lo_close'
	LANGUAGE C STRICT VOLATILE;

-- Create the trigger that will fire on DROP EXTENSION
-- to perform cleanup
CREATE FUNCTION pg_catalog.lo_on_drop_extension()
	RETURNS pg_catalog.event_trigger
	AS 'MODULE_PATHNAME', 'lobj_replacement_on_drop_extension'
	LANGUAGE C VOLATILE;
CREATE EVENT TRIGGER lo_on_drop_extension
	ON ddl_command_start WHEN tag IN ('DROP EXTENSION')
	EXECUTE FUNCTION pg_catalog.lo_on_drop_extension();

