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

-- DROP EXTENSION while lolor is disabled.  Through 1.3.0 this failed with
-- "lolor must be enabled before migration to native", because the reverse
-- migration ran through the renamed _orig functions.  It now works against
-- the catalogs directly, so the disabled state is no longer a special case
-- and the objects are still rescued.
CREATE EXTENSION lolor;
SELECT lo_from_bytea(0, 'stored before disabling') AS disabled_drop_oid \gset
SELECT lolor.disable();
DROP EXTENSION lolor;
SELECT extname FROM pg_extension; -- check lolor removal
-- The object was migrated to native storage, not dropped with lolor's tables
SELECT convert_from(lo_get(:disabled_drop_oid), 'UTF8') AS survived_disabled_drop;
SELECT lo_unlink(:disabled_drop_oid);

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
-- Fidelity of the storage relocation (lolor 1.4.0)
--
CREATE EXTENSION lolor;
CREATE ROLE lolor_owner;
CREATE ROLE lolor_grantee;

-- A sparse object: two pages holding a 10 MB logical object.  Migration must
-- not fill the hole; the old implementation rewrote it through the LO API and
-- materialised every intervening page.
SELECT lolor.disable();
SELECT lo_create(0) AS sparse_oid \gset
BEGIN;
SELECT lo_open(:sparse_oid, x'60000'::int) AS fd \gset
SELECT lowrite(:fd, 'start');
SELECT lo_lseek64(:fd, 10000000, 0);
SELECT lowrite(:fd, 'end');
SELECT lo_close(:fd);
END;

-- An object carrying owner, ACL and a comment
SELECT lo_from_bytea(0, 'annotated object') AS annotated_oid \gset
ALTER LARGE OBJECT :annotated_oid OWNER TO lolor_owner;
GRANT SELECT ON LARGE OBJECT :annotated_oid TO lolor_grantee;
COMMENT ON LARGE OBJECT :annotated_oid IS 'kept across migration';

-- An object with no data pages at all
SELECT lo_create(0) AS empty_oid \gset

SELECT lolor.enable();
SELECT lolor.migrate_from_native();

-- Sparse object keeps its exact page count (2), not 4883
SELECT count(*) AS sparse_pages FROM lolor.pg_largeobject WHERE loid = :sparse_oid;
SELECT lo_get(:sparse_oid) IS NOT NULL AS sparse_readable;
SELECT length(lo_get(:sparse_oid)) AS sparse_length;
SELECT length(lo_get(:empty_oid)) AS empty_length;

-- Owner and ACL survive; the comment is parked for the round trip
SELECT pg_get_userbyid(lomowner) AS owner, lomacl IS NOT NULL AS has_acl
FROM lolor.pg_largeobject_metadata WHERE oid = :annotated_oid;
SELECT description FROM lolor.pg_largeobject_description WHERE loid = :annotated_oid;

-- Native side is fully cleaned up, including shared deps and comments
SELECT count(*) AS native_objs FROM pg_catalog.pg_largeobject_metadata;
SELECT count(*) AS native_shdep FROM pg_shdepend
  WHERE classid = 'pg_largeobject'::regclass
    AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database());
SELECT count(*) AS native_comments FROM pg_description
  WHERE classoid = 'pg_largeobject'::regclass;

-- Back to native storage
SELECT lolor.migrate_to_native();

-- Ownership is recorded in pg_shdepend, not merely in lomowner: a raw catalog
-- UPDATE (what 1.3.0 did) left DROP ROLE unable to see the object.
SELECT pg_get_userbyid(lomowner) AS owner
FROM pg_catalog.pg_largeobject_metadata WHERE oid = :annotated_oid;
SELECT deptype, refobjid::regrole::text AS role FROM pg_shdepend
  WHERE classid = 'pg_largeobject'::regclass AND objid = :annotated_oid
    AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  ORDER BY deptype;
SELECT description FROM pg_description
  WHERE classoid = 'pg_largeobject'::regclass AND objoid = :annotated_oid;

