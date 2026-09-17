/* contrib/pg_lolor/pg_lolor--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_lolor" to load this file. \quit

-- Streaming replicas run the same shared library, so they need the extension
-- installed too; otherwise large object access breaks if one is promoted.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_stat_replication WHERE state = 'streaming') THEN
    RAISE NOTICE 'pg_lolor must also be installed on streaming standbys'
      USING DETAIL = 'Large object access fails if a standby without the '
                     'extension is promoted.';
  END IF;
END;
$$;

-- Replace pg_largeobject
CREATE TABLE lolor.pg_largeobject(
	loid oid NOT NULL,
	pageno int NOT NULL,
	data bytea NOT NULL,
	PRIMARY KEY(loid,pageno));
SELECT pg_catalog.pg_extension_config_dump('lolor.pg_largeobject', '');

-- Replace pg_largeobject_metadata
CREATE TABLE lolor.pg_largeobject_metadata(
	oid oid NOT NULL,
	lomowner oid NOT NULL,
	lomacl aclitem[],
	PRIMARY KEY(oid));
SELECT pg_catalog.pg_extension_config_dump('lolor.pg_largeobject_metadata', '');

-- Replace lo_open()
ALTER FUNCTION pg_catalog.lo_open(Oid, int4)
	RENAME TO lo_open_orig;
CREATE FUNCTION pg_catalog.lo_open(Oid, int4)
	RETURNS pg_catalog.int4
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_open'
	LANGUAGE C STRICT VOLATILE;

-- Replace lo_close()
ALTER FUNCTION pg_catalog.lo_close(int4)
	RENAME TO lo_close_orig;
CREATE FUNCTION pg_catalog.lo_close(int4)
	RETURNS pg_catalog.int4
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_close'
	LANGUAGE C STRICT VOLATILE;

-- lo_creat
ALTER FUNCTION pg_catalog.lo_creat(integer)
	RENAME TO lo_creat_orig;
CREATE FUNCTION pg_catalog.lo_creat(integer)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_creat'
	LANGUAGE C STRICT VOLATILE;

-- lo_create
ALTER FUNCTION pg_catalog.lo_create(oid)
	RENAME TO lo_create_orig;
CREATE FUNCTION pg_catalog.lo_create(oid)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_create'
	LANGUAGE C STRICT VOLATILE;

-- loread
ALTER FUNCTION pg_catalog.loread(integer, integer)
	RENAME TO loread_orig;
CREATE FUNCTION pg_catalog.loread(integer, integer)
	RETURNS bytea
	AS 'MODULE_PATHNAME', 'pg_lolor_loread'
	LANGUAGE C STRICT VOLATILE;

-- lowrite
ALTER FUNCTION pg_catalog.lowrite(integer, bytea)
	RENAME TO lowrite_orig;
CREATE FUNCTION pg_catalog.lowrite(integer, bytea)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'pg_lolor_lowrite'
	LANGUAGE C STRICT VOLATILE;

-- lo_export
ALTER FUNCTION pg_catalog.lo_export(oid, text)
	RENAME TO lo_export_orig;
CREATE FUNCTION pg_catalog.lo_export(oid, text)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_export'
	LANGUAGE C STRICT VOLATILE;
-- lo_export writes a file on the server.  The original's restrictive ACL stays
-- behind on lo_export_orig when it is renamed, so the replacement has to be
-- locked down explicitly or any user could write files as the server account.
REVOKE ALL ON FUNCTION pg_catalog.lo_export(oid, text) FROM PUBLIC;

-- lo_from_bytea
ALTER FUNCTION pg_catalog.lo_from_bytea(oid, bytea)
	RENAME TO lo_from_bytea_orig;
CREATE FUNCTION pg_catalog.lo_from_bytea(oid, bytea)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_from_bytea'
	LANGUAGE C STRICT VOLATILE;

-- lo_get
ALTER FUNCTION pg_catalog.lo_get(oid)
	RENAME TO lo_get_orig;
CREATE FUNCTION pg_catalog.lo_get(oid)
	RETURNS bytea
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_get'
	LANGUAGE C STRICT VOLATILE;

-- lo_get
ALTER FUNCTION pg_catalog.lo_get(oid, bigint, integer)
	RENAME TO lo_get_orig;
CREATE FUNCTION pg_catalog.lo_get(oid, bigint, integer)
	RETURNS bytea
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_get_fragment'
	LANGUAGE C STRICT VOLATILE;

-- lo_import
ALTER FUNCTION pg_catalog.lo_import(text)
	RENAME TO lo_import_orig;
CREATE FUNCTION pg_catalog.lo_import(text)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_import'
	LANGUAGE C STRICT VOLATILE;
-- Reads a file on the server; see the note on lo_export above.
REVOKE ALL ON FUNCTION pg_catalog.lo_import(text) FROM PUBLIC;

-- lo_import
ALTER FUNCTION pg_catalog.lo_import(text, oid)
	RENAME TO lo_import_orig;
CREATE FUNCTION pg_catalog.lo_import(text, oid)
	RETURNS oid
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_import_with_oid'
	LANGUAGE C STRICT VOLATILE;
-- Reads a file on the server; see the note on lo_export above.
REVOKE ALL ON FUNCTION pg_catalog.lo_import(text, oid) FROM PUBLIC;

-- lo_lseek
ALTER FUNCTION pg_catalog.lo_lseek(integer, integer, integer)
	RENAME TO lo_lseek_orig;
CREATE FUNCTION pg_catalog.lo_lseek(integer, integer, integer)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_lseek'
	LANGUAGE C STRICT VOLATILE;

-- lo_lseek64
ALTER FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer)
	RENAME TO lo_lseek64_orig;
CREATE FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer)
	RETURNS bigint
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_lseek64'
	LANGUAGE C STRICT VOLATILE;

-- lo_put
ALTER FUNCTION pg_catalog.lo_put(oid, bigint, bytea)
	RENAME TO lo_put_orig;
CREATE FUNCTION pg_catalog.lo_put(oid, bigint, bytea)
	RETURNS void
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_put'
	LANGUAGE C STRICT VOLATILE;

-- lo_tell
ALTER FUNCTION pg_catalog.lo_tell(integer)
	RENAME TO lo_tell_orig;
CREATE FUNCTION pg_catalog.lo_tell(integer)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_tell'
	LANGUAGE C STRICT VOLATILE;

-- lo_tell64
ALTER FUNCTION pg_catalog.lo_tell64(integer)
	RENAME TO lo_tell64_orig;
CREATE FUNCTION pg_catalog.lo_tell64(integer)
	RETURNS bigint
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_tell64'
	LANGUAGE C STRICT VOLATILE;

-- lo_truncate
ALTER FUNCTION pg_catalog.lo_truncate(integer, integer)
	RENAME TO lo_truncate_orig;
CREATE FUNCTION pg_catalog.lo_truncate(integer, integer)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_truncate'
	LANGUAGE C STRICT VOLATILE;

-- lo_truncate64
ALTER FUNCTION pg_catalog.lo_truncate64(integer, bigint)
	RENAME TO lo_truncate64_orig;
CREATE FUNCTION pg_catalog.lo_truncate64(integer, bigint)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_truncate64'
	LANGUAGE C STRICT VOLATILE;

-- lo_unlink
ALTER FUNCTION pg_catalog.lo_unlink(oid)
	RENAME TO lo_unlink_orig;
CREATE FUNCTION pg_catalog.lo_unlink(oid)
	RETURNS integer
	AS 'MODULE_PATHNAME', 'pg_lolor_lo_unlink'
	LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION pg_catalog.pg_lolor_on_drop_extension()
	RETURNS pg_catalog.event_trigger
	AS 'MODULE_PATHNAME', 'pg_lolor_on_drop_extension'
	LANGUAGE C VOLATILE;
/*
 * Register the drop cleanup for every spelling of the drop.
 *
 * DROP SCHEMA lolor CASCADE and DROP OWNED BY reach the extension by
 * dependency cascade rather than as DROP EXTENSION, and fire under their own
 * command tags.  Without them the cleanup never runs, the large objects are
 * destroyed with the pg_lolor tables, and pg_catalog is left without a working
 * lo_open().
 */
