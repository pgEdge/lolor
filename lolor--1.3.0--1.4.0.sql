/* lolor--1.3.0--1.4.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION lolor UPDATE" to load this file. \quit

/*
 * ---------------------------------------------------------------------------
 * Comment parking
 * ---------------------------------------------------------------------------
 *
 * COMMENT ON LARGE OBJECT stores its text in pg_description keyed by
 * (classoid = 'pg_largeobject', objoid = loid).  While an object lives in
 * lolor storage there is no catalog object for that row to describe, so the
 * comment is parked here and restored on the way back to native storage.
 * Without this the comment is silently lost the first time an object is
 * migrated.
 */
CREATE TABLE lolor.pg_largeobject_description(
	loid		oid NOT NULL,
	description	text NOT NULL,
	CONSTRAINT pg_largeobject_description_pkey PRIMARY KEY (loid));
SELECT pg_catalog.pg_extension_config_dump('lolor.pg_largeobject_description', '');

/*
 * ---------------------------------------------------------------------------
 * Storage relocation mechanism
 * ---------------------------------------------------------------------------
 *
 * lolor.migrate_storage() moves every large object from one store to the
 * other by copying tuples directly between the two relations, which have
 * identical layouts by construction.  It carries ownership, ACLs and comments
 * across, verifies the layouts at run time, and removes native objects
 * through the same deletion path DROP uses.
 *
 * It is the mechanism only.  Policy -- privileges and the interaction with
 * logical replication -- lives in the wrappers below, which are the supported
 * entry points.
 */
CREATE FUNCTION lolor.migrate_storage(to_native boolean)
	RETURNS bigint
	AS 'MODULE_PATHNAME', 'lolor_migrate_storage'
	LANGUAGE C STRICT VOLATILE;

REVOKE ALL ON FUNCTION lolor.migrate_storage(boolean) FROM PUBLIC;

/*
 * ---------------------------------------------------------------------------
 * Shared replication guard
 * ---------------------------------------------------------------------------
 *
 * Both migration directions face the same question: the row movement is a
 * node-local storage relocation, but logical decoding cannot tell that apart
 * from ordinary DML.  If a subscriber decodes it, the two nodes diverge.
 *
 * Returns true when repair mode was engaged and the caller must turn it off,
 * false when no suppression was needed, and NULL when the migration must be
 * refused.  NULL is only ever returned when strict_mode is false; a strict
 * caller gets an ERROR instead.  That asymmetry is deliberate and is
 * explained at each call site.
 */
CREATE FUNCTION lolor._migration_guard(strict_mode boolean, refuse_hint text)
RETURNS boolean AS $$
DECLARE
  lr_slots      boolean;
  foreign_slots boolean;
  spock_ready   boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_replication_slots
     WHERE slot_type = 'logical' AND database = current_database()
  ) INTO lr_slots;

  -- Nothing decodes this database: nothing to suppress.
  IF NOT lr_slots THEN
    RETURN false;
  END IF;

  -- Use spock only when it is fully operational: the extension is installed
  -- (pg_extension is superuser-gated, so the schema name cannot be squatted
  -- by an unprivileged user), the function exists (older spock versions lack
  -- it) and the GUC exists (the library is actually preloaded).
  spock_ready :=
       EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'spock')
   AND to_regprocedure('spock.repair_mode(boolean)') IS NOT NULL
   AND current_setting('spock.replication_repair_mode', true) IS NOT NULL;

  IF NOT spock_ready THEN
    IF strict_mode THEN
      RAISE EXCEPTION 'cannot migrate large objects: logical replication slot(s) exist'
        USING DETAIL = 'Without spock the migration DML cannot be excluded from '
                       'logical decoding, so subscribers would receive this '
                       'node-local storage relocation as ordinary row changes',
              HINT = refuse_hint;
    END IF;
    RAISE WARNING 'not migrating: logical replication slot(s) exist'
      USING DETAIL = 'This call is a no-op: no large objects were migrated',
            HINT = refuse_hint;
    RETURN NULL;
  END IF;

  -- spock.repair_mode() suppresses spock's own output plugin only.  That
  -- plugin is the 'spock_output' module (spock's Makefile builds it as
  -- MODULES = spock_output); any other plugin decoding this database would
  -- still see the migration DML.
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_replication_slots
     WHERE slot_type = 'logical' AND database = current_database()
       AND plugin <> 'spock_output'
  ) INTO foreign_slots;

  IF foreign_slots THEN
    IF strict_mode THEN
      RAISE EXCEPTION 'cannot migrate large objects: non-spock logical replication slot(s) exist'
        USING DETAIL = 'spock repair mode silences only the spock_output plugin; a slot '
                       'using another plugin (pgoutput, wal2json, decoderbufs, ...) would '
                       'still decode the migration and diverge from this node',
              HINT = refuse_hint;
    END IF;
    RAISE WARNING 'not migrating: non-spock logical replication slot(s) exist'
      USING DETAIL = 'This call is a no-op: no large objects were migrated',
            HINT = refuse_hint;
    RETURN NULL;
  END IF;

  IF current_setting('spock.replication_repair_mode', true) = 'off' THEN
    PERFORM spock.repair_mode(true);
    RETURN true;
  END IF;

  -- Repair mode was already on; leave it to whoever turned it on.
  RETURN false;
