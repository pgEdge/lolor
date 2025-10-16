# lolor - Managing Large Objects for Logical Replication

[lolor](https://github.com/pgEdge/lolor) is an extension that makes Postgres-style large objects compatible with logical Replication.

Postgres supports large objects as related chunks as described in the [pg_largeobject](https://www.postgresql.org/docs/current/catalog-pg-largeobject.html) table. Large objects provide stream-style access to user data stored in a special large-object structure in the catalog. Large objects stored in catalog tables require special handling during replication; the lolor extension allows for the storage of large objects in non-catalog tables, aiding in replication of large objects.

lolor creates and manages large object related tables in the `lolor` schema:

```
lolor.pg_largeobject
lolor.pg_largeobject_metadata
```

Postgres large objects allow you to store large files within the database. Each large object is recognised by an OID that is assigned at the time of its creation. lolor stores objects in smaller segments within a separate system table and generates associated OIDs for large objects that are distinct from those of native large objects.

Use of the `lolor` extension requires Postgres 16 or newer.


## Limitations

- Native Postgres large object functionality cannot be used while you are using the lolor extension.
- Native large object migration to the lolor feature is not available yet.
- lolor does not support the following statements: `ALTER LARGE OBJECT`, `GRANT ON LARGE OBJECT`, `COMMENT ON LARGE OBJECT`, and `REVOKE ON LARGE OBJECT`.