CREATE EVENT TRIGGER pg_lolor_on_drop_extension
	ON ddl_command_start
	WHEN tag IN ('DROP EXTENSION', 'DROP SCHEMA', 'DROP OWNED')
	EXECUTE FUNCTION pg_catalog.pg_lolor_on_drop_extension();
ALTER EVENT TRIGGER pg_lolor_on_drop_extension ENABLE ALWAYS;

/*
 * Comment parking.
 *
 * COMMENT ON LARGE OBJECT stores its text in pg_description keyed by
 * (classoid = 'pg_largeobject', objoid = loid).  While an object lives in
 * pg_lolor storage there is no catalog object for that row to describe, so the
 * comment is parked here and restored on the way back.  Without this it is
 * silently lost the first time an object is migrated.
 */
CREATE TABLE lolor.pg_largeobject_description(
	loid		oid NOT NULL,
	description	text NOT NULL,
	CONSTRAINT pg_largeobject_description_pkey PRIMARY KEY (loid));
SELECT pg_catalog.pg_extension_config_dump('lolor.pg_largeobject_description', '');

/*
 * Hardened enable / disable / is_enabled.
 */

CREATE FUNCTION lolor.is_enabled()
RETURNS boolean AS $$
DECLARE
  parked_present boolean;
  orig_present   boolean;
