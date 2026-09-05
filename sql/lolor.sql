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
SELECT lo_unlink(:loid);

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
SELECT lo_unlink(:loid);

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
SELECT lo_unlink(:loid);

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
ALTER EXTENSION lolor UPDATE TO '1.3.0';
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
BEGIN;
SELECT lo_open(2, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8'); -- OK, see the native object
SELECT lo_close(:fd);
END;
BEGIN;
SELECT lo_open(1, 262144) AS fd \gset
SELECT convert_from(loread(:fd, 1024), 'UTF8'); -- OK, see the object
SELECT lo_close(:fd);
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
-- Print a stable boolean rather than the generated OID, which varies per run
SELECT lo_create(:'drop_conflict_oid') = :'drop_conflict_oid'::oid AS native_oid_honored;
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

--
-- lo_import() and lo_export() read and write files on the server, so core
-- revokes EXECUTE on them from PUBLIC.  lolor replaces them by renaming the
-- originals out of the way, and an ACL belongs to a function rather than to a
-- name: the restriction stays on the parked original, and the replacement is
-- created with the default unless locked down explicitly, which would let any
-- database user read or overwrite server files.
--
CREATE EXTENSION lolor;
SELECT r.proname || '(' || pg_get_function_arguments(r.oid) || ')' AS func,
       EXISTS (SELECT 1 FROM aclexplode(coalesce(r.proacl, acldefault('f', r.proowner))) a
                WHERE a.grantee = 0) AS replacement_public_execute,
       EXISTS (SELECT 1 FROM aclexplode(coalesce(o.proacl, acldefault('f', o.proowner))) a
                WHERE a.grantee = 0) AS original_public_execute
FROM pg_proc r
JOIN pg_namespace n ON n.oid = r.pronamespace AND n.nspname = 'pg_catalog'
JOIN pg_proc o ON o.pronamespace = r.pronamespace
              AND o.proname = r.proname || '_orig'
              AND o.proargtypes = r.proargtypes
WHERE r.proname IN ('lo_import', 'lo_export')
ORDER BY 1;
DROP EXTENSION lolor;

--
-- lolor.node is bounded by the OID encoding, not by an independently written
-- constant: the low LOLOR_NODEID_BITS of a generated OID carry the node id, so
-- 16 does not fit and was previously accepted while encoding as node 0.
--
SET lolor.node = 16;
SET lolor.node = 15;
SET lolor.node = 1;

--
-- 64-bit interface and page-boundary I/O.  lo_put(), lo_tell64() and
-- lo_truncate64() had no coverage.
--
CREATE EXTENSION lolor;
SELECT current_setting('block_size')::int / 4 AS loblksize \gset

-- Write straddling a page boundary, then read the fragment back.
SELECT lo_create(0) AS span_oid \gset
SELECT lo_put(:span_oid, (:loblksize - 4)::bigint, '\x4142434445464748'::bytea);
SELECT length(lo_get(:span_oid)) = :loblksize + 4 AS spans_two_pages;
SELECT count(*) = 2 AS two_data_pages FROM lolor.pg_largeobject WHERE loid = :span_oid;
SELECT encode(lo_get(:span_oid, (:loblksize - 4)::bigint, 8), 'hex') AS across_boundary;

-- lo_truncate64() extending past the end leaves a hole rather than pages.
BEGIN;
SELECT lo_open(:span_oid, x'60000'::int) AS fd \gset
SELECT lo_truncate64(:fd, (:loblksize * 4)::bigint);
SELECT lo_lseek64(:fd, 0, 2) = (:loblksize * 4)::bigint AS seek_end_matches;
SELECT lo_tell64(:fd) = (:loblksize * 4)::bigint AS tell64_matches;
SELECT lo_close(:fd);
END;
SELECT length(lo_get(:span_oid)) = :loblksize * 4 AS truncate64_extended;
SELECT count(*) < 4 AS hole_not_materialised
  FROM lolor.pg_largeobject WHERE loid = :span_oid;

-- Truncating back down releases the pages beyond the new length.
BEGIN;
SELECT lo_open(:span_oid, x'60000'::int) AS fd \gset
SELECT lo_truncate64(:fd, 10);
SELECT lo_close(:fd);
END;
SELECT length(lo_get(:span_oid)) AS len_after_shrink;
SELECT lo_unlink(:span_oid);

--
-- Subtransaction cleanup.  A descriptor opened inside an aborted
-- subtransaction must be closed by the rollback, one opened in the enclosing
-- transaction must survive it, and data written in the aborted
-- subtransaction must not persist.
--
BEGIN;
SELECT lo_from_bytea(0, 'outer') AS sub_oid \gset
SELECT lo_open(:sub_oid, x'60000'::int) AS outer_fd \gset
SAVEPOINT s1;
SELECT lo_open(:sub_oid, x'60000'::int) AS inner_fd \gset
SELECT lo_put(:sub_oid, 0, 'INNER');
ROLLBACK TO s1;
SAVEPOINT s2;
SELECT lo_tell(:inner_fd);
ROLLBACK TO s2;
SELECT lo_tell(:outer_fd) AS outer_descriptor_survives;
SELECT lo_close(:outer_fd);
COMMIT;
SELECT convert_from(lo_get(:sub_oid), 'UTF8') AS subxact_write_rolled_back;
SELECT lo_unlink(:sub_oid);

--
-- A rolled back transaction must leave no trace in lolor storage.
--
SELECT count(*) AS rows_before FROM lolor.pg_largeobject_metadata;
BEGIN;
SELECT lo_from_bytea(0, 'discarded') IS NOT NULL AS created_in_aborted_xact;
ROLLBACK;
SELECT count(*) AS rows_after FROM lolor.pg_largeobject_metadata;

--
-- Seek variants and read/write edge cases.
--
SELECT lo_from_bytea(0, '0123456789abcdef') AS seek_oid \gset
BEGIN;
SELECT lo_open(:seek_oid, x'60000'::int) AS fd \gset
SELECT lo_lseek(:fd, 4, 0) AS seek_set;
SELECT lo_lseek(:fd, 2, 1) AS seek_cur;
SELECT lo_lseek(:fd, -3, 2) AS seek_end;
SELECT lo_tell(:fd) AS tell_after_seeks;
SELECT convert_from(loread(:fd, 3), 'UTF8') AS read_tail;
-- A read at end of object returns nothing rather than failing.
SELECT length(loread(:fd, 100)) AS read_past_eof;
-- Zero-length read and empty write are both no-ops.
SELECT lo_lseek(:fd, 0, 0);
SELECT length(loread(:fd, 0)) AS zero_length_read;
SELECT lowrite(:fd, '') AS empty_write;
SELECT lo_close(:fd);
END;
SELECT length(lo_get(:seek_oid)) AS unchanged_length;
-- lo_get with a fragment length beyond the end is clamped, not an error.
SELECT convert_from(lo_get(:seek_oid, 10, 1000), 'UTF8') AS clamped_fragment;
SELECT lo_unlink(:seek_oid);

--
-- Reading a multi-page object back in chunks that do not align with the page
-- size exercises the page-assembly path in lolor_inv_read().
--
SELECT lo_from_bytea(0, repeat('abcdefgh', (:loblksize * 3 / 8))::bytea) AS multi_oid \gset
SELECT length(lo_get(:multi_oid)) = :loblksize * 3 AS three_pages_written;
SELECT count(*) AS page_rows FROM lolor.pg_largeobject WHERE loid = :multi_oid;
BEGIN;
SELECT lo_open(:multi_oid, 262144) AS fd \gset
SELECT length(loread(:fd, 1000)) AS chunk1;
SELECT length(loread(:fd, 5000)) AS chunk2;
SELECT length(loread(:fd, 100000)) AS chunk_rest;
SELECT lo_close(:fd);
END;
SELECT md5(lo_get(:multi_oid)) = md5(repeat('abcdefgh', (:loblksize * 3 / 8))::bytea)
  AS content_round_trips;
SELECT lo_unlink(:multi_oid);

--
-- Error paths.
--
SELECT lo_get(0);
BEGIN;
SELECT lo_open(0, 262144);
ROLLBACK;
-- Zero-downtime migration: transparent reading and on-the-fly migration
--
CREATE EXTENSION lolor;

-- 1. Create a native large object while lolor is disabled
SELECT lolor.disable();
SELECT lo_from_bytea(3001, 'Native LO data for zero-downtime reading test');
SELECT lolor.enable();

-- 2. Verify reading via lo_get and lo_get_fragment works transparently with lolor enabled
SELECT convert_from(lo_get(3001), 'UTF8');
SELECT convert_from(lo_get(3001, 7, 7), 'UTF8');

-- 3. Verify reading via lo_open, lo_lseek, lo_tell, loread, lo_close
BEGIN;
SELECT lo_open(3001, 262144) AS fd \gset
SELECT lo_tell(:fd);
SELECT lo_lseek(:fd, 7, 0);
SELECT lo_tell(:fd);
SELECT convert_from(loread(:fd, 7), 'UTF8');
SELECT lo_close(:fd);
END;

-- 4. Verify object is still in native storage (reads do not migrate)
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 3001;
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 3001;

-- 5. On-the-fly migration on write (lo_put)
SELECT lo_put(3001, 0, 'MODIFIED');
-- Now object 3001 must be in lolor storage and gone from native storage!
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 3001;
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 3001;
SELECT convert_from(lo_get(3001), 'UTF8');

-- 6. On-the-fly migration on write via lo_open(INV_WRITE) + lowrite
SELECT lolor.disable();
SELECT lo_from_bytea(3002, 'Native LO for write migration test');
SELECT lolor.enable();
BEGIN;
SELECT lo_open(3002, x'60000'::int) AS fd \gset
SELECT lowrite(:fd, 'MIGRATED');
SELECT lo_close(:fd);
END;
-- Must be in lolor storage and gone from native storage
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 3002;
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 3002;
SELECT convert_from(lo_get(3002), 'UTF8');

-- 7. Transparent lo_unlink of native object
SELECT lolor.disable();
SELECT lo_from_bytea(3003, 'Native LO to be unlinked');
SELECT lolor.enable();
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 3003;
SELECT lo_unlink(3003);
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 3003;
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 3003;

-- Cleanup migrated objects
SELECT lo_unlink(3001);
SELECT lo_unlink(3002);
DROP EXTENSION lolor;

--
-- ProcessUtility hook: ALTER, COMMENT, GRANT, REVOKE on LARGE OBJECT
--
CREATE EXTENSION lolor;

-- Create test roles
CREATE ROLE lolor_test_user1;
CREATE ROLE lolor_test_user2;

-- Create large objects (one in lolor, one native)
SELECT lo_from_bytea(4001, 'Lolor LO for utility tests');

SELECT lolor.disable();
SELECT lo_from_bytea(4002, 'Native LO for utility tests');
SELECT lolor.enable();

-- 1. COMMENT ON LARGE OBJECT
-- Set comment on lolor object
COMMENT ON LARGE OBJECT 4001 IS 'Test comment on lolor LO';
SELECT description FROM pg_description WHERE objoid = 4001 AND classoid = 'pg_largeobject'::regclass;

-- Set comment on native object
COMMENT ON LARGE OBJECT 4002 IS 'Test comment on native LO';
SELECT description FROM pg_description WHERE objoid = 4002 AND classoid = 'pg_largeobject'::regclass;

-- Remove comment by setting to NULL
COMMENT ON LARGE OBJECT 4001 IS NULL;
SELECT description FROM pg_description WHERE objoid = 4001 AND classoid = 'pg_largeobject'::regclass;

-- Error on non-existent object
COMMENT ON LARGE OBJECT 999999 IS 'Should fail';

-- 2. ALTER LARGE OBJECT ... OWNER TO
-- Alter owner of lolor object
ALTER LARGE OBJECT 4001 OWNER TO lolor_test_user1;
SELECT lomowner = (SELECT oid FROM pg_roles WHERE rolname = 'lolor_test_user1') AS is_user1_owner
  FROM lolor.pg_largeobject_metadata WHERE oid = 4001;

-- Alter owner of native object: should migrate on-the-fly to lolor storage
ALTER LARGE OBJECT 4002 OWNER TO lolor_test_user1;
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 4002;
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 4002;
SELECT lomowner = (SELECT oid FROM pg_roles WHERE rolname = 'lolor_test_user1') AS is_user1_owner
  FROM lolor.pg_largeobject_metadata WHERE oid = 4002;
-- Verify comment on 4002 is still preserved after migration
SELECT description FROM pg_description WHERE objoid = 4002 AND classoid = 'pg_largeobject'::regclass;

-- Error on non-existent object
ALTER LARGE OBJECT 999999 OWNER TO lolor_test_user1;

-- 3. GRANT and REVOKE on LARGE OBJECT
-- Grant SELECT and UPDATE to lolor_test_user2
GRANT SELECT, UPDATE ON LARGE OBJECT 4001 TO lolor_test_user2;
SELECT lomacl IS NOT NULL AS has_acl FROM lolor.pg_largeobject_metadata WHERE oid = 4001;

-- Revoke UPDATE from lolor_test_user2
REVOKE UPDATE ON LARGE OBJECT 4001 FROM lolor_test_user2;
SELECT lomacl IS NOT NULL AS has_acl FROM lolor.pg_largeobject_metadata WHERE oid = 4001;

-- Grant ALL PRIVILEGES
GRANT ALL PRIVILEGES ON LARGE OBJECT 4001 TO lolor_test_user2;
SELECT lomacl::text LIKE '%lolor_test_user2=rw/%' AS has_all_privs FROM lolor.pg_largeobject_metadata WHERE oid = 4001;

-- Revoke ALL PRIVILEGES
REVOKE ALL PRIVILEGES ON LARGE OBJECT 4001 FROM lolor_test_user2;
SELECT lomacl::text NOT LIKE '%lolor_test_user2%' AS revoked_all FROM lolor.pg_largeobject_metadata WHERE oid = 4001;

-- Error on non-existent object
GRANT SELECT ON LARGE OBJECT 999999 TO lolor_test_user2;
REVOKE SELECT ON LARGE OBJECT 999999 FROM lolor_test_user2;

-- 4. Dependency tracking and lolor.cleanup_dependencies()
-- Grant privilege to lolor_test_user2 to record dependency
GRANT SELECT ON LARGE OBJECT 4001 TO lolor_test_user2;

-- Dropping user1 or user2 should fail because they have dependencies
DROP ROLE lolor_test_user1;
DROP ROLE lolor_test_user2;

-- Test security: non-superuser should be denied from cleanup_dependencies
SET ROLE lolor_test_user1;
SELECT lolor.cleanup_dependencies();
RESET ROLE;

-- Now transfer ownership back to current user and revoke privileges from user2
ALTER LARGE OBJECT 4001 OWNER TO CURRENT_USER;
ALTER LARGE OBJECT 4002 OWNER TO CURRENT_USER;
REVOKE SELECT ON LARGE OBJECT 4001 FROM lolor_test_user2;

-- Attempting to drop role directly still fails before cleanup
DROP ROLE lolor_test_user1;
DROP ROLE lolor_test_user2;

-- Run lolor.cleanup_dependencies()
SELECT lolor.cleanup_dependencies() >= 2 AS cleaned_deps;

-- Now dropping the roles should succeed!
DROP ROLE lolor_test_user1;
DROP ROLE lolor_test_user2;

-- Verify DeleteComments removes comment on lo_unlink
COMMENT ON LARGE OBJECT 4001 IS 'Comment before unlink';
SELECT count(*) FROM pg_description WHERE objoid = 4001 AND classoid = 'pg_largeobject'::regclass;
SELECT lo_unlink(4001);
SELECT count(*) FROM pg_description WHERE objoid = 4001 AND classoid = 'pg_largeobject'::regclass;
SELECT lo_unlink(4002);
DROP EXTENSION lolor;

--
-- lolor.migrate(): incremental batch migration
--
CREATE EXTENSION lolor;

-- Ensure any leftover native large objects are migrated first
SELECT lolor.migrate() >= 0 AS clean_start;

-- 1. Create 5 native large objects
SELECT lolor.disable();
SELECT lo_from_bytea(5001, 'Batch migration 1');
SELECT lo_from_bytea(5002, 'Batch migration 2');
SELECT lo_from_bytea(5003, 'Batch migration 3');
SELECT lo_from_bytea(5004, 'Batch migration 4');
SELECT lo_from_bytea(5005, 'Batch migration 5');
SELECT lolor.enable();

-- Check initial distribution
SELECT count(*) AS native_cnt FROM pg_catalog.pg_largeobject_metadata WHERE oid BETWEEN 5001 AND 5005;
SELECT count(*) AS lolor_cnt FROM lolor.pg_largeobject_metadata WHERE oid BETWEEN 5001 AND 5005;

-- Migrate batch of 2
SELECT lolor.migrate(2);
SELECT count(*) AS native_cnt FROM pg_catalog.pg_largeobject_metadata WHERE oid BETWEEN 5001 AND 5005;
SELECT count(*) AS lolor_cnt FROM lolor.pg_largeobject_metadata WHERE oid BETWEEN 5001 AND 5005;

-- Migrate all remaining
SELECT lolor.migrate();
SELECT count(*) AS native_cnt FROM pg_catalog.pg_largeobject_metadata WHERE oid BETWEEN 5001 AND 5005;
SELECT count(*) AS lolor_cnt FROM lolor.pg_largeobject_metadata WHERE oid BETWEEN 5001 AND 5005;

-- Calling again returns 0
SELECT lolor.migrate();

-- 2. strict_from_end_to_start: reverse physical scan
SELECT lolor.disable();
SELECT lo_from_bytea(5011, 'End to start 1');
SELECT lo_from_bytea(5012, 'End to start 2');
SELECT lo_from_bytea(5013, 'End to start 3');
SELECT lolor.enable();

-- Reverse scan should pick 5013 first (written last at physical end)
SELECT lolor.migrate(1, strict_from_end_to_start => true);
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 5013;
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 5013;

-- Migrate remaining objects with reverse scan
SELECT lolor.migrate(strict_from_end_to_start => true);
SELECT count(*) AS native_cnt FROM pg_catalog.pg_largeobject_metadata WHERE oid BETWEEN 5011 AND 5013;
SELECT count(*) AS lolor_cnt FROM lolor.pg_largeobject_metadata WHERE oid BETWEEN 5011 AND 5013;

-- 3. run_vacuum and procedure call
SELECT lolor.disable();
SELECT lo_from_bytea(5021, 'Vacuum test 1');
SELECT lo_from_bytea(5022, 'Vacuum test 2');
SELECT lolor.enable();

-- Function with run_vacuum => true
SELECT lolor.migrate(1, run_vacuum => true);
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 5021;

SELECT lolor.migrate(1, run_vacuum => true);
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 5022;

-- 4. Alias test: lolor.lolor_migrate
SELECT lolor.lolor_migrate(0);

-- 5. Negative batch size validation
SELECT lolor.migrate(-1);

-- 6. Empty (0-page) large object migrated by reverse mode
SELECT lolor.disable();
SELECT lo_create(5030);
SELECT lolor.enable();
SELECT lolor.migrate(strict_from_end_to_start => true);
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 5030;
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 5030;
SELECT lo_unlink(5030);

-- 7. Disabled state passthrough for utility commands
SELECT lolor.disable();
SELECT lo_create(5031);
ALTER LARGE OBJECT 5031 OWNER TO CURRENT_ROLE;
SELECT count(*) FROM pg_catalog.pg_largeobject_metadata WHERE oid = 5031;
SELECT count(*) FROM lolor.pg_largeobject_metadata WHERE oid = 5031;
SELECT lo_unlink(5031);
SELECT lolor.enable();



-- Cleanup
SELECT lo_unlink(5001);
SELECT lo_unlink(5002);
SELECT lo_unlink(5003);
SELECT lo_unlink(5004);
SELECT lo_unlink(5005);
SELECT lo_unlink(5011);
SELECT lo_unlink(5012);
SELECT lo_unlink(5013);
SELECT lo_unlink(5021);
SELECT lo_unlink(5022);
DROP EXTENSION lolor;


