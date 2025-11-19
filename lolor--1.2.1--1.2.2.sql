/* lolor--1.2.1--1.2.2.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION lolor" to load this file. \quit

/*
 * Disable lolor functionality.
 *
 * Renames LO-related routines referencing lolor C-functions to corresponding
 * pg_catalog.lolor_* ones. Afterwards, renames pg_catalog.*_orig routines to
 * corresponding LO ones. If the lolor is disabled, do nothing.
 * Designed to not create / drop any database objects.
 *
 * Returns true on success, false on a handled error and an ERROR otherwise.
 */
CREATE FUNCTION lolor.disable()
RETURNS boolean AS $$
BEGIN
  -- Doesn't protect a lot but provides a user with meaningful peace of information
  IF NOT EXISTS (SELECT 1 FROM pg_proc where proname = 'lo_close_orig') THEN
    raise NOTICE 'lolor still not enabled';
    RETURN false;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc where proname = 'lolor_lo_open') THEN
    raise NOTICE 'lolor.dsable() has been called before';
    RETURN false;
  END IF;

  ALTER FUNCTION pg_catalog.lo_open(oid, int4) RENAME TO lolor_lo_open;
  ALTER FUNCTION pg_catalog.lo_open_orig(oid, int4) RENAME TO lo_open;

  ALTER FUNCTION pg_catalog.lo_close(int4) RENAME TO lolor_lo_close;
  ALTER FUNCTION pg_catalog.lo_close_orig(int4) RENAME TO lo_close;

  ALTER FUNCTION pg_catalog.lo_creat(integer) RENAME TO lolor_lo_creat;
  ALTER FUNCTION pg_catalog.lo_creat_orig(integer) RENAME TO lo_creat;

  ALTER FUNCTION pg_catalog.lo_create(oid) RENAME TO lolor_lo_create;
  ALTER FUNCTION pg_catalog.lo_create_orig(oid) RENAME TO lo_create;

  ALTER FUNCTION pg_catalog.loread(integer, integer) RENAME TO lolor_loread;
  ALTER FUNCTION pg_catalog.loread_orig(integer, integer) RENAME TO loread;

  ALTER FUNCTION pg_catalog.lowrite(integer, bytea) RENAME TO lolor_lowrite;
  ALTER FUNCTION pg_catalog.lowrite_orig(integer, bytea) RENAME TO lowrite;

  ALTER FUNCTION pg_catalog.lo_export(oid, text) RENAME TO lolor_lo_export;
  ALTER FUNCTION pg_catalog.lo_export_orig(oid, text) RENAME TO lo_export;

  ALTER FUNCTION pg_catalog.lo_from_bytea(oid, bytea) RENAME TO lolor_lo_from_bytea;
  ALTER FUNCTION pg_catalog.lo_from_bytea_orig(oid, bytea) RENAME TO lo_from_bytea;

  ALTER FUNCTION pg_catalog.lo_get(oid) RENAME TO lolor_lo_get;
  ALTER FUNCTION pg_catalog.lo_get_orig(oid) RENAME TO lo_get;

  ALTER FUNCTION pg_catalog.lo_get(oid, bigint, integer) RENAME TO lolor_lo_get;
  ALTER FUNCTION pg_catalog.lo_get_orig(oid, bigint, integer) RENAME TO lo_get;

  ALTER FUNCTION pg_catalog.lo_import(text) RENAME TO lolor_lo_import;
  ALTER FUNCTION pg_catalog.lo_import_orig(text) RENAME TO lo_import;

  ALTER FUNCTION pg_catalog.lo_import(text, oid) RENAME TO lolor_lo_import;
  ALTER FUNCTION pg_catalog.lo_import_orig(text, oid) RENAME TO lo_import;

  ALTER FUNCTION pg_catalog.lo_lseek(integer, integer, integer) RENAME TO lolor_lo_lseek;
  ALTER FUNCTION pg_catalog.lo_lseek_orig(integer, integer, integer) RENAME TO lo_lseek;

  ALTER FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer) RENAME TO lolor_lo_lseek64;
  ALTER FUNCTION pg_catalog.lo_lseek64_orig(integer, bigint, integer) RENAME TO lo_lseek64;

  ALTER FUNCTION pg_catalog.lo_put(oid, bigint, bytea) RENAME TO lolor_lo_put;
  ALTER FUNCTION pg_catalog.lo_put_orig(oid, bigint, bytea) RENAME TO lo_put;

  ALTER FUNCTION pg_catalog.lo_tell(integer) RENAME TO lolor_lo_tell;
  ALTER FUNCTION pg_catalog.lo_tell_orig(integer) RENAME TO lo_tell;

  ALTER FUNCTION pg_catalog.lo_tell64(integer) RENAME TO lolor_lo_tell64;
  ALTER FUNCTION pg_catalog.lo_tell64_orig(integer) RENAME TO lo_tell64;

  ALTER FUNCTION pg_catalog.lo_truncate(integer, integer) RENAME TO lolor_lo_truncate;
  ALTER FUNCTION pg_catalog.lo_truncate_orig(integer, integer) RENAME TO lo_truncate;

  ALTER FUNCTION pg_catalog.lo_truncate64(integer, bigint) RENAME TO lolor_lo_truncate64;
  ALTER FUNCTION pg_catalog.lo_truncate64_orig(integer, bigint) RENAME TO lo_truncate64;

  ALTER FUNCTION pg_catalog.lo_unlink(oid) RENAME TO lolor_lo_unlink;
  ALTER FUNCTION pg_catalog.lo_unlink_orig(oid) RENAME TO lo_unlink;

  RETURN true;