BEGIN
  -- Exact signatures, qualified to pg_catalog: see the note in lolor.enable().
  parked_present := to_regprocedure('pg_catalog.pg_lolor_lo_open(oid,int4)') IS NOT NULL;
  orig_present   := to_regprocedure('pg_catalog.lo_open_orig(oid,int4)') IS NOT NULL;

  IF parked_present = orig_present THEN
    RAISE EXCEPTION 'pg_lolor is in inconsistent state'
      USING DETAIL = format('pg_catalog.pg_lolor_lo_open present: %s; '
                            'pg_catalog.lo_open_orig present: %s.',
                            parked_present, orig_present);
  END IF;

  -- Our functions parked under pg_lolor_* means the native ones are in place.
  RETURN NOT parked_present;
END;
$$ LANGUAGE plpgsql STRICT STABLE;


/*
 * Disable pg_lolor functionality.
 *
 * Parks the pg_lolor implementations under pg_catalog.pg_lolor_* and restores the
 * native pg_catalog names from their *_orig parking spot.  Creates and drops
 * nothing.  Returns true on success, false on a handled no-op.
 */
CREATE FUNCTION lolor.disable()
RETURNS boolean AS $$
BEGIN
  -- The probes below are a check-then-act, but no lock is needed: the whole
  -- body runs in one transaction, so a concurrent caller that loses the race
  -- fails on a rename and rolls back, leaving the state consistent.
  -- Probe exact signatures qualified to pg_catalog.  Matching on proname
  -- alone would let any user with CREATE on any schema squat 'pg_lolor_lo_open'
  -- and wedge pg_lolor into a permanent 'inconsistent state', which would also
  -- block DROP EXTENSION.
  IF to_regprocedure('pg_catalog.lo_close_orig(int4)') IS NULL THEN
    RAISE NOTICE 'pg_lolor is already disabled';
    RETURN false;
  END IF;
  IF to_regprocedure('pg_catalog.pg_lolor_lo_open(oid,int4)') IS NOT NULL THEN
    RAISE NOTICE 'lolor.disable() has been called before';
    RETURN false;
  END IF;

  ALTER FUNCTION pg_catalog.lo_open(oid, int4) RENAME TO pg_lolor_lo_open;
  ALTER FUNCTION pg_catalog.lo_open_orig(oid, int4) RENAME TO lo_open;
  ALTER FUNCTION pg_catalog.lo_close(int4) RENAME TO pg_lolor_lo_close;
  ALTER FUNCTION pg_catalog.lo_close_orig(int4) RENAME TO lo_close;
  ALTER FUNCTION pg_catalog.lo_creat(integer) RENAME TO pg_lolor_lo_creat;
  ALTER FUNCTION pg_catalog.lo_creat_orig(integer) RENAME TO lo_creat;
  ALTER FUNCTION pg_catalog.lo_create(oid) RENAME TO pg_lolor_lo_create;
  ALTER FUNCTION pg_catalog.lo_create_orig(oid) RENAME TO lo_create;
  ALTER FUNCTION pg_catalog.loread(integer, integer) RENAME TO pg_lolor_loread;
  ALTER FUNCTION pg_catalog.loread_orig(integer, integer) RENAME TO loread;
  ALTER FUNCTION pg_catalog.lowrite(integer, bytea) RENAME TO pg_lolor_lowrite;
  ALTER FUNCTION pg_catalog.lowrite_orig(integer, bytea) RENAME TO lowrite;
  ALTER FUNCTION pg_catalog.lo_export(oid, text) RENAME TO pg_lolor_lo_export;
  ALTER FUNCTION pg_catalog.lo_export_orig(oid, text) RENAME TO lo_export;
  ALTER FUNCTION pg_catalog.lo_from_bytea(oid, bytea) RENAME TO pg_lolor_lo_from_bytea;
  ALTER FUNCTION pg_catalog.lo_from_bytea_orig(oid, bytea) RENAME TO lo_from_bytea;
  ALTER FUNCTION pg_catalog.lo_get(oid) RENAME TO pg_lolor_lo_get;
  ALTER FUNCTION pg_catalog.lo_get_orig(oid) RENAME TO lo_get;
  ALTER FUNCTION pg_catalog.lo_get(oid, bigint, integer) RENAME TO pg_lolor_lo_get;
  ALTER FUNCTION pg_catalog.lo_get_orig(oid, bigint, integer) RENAME TO lo_get;
  ALTER FUNCTION pg_catalog.lo_import(text) RENAME TO pg_lolor_lo_import;
  ALTER FUNCTION pg_catalog.lo_import_orig(text) RENAME TO lo_import;
  ALTER FUNCTION pg_catalog.lo_import(text, oid) RENAME TO pg_lolor_lo_import;
  ALTER FUNCTION pg_catalog.lo_import_orig(text, oid) RENAME TO lo_import;
  ALTER FUNCTION pg_catalog.lo_lseek(integer, integer, integer) RENAME TO pg_lolor_lo_lseek;
  ALTER FUNCTION pg_catalog.lo_lseek_orig(integer, integer, integer) RENAME TO lo_lseek;
  ALTER FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer) RENAME TO pg_lolor_lo_lseek64;
  ALTER FUNCTION pg_catalog.lo_lseek64_orig(integer, bigint, integer) RENAME TO lo_lseek64;
  ALTER FUNCTION pg_catalog.lo_put(oid, bigint, bytea) RENAME TO pg_lolor_lo_put;
  ALTER FUNCTION pg_catalog.lo_put_orig(oid, bigint, bytea) RENAME TO lo_put;
  ALTER FUNCTION pg_catalog.lo_tell(integer) RENAME TO pg_lolor_lo_tell;
  ALTER FUNCTION pg_catalog.lo_tell_orig(integer) RENAME TO lo_tell;
  ALTER FUNCTION pg_catalog.lo_tell64(integer) RENAME TO pg_lolor_lo_tell64;
  ALTER FUNCTION pg_catalog.lo_tell64_orig(integer) RENAME TO lo_tell64;
  ALTER FUNCTION pg_catalog.lo_truncate(integer, integer) RENAME TO pg_lolor_lo_truncate;
  ALTER FUNCTION pg_catalog.lo_truncate_orig(integer, integer) RENAME TO lo_truncate;
  ALTER FUNCTION pg_catalog.lo_truncate64(integer, bigint) RENAME TO pg_lolor_lo_truncate64;
  ALTER FUNCTION pg_catalog.lo_truncate64_orig(integer, bigint) RENAME TO lo_truncate64;
  ALTER FUNCTION pg_catalog.lo_unlink(oid) RENAME TO pg_lolor_lo_unlink;
  ALTER FUNCTION pg_catalog.lo_unlink_orig(oid) RENAME TO lo_unlink;

  -- Renaming changes which OID owns the name lo_open, and libpq caches the
  -- large object fastpath OIDs per connection: sessions that touched a large
  -- object before this call keep using the previous implementation.
  RAISE NOTICE 'existing sessions must reconnect before using large objects'
    USING DETAIL = 'libpq resolves the large object function OIDs once per '
                   'connection and caches them.';

  RETURN true;
