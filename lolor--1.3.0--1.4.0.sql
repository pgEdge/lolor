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
