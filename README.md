# lolor

lolor is an extension that makes Postgres' Large Objects compatible with Logical Replication.

## Table of Contents
- [lolor Overview](docs/index.md)
- [Building and Installing lolor](docs/install_configure.md)
- [Basic Configuration](README.md#configuring-lolor)
- [Using lolor](docs/using_lolor.md)
- [Limitations](README.md#limitations)
- [Using pg_upgrade with lolor](docs/pg_upgrade_with_lolor.md)
- [Release Notes](docs/lolor_release_notes.md)

PostgreSQL supports large objects as related chunks as described in the [pg_largeobject](https://www.postgresql.org/docs/current/catalog-pg-largeobject.html) table. Large objects provide stream-style access to user data stored in a special large-object structure in the catalog. Large objects stored in catalog tables require special handling during replication; the lolor extension allows for the storage of large objects in non-catalog tables, aiding in replication of large objects.

lolor creates and manages large object related tables in the `lolor` schema:

```
lolor.pg_largeobject
lolor.pg_largeobject_metadata
```

PostgreSQL large objects allow you to store huge files within the database. Each large object is recognised by an OID that is assigned at the time of its creation. lolor stores objects in smaller segments within a separate system table and generates associated OIDs for large objects that are distinct from those of native large objects.

Use of the lolor extension requires Postgres 16 or newer.

### Building and Installing lolor

You can also compile and install the extension from the source code, with the same guidelines as any other Postgres extension constructed using PGXS.
Make sure that your PATH environment variable includes the directory where `pg_config` (under your Postgres installation) is located.

```
export PATH=/usr/pgsql-17/bin:$PATH

# compile
make USE_PGXS=1
# install, might be requiring sudo for the installation step
make USE_PGXS=1 install
```

After installing the lolor extension, connect to your Postgres database and create the extension with the command:

```
CREATE EXTENSION lolor;
```

### Configuring lolor

You must set the `lolor.node` parameter before using the extension. The value can be from 1 to 2^28; the value is used to help in generation of new large object OID.

```
lolor.node = 1
```

You can also change the `search_path` to pick large object related tables from the `lolor` schema:

```
set search_path=lolor,"$user",public,pg_catalog
```

Any existing methods in `pg_catalog.lo_*` are renamed to `pg_catalog.lo_*_orig`, and new versions of these methods are introduced.
If you remove the extension, the renamed `pg_catalog.lo_*_orig` functions are restored to their initial names.

When you replicate large objects with Spock, the tables `pg_largeobject` and `pg_largeobject_metadata` must belong to your replication set. Connect to the lolor database and add them with `spock.repset_add_table`:

```sql
SELECT spock.repset_add_table('spock_replication_set', 'lolor.pg_largeobject');
SELECT spock.repset_add_table('spock_replication_set', 'lolor.pg_largeobject_metadata');
```

### Migrating large objects

Migration from native to lolor is **manual**; migration back is **automatic**
on `DROP EXTENSION` so no objects are ever lost.

Migrate existing native large objects into lolor storage (requires superuser):

```sql
CREATE EXTENSION lolor;
SELECT lolor.migrate_from_native();
```

Reverse migration happens automatically when the extension is dropped, or can
be triggered manually:

```sql
SELECT lolor.migrate_to_native();  -- manual
DROP EXTENSION lolor;              -- automatic
```

Both directions preserve original OIDs, owners, ACLs, comments and data, and
copy pages verbatim so sparse large objects stay sparse. Moving an object to
native storage also reinstates its `pg_shdepend` entries, so `DROP ROLE`,
`REASSIGN OWNED` and `DROP OWNED` continue to see it.

`migrate_to_native()` does not require lolor to be enabled; it operates on the
catalogs directly.

Security labels on large objects cannot be represented in lolor storage and
cannot be reinstated without their label provider, so `migrate_from_native()`
refuses rather than discarding them. Remove them first if you hit this.

Two helpers support verifying a migration:

```sql
SELECT * FROM lolor.digest();         -- per-object checksum, compare across nodes
SELECT * FROM lolor.check_orphans();  -- lolor objects whose owner no longer exists
```

When the spock extension is installed, both migration functions run under
`spock.repair_mode()`, so the row-shuffling migration DML is **not**
replicated to other nodes. This is essential for `migrate_to_native()`: its
deletes from the lolor tables would otherwise replicate while the native
re-creation stayed local, destroying large objects on the other nodes.

Even with spock, migration is refused if a non-spock logical replication slot
(e.g. `pgoutput`, `wal2json`) exists, since repair mode only suppresses spock's
own output plugin and those consumers would still decode the migration DML:
`migrate_to_native()` raises an `ERROR`, while `migrate_from_native()` warns and
returns -1 without doing anything. Drop the offending slots before migrating.
The check identifies spock's slots by their `spock_output` plugin.

Without spock, the migration DML cannot be excluded from logical decoding, so
both functions refuse to migrate while logical replication slots exist in the
database: `migrate_from_native()` raises a `WARNING` and returns -1 without
doing anything (0 is reserved for "nothing to migrate"), while
`migrate_to_native()` (and therefore `DROP EXTENSION lolor`) raises an
`ERROR`. Drop all logical replication slots before
migrating; merely disabling a subscription is not sufficient, since its slot
retains the changes and delivers them when replication resumes.

### Security

`lo_import()` and `lo_export()` read and write files on the server host. As in
core PostgreSQL, `EXECUTE` on them is revoked from `PUBLIC`; grant it
deliberately if a non-superuser needs server-side file access.

Versions 1.0 through 1.3.0 left these two functions executable by every
database user. Upgrading to 1.4.0 revokes the privilege; see the release notes.

### Limitations

- Native large object functionality cannot be used while you are using the lolor extension.
- lolor does not support the following statements against objects held in lolor storage: `ALTER LARGE OBJECT`, `GRANT ON LARGE OBJECT`, `COMMENT ON LARGE OBJECT`, and `REVOKE ON LARGE OBJECT`. Owners, ACLs and comments set while an object was in native storage are preserved across migration in both directions.
- Objects in lolor storage are rows in ordinary tables and so cannot participate in `pg_shdepend`: `DROP ROLE` will not notice that a role still owns them, the way it does for native large objects. Use `lolor.check_orphans()` to find objects whose owner has been dropped.
- `lolor.enable()` and `lolor.disable()` change which function OID owns each `pg_catalog.lo_*` name. libpq resolves those OIDs once per connection and caches them, so existing client sessions must reconnect afterwards.
- Large object migration is node-local. Native large objects live in `pg_catalog.pg_largeobject`, which is never replicated, so each node holds an independent set and `migrate_from_native()` migrates only the local node's objects; with spock installed, the migration DML runs in repair mode and is not replicated. Run the migration on every node that holds native large objects — for example with `spock.replicate_ddl('SELECT lolor.migrate_from_native()')`, which queues the command so that each node executes it locally. Migrated objects keep their original native OIDs, which are not node-encoded: if different nodes hold different objects under the same OID, the nodes' lolor contents will diverge and later replicated changes to those objects can conflict. Newly created large objects are collision-free, since new OIDs are node-encoded via `lolor.node` and checked against existing rows. To make that hazard an error rather than silent divergence, collect the other nodes' OIDs with `lolor.native_lo_oids()` and pass them in: `SELECT lolor.migrate_from_native(peer_oids => ARRAY[...])` refuses when any of them collide. After migrating every node, compare `lolor.digest()` across nodes to confirm they converged.