END;
$$ LANGUAGE plpgsql STRICT VOLATILE;


/*
 * Enable pg_lolor functionality, undoing lolor.disable().
 */
CREATE FUNCTION lolor.enable()
RETURNS boolean AS $$
BEGIN
  -- The probes below are a check-then-act, but no lock is needed: the whole
  -- body runs in one transaction, so a concurrent caller that loses the race
  -- fails on a rename and rolls back, leaving the state consistent.
  -- Probe exact signatures qualified to pg_catalog.  Matching on proname
  -- alone would let any user with CREATE on any schema squat 'pg_lolor_lo_open'
  -- and wedge pg_lolor into a permanent 'inconsistent state', which would also
  -- block DROP EXTENSION.
  IF to_regprocedure('pg_catalog.pg_lolor_lo_open(oid,int4)') IS NULL THEN
    RAISE NOTICE 'pg_lolor is already enabled';
    RETURN false;
  END IF;
  IF to_regprocedure('pg_catalog.lo_close_orig(int4)') IS NOT NULL THEN
    RAISE NOTICE 'lolor.enable() has been called before';
    RETURN false;
  END IF;

  ALTER FUNCTION pg_catalog.lo_open(oid, int4) RENAME TO lo_open_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_open(oid, int4) RENAME TO lo_open;
  ALTER FUNCTION pg_catalog.lo_close(int4) RENAME TO lo_close_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_close(int4) RENAME TO lo_close;
  ALTER FUNCTION pg_catalog.lo_creat(integer) RENAME TO lo_creat_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_creat(integer) RENAME TO lo_creat;
  ALTER FUNCTION pg_catalog.lo_create(oid) RENAME TO lo_create_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_create(oid) RENAME TO lo_create;
  ALTER FUNCTION pg_catalog.loread(integer, integer) RENAME TO loread_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_loread(integer, integer) RENAME TO loread;
  ALTER FUNCTION pg_catalog.lowrite(integer, bytea) RENAME TO lowrite_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lowrite(integer, bytea) RENAME TO lowrite;
  ALTER FUNCTION pg_catalog.lo_export(oid, text) RENAME TO lo_export_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_export(oid, text) RENAME TO lo_export;
  ALTER FUNCTION pg_catalog.lo_from_bytea(oid, bytea) RENAME TO lo_from_bytea_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_from_bytea(oid, bytea) RENAME TO lo_from_bytea;
  ALTER FUNCTION pg_catalog.lo_get(oid) RENAME TO lo_get_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_get(oid) RENAME TO lo_get;
  ALTER FUNCTION pg_catalog.lo_get(oid, bigint, integer) RENAME TO lo_get_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_get(oid, bigint, integer) RENAME TO lo_get;
  ALTER FUNCTION pg_catalog.lo_import(text) RENAME TO lo_import_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_import(text) RENAME TO lo_import;
  ALTER FUNCTION pg_catalog.lo_import(text, oid) RENAME TO lo_import_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_import(text, oid) RENAME TO lo_import;
  ALTER FUNCTION pg_catalog.lo_lseek(integer, integer, integer) RENAME TO lo_lseek_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_lseek(integer, integer, integer) RENAME TO lo_lseek;
  ALTER FUNCTION pg_catalog.lo_lseek64(integer, bigint, integer) RENAME TO lo_lseek64_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_lseek64(integer, bigint, integer) RENAME TO lo_lseek64;
  ALTER FUNCTION pg_catalog.lo_put(oid, bigint, bytea) RENAME TO lo_put_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_put(oid, bigint, bytea) RENAME TO lo_put;
  ALTER FUNCTION pg_catalog.lo_tell(integer) RENAME TO lo_tell_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_tell(integer) RENAME TO lo_tell;
  ALTER FUNCTION pg_catalog.lo_tell64(integer) RENAME TO lo_tell64_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_tell64(integer) RENAME TO lo_tell64;
  ALTER FUNCTION pg_catalog.lo_truncate(integer, integer) RENAME TO lo_truncate_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_truncate(integer, integer) RENAME TO lo_truncate;
  ALTER FUNCTION pg_catalog.lo_truncate64(integer, bigint) RENAME TO lo_truncate64_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_truncate64(integer, bigint) RENAME TO lo_truncate64;
  ALTER FUNCTION pg_catalog.lo_unlink(oid) RENAME TO lo_unlink_orig;
  ALTER FUNCTION pg_catalog.pg_lolor_lo_unlink(oid) RENAME TO lo_unlink;

  -- Renaming changes which OID owns the name lo_open, and libpq caches the
  -- large object fastpath OIDs per connection: sessions that touched a large
  -- object before this call keep using the previous implementation.
  RAISE NOTICE 'existing sessions must reconnect before using large objects'
    USING DETAIL = 'libpq resolves the large object function OIDs once per '
                   'connection and caches them.';

  RETURN true;