END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE ALL ON FUNCTION lolor._migration_guard(boolean, text) FROM PUBLIC;

/*
 * ---------------------------------------------------------------------------
 * Migration entry points
 * ---------------------------------------------------------------------------
 */

/*
 * lolor.migrate_from_native(peer_oids)
 *
 * Move every native large object into lolor storage, preserving OIDs, owners,
 * ACLs, comments and exact page layout.  Returns the number of objects moved,
 * or -1 if the migration was refused because logical decoding of the movement
 * could not be suppressed.
 *
 * Refusal is a soft -1 rather than an ERROR because this is a manual,
 * non-destructive operation: on refusal the native objects are untouched, so
 * the caller can drop the offending slots and retry.  Callers acting on the
 * result MUST check for a negative return; 0 means "nothing to migrate".
 *
 * peer_oids optionally carries the native large object OIDs held by the other
 * nodes of the cluster.  Native OIDs are not node-encoded, so two nodes can
 * independently hold different objects under the same OID; migrating both
 * would converge them onto one row and diverge the cluster.  Because the
 * movement is hidden from replication, nothing would detect that afterwards.
 * Supplying peer_oids turns it into a pre-flight refusal.  Collect them with
 * lolor.native_lo_oids() on each node first.
 */
DROP FUNCTION lolor.migrate_from_native();
CREATE FUNCTION lolor.migrate_from_native(peer_oids oid[] DEFAULT NULL)
RETURNS bigint AS $$
DECLARE
  lo_count       bigint;
  repair_enabled boolean;
  overlap        oid[];
  labelled       bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper) THEN
    RAISE EXCEPTION 'lolor.migrate_from_native() requires superuser privileges';
  END IF;

  SELECT count(*) INTO lo_count FROM pg_catalog.pg_largeobject_metadata;

  IF lo_count = 0 THEN
    RAISE NOTICE 'no native large objects to migrate';
    RETURN 0;
  END IF;

  /*
   * Security labels are attached to the pg_largeobject catalog entry and have
   * nowhere to live in lolor storage.  Unlike comments they cannot be parked
   * and replayed, because reinstating one has to go through the label
   * provider.  Refuse rather than discard them silently.
   */
  SELECT count(*) INTO labelled
  FROM pg_catalog.pg_seclabel
  WHERE classoid = 'pg_catalog.pg_largeobject'::regclass;

  IF labelled > 0 THEN
    RAISE EXCEPTION 'cannot migrate: % large object security label(s) present', labelled
      USING DETAIL = 'lolor storage cannot represent security labels, and they '
                     'cannot be reinstated without their label provider',
            HINT = 'Remove the labels with SECURITY LABEL ... IS NULL before migrating';
  END IF;

  /* Cross-node OID collision pre-flight; see the comment on this function. */
  IF peer_oids IS NOT NULL THEN
    SELECT array_agg(m.oid ORDER BY m.oid) INTO overlap
    FROM pg_catalog.pg_largeobject_metadata m
    WHERE m.oid = ANY (peer_oids);

    IF overlap IS NOT NULL THEN
      RAISE EXCEPTION 'cannot migrate: % OID(s) are also held natively by another node',
        array_length(overlap, 1)
        USING DETAIL = format('Colliding OID(s): %s', overlap),
              HINT = 'Native OIDs are not node-encoded. Re-create the colliding objects '
                     'under fresh OIDs on one of the nodes before migrating';
    END IF;
  END IF;

  repair_enabled := lolor._migration_guard(
      false,
      'Drop the offending logical replication slots in this database and retry');

  IF repair_enabled IS NULL THEN
    RETURN -1;
  END IF;

  PERFORM lolor.migrate_storage(false);

  /*
   * Re-enable replication for the remainder of the caller's transaction, so
   * repair mode covers exactly the migration and nothing after it.  Error
   * paths need no cleanup: they abort the whole transaction.
   */
  IF repair_enabled THEN
    PERFORM spock.repair_mode(false);
  END IF;

  RETURN lo_count;
