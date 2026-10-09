/* lolor--1.2.2--1.3.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION lolor UPDATE" to load this file. \quit

-- Warn if there are active streaming replicas — they need lolor installed too
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_stat_replication WHERE state = 'streaming') THEN
    RAISE NOTICE 'lolor: active streaming replica(s) detected. '
      'Ensure the lolor extension is also installed on each replica, '
      'otherwise large object operations will fail if a replica is promoted.';
  END IF;
END;
$$;

/*
 * Restore the ACLs on the server-side file access functions.
 *
 * pg_catalog.lo_import() and lo_export() read and write files as the account
 * PostgreSQL runs under, so core revokes EXECUTE on them from PUBLIC.  lolor
 * replaces them by renaming the originals to *_orig and creating its own.  An
 * ACL belongs to a function rather than to a name, so the restriction stayed
 * on the parked original while each replacement was created with the default
 * of EXECUTE TO PUBLIC.  Every version through 1.2.2 is affected.
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
 * Shared precondition for enable(), disable() and the migration functions.
 * Defined with CREATE OR REPLACE so that the lifecycle change set can carry an
 * identical copy; whichever lands second is a no-op.
 */
CREATE OR REPLACE FUNCTION lolor._require_no_other_sessions(what text)
RETURNS void AS $$
DECLARE
  n    int;
  self text;
BEGIN
  -- A background worker, such as an apply worker executing replicated DDL,
  -- is not a client session and must not do this at all: the change is
  -- node-local and a refusal would leave that worker retrying forever.
  SELECT backend_type INTO self
  FROM pg_catalog.pg_stat_activity
  WHERE pid = pg_backend_pid();

  IF self IS DISTINCT FROM 'client backend' THEN
    RAISE EXCEPTION 'cannot % from a %', what, coalesce(self, 'non-client process')
      USING HINT = 'Run it from a client session connected directly to this node.';
  END IF;

  SELECT count(*) INTO n
  FROM pg_catalog.pg_stat_activity
  WHERE datname = current_database()
    AND backend_type = 'client backend'
    AND pid <> pg_backend_pid();

  IF n > 0 THEN
    RAISE EXCEPTION 'cannot % while other sessions are connected to the database', what
      USING DETAIL = CASE WHEN n = 1 THEN '1 other session is connected.'
                          ELSE n || ' other sessions are connected.' END,
            HINT = 'Disconnect them first. A session that already resolved the '
                   'large object functions keeps calling the previous implementation.';
  END IF;
END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE ALL ON FUNCTION lolor._require_no_other_sessions(text) FROM PUBLIC;


/*
 * Comment parking.
 *
 * COMMENT ON LARGE OBJECT stores its text in pg_description keyed by
 * (classoid = 'pg_largeobject', objoid = loid).  While an object lives in
 * lolor storage there is no catalog object for that row to describe, so the
 * comment is parked here and restored on the way back.  Without this it is
 * silently lost the first time an object is migrated.
 */
CREATE TABLE lolor.pg_largeobject_description(
	loid		oid NOT NULL,
	description	text NOT NULL,
	CONSTRAINT pg_largeobject_description_pkey PRIMARY KEY (loid));
SELECT pg_catalog.pg_extension_config_dump('lolor.pg_largeobject_description', '');

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
	AS 'MODULE_PATHNAME', 'lolor_migrate_storage'
	LANGUAGE C STRICT VOLATILE;

REVOKE ALL ON FUNCTION lolor.migrate_storage(boolean) FROM PUBLIC;

/*
 * Shared replication guard.
 *
 * Both migration directions face the same question: the row movement is a
 * node-local storage relocation, but logical decoding cannot tell that apart
 * from ordinary DML.  If a subscriber decodes it, the two nodes diverge.
 *
 * Returns true when repair mode was engaged and the caller must turn it off,
 * false when no suppression was needed, and NULL when the migration must be
 * refused.  NULL is only ever returned when strict_mode is false; a strict
 * caller gets an ERROR instead.
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

  -- spock.repair_mode() suppresses spock's own 'spock_output' plugin only;
  -- any other plugin decoding this database would still see the migration.
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

  PERFORM lolor._require_no_other_sessions('migrate large objects');

  SELECT count(*) INTO lo_count FROM pg_catalog.pg_largeobject_metadata;

  IF lo_count = 0 THEN
    RAISE NOTICE 'no native large objects to migrate';
    RETURN 0;
  END IF;

  -- Security labels have nowhere to live in lolor storage and, unlike
  -- comments, cannot be parked and replayed: reinstating one has to go
  -- through the label provider.  Refuse rather than discard them.
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

  -- Cover exactly the migration and nothing after it.  Error paths need no
  -- cleanup: they abort the whole transaction.
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
CREATE FUNCTION lolor.migrate_to_native()
RETURNS bigint AS $$
DECLARE
  lo_count       bigint;
  repair_enabled boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper) THEN
    RAISE EXCEPTION 'lolor.migrate_to_native() requires superuser privileges';
  END IF;

  PERFORM lolor._require_no_other_sessions('migrate large objects');

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