END;
$$ LANGUAGE plpgsql STRICT VOLATILE;

/*
 * Storage relocation mechanism.
 *
 * lolor.migrate_storage() moves every large object from one store to the
 * other by copying tuples directly between the two relations, which have
 * identical layouts by construction.  It carries ownership, ACLs and comments
 * across, verifies the layouts at run time, and removes native objects
 * through the same deletion path DROP uses.
 *
 * This is the mechanism only.  Policy -- privileges and the interaction with
 * logical replication -- lives in the wrappers below, which are the supported
 * entry points.
 */
CREATE FUNCTION lolor.migrate_storage(to_native boolean)
	RETURNS bigint
	AS 'MODULE_PATHNAME', 'pg_lolor_migrate_storage'
	LANGUAGE C STRICT VOLATILE;

REVOKE ALL ON FUNCTION lolor.migrate_storage(boolean) FROM PUBLIC;

/*
 * Shared replication guard.
 *
 * Both migration directions face the same question: the row movement is a
 * node-local storage relocation, but logical decoding cannot tell that apart
 * from ordinary DML.  A subscriber that decodes it applies the relocation as
 * ordinary row changes and diverges from this node.
 *
 * PostgreSQL offers no way to exclude specific DML from logical decoding, so
 * the only safe answer is to refuse while any logical slot could observe it.
 * Returns true when the migration may proceed and false when it must be
 * skipped; a strict caller gets an ERROR rather than false.
 */