END;
$$ LANGUAGE plpgsql VOLATILE;

/*
 * lolor.migrate_to_native()
 *
 * Move every large object from lolor storage back into native storage.
 *
 * Called automatically by the drop event trigger, and safe to invoke by hand.
 * Unlike previous versions this does not require lolor to be enabled: the
 * movement is performed directly against the catalogs and never calls the
 * renamed _orig functions.
 *
 * Failure is a hard ERROR, not a soft return: this runs on the DROP path,
 * where silently losing large objects is far worse than a failed DROP.
 */
CREATE OR REPLACE FUNCTION lolor.migrate_to_native()
RETURNS bigint AS $$
DECLARE
  lo_count       bigint;
  repair_enabled boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper) THEN
    RAISE EXCEPTION 'lolor.migrate_to_native() requires superuser privileges';
  END IF;

  SELECT count(*) INTO lo_count FROM lolor.pg_largeobject_metadata;

  IF lo_count = 0 THEN
    RAISE NOTICE 'no lolor large objects to migrate';
    RETURN 0;
  END IF;

  repair_enabled := lolor._migration_guard(
      true,
      'Drop the offending logical replication slots in this database and retry');

  PERFORM lolor.migrate_storage(true);

  IF repair_enabled THEN
    PERFORM spock.repair_mode(false);
  END IF;

  RETURN lo_count;
