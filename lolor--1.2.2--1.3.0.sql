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
 * lolor.migrate_from_native()
 *
 * Migrate all native PostgreSQL large objects from pg_catalog.pg_largeobject
 * into lolor's storage, preserving original OIDs, owners, ACLs, and data.
 * After migration, the native copies are removed.
 *
 * The entire operation is transactional: if anything fails, ROLLBACK undoes
 * all changes and no data is lost.
 *
 * Returns the number of large objects migrated, or -1 if migration was
 * refused because logical replication slots exist whose decoding of the
 * migration DML cannot be suppressed: either spock is not available to
 * silence its own slots, or a non-spock slot (e.g. pgoutput, wal2json) is
 * present that spock.repair_mode() cannot exclude.
 *
 * Refusal is reported as a soft -1 return (alongside a WARNING), not an
 * error, and this asymmetry with migrate_to_native() is deliberate.  This
 * function is a manual, non-destructive operation: on refusal the native
 * large objects are left untouched, so the caller can drop the offending
 * slots and simply retry.
 *
 * Callers acting on the result MUST check for a non-positive return: a -1
 * means nothing was migrated, and ignoring it treats a refused migration
 * as success.
 */
CREATE FUNCTION lolor.migrate_from_native()
RETURNS bigint AS $$
DECLARE
  lo_count          bigint;
  inserted_count    bigint;
  page_count        bigint;
  native_page_count bigint;
  repair_enabled    boolean := false;
  lr_slots_exists   boolean := false;
  foreign_lr_slots_exists boolean := false;
BEGIN
  -- Only superusers can read pg_largeobject.data and unlink others' objects
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper) THEN
    RAISE EXCEPTION 'lolor.migrate_from_native() requires superuser privileges';
  END IF;

  -- Verify lolor is enabled (functions are replaced)
  IF NOT lolor.is_enabled() THEN
    RAISE EXCEPTION 'lolor must be enabled before migration';
  END IF;

  -- Check for OID conflicts: native LOs that already exist in lolor storage
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_largeobject_metadata native
    JOIN lolor.pg_largeobject_metadata lm ON lm.oid = native.oid
  ) THEN
    RAISE EXCEPTION 'OID conflict: some native large objects already exist in lolor storage';
  END IF;

  -- Count what we are about to migrate
  SELECT count(*) INTO lo_count FROM pg_catalog.pg_largeobject_metadata;

  IF lo_count = 0 THEN
    RAISE NOTICE 'no native large objects to migrate';
    RETURN 0;
  END IF;

  -- Logical slots indicate subscribers (replica nodes) that will not receive
  -- the node-local migration DML.
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_replication_slots
    WHERE slot_type = 'logical' AND database = current_database()
  ) INTO lr_slots_exists;

  -- XXX: there are no evidence that the 'spock' name has been used anywhere.
  -- Fix this mess later.
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_replication_slots
    WHERE slot_type = 'logical' AND database = current_database()
      AND plugin NOT IN ('spock_output', 'spock')
  ) INTO foreign_lr_slots_exists;

  -- Suppress spock replication of the bulk migration DML.  The migration only
  -- shuffles rows between native and lolor storage on this node.
  --
  -- Use spock only when it is fully operational: the extension is installed
  -- (pg_extension is superuser-gated, so the schema name cannot be squatted
  -- by an unprivileged user), the function exists (older spock versions lack
  -- it) and the GUC exists (the library is actually preloaded).  Anything
  -- less falls through to the refusal branch below.
  --
  -- Without spock the migration DML cannot be excluded from logical decoding,
  -- so if any logical replication slot exists the migrated rows would leak to
  -- subscribers.
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'spock')
     AND to_regprocedure('spock.repair_mode(boolean)') IS NOT NULL
     AND current_setting('spock.replication_repair_mode', true) IS NOT NULL
  THEN
    -- If a non-spock logical slot is present its consumer would still decode
    -- the bulk migration DML and receive the node-local row shuffling.
    -- Refuse rather than leak the migration to that subscriber.
    IF foreign_lr_slots_exists THEN
      RAISE WARNING 'not migrating: non-spock logical replication slot(s) exist'
        USING DETAIL = 'This call is a no-op: no large objects were migrated. '
                       'spock repair mode cannot exclude the migration DML from '
                       'non-spock output plugins (e.g. pgoutput, wal2json), so the '
                       'migrated rows would leak to those subscribers',
              HINT = 'Drop all non-spock logical replication slots in this database before executing this procedure';
      RETURN -1;
    END IF;

    IF current_setting('spock.replication_repair_mode', true) = 'off' THEN
      PERFORM spock.repair_mode(true);
      repair_enabled := true;
    END IF;
  ELSIF lr_slots_exists THEN
    RAISE WARNING 'not migrating: logical replication slot(s) exist'
      USING DETAIL = 'This call is a no-op: no large objects were migrated',
            HINT = 'Drop all logical replication slots in this database before executing this procedure';
    RETURN -1;
  END IF;

  SELECT count(*) INTO native_page_count
  FROM pg_catalog.pg_largeobject;

  -- Copy metadata (preserving OIDs, owners, and ACLs)
  INSERT INTO lolor.pg_largeobject_metadata (oid, lomowner, lomacl)
  SELECT oid, lomowner, lomacl
  FROM pg_catalog.pg_largeobject_metadata;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  IF inserted_count <> lo_count THEN
    RAISE EXCEPTION 'metadata row count mismatch: expected %, inserted %',
      lo_count, inserted_count;
  END IF;

  -- Copy data pages
  INSERT INTO lolor.pg_largeobject (loid, pageno, data)
    SELECT loid, pageno, data FROM pg_catalog.pg_largeobject;

  GET DIAGNOSTICS page_count = ROW_COUNT;
  IF page_count <> native_page_count THEN
    RAISE EXCEPTION 'data page count mismatch: expected %, inserted %',
      native_page_count, page_count;
  END IF;

  -- Remove native large objects using the original (renamed) function.
  -- Materialize the OID list first to avoid scanning the catalog while
  -- lo_unlink_orig modifies it.
  PERFORM pg_catalog.lo_unlink_orig(oid)
  FROM (SELECT oid FROM pg_catalog.pg_largeobject_metadata) AS native_oids;

  -- Re-enable replication for the remainder of the caller's transaction, so
  -- repair mode covers exactly the migration DML and nothing after it.
  -- Error paths need no cleanup: they abort the whole transaction.
  IF repair_enabled THEN
    PERFORM spock.repair_mode(false);
  END IF;

  RAISE NOTICE 'migrated % large object(s) (% data page(s)) from native to lolor storage',
    lo_count, page_count;

  -- The migration DML was excluded from replication, so connected subscribers
  -- (replica nodes) did not receive it.
  IF lr_slots_exists THEN
    RAISE NOTICE 'this migration is local to this node: '
      'execute lolor.migrate_from_native() on each replica as well before modifying LOs';
  END IF;

  RETURN lo_count;
