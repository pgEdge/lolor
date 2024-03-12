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
CREATE OR REPLACE FUNCTION pg_catalog.lo_creat(integer)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'lolor_lo_creat'
	LANGUAGE C STRICT VOLATILE;

-- lo_create
ALTER FUNCTION pg_catalog.lo_create(oid)
	RENAME TO lo_create_orig;
CREATE OR REPLACE FUNCTION pg_catalog.lo_create(oid)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'lolor_lo_create'
	LANGUAGE C STRICT VOLATILE;

-- loread
ALTER FUNCTION pg_catalog.loread(integer, integer)
	RENAME TO loread_orig;
CREATE OR REPLACE FUNCTION pg_catalog.loread(integer, integer)
	RETURNS bytea
	AS 'MODULE_PATHNAME', 'lolor_loread'
	LANGUAGE C STRICT VOLATILE;

-- lowrite
ALTER FUNCTION pg_catalog.lowrite(integer, bytea)
	RENAME TO lowrite_orig;
CREATE OR REPLACE FUNCTION pg_catalog.lowrite(integer, bytea)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'lolor_lowrite'
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