END;
$$ LANGUAGE plpgsql STRICT VOLATILE;

/*
 * Enable lolor functionality, disabled by the lolor.disable() call.
 *
 * Renames LO-related routines to corresponding pg_catalog.*_orig. Afterwards,
 * renames pg_catalog.lolor_* routines to corresponding LO ones. If the lolor is
 * enabled, do nothing.
 * Designed to not create / drop any database objects.
 *
 * Returns true on success, false on a handled error and an ERROR otherwise.
 */
CREATE FUNCTION lolor.enable()
RETURNS boolean AS $$
BEGIN
  -- Doesn't protect a lot but provides a user with meaningful peace of information
  IF NOT EXISTS (SELECT 1 FROM pg_proc where proname = 'lolor_lo_open') THEN
    raise NOTICE 'lolor still not disabled';
    RETURN false;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc where proname = 'lo_close_orig') THEN
    raise NOTICE 'lolor.enable() has been called before';
    RETURN false;
  END IF;

  ALTER FUNCTION pg_catalog.lo_open(oid, int4) RENAME TO lo_open_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_open(oid, int4) RENAME TO lo_open;

  ALTER FUNCTION pg_catalog.lo_close(int4) RENAME TO lo_close_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_close(int4) RENAME TO lo_close;

  ALTER FUNCTION pg_catalog.lo_creat(integer) RENAME TO lo_creat_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_creat(integer) RENAME TO lo_creat;

  ALTER FUNCTION pg_catalog.lo_create(oid) RENAME TO lo_create_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_create(oid) RENAME TO lo_create;

  ALTER FUNCTION pg_catalog.loread(integer, integer) RENAME TO loread_orig;
  ALTER FUNCTION pg_catalog.lolor_loread(integer, integer) RENAME TO loread;

  ALTER FUNCTION pg_catalog.lowrite(integer, bytea) RENAME TO lowrite_orig;
  ALTER FUNCTION pg_catalog.lolor_lowrite(integer, bytea) RENAME TO lowrite;

  ALTER FUNCTION pg_catalog.lo_export(oid, text) RENAME TO lo_export_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_export(oid, text) RENAME TO lo_export;

  ALTER FUNCTION pg_catalog.lo_from_bytea(oid, bytea) RENAME TO lo_from_bytea_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_from_bytea(oid, bytea) RENAME TO lo_from_bytea;

  ALTER FUNCTION pg_catalog.lo_get(oid) RENAME TO lo_get_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_get(oid) RENAME TO lo_get;

  ALTER FUNCTION pg_catalog.lo_get(oid, bigint, integer) RENAME TO lo_get_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_get(oid, bigint, integer) RENAME TO lo_get;

  ALTER FUNCTION pg_catalog.lo_import(text) RENAME TO lo_import_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_import(text) RENAME TO lo_import;

  ALTER FUNCTION pg_catalog.lo_import(text, oid) RENAME TO lo_import_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_import(text, oid) RENAME TO lo_import;

  ALTER FUNCTION pg_catalog.lo_lseek(integer, integer, integer) RENAME TO lo_lseek_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_lseek(integer, integer, integer) RENAME TO lo_lseek;

  ALTER FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer) RENAME TO lo_lseek64_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_lseek64(integer, bigint, integer) RENAME TO lo_lseek64;

  ALTER FUNCTION pg_catalog.lo_put(oid, bigint, bytea) RENAME TO lo_put_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_put(oid, bigint, bytea) RENAME TO lo_put;

  ALTER FUNCTION pg_catalog.lo_tell(integer) RENAME TO lo_tell_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_tell(integer) RENAME TO lo_tell;

  ALTER FUNCTION pg_catalog.lo_tell64(integer) RENAME TO lo_tell64_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_tell64(integer) RENAME TO lo_tell64;

  ALTER FUNCTION pg_catalog.lo_truncate(integer, integer) RENAME TO lo_truncate_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_truncate(integer, integer) RENAME TO lo_truncate;

  ALTER FUNCTION pg_catalog.lo_truncate64(integer, bigint) RENAME TO lo_truncate64_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_truncate64(integer, bigint) RENAME TO lo_truncate64;

  ALTER FUNCTION pg_catalog.lo_unlink(oid) RENAME TO lo_unlink_orig;
  ALTER FUNCTION pg_catalog.lolor_lo_unlink(oid) RENAME TO lo_unlink;

  RETURN true;
END;
$$ LANGUAGE plpgsql STRICT VOLATILE;