-- DROP ROLE must refuse for both the owner and the ACL grantee
DROP ROLE lolor_owner;
DROP ROLE lolor_grantee;

-- Sparse object is still sparse after the round trip
SELECT count(*) AS sparse_pages_native FROM pg_catalog.pg_largeobject
  WHERE loid = :sparse_oid;

-- Comment parking table is emptied once the comments are reinstated
SELECT count(*) AS parked_left FROM lolor.pg_largeobject_description;

-- Cleanup
SELECT lolor.disable();
SELECT lo_unlink(:sparse_oid);
SELECT lo_unlink(:annotated_oid);
SELECT lo_unlink(:empty_oid);
SELECT lolor.enable();
DROP EXTENSION lolor;
DROP ROLE lolor_owner;
DROP ROLE lolor_grantee;

--
-- An unprivileged user must not be able to wedge lolor by squatting the
-- names the state probes look for.  Before 1.4.0 this made is_enabled()
-- raise "inconsistent state", which also blocked DROP EXTENSION.
--
CREATE EXTENSION lolor;
CREATE ROLE lolor_squatter;
GRANT CREATE ON SCHEMA public TO lolor_squatter;
SET ROLE lolor_squatter;
CREATE FUNCTION public.lolor_lo_open(oid, int4) RETURNS int4
  AS 'SELECT 1' LANGUAGE sql;
CREATE FUNCTION public.lo_close_orig(int4) RETURNS int4
  AS 'SELECT 1' LANGUAGE sql;
RESET ROLE;
SELECT lolor.is_enabled() AS unaffected_by_squatting;
DROP FUNCTION public.lolor_lo_open(oid, int4);
DROP FUNCTION public.lo_close_orig(int4);
REVOKE CREATE ON SCHEMA public FROM lolor_squatter;
DROP ROLE lolor_squatter;
DROP EXTENSION lolor;

--
-- DROP SCHEMA lolor CASCADE reaches the extension by dependency cascade
-- rather than as DROP EXTENSION.  The cleanup trigger must still run, or the
-- objects are destroyed and pg_catalog is left without a working lo_open().
--
CREATE EXTENSION lolor;
SELECT lo_from_bytea(0, 'rescued from drop schema') AS rescued_oid \gset
DROP SCHEMA lolor CASCADE;
SELECT count(*) AS ext_left FROM pg_extension WHERE extname = 'lolor';
SELECT to_regprocedure('pg_catalog.lo_open(oid,int4)') IS NOT NULL AS lo_open_restored;
SELECT to_regprocedure('pg_catalog.lo_open_orig(oid,int4)') IS NULL AS no_orig_left;
SELECT convert_from(lo_get(:rescued_oid), 'UTF8') AS rescued_content;
SELECT lo_unlink(:rescued_oid);

--
-- lo_import() and lo_export() read and write files on the server, so core
-- revokes EXECUTE on them from PUBLIC.  lolor replaces them by renaming the
-- originals out of the way, and an ACL belongs to a function rather than to a
-- name: the restriction stays on the parked original, and the replacement is
-- created with the default (EXECUTE TO PUBLIC) unless locked down explicitly.
-- Before 1.4.0 that let any database user read or overwrite server files.
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
-- Permission enforcement.
--
-- Objects in lolor storage have no catalog entry, so lolor cannot use the
-- syscache-backed owner and ACL checks and reimplements them against its own
-- tables.  Exercise that path rather than assuming it matches core.
--
CREATE EXTENSION lolor;
CREATE ROLE lolor_alice;
CREATE ROLE lolor_bob;

-- Large object error messages quote the OID, which is generated and so
-- differs between runs.  Report the message with digits masked instead.
CREATE FUNCTION lolor_expect_error(cmd text) RETURNS text AS $$
BEGIN
  EXECUTE cmd;
  RETURN 'unexpectedly succeeded';
EXCEPTION WHEN OTHERS THEN
  RETURN regexp_replace(SQLERRM, '[0-9]+', 'NNN', 'g');
END
$$ LANGUAGE plpgsql;

