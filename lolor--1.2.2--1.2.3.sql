/* lolor--1.2.2--1.2.3.sql */

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
 * Returns the number of large objects migrated.
 */
CREATE FUNCTION lolor.migrate_from_native()
RETURNS bigint AS $$
DECLARE
  lo_count          bigint;
  inserted_count    bigint;
  page_count        bigint;
  native_page_count bigint;
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

  RAISE NOTICE 'migrated % large object(s) (% data page(s)) from native to lolor storage',
    lo_count, page_count;

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
 * Returns the number of large objects migrated.
 */
CREATE FUNCTION lolor.migrate_to_native()
RETURNS bigint AS $$
DECLARE
  lo_count  bigint;
  loblksize bigint;
  r_meta    record;
  r_data    record;
  fd        integer;
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

  RAISE NOTICE 'migrated % large object(s) from lolor to native storage', lo_count;

  RETURN lo_count;
END;
$$ LANGUAGE plpgsql VOLATILE;
