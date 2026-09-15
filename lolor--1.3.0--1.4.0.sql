/* lolor--1.3.0--1.4.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION lolor UPDATE" to load this file. \quit

/*
 * Restore the ACLs on the server-side file access functions.
 *
 * pg_catalog.lo_import() and lo_export() read and write files as the account
 * PostgreSQL runs under, so core revokes EXECUTE on them from PUBLIC.  lolor
 * replaces them by renaming the originals to *_orig and creating its own.  An
 * ACL belongs to a function rather than to a name, so the restriction stayed
 * on the parked original while each replacement was created with the default
 * of EXECUTE TO PUBLIC.  Every version through 1.3.0 is affected.
 *
 * Revoke on both spellings, since the installation may be enabled or
 * disabled.  Revoking on an already restricted function is a no-op.
 */
DO $$
DECLARE
  target text;
BEGIN
  FOREACH target IN ARRAY ARRAY[
    'lo_import(text)',
    'lo_import(text,oid)',
    'lo_export(oid,text)',
    'lolor_lo_import(text)',
    'lolor_lo_import(text,oid)',
    'lolor_lo_export(oid,text)'
  ]
  LOOP
    IF to_regprocedure('pg_catalog.' || target) IS NOT NULL THEN
      EXECUTE format('REVOKE ALL ON FUNCTION pg_catalog.%s FROM PUBLIC', target);
    END IF;
  END LOOP;
END;
$$;

/*
 * Large objects in lolor storage whose owner no longer exists.
 *
 * Objects in lolor storage are rows in ordinary tables, so they cannot
 * participate in pg_shdepend: DROP ROLE will not notice them the way it
 * notices native large objects.  That is inherent to storing them outside the
 * catalogs; this function makes the consequence findable.
 */
CREATE FUNCTION lolor.check_orphans()
RETURNS TABLE (loid oid, lomowner oid) AS $$
  SELECT m.oid, m.lomowner
  FROM lolor.pg_largeobject_metadata m
  LEFT JOIN pg_catalog.pg_authid a ON a.oid = m.lomowner
  WHERE a.oid IS NULL
  ORDER BY m.oid
$$ LANGUAGE sql STABLE;

/*
 * Remove the bogus pg_shdepend rows left by earlier versions.
 *
 * Through 1.3.0, creating a large object recorded a pg_shdepend row whose
 * classId was the OID of lolor.pg_largeobject -- an ordinary table, not a
 * catalog the dependency machinery can describe.  DROP ROLE on any role that
 * had created one failed with "unrecognized object class", and the rows were
 * never removed.
 *
 * pg_shdepend is shared across the cluster, so restrict the delete to this
 * database: the same classId in another database is an unrelated relation.
 */
DELETE FROM pg_catalog.pg_shdepend
WHERE dbid = (SELECT oid FROM pg_catalog.pg_database
               WHERE datname = current_database())
  AND classid IN ('lolor.pg_largeobject'::regclass,
                  'lolor.pg_largeobject_metadata'::regclass);

/*
 * Hardened enable / disable / is_enabled.
 */

CREATE OR REPLACE FUNCTION lolor.is_enabled()
RETURNS boolean AS $$
DECLARE
  parked_present boolean;
  orig_present   boolean;
BEGIN
  -- Exact signatures, qualified to pg_catalog: see the note in lolor.enable().
  parked_present := to_regprocedure('pg_catalog.lolor_lo_open(oid,int4)') IS NOT NULL;
  orig_present   := to_regprocedure('pg_catalog.lo_open_orig(oid,int4)') IS NOT NULL;

  IF parked_present = orig_present THEN
    RAISE EXCEPTION 'lolor is in inconsistent state'
      USING DETAIL = format('pg_catalog.lolor_lo_open present: %s; pg_catalog.lo_open_orig present: %s',
                            parked_present, orig_present);
  END IF;

  -- Our functions parked under lolor_* means the native ones are in place.
  RETURN NOT parked_present;
