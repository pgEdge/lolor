-- Basic checks
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

DROP EXTENSION lolor;