CREATE FUNCTION lolor._migration_guard(strict_mode boolean, refuse_hint text)
RETURNS boolean AS $$
DECLARE
  lr_slots boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_replication_slots
     WHERE slot_type = 'logical' AND database = current_database()
  ) INTO lr_slots;

  -- Nothing decodes this database, so the relocation cannot be observed.
  IF NOT lr_slots THEN
    RETURN true;
  END IF;

  IF strict_mode THEN
    RAISE EXCEPTION 'cannot migrate large objects while logical replication slots exist'
      USING DETAIL = 'The migration cannot be excluded from logical decoding, so '
                     'subscribers would receive this node-local storage '
                     'relocation as ordinary row changes.',
            HINT = refuse_hint;
  END IF;

  RAISE WARNING 'not migrating large objects while logical replication slots exist'
    USING DETAIL = 'No large objects were migrated.',
          HINT = refuse_hint;
  RETURN false;
END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE ALL ON FUNCTION lolor._migration_guard(boolean, text) FROM PUBLIC;

CREATE FUNCTION lolor.migrate_from_native(peer_oids oid[] DEFAULT NULL)
RETURNS bigint AS $$
DECLARE
  lo_count bigint;
  overlap  oid[];
  labelled bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper) THEN
    RAISE EXCEPTION 'must be superuser to migrate large objects';
  END IF;

  SELECT count(*) INTO lo_count FROM pg_catalog.pg_largeobject_metadata;

  IF lo_count = 0 THEN
    RAISE NOTICE 'no native large objects to migrate';
    RETURN 0;
  END IF;

  -- Security labels have nowhere to live in pg_lolor storage and, unlike
  -- comments, cannot be parked and replayed: reinstating one has to go
  -- through the label provider.  Refuse rather than discard them.
  SELECT count(*) INTO labelled
  FROM pg_catalog.pg_seclabel
  WHERE classoid = 'pg_catalog.pg_largeobject'::regclass;

  IF labelled > 0 THEN
    RAISE EXCEPTION 'cannot migrate large objects that have security labels'
      USING DETAIL = format('%s large object security label(s) found.', labelled),
            HINT = 'Remove them with SECURITY LABEL ... IS NULL before migrating.';
  END IF;

  /* Cross-node OID collision pre-flight; see the comment on this function. */
  IF peer_oids IS NOT NULL THEN
    SELECT array_agg(m.oid ORDER BY m.oid) INTO overlap
    FROM pg_catalog.pg_largeobject_metadata m
    WHERE m.oid = ANY (peer_oids);

    IF overlap IS NOT NULL THEN
      RAISE EXCEPTION 'cannot migrate large objects that another node also holds natively'
        USING DETAIL = format('Colliding OIDs: %s.', overlap),
              HINT = 'Native OIDs are not node-encoded. Re-create the colliding '
                     'objects under fresh OIDs on one node before migrating.';
    END IF;
  END IF;

  IF NOT lolor._migration_guard(
           false,
           'Drop the offending logical replication slots in this database and retry.') THEN
    RETURN -1;
  END IF;

  PERFORM lolor.migrate_storage(false);

  RETURN lo_count;
