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
CREATE EXTENSION lolor;
SELECT lolor.disable();
DROP EXTENSION lolor;
SELECT oid, proname FROM pg_proc WHERE proname IN ('lo_open_orig',
  'lolor_lo_open');