END;
$$ LANGUAGE plpgsql VOLATILE;

/*
 * lolor.migrate_to_native()
 *
 * Migrate all large objects from lolor storage back into native PostgreSQL
 * storage, preserving original OIDs, owners, ACLs, and data.  After
 * migration, the lolor copies are removed.
 *
 * Called automatically by the DROP EXTENSION event trigger, but can also
 * be invoked manually to revert to native large object storage.
 *
 * The _orig functions (native LO API) must be available, which means lolor
 * must be in the enabled state.
 *
 * Returns the number of large objects migrated. RAISEs an ERROR if something
 * goes wrong.
 * The hard failure is deliberate: accidental ignore of a failure may result in
 * loosing LOs. So, user must solve the issue manually before moving forward.
 */
CREATE FUNCTION lolor.migrate_to_native()
RETURNS bigint AS $$
DECLARE
  lo_count        bigint;
  loblksize       bigint;
  r_meta          record;
  r_data          record;
  fd              integer;
  repair_enabled  boolean := false;
  lr_slots_exists boolean := false;
  foreign_lr_slots_exists boolean := false;
BEGIN
  -- Only superusers can UPDATE pg_catalog.pg_largeobject_metadata
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper) THEN
    RAISE EXCEPTION 'lolor.migrate_to_native() requires superuser privileges';
  END IF;

  -- Verify lolor is enabled so _orig functions point to native API
  IF NOT lolor.is_enabled() THEN
    RAISE EXCEPTION 'lolor must be enabled before migration to native';
  END IF;

  -- Derive LOBLKSIZE at runtime.  PostgreSQL defines it as BLCKSZ / 4.
  -- Hard-coding 2048 would break on non-default block size builds.
  loblksize := current_setting('block_size')::bigint / 4;

  -- Count what we are about to migrate
  SELECT count(*) INTO lo_count FROM lolor.pg_largeobject_metadata;

  IF lo_count = 0 THEN
    RAISE NOTICE 'no lolor large objects to migrate';
    RETURN 0;
  END IF;

  -- Check for OID conflicts
  IF EXISTS (
    SELECT 1
    FROM lolor.pg_largeobject_metadata lm
    JOIN pg_catalog.pg_largeobject_metadata native ON native.oid = lm.oid
  ) THEN
    RAISE EXCEPTION 'OID conflict: some lolor large objects already exist in native storage';
  END IF;

  -- Logical slots indicate subscribers (replica nodes) that will not receive
  -- the node-local migration DML.
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_replication_slots
    WHERE slot_type = 'logical' AND database = current_database()
  ) INTO lr_slots_exists;

  -- A logical slot whose output plugin is not spock's own cannot be silenced
  -- by spock.repair_mode().  Track those separately: their consumers would
  -- still decode the migration DML even when spock is fully operational.
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_replication_slots
    WHERE slot_type = 'logical' AND database = current_database()
      AND plugin NOT IN ('spock_output', 'spock')
  ) INTO foreign_lr_slots_exists;

  -- Suppress spock replication of the bulk migration DML.  The migration only
  -- shuffles rows between lolor and native storage on this node.
  --
  -- Use spock only when it is fully operational: the extension is installed
  -- (pg_extension is superuser-gated, so the schema name cannot be squatted
  -- by an unprivileged user), the function exists (older spock versions lack
  -- it) and the GUC exists (the library is actually preloaded).  Anything
  -- less falls through to the refusal branch below.
  --
  -- Without spock the migration DML cannot be excluded from logical decoding,
  -- so if any logical replication slot exists the deletes from the lolor
  -- tables would replicate while the re-created native large objects would
  -- not, losing large objects on the subscriber side.
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'spock')
     AND to_regprocedure('spock.repair_mode(boolean)') IS NOT NULL
     AND current_setting('spock.replication_repair_mode', true) IS NOT NULL
  THEN
    -- spock.repair_mode() only suppresses spock's own output plugin
    -- ('spock_output'/'spock').  If a non-spock logical slot is present
    -- (pgoutput, wal2json, decoderbufs, ...) its consumer would still decode
    -- the migration DML: the lolor deletes would replicate while the
    -- re-created native large objects would not, losing LOs on the subscriber.
    IF foreign_lr_slots_exists THEN
      RAISE EXCEPTION 'cannot migrate LOs to pg_catalog: non-spock logical replication slot(s) exist'
        USING DETAIL = 'spock repair mode only silences spock''s own output plugin; '
                       'a non-spock slot (e.g. pgoutput, wal2json) would replicate the '
                       'lolor deletes while the re-created native large objects would not, '
                       'losing large objects on the subscriber side',
              HINT = 'Drop all non-spock logical replication slots in this database before executing this procedure';
    END IF;

    IF current_setting('spock.replication_repair_mode', true) = 'off' THEN
      PERFORM spock.repair_mode(true);
      repair_enabled := true;
    END IF;
  ELSIF lr_slots_exists THEN
    RAISE EXCEPTION 'cannot migrate LOs to pg_catalog: logical replication slot(s) exist'
      USING DETAIL = 'Without spock the migration DML cannot be excluded from logical decoding: '
                     'the deletes from the lolor tables would replicate to subscribers while '
                     'the re-created native large objects would not, losing large objects on '
                     'the subscriber side',
            HINT = 'Drop all logical replication slots in this database before executing this procedure';
  END IF;

  -- Migrate each object using the native LO API (_orig functions).
  -- We cannot INSERT directly into pg_catalog.pg_largeobject from SQL,
  -- so we use lo_create_orig + lo_open_orig + lowrite_orig.
  --
  -- Zero-data-page LOs (metadata only) are handled correctly: lo_create_orig
  -- creates an empty LO and the inner FOR loop simply does not execute.
  --
  -- Note on sparse LOs: any gap between non-consecutive page numbers will
  -- be filled with zeroes by the native LO write API.  This preserves read
  -- semantics (holes already returned zeroes) but may increase storage.
  FOR r_meta IN SELECT oid, lomowner, lomacl FROM lolor.pg_largeobject_metadata
  LOOP
    -- Create native LO with the exact same OID
    PERFORM pg_catalog.lo_create_orig(r_meta.oid);

    -- Write data pages through the native LO write API.
    -- Use lo_lseek64_orig (bigint offset) to handle LOs larger than 2 GB.
    fd := pg_catalog.lo_open_orig(r_meta.oid, x'60000'::int);
    FOR r_data IN
      SELECT pageno, data FROM lolor.pg_largeobject
      WHERE loid = r_meta.oid ORDER BY pageno
    LOOP
      PERFORM pg_catalog.lo_lseek64_orig(fd, r_data.pageno::bigint * loblksize, 0);
      PERFORM pg_catalog.lowrite_orig(fd, r_data.data);
    END LOOP;
    PERFORM pg_catalog.lo_close_orig(fd);

    -- Restore ownership and ACL (lo_create sets current user as owner)
    UPDATE pg_catalog.pg_largeobject_metadata
    SET lomowner = r_meta.lomowner, lomacl = r_meta.lomacl
    WHERE pg_catalog.pg_largeobject_metadata.oid = r_meta.oid;
  END LOOP;

  -- Clean lolor storage
  DELETE FROM lolor.pg_largeobject;
  DELETE FROM lolor.pg_largeobject_metadata;

  -- Re-enable replication for the remainder of the caller's transaction, so
  -- repair mode covers exactly the migration DML and nothing after it.
  -- Error paths need no cleanup: they abort the whole transaction.
  IF repair_enabled THEN
    PERFORM spock.repair_mode(false);
  END IF;

  RAISE NOTICE 'migrated % large object(s) from lolor to native storage', lo_count;

  -- The migration DML was excluded from replication, so connected subscribers
  -- (replica nodes) did not receive it.
  IF lr_slots_exists THEN
    RAISE NOTICE 'this migration is local to this node: '
      'execute lolor.migrate_to_native() on each replica as well before modifying LOs';
  END IF;

  RETURN lo_count;
END;
$$ LANGUAGE plpgsql VOLATILE;
