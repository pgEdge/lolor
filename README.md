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

After installing the lolor extension, add it to `shared_preload_libraries` and restart the server (see [Configuring lolor](#configuring-lolor)), then connect to your Postgres database and create the extension with the command:

```
CREATE EXTENSION lolor;
```

### Configuring lolor

lolor must be loaded at server start. Add it to `shared_preload_libraries` in
`postgresql.conf` and restart; `CREATE EXTENSION lolor`, `LOAD 'lolor'` and any call that reaches one of lolor's functions fail with `lolor must be loaded via "shared_preload_libraries"` when the library was loaded on demand; the native `pg_catalog.lo_*` functions are not affected while lolor is not installed or is disabled. The guard that protects large
objects when the extension is dropped is an object access hook, which is only
in place in every backend when the library is preloaded.

```
shared_preload_libraries = 'lolor'
```

You must set the `lolor.node` parameter before using the extension. The value can be from 1 to 15 (0 means unset); it is encoded in the four low bits of every large object OID lolor generates, so each node must use a different value.

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

Migration is a manual step in both directions. Dropping the extension never
moves data: it is refused while any object remains in lolor storage.

Migrate existing native large objects into lolor storage (requires superuser):

```sql
CREATE EXTENSION lolor;
SELECT lolor.migrate_from_native();
```

To remove the extension, migrate the objects back first:

```sql
SELECT lolor.migrate_to_native();
DROP EXTENSION lolor;
```

An object access hook refuses to remove the extension while it is enabled or
while any object remains in lolor storage, on every path that reaches it
(`DROP EXTENSION`, `DROP SCHEMA lolor CASCADE`, `DROP OWNED BY`). The drop
itself only puts the native `pg_catalog.lo_*` names back. To discard whatever
is in lolor storage instead, a superuser can set `lolor.allow_unsafe_drop = on`
for the session that runs the drop; it skips both checks. The drop renames the
native functions back, so it has the same requirements as `lolor.disable()`:
no other session connected to the database, and a client session.

Both directions preserve original OIDs, owners, ACLs, and data.

Two helpers find and repair objects whose roles have been dropped:

```sql
SELECT * FROM lolor.check_orphans();  -- objects referring to a dropped role
SELECT lolor.fix_orphans('some_role');  -- reassign them and drop dead ACL entries
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

Versions 1.0 through 1.2.2 left these two functions executable by every
database user. Upgrading to 1.3.0 revokes the privilege; see the release notes.

### Limitations

- Native large object functionality cannot be used while you are using the lolor extension.
- lolor does not support the following statements: `ALTER LARGE OBJECT`, `GRANT ON LARGE OBJECT`, `COMMENT ON LARGE OBJECT`, and `REVOKE ON LARGE OBJECT`.
- `lolor.enable()`, `lolor.disable()`, and dropping the extension while lolor is enabled, refuse while any other session is connected to the database, the same rule as `ALTER DATABASE ... RENAME`: a renamed function keeps its OID, so a session that already resolved the `lo_*` functions keeps calling the previous implementation, and the row movement cannot be made atomic for other backends either. The calling session must reconnect after `enable()` or `disable()`. They also refuse to run from anything but a client session, so replicated DDL cannot drive them from an apply worker.
- Objects in lolor storage are rows in ordinary tables and so cannot participate in `pg_shdepend`. `DROP ROLE`, `DROP OWNED BY` and `REASSIGN OWNED BY` do not see them: a role that owns them or appears in their ACL can be dropped without a warning, and `REASSIGN OWNED` / `DROP OWNED` leave them untouched. Before dropping a role, run `REASSIGN OWNED BY` or `DROP OWNED BY` in each database that has lolor, then `DROP ROLE`. Afterwards run `lolor.check_orphans()` in each such database and repair anything it reports with `lolor.fix_orphans(new_owner)`; `lolor.migrate_to_native()` refuses while orphans exist.
- Role OIDs come from a cluster-wide counter that wraps around, so a new role can receive a dropped role's OID and silently become the owner or grantee of that role's orphaned objects. This cannot be detected after the fact, which is another reason to run `lolor.check_orphans()` promptly after dropping roles.
- Large object migration is node-local. Native large objects live in `pg_catalog.pg_largeobject`, which is never replicated, so each node holds an independent set and `migrate_from_native()` migrates only the local node's objects; with spock installed, the migration DML runs in repair mode and is not replicated. Run the migration on every node that holds native large objects — for example with `spock.replicate_ddl('SELECT lolor.migrate_from_native()')`, which queues the command so that each node executes it locally. Migrated objects keep their original native OIDs, which are not node-encoded: if different nodes hold different objects under the same OID, the nodes' lolor contents will diverge and later replicated changes to those objects can conflict. Newly created large objects are collision-free, since new OIDs are node-encoded via `lolor.node` and checked against existing rows.
