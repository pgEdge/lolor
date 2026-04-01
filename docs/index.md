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


## Migrating large objects

Migration from native to lolor storage is **manual** — you decide when to move
existing large objects.  Migration back to native is **automatic** — dropping
the extension moves all objects back so nothing is lost.

### Native to lolor (manual)

If your database already contains native Postgres large objects, call
`migrate_from_native()` after enabling the extension.  The migration preserves
original OIDs, owners, ACLs, and data, so existing application references remain
valid.

```sql
CREATE EXTENSION lolor;
SELECT lolor.migrate_from_native();
```

The function returns the number of large objects migrated.  It is safe to call
when there are no native large objects.  This step is intentionally not
automatic: it requires superuser privileges and should be performed during a
maintenance window.

### Lolor to native (automatic on DROP EXTENSION)

Large objects are automatically migrated back to native Postgres storage when the
extension is dropped:

```sql
DROP EXTENSION lolor;
```

This ensures that no large objects are lost if the extension is removed.  You
can also trigger the reverse migration manually while the extension is still
installed:

```sql
SELECT lolor.migrate_to_native();
```

Both paths preserve OIDs, owners, ACLs, and data.

## Limitations

- Native Postgres large object functionality cannot be used while you are using the lolor extension.
- lolor does not support the following statements: `ALTER LARGE OBJECT`, `GRANT ON LARGE OBJECT`, `COMMENT ON LARGE OBJECT`, and `REVOKE ON LARGE OBJECT`.
- The migration procedures (`migrate_from_native`, `migrate_to_native`) are currently safe only in master-replica configurations. In multi-master setups, migrated OIDs (which lack node-encoding) may conflict with OIDs on other nodes.
