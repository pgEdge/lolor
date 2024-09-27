--
-- lolor: large objects for logical replication
--
-- Needs a server patched with the lolor core patch and started with
--   shared_preload_libraries = 'lolor'
--   lolor.node = 3
--   wal_level = logical
-- and test_decoding installed.
--

-- Without the extension the large object catalogs are not decoded.
SELECT 'init' FROM pg_create_logical_replication_slot('lolor_slot', 'test_decoding');
SELECT lo_create(900001) AS before_extension;
SELECT count(*) AS decoded_before_extension
  FROM pg_logical_slot_get_changes('lolor_slot', NULL, NULL)
 WHERE data !~ '^(BEGIN|COMMIT)';
SELECT lo_unlink(900001);
SELECT count(*) AS decoded_unlink_before_extension
  FROM pg_logical_slot_get_changes('lolor_slot', NULL, NULL)
 WHERE data !~ '^(BEGIN|COMMIT)';

CREATE EXTENSION lolor;

-- The extension gives both catalogs a replica identity ...
SELECT relname, relreplident FROM pg_class
 WHERE oid IN ('pg_catalog.pg_largeobject'::regclass,
               'pg_catalog.pg_largeobject_metadata'::regclass)
 ORDER BY relname;
SELECT lolor.replication_enabled();

-- ... and the setting stays confined to the function that made it.
SHOW allow_system_table_mods;

-- Generated OIDs carry the node id in the low bits.
SHOW lolor.node;
SELECT lo_create(0)::bigint & 15 AS node_bits_lo_create;
SELECT lo_creat(-1)::bigint & 15 AS node_bits_lo_creat;
SELECT lo_from_bytea(0, 'x'::bytea)::bigint & 15 AS node_bits_lo_from_bytea;

-- The OIDs of different calls differ, and none is zero.
SELECT count(DISTINCT o) = 50 AS distinct_oids, bool_and(o <> 0) AS valid_oids
  FROM (SELECT lo_create(0)::bigint AS o FROM generate_series(1, 50)) s;

-- Explicitly requested OIDs are used as given.
SELECT lo_create(900002);
SELECT lo_create(900002);

-- Discard what the above has produced.
SELECT count(*) > 0 AS has_changes
  FROM pg_logical_slot_get_changes('lolor_slot', NULL, NULL);

-- Every kind of change to a large object is decoded.
SELECT lo_create(900003);
SELECT lowrite(lo_open(900003, 131072), 'hello'::bytea);
SELECT lowrite(lo_open(900003, 131072), 'J'::bytea);
SELECT lo_truncate(lo_open(900003, 131072), 1);
SELECT lo_unlink(900003);
SELECT data FROM pg_logical_slot_get_changes('lolor_slot', NULL, NULL)
 WHERE data !~ '^(BEGIN|COMMIT)';

-- Only a superuser may change the setting, and it can be applied again.
CREATE ROLE lolor_regress_user;
GRANT USAGE ON SCHEMA lolor TO lolor_regress_user;
SET ROLE lolor_regress_user;
SELECT lolor.set_replica_identity(false);
RESET ROLE;
REVOKE USAGE ON SCHEMA lolor FROM lolor_regress_user;
DROP ROLE lolor_regress_user;
SELECT lolor.set_replica_identity(true);
SELECT lolor.replication_enabled();

-- The node id cannot change on a running server.
SET lolor.node = 5;

-- Dropping the extension switches decoding off again ...
DROP EXTENSION lolor;
SELECT relname, relreplident FROM pg_class
 WHERE oid IN ('pg_catalog.pg_largeobject'::regclass,
               'pg_catalog.pg_largeobject_metadata'::regclass)
 ORDER BY relname;
SELECT lo_create(900004);
SELECT lo_unlink(900004);
SELECT count(*) AS decoded_after_drop
  FROM pg_logical_slot_get_changes('lolor_slot', NULL, NULL)
 WHERE data !~ '^(BEGIN|COMMIT)';

-- ... and the extension can be created again.
CREATE EXTENSION lolor;
SELECT lolor.replication_enabled();
DROP EXTENSION lolor;

-- Clean up.
SELECT pg_drop_replication_slot('lolor_slot');
SELECT count(lo_unlink(oid)) AS leftover_large_objects
  FROM pg_largeobject_metadata;