SET ROLE lolor_alice;
SELECT lo_from_bytea(0, 'alice private data') AS alice_oid \gset
SELECT convert_from(lo_get(:alice_oid), 'UTF8') AS owner_can_read;
RESET ROLE;

-- A different role gets nothing without a grant.
SET ROLE lolor_bob;
SELECT lolor_expect_error(format('SELECT lo_get(%s)', :alice_oid)) AS read_denied;
SELECT lolor_expect_error(format('SELECT lo_open(%s, 262144)', :alice_oid)) AS open_denied;
SELECT lolor_expect_error(format('SELECT lo_put(%s, 0, ''x'')', :alice_oid)) AS write_denied;
SELECT lolor_expect_error(format('SELECT lo_unlink(%s)', :alice_oid)) AS unlink_denied;
RESET ROLE;

-- The superuser bypasses the check, as in core.
SELECT convert_from(lo_get(:alice_oid), 'UTF8') AS superuser_can_read;

-- GRANT/ALTER on a large object act on pg_largeobject_metadata, where an
-- object in lolor storage has no row.  This limitation is documented; assert
-- it so that a change in behaviour is noticed.
SELECT lolor_expect_error(
  format('GRANT SELECT ON LARGE OBJECT %s TO lolor_bob', :alice_oid)) AS grant_unsupported;
SELECT lolor_expect_error(
  format('ALTER LARGE OBJECT %s OWNER TO lolor_bob', :alice_oid)) AS alter_unsupported;

SELECT lo_unlink(:alice_oid);

--
-- Objects in lolor storage are rows in ordinary tables and cannot participate
-- in pg_shdepend, so DROP ROLE does not notice that a role still owns one.
-- lolor.check_orphans() exists to make the consequence findable.
--
SET ROLE lolor_alice;
SELECT lo_from_bytea(0, 'owned by a role about to vanish') AS orphan_oid \gset
RESET ROLE;
SELECT count(*) AS orphans_before FROM lolor.check_orphans();
DROP ROLE lolor_alice;
SELECT count(*) AS orphans_after FROM lolor.check_orphans();
SELECT lo_unlink(:orphan_oid);
SELECT count(*) AS orphans_cleared FROM lolor.check_orphans();
DROP ROLE lolor_bob;
DROP FUNCTION lolor_expect_error(text);

--
-- 64-bit interface and page-boundary I/O.  lo_put(), lo_tell64() and
-- lo_truncate64() had no coverage at all.
--
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
-- Reading a multi-page object back in chunks that do not align with the
-- page size exercises the page-assembly path in lolor_inv_read().
--
SELECT current_setting('block_size')::int / 4 AS loblksize \gset
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
SELECT lo_unlink(0);
BEGIN;
SELECT lo_open(0, 262144);
ROLLBACK;

--
-- Verification helpers introduced in 1.4.0.
--
-- Start from a clean slate so the counts below do not depend on what earlier
-- sections happened to leave behind.  The notices carry those counts, so they
-- are suppressed for the duration.
SET client_min_messages = warning;
SELECT lolor.migrate_to_native() IS NOT NULL AS drained_to_native;
SELECT lolor.disable();
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT oid FROM pg_catalog.pg_largeobject_metadata LOOP
    PERFORM lo_unlink(r.oid);
  END LOOP;
END
$$;
SELECT lolor.enable();
RESET client_min_messages;

SELECT count(*) AS native_oids_when_empty FROM lolor.native_lo_oids();

-- Both directions report zero rather than failing when there is nothing.
SELECT lolor.migrate_to_native() AS nothing_to_move;
SELECT lolor.migrate_from_native() AS nothing_to_take;

-- digest() reports one row per object.  The OID and owner vary between runs;
-- the page count, byte count and content digest do not.
SELECT lo_from_bytea(0, 'digest one') AS d1 \gset
SELECT lo_from_bytea(0, 'digest two, longer') AS d2 \gset
SELECT npages, nbytes, digest FROM lolor.digest() ORDER BY nbytes, digest;
SELECT lo_unlink(:d1);
SELECT lo_unlink(:d2);