END;
$$ LANGUAGE plpgsql STRICT STABLE;


/*
 * Disable lolor functionality.
 *
 * Parks the lolor implementations under pg_catalog.lolor_* and restores the
 * native pg_catalog names from their *_orig parking spot.  Creates and drops
 * nothing.  Returns true on success, false on a handled no-op.
 */
CREATE OR REPLACE FUNCTION lolor.disable()
RETURNS boolean AS $$
BEGIN
  -- Serialise against a concurrent enable()/disable().  The probes below
  -- are a check-then-act and the renames are not atomic on their own.
  PERFORM pg_catalog.pg_advisory_xact_lock(4919420001);

  -- Probe exact signatures in pg_catalog.  Earlier versions matched on
  -- proname alone across every schema, so any user with CREATE on any schema
  -- could squat 'lolor_lo_open' and wedge lolor into a permanent
  -- 'inconsistent state', which also blocked DROP EXTENSION.
  IF to_regprocedure('pg_catalog.lo_close_orig(int4)') IS NULL THEN
    RAISE NOTICE 'lolor is already disabled';
    RETURN false;
  END IF;
  IF to_regprocedure('pg_catalog.lolor_lo_open(oid,int4)') IS NOT NULL THEN
    RAISE NOTICE 'lolor.disable() has been called before';
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

  -- Renaming changes which OID owns the name lo_open, and libpq caches the
  -- large object fastpath OIDs per connection: sessions that touched a large
  -- object before this call keep using the previous implementation.
  RAISE NOTICE 'lolor: reconnect existing client sessions; they cache large object function OIDs';

  RETURN true;
END;
$$ LANGUAGE plpgsql STRICT VOLATILE;


/*
 * Enable lolor functionality, undoing lolor.disable().
 */
CREATE OR REPLACE FUNCTION lolor.enable()
RETURNS boolean AS $$
BEGIN
  -- Serialise against a concurrent enable()/disable().  The probes below
  -- are a check-then-act and the renames are not atomic on their own.
  PERFORM pg_catalog.pg_advisory_xact_lock(4919420001);

  -- Probe exact signatures in pg_catalog.  Earlier versions matched on
  -- proname alone across every schema, so any user with CREATE on any schema
  -- could squat 'lolor_lo_open' and wedge lolor into a permanent
  -- 'inconsistent state', which also blocked DROP EXTENSION.
  IF to_regprocedure('pg_catalog.lolor_lo_open(oid,int4)') IS NULL THEN
    RAISE NOTICE 'lolor is already enabled';
    RETURN false;
  END IF;
  IF to_regprocedure('pg_catalog.lo_close_orig(int4)') IS NOT NULL THEN
    RAISE NOTICE 'lolor.enable() has been called before';
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

  -- Renaming changes which OID owns the name lo_open, and libpq caches the
  -- large object fastpath OIDs per connection: sessions that touched a large
  -- object before this call keep using the previous implementation.
  RAISE NOTICE 'lolor: reconnect existing client sessions; they cache large object function OIDs';

  RETURN true;
END;
$$ LANGUAGE plpgsql STRICT VOLATILE;

/*
 * Re-register the drop cleanup for every spelling of the drop.
 *
 * DROP SCHEMA lolor CASCADE and DROP OWNED BY reach the extension by
 * dependency cascade rather than as DROP EXTENSION, and fire under their own
 * command tags.  Without them the cleanup never runs, the large objects are
 * destroyed with the lolor tables, and pg_catalog is left without a working
 * lo_open().  Tags cannot be altered in place, so re-create the trigger.
 */
DROP EVENT TRIGGER lo_on_drop_extension;
CREATE EVENT TRIGGER lo_on_drop_extension
	ON ddl_command_start
	WHEN tag IN ('DROP EXTENSION', 'DROP SCHEMA', 'DROP OWNED')
	EXECUTE FUNCTION pg_catalog.lo_on_drop_extension();
ALTER EVENT TRIGGER lo_on_drop_extension ENABLE ALWAYS;
