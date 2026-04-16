-- Basic checks
\set VERBOSITY terse
LOAD 'lolor';
SET lolor.node = 1;

CREATE EXTENSION lolor;

SELECT lo_creat(-1) AS loid \gset
SELECT lo_from_bytea(:loid, 'Example large object'); -- ERROR
BEGIN;
SELECT lo_open(:loid, x'60000'::int) AS fd \gset
SELECT lowrite(:fd, 'Example large object');
SELECT lo_close(:fd);
END;

SELECT count(*) FROM pg_largeobject;
SELECT count(*) FROM lolor.pg_largeobject;

-- Check that the LO is accessible.
BEGIN;
SELECT lo_open(:loid, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8');
SELECT lo_close(:fd);
END;

-- Force the oid change for the indexes
REINDEX INDEX CONCURRENTLY lolor.pg_largeobject_pkey;
REINDEX INDEX CONCURRENTLY lolor.pg_largeobject_metadata_pkey;

BEGIN;
SELECT lo_open(:loid, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8');
SELECT lo_close(:fd);
END;

--
-- lo_lseek: seek to an offset, overwrite partial content, verify result.
-- Expected: first 15 chars unchanged, next 11 replaced by '<ADDEDDATA>',
-- trailing chars from original string preserved.
--
SELECT lo_creat(-1) AS loid \gset
BEGIN;
SELECT lo_open(:loid, x'60000'::int) AS fd \gset
SELECT lowrite(:fd, '0123456789abcdefghijklmnopqrstuvwxyz');
SELECT lo_lseek(:fd, 15, 0);
SELECT lowrite(:fd, '<ADDEDDATA>');
SELECT lo_close(:fd);
END;
BEGIN;
SELECT lo_open(:loid, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8');
SELECT lo_close(:fd);
END;

--
-- lo_tell: verify cursor position before and after a write.
-- Expected: position 0 before write, position 11 after writing 11 bytes;
-- content has first 11 chars overwritten by '<ADDEDDATA>'.
--
SELECT lo_creat(-1) AS loid \gset
BEGIN;
SELECT lo_open(:loid, x'60000'::int) AS fd \gset
SELECT lowrite(:fd, '0123456789abcdefghijklmnopqrstuvwxyz');
SELECT lo_lseek(:fd, 0, 0);
SELECT lo_tell(:fd);
SELECT lowrite(:fd, '<ADDEDDATA>');
SELECT lo_tell(:fd);
SELECT lo_close(:fd);
END;
BEGIN;
SELECT lo_open(:loid, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8');
SELECT lo_close(:fd);
END;

--
-- lo_truncate: truncate to 10 bytes, verify only the prefix survives.
-- Expected: only "0123456789" readable after truncation.
--
SELECT lo_creat(-1) AS loid \gset
BEGIN;
SELECT lo_open(:loid, x'60000'::int) AS fd \gset
SELECT lowrite(:fd, '0123456789abcdefghijklmnopqrstuvwxyz');
SELECT lo_truncate(:fd, 10);
SELECT lo_close(:fd);
END;
BEGIN;
SELECT lo_open(:loid, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8');
SELECT lo_close(:fd);
END;

DROP EXTENSION lolor;

-- Check extension upgrade
CREATE EXTENSION lolor VERSION '1.0';
SELECT lo_creat(-1) AS loid \gset
ALTER EXTENSION lolor UPDATE TO '1.2.1';
BEGIN;
SELECT lo_open(:loid, x'60000'::int) AS fd \gset
SELECT lowrite(:fd, 'Example large object');
END;
ALTER EXTENSION lolor UPDATE TO '1.2.2';
BEGIN;
SELECT lo_open(:loid, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8');
END;
ALTER EXTENSION lolor UPDATE TO '1.2.3';
-- Verify migration functions are available after upgrade
SELECT lolor.migrate_to_native(); -- One LO object has been created before LOLOR
SELECT lolor.migrate_from_native(); -- two objects

-- Repeat conversion cycle - should see the same two objects
SELECT lolor.migrate_to_native();
SELECT lolor.migrate_from_native();

--
-- Basic checks for enable/disable routines.
--

SELECT lolor.enable(); -- ERROR
SELECT lo_from_bytea(1, 'Example large object stored in lolor LO storage');
SELECT lolor.disable();
SELECT lo_open(1, 262144); -- 'not found' ERROR
SELECT lo_from_bytea(2, 'Example large object stored in built-in LO storage');

-- We should see the object
SELECT lolor.enable();
SELECT lo_open(2, 262144); -- 'not found' ERROR
BEGIN;
SELECT lo_open(1, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8'); -- OK, see the object
END;

-- To be sure that the behaviour is repeatable
SELECT lolor.disable();
SELECT lolor.enable();

-- Check that no tails existing after the extension drop in both enabled and
-- disabled states.
DROP EXTENSION lolor;
SELECT oid, proname FROM pg_proc WHERE proname IN ('lo_open_orig',
  'lolor_lo_open');

-- Check: we can't just delete LOLOR without LO migration in disabled mode.
-- XXX: should we introduce a 'forced' flag to allow this?
CREATE EXTENSION lolor;
SELECT lolor.disable();
DROP EXTENSION lolor;
SELECT extname FROM pg_extension; -- lolor is here
SELECT lolor.enable();
DROP EXTENSION lolor;
SELECT extname FROM pg_extension; -- check lolor removal

--
-- Migration tests: migrate_from_native / migrate_to_native / DROP EXTENSION
--

-- Start fresh: no extension, create native LOs
SELECT lo_from_bytea(0, 'Native object number one') AS native_oid1 \gset
SELECT lo_from_bytea(0, 'Native object number two') AS native_oid2 \gset

-- Forward migration: expect native_lo_count = 2
SELECT count(*) AS native_lo_count FROM pg_catalog.pg_largeobject_metadata;

-- Install lolor and migrate native LOs into lolor storage
CREATE EXTENSION lolor;
SELECT lolor.migrate_from_native();

-- After forward migration: expect 0 native objects
SELECT count(*) AS native_after_migrate FROM pg_catalog.pg_largeobject_metadata;
SELECT count(*) AS lolor_after_migrate FROM lolor.pg_largeobject_metadata;

-- Data integrity: expect "Native object number one"
BEGIN;
SELECT lo_open(:'native_oid1'::oid, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8') AS obj1_data;
SELECT lo_close(:fd);
END;

-- Data integrity: expect "Native object number two"
BEGIN;
SELECT lo_open(:'native_oid2'::oid, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8') AS obj2_data;
SELECT lo_close(:fd);
END;

-- Create an additional LO directly in lolor storage
SELECT lo_from_bytea(0, 'Created directly in lolor') AS lolor_direct_oid \gset

-- Reverse migration via DROP EXTENSION
DROP EXTENSION lolor;

SELECT count(*) AS native_after_drop FROM pg_catalog.pg_largeobject_metadata;

-- After DROP: expect "Native object number one"
SELECT convert_from(lo_get(:'native_oid1'::oid), 'UTF8') AS obj1_after_reverse;
-- After DROP: expect "Native object number two"
SELECT convert_from(lo_get(:'native_oid2'::oid), 'UTF8') AS obj2_after_reverse;
-- After DROP: expect "Created directly in lolor"
SELECT convert_from(lo_get(:'lolor_direct_oid'::oid), 'UTF8') AS obj3_after_reverse;

-- Cleanup native LOs
SELECT lo_unlink(:'native_oid1'::oid);
SELECT lo_unlink(:'native_oid2'::oid);
SELECT lo_unlink(:'lolor_direct_oid'::oid);

CREATE EXTENSION lolor;
SELECT lolor.migrate_from_native();
DROP EXTENSION lolor;

--
-- Manual migrate_to_native (not via DROP EXTENSION)
--
CREATE EXTENSION lolor;
SELECT lo_from_bytea(0, 'Manual reverse test') AS manual_oid \gset
SELECT lolor.migrate_to_native();
SELECT count(*) AS native_after_manual FROM pg_catalog.pg_largeobject_metadata;
SELECT count(*) AS lolor_after_manual FROM lolor.pg_largeobject_metadata;

-- After manual migration: expect "Manual reverse test"
BEGIN;
-- Disable lolor to read from native storage directly
SELECT lolor.disable();
SELECT convert_from(lo_get(:'manual_oid'::oid), 'UTF8') AS manual_data;
END;

-- Cleanup
SELECT lo_unlink(:'manual_oid'::oid);
SELECT lolor.enable();
DROP EXTENSION lolor;

--
-- OID conflict detection
--

-- OID conflict: migrate_from_native should ERROR on duplicate OID
SELECT lo_from_bytea(0, 'Conflict test object') AS conflict_oid \gset
CREATE EXTENSION lolor;
-- HACK: Manually insert a row with the same OID into lolor storage
INSERT INTO lolor.pg_largeobject_metadata (oid, lomowner, lomacl)
  VALUES (:'conflict_oid', (SELECT oid FROM pg_roles WHERE rolname = current_user), NULL);
-- This should fail with OID conflict
SELECT lolor.migrate_from_native();
-- Cleanup: remove the conflicting row and drop cleanly
DELETE FROM lolor.pg_largeobject_metadata WHERE oid = :'conflict_oid';
DROP EXTENSION lolor;
SELECT lo_unlink(:'conflict_oid'::oid);

-- OID conflict: migrate_to_native should ERROR on duplicate OID
CREATE EXTENSION lolor;
SELECT lo_from_bytea(0, 'Lolor side object') AS conflict_oid2 \gset
-- Disable lolor to create a native LO with the same OID
SELECT lolor.disable();
SELECT lo_create(:'conflict_oid2') AS created_oid \gset
-- Verify native lo_create honored the explicit OID
SELECT :'created_oid' = :'conflict_oid2' AS oid_matches;
SELECT lolor.enable();
-- migrate_to_native should detect the collision
SELECT lolor.migrate_to_native();
-- Cleanup: remove the native duplicate, then drop cleanly
SELECT lolor.disable();
SELECT lo_unlink(:'conflict_oid2'::oid);
SELECT lolor.enable();
DROP EXTENSION lolor;

-- DROP EXTENSION should be rejected when migrate_to_native has OID conflict
CREATE EXTENSION lolor;
SELECT lo_from_bytea(0, 'Drop conflict test') AS drop_conflict_oid \gset
-- Create a native LO with the same OID to force conflict at DROP time
SELECT lolor.disable();
SELECT lo_create(:'drop_conflict_oid');
SELECT lolor.enable();
-- DROP EXTENSION should ERROR to prevent data loss
DROP EXTENSION lolor;
-- Extension should still be installed
SELECT extname FROM pg_extension WHERE extname = 'lolor';
-- Objects should be in place
SELECT count(*) FROM lolor.pg_largeobject;
-- Resolve the conflict: remove the native duplicate, then retry
SELECT lolor.disable();
SELECT lo_unlink(:'drop_conflict_oid'::oid);
SELECT lolor.enable();
-- Now DROP should succeed
DROP EXTENSION lolor;