END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE ALL ON FUNCTION lolor.migrate_from_native(oid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION lolor.migrate_to_native() FROM PUBLIC;

/*
 * ---------------------------------------------------------------------------
 * Verification helpers
 * ---------------------------------------------------------------------------
 */

/*
 * Native large object OIDs held by this node, for the cross-node pre-flight
 * of lolor.migrate_from_native().
 */
CREATE FUNCTION lolor.native_lo_oids()
RETURNS SETOF oid AS $$
  SELECT oid FROM pg_catalog.pg_largeobject_metadata ORDER BY oid
$$ LANGUAGE sql STABLE;

/*
 * Per-object digest of lolor storage, so that convergence across nodes can be
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
 * Large objects in lolor storage whose owner no longer exists.
 *
 * Objects in lolor storage are rows in ordinary tables, so they cannot
 * participate in pg_shdepend: DROP ROLE will not notice them the way it
 * notices native large objects.  This is inherent to storing them outside the
 * catalogs.  This function makes the consequence findable.
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
 * ---------------------------------------------------------------------------
 * Hardened enable / disable / is_enabled
 * ---------------------------------------------------------------------------
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
  -- proname alone across every schema, which let any user with CREATE on any
  -- schema squat a name such as 'lolor_lo_open' and wedge lolor into a
  -- permanent 'inconsistent state' -- including blocking DROP EXTENSION.
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

  -- Renaming changes which OID owns the name lo_open.  libpq resolves the
  -- large object fastpath OIDs once per connection and caches them, so
  -- sessions that touched a large object before this call keep calling the
  -- previous implementation until they reconnect.
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
  -- proname alone across every schema, which let any user with CREATE on any
  -- schema squat a name such as 'lolor_lo_open' and wedge lolor into a
  -- permanent 'inconsistent state' -- including blocking DROP EXTENSION.
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

  -- Renaming changes which OID owns the name lo_open.  libpq resolves the
  -- large object fastpath OIDs once per connection and caches them, so
  -- sessions that touched a large object before this call keep calling the
  -- previous implementation until they reconnect.
  RAISE NOTICE 'lolor: reconnect existing client sessions; they cache large object function OIDs';

  RETURN true;
END;
$$ LANGUAGE plpgsql STRICT VOLATILE;


/*
 * ---------------------------------------------------------------------------
 * Drop cleanup
 * ---------------------------------------------------------------------------
 *
 * The extension does not only go away through DROP EXTENSION: DROP SCHEMA
 * lolor CASCADE and DROP OWNED BY <extension owner> reach it by dependency
 * cascade.  Those fire under their own command tags, so the trigger has to be
 * registered for them too -- otherwise the cleanup never runs, the large
 * objects are destroyed with the lolor tables, and pg_catalog is left without
 * a working lo_open().  Tags cannot be altered in place, so re-create it.
 */
DROP EVENT TRIGGER lo_on_drop_extension;
CREATE EVENT TRIGGER lo_on_drop_extension
	ON ddl_command_start
	WHEN tag IN ('DROP EXTENSION', 'DROP SCHEMA', 'DROP OWNED')
	EXECUTE FUNCTION pg_catalog.lo_on_drop_extension();
ALTER EVENT TRIGGER lo_on_drop_extension ENABLE ALWAYS;

/*
 * ---------------------------------------------------------------------------
 * Restore the ACLs on the server-side file access functions
 * ---------------------------------------------------------------------------
 *
 * pg_catalog.lo_import() and lo_export() read and write files on the server as
 * the operating system account PostgreSQL runs under, so core revokes EXECUTE
 * on them from PUBLIC.
 *
 * lolor replaces them by renaming the originals to *_orig and creating its own
 * versions.  An ACL belongs to a function, not to a name, so the restriction
 * stayed behind on the parked originals while the replacements were created
 * with the default: EXECUTE granted to PUBLIC.  Any database user could
 * therefore call lo_import('/etc/passwd') or overwrite a file with
 * lo_export().  Installations created before 1.4.0 are affected whether or not
 * lolor is currently enabled.
 *
 * Revoke on both spellings so the fix lands regardless of which state the
 * installation is in.  Revoking on a native function that is already
 * restricted is a no-op.
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
 * ---------------------------------------------------------------------------
 * Remove bogus pg_shdepend rows left by earlier versions
 * ---------------------------------------------------------------------------
 *
 * Through 1.3.0, creating a large object recorded a pg_shdepend row whose
 * classId was the OID of lolor.pg_largeobject -- an ordinary table, not a
 * catalog the dependency machinery can describe.  DROP ROLE on any role that
 * had created a large object failed with "unrecognized object class", and the
 * rows were never removed because inv_drop() deletes with
 * PERFORM_DELETION_SKIP_ORIGINAL.  lolor no longer records them; delete the
 * ones already there.
 *
 * pg_shdepend is shared across the cluster, so restrict the delete to this
 * database: the same classId value in another database refers to some
 * unrelated relation.
 */
DELETE FROM pg_catalog.pg_shdepend
WHERE dbid = (SELECT oid FROM pg_catalog.pg_database
               WHERE datname = current_database())
  AND classid IN ('lolor.pg_largeobject'::regclass,
                  'lolor.pg_largeobject_metadata'::regclass);
