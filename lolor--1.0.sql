/* contrib/lolor/lolor--1.1.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION lolor" to load this file. \quit

-- Replace pg_largeobject
CREATE TABLE lolor.pg_largeobject(
	loid oid NOT NULL,
	pageno int NOT NULL,
	data bytea NOT NULL,
	PRIMARY KEY(loid,pageno));

-- Replace pg_largeobject_metadata
CREATE TABLE lolor.pg_largeobject_metadata(
	oid oid NOT NULL,
	lomowner oid NOT NULL,
	lomacl aclitem[],
	PRIMARY KEY(oid));

-- Replace lo_open()
ALTER FUNCTION pg_catalog.lo_open(Oid, int4)
	RENAME TO lo_open_orig;
CREATE FUNCTION pg_catalog.lo_open(Oid, int4)
	RETURNS pg_catalog.int4
	AS 'MODULE_PATHNAME', 'lolor_lo_open'
	LANGUAGE C STRICT VOLATILE;

-- Replace lo_close()
ALTER FUNCTION pg_catalog.lo_close(int4)
	RENAME TO lo_close_orig;
CREATE FUNCTION pg_catalog.lo_close(int4)
	RETURNS pg_catalog.int4
	AS 'MODULE_PATHNAME', 'lolor_lo_close'
	LANGUAGE C STRICT VOLATILE;

-- lo_creat
ALTER FUNCTION pg_catalog.lo_creat(integer)
	RENAME TO lo_creat_orig;
CREATE FUNCTION pg_catalog.lo_creat(integer)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'lolor_lo_creat'
	LANGUAGE C STRICT VOLATILE;

-- lo_create
ALTER FUNCTION pg_catalog.lo_create(oid)
	RENAME TO lo_create_orig;
CREATE FUNCTION pg_catalog.lo_create(oid)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'lolor_lo_create'
	LANGUAGE C STRICT VOLATILE;

-- loread
ALTER FUNCTION pg_catalog.loread(integer, integer)
	RENAME TO loread_orig;
CREATE FUNCTION pg_catalog.loread(integer, integer)
	RETURNS bytea
	AS 'MODULE_PATHNAME', 'lolor_loread'
	LANGUAGE C STRICT VOLATILE;

-- lowrite
ALTER FUNCTION pg_catalog.lowrite(integer, bytea)
	RENAME TO lowrite_orig;
CREATE FUNCTION pg_catalog.lowrite(integer, bytea)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'lolor_lowrite'
	LANGUAGE C STRICT VOLATILE;

-- lo_export
ALTER FUNCTION pg_catalog.lo_export(oid, text)
	RENAME TO lo_export_orig;
CREATE FUNCTION pg_catalog.lo_export(oid, text)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'lolor_lo_export'
	LANGUAGE C STRICT VOLATILE;

-- lo_from_bytea
ALTER FUNCTION pg_catalog.lo_from_bytea(oid, bytea)
	RENAME TO lo_from_bytea_orig;
CREATE FUNCTION pg_catalog.lo_from_bytea(oid, bytea)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'lolor_lo_from_bytea'
	LANGUAGE C STRICT VOLATILE;

-- lo_get
ALTER FUNCTION pg_catalog.lo_get(oid)
	RENAME TO lo_get_orig;
CREATE FUNCTION pg_catalog.lo_get(oid)
	RETURNS bytea
	AS 'MODULE_PATHNAME', 'lolor_lo_get'
	LANGUAGE C STRICT VOLATILE;

-- lo_get
ALTER FUNCTION pg_catalog.lo_get(oid, bigint, integer)
	RENAME TO lo_get_orig;
CREATE FUNCTION pg_catalog.lo_get(oid, bigint, integer)
	RETURNS bytea
	AS 'MODULE_PATHNAME', 'lolor_lo_get_fragment'
	LANGUAGE C STRICT VOLATILE;

-- lo_import
ALTER FUNCTION pg_catalog.lo_import(text)
	RENAME TO lo_import_orig;
CREATE FUNCTION pg_catalog.lo_import(text)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'lolor_lo_import'
	LANGUAGE C STRICT VOLATILE;

-- lo_import
ALTER FUNCTION pg_catalog.lo_import(text, oid)
	RENAME TO lo_import_orig;
CREATE FUNCTION pg_catalog.lo_import(text, oid)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'lolor_lo_import_with_oid'
	LANGUAGE C STRICT VOLATILE;

-- lo_lseek
ALTER FUNCTION pg_catalog.lo_lseek(integer, integer, integer)
	RENAME TO lo_lseek_orig;
CREATE FUNCTION pg_catalog.lo_lseek(integer, integer, integer)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'lolor_lo_lseek'
	LANGUAGE C STRICT VOLATILE;

-- lo_lseek64
ALTER FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer)
	RENAME TO lo_lseek64_orig;
CREATE FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer)
	RETURNS bigint
	AS 'MODULE_PATHNAME', 'lolor_lo_lseek64'
	LANGUAGE C STRICT VOLATILE;

-- lo_put
ALTER FUNCTION pg_catalog.lo_put(oid, bigint, bytea)
	RENAME TO lo_put_orig;
CREATE FUNCTION pg_catalog.lo_put(oid, bigint, bytea)
	RETURNS void
	AS 'MODULE_PATHNAME', 'lolor_lo_put'
	LANGUAGE C STRICT VOLATILE;

-- lo_tell
ALTER FUNCTION pg_catalog.lo_tell(integer)
	RENAME TO lo_tell_orig;
CREATE FUNCTION pg_catalog.lo_tell(integer)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'lolor_lo_tell'
	LANGUAGE C STRICT VOLATILE;

-- lo_tell64
ALTER FUNCTION pg_catalog.lo_tell64(integer)
	RENAME TO lo_tell64_orig;
CREATE FUNCTION pg_catalog.lo_tell64(integer)
	RETURNS bigint
	AS 'MODULE_PATHNAME', 'lolor_lo_tell64'
	LANGUAGE C STRICT VOLATILE;

-- lo_truncate
ALTER FUNCTION pg_catalog.lo_truncate(integer, integer)
	RENAME TO lo_truncate_orig;
CREATE FUNCTION pg_catalog.lo_truncate(integer, integer)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'lolor_lo_truncate'
	LANGUAGE C STRICT VOLATILE;

-- lo_truncate64
ALTER FUNCTION pg_catalog.lo_truncate64(integer, bigint)
	RENAME TO lo_truncate64_orig;
CREATE FUNCTION pg_catalog.lo_truncate64(integer, bigint)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'lolor_lo_truncate64'
	LANGUAGE C STRICT VOLATILE;

-- lo_unlink
ALTER FUNCTION pg_catalog.lo_unlink(oid)
	RENAME TO lo_unlink_orig;
CREATE FUNCTION pg_catalog.lo_unlink(oid)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'lolor_lo_unlink'
	LANGUAGE C STRICT VOLATILE;

-- Create the trigger that will fire on DROP EXTENSION
-- to perform cleanup
CREATE FUNCTION pg_catalog.lo_on_drop_extension()
	RETURNS pg_catalog.event_trigger
	AS 'MODULE_PATHNAME', 'lolor_on_drop_extension'
	LANGUAGE C VOLATILE;
CREATE EVENT TRIGGER lo_on_drop_extension
	ON ddl_command_start WHEN tag IN ('DROP EXTENSION')
	EXECUTE FUNCTION pg_catalog.lo_on_drop_extension();