END;
$$ LANGUAGE plpgsql VOLATILE;

/*
 * lolor.migrate_to_native()
 *
 * Move every large object from pg_lolor storage back into native storage.
 *
 * Called automatically by the drop event trigger, and safe to invoke by hand.
 * Does not require pg_lolor to be enabled: the movement is performed directly
 * against the catalogs and never calls the renamed _orig functions.
 *
 * Failure is a hard ERROR, not a soft return: this runs on the DROP path,
 * where silently losing large objects is far worse than a failed DROP.
 */
CREATE FUNCTION lolor.migrate_to_native()
RETURNS bigint AS $$
DECLARE
  lo_count bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper) THEN
    RAISE EXCEPTION 'must be superuser to migrate large objects';
  END IF;

  SELECT count(*) INTO lo_count FROM lolor.pg_largeobject_metadata;

  IF lo_count = 0 THEN
    RAISE NOTICE 'no pg_lolor large objects to migrate';
    RETURN 0;
  END IF;

  PERFORM lolor._migration_guard(
      true,
      'Drop the offending logical replication slots in this database and retry.');

  PERFORM lolor.migrate_storage(true);

  RETURN lo_count;
END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE ALL ON FUNCTION lolor.migrate_from_native(oid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION lolor.migrate_to_native() FROM PUBLIC;

/*
 * Native large object OIDs held by this node, for the cross-node pre-flight
 * of lolor.migrate_from_native().
 */
CREATE FUNCTION lolor.native_lo_oids()
RETURNS SETOF oid AS $$
  SELECT oid FROM pg_catalog.pg_largeobject_metadata ORDER BY oid
$$ LANGUAGE sql STABLE;

/*
 * Per-object digest of pg_lolor storage, so that convergence across nodes can be
 * checked instead of assumed.  Compare the output on every node after
 * migrating: because the movement is hidden from replication, divergence is
 * otherwise silent until a later conflict.
 *
 * This reads every page and is deliberately not cheap; run it as a check, not
 * on a schedule.
 */
CREATE FUNCTION lolor.digest()
RETURNS TABLE (loid oid, lomowner name, npages bigint, nbytes bigint, digest text)
AS $$
  SELECT m.oid,
         pg_catalog.pg_get_userbyid(m.lomowner),
         count(d.pageno),
         coalesce(sum(length(d.data)), 0),
         md5(coalesce(string_agg(md5(d.data), ',' ORDER BY d.pageno), ''))
  FROM lolor.pg_largeobject_metadata m
  LEFT JOIN lolor.pg_largeobject d ON d.loid = m.oid
  GROUP BY m.oid, m.lomowner
  ORDER BY m.oid
$$ LANGUAGE sql STABLE;

/*
 * Large objects in pg_lolor storage whose owner no longer exists.
 *
 * Objects in pg_lolor storage are rows in ordinary tables, so they cannot
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