-- migrate_storage() is the mechanism behind both migration functions.  Grant
-- schema access so that the function's own privileges are what is exercised
-- rather than USAGE on the schema.
CREATE ROLE lolor_nosuper;
GRANT USAGE ON SCHEMA lolor TO lolor_nosuper;
SET ROLE lolor_nosuper;
SELECT lolor.migrate_storage(true);
SELECT lolor.migrate_from_native();
SELECT lolor.migrate_to_native();
RESET ROLE;
REVOKE USAGE ON SCHEMA lolor FROM lolor_nosuper;
DROP ROLE lolor_nosuper;

-- Native OIDs are not node-encoded, so two nodes can hold different objects
-- under the same OID.  Passing the peer OIDs makes that a refusal instead of
-- silent divergence once the migration is hidden from replication.
SELECT lolor.disable();
SELECT lo_create(0) AS peer_oid \gset
SELECT lolor.enable();
SELECT lolor.migrate_from_native(peer_oids => ARRAY[:peer_oid]::oid[]);

-- Security labels cannot be represented in lolor storage and cannot be
-- reinstated without their provider, so migration refuses rather than
-- discarding them.
INSERT INTO pg_catalog.pg_seclabel (objoid, classoid, objsubid, provider, label)
VALUES (:peer_oid, 'pg_catalog.pg_largeobject'::regclass, 0, 'lolor_test', 'secret');
SELECT lolor.migrate_from_native();
DELETE FROM pg_catalog.pg_seclabel
 WHERE classoid = 'pg_catalog.pg_largeobject'::regclass AND provider = 'lolor_test';

-- With the label gone the migration proceeds.
SELECT lolor.migrate_from_native() AS migrated;
SELECT lo_unlink(:peer_oid);
DROP EXTENSION lolor;

--
-- A parked comment must not outlive the object it describes.  Object OIDs are
-- only checked against pg_largeobject_metadata when a new one is generated, so
-- a comment left behind by lo_unlink() would be handed to whatever object next
-- took that OID.
--
CREATE EXTENSION lolor;
SELECT lolor.disable();
SELECT lo_from_bytea(0, 'has a comment') AS commented_oid \gset
COMMENT ON LARGE OBJECT :commented_oid IS 'parked then orphaned';
SELECT lolor.enable();
SELECT lolor.migrate_from_native();
SELECT count(*) AS parked FROM lolor.pg_largeobject_description
  WHERE loid = :commented_oid;

-- Unlinking must take the parked comment with it.
SELECT lo_unlink(:commented_oid);
SELECT count(*) AS parked_after_unlink FROM lolor.pg_largeobject_description
  WHERE loid = :commented_oid;

-- Re-create an object under the very same OID and send it back to native
-- storage.  It must arrive with no comment.
SELECT lo_create(:commented_oid) = :commented_oid AS oid_reused;
SELECT lolor.migrate_to_native();
SELECT count(*) AS inherited_comment FROM pg_description
  WHERE classoid = 'pg_largeobject'::regclass AND objoid = :commented_oid;
SELECT lolor.disable();
SELECT lo_unlink(:commented_oid);
SELECT lolor.enable();

--
-- DROP SCHEMA without CASCADE is RESTRICT and cannot remove a schema that
-- still holds the extension's tables.  The cleanup must not run for a command
-- that is going to be rejected, or it would migrate every large object and
-- take the storage locks only to have the work rolled back.
--
SELECT lo_from_bytea(0, 'still here afterwards') AS kept_oid \gset
DROP SCHEMA lolor;
SELECT count(*) AS extension_still_installed
  FROM pg_extension WHERE extname = 'lolor';
SELECT convert_from(lo_get(:kept_oid), 'UTF8') AS object_untouched;
SELECT count(*) AS still_in_lolor_storage
  FROM lolor.pg_largeobject_metadata WHERE oid = :kept_oid;
SELECT lo_unlink(:kept_oid);
DROP EXTENSION lolor;
