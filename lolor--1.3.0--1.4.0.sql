/* lolor--1.3.0--1.4.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION lolor UPDATE" to load this file. \quit

/*
 * Restore the ACLs on the server-side file access functions.
 *
 * pg_catalog.lo_import() and lo_export() read and write files as the account
 * PostgreSQL runs under, so core revokes EXECUTE on them from PUBLIC.  lolor
 * replaces them by renaming the originals to *_orig and creating its own.  An
 * ACL belongs to a function rather than to a name, so the restriction stayed
 * on the parked original while each replacement was created with the default
 * of EXECUTE TO PUBLIC.  Every version through 1.3.0 is affected.
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
 * Large objects in lolor storage whose owner no longer exists.
 *
 * Objects in lolor storage are rows in ordinary tables, so they cannot
 * participate in pg_shdepend: DROP ROLE will not notice them the way it
 * notices native large objects.  That is inherent to storing them outside the
 * catalogs; this function makes the consequence findable.
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
 * Remove the bogus pg_shdepend rows left by earlier versions.
 *
 * Through 1.3.0, creating a large object recorded a pg_shdepend row whose
 * classId was the OID of lolor.pg_largeobject -- an ordinary table, not a
 * catalog the dependency machinery can describe.  DROP ROLE on any role that
 * had created one failed with "unrecognized object class", and the rows were
 * never removed.
 *
 * pg_shdepend is shared across the cluster, so restrict the delete to this
 * database: the same classId in another database is an unrelated relation.
 */
DELETE FROM pg_catalog.pg_shdepend
WHERE dbid = (SELECT oid FROM pg_catalog.pg_database
               WHERE datname = current_database())
  AND classid IN ('lolor.pg_largeobject'::regclass,
                  'lolor.pg_largeobject_metadata'::regclass);
