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

Migration is a manual step in both directions: you decide when to move
existing large objects into lolor storage, and you move them back before
dropping the extension.  Dropping the extension never moves data: it is
refused while any object remains in lolor storage.

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

### Lolor to native (before DROP EXTENSION)

Move the large objects back to native Postgres storage, then drop the
extension:

```sql
SELECT lolor.migrate_to_native();
DROP EXTENSION lolor;
```

Both paths preserve OIDs, owners, ACLs, comments and data, and copy pages
verbatim so sparse large objects stay sparse.

`migrate_to_native()` does not require lolor to be enabled; it operates on the
catalogs directly.

`migrate_from_native()` does not check whether lolor is enabled. If lolor is
disabled, the objects still move into lolor storage, and the native
`pg_catalog.lo_*` functions then report that they do not exist. No data is
lost; the objects are reachable again after `lolor.enable()`. Enable lolor
before migrating so that applications never see that state.

A helper supports verifying a migration across nodes:

```sql
SELECT * FROM lolor.digest();         -- per-object checksum, compare across nodes
```

The drop is refused while any object remains in lolor storage, on every path
that reaches the extension (`DROP EXTENSION`, `DROP SCHEMA lolor CASCADE`,
`DROP OWNED BY`). The drop itself moves no data; an event trigger puts the
native `pg_catalog.lo_*` names back first, so a normal drop of an enabled lolor
works. An object access hook makes the same checks when the extension is
deleted, and also refuses if lolor is still enabled at that point, for example
because event triggers are turned off. To discard whatever
is in lolor storage instead, a superuser can set `lolor.allow_unsafe_drop = on`
for the session that runs the drop. It skips every check, and the drop then
does not restore the native function names either, so run `lolor.disable()`
first if lolor is enabled. While lolor is enabled, a normal drop renames the
native functions back, so it has the same requirements as `lolor.disable()`:
no other session connected to the database, and a client session. A disabled
lolor renames nothing, and the drop has no such requirement.

`lolor.enable()` and `lolor.disable()` refuse while
any other session is connected to the database, and refuse to run from
anything but a client session. Reconnect client sessions after `enable()` or
`disable()`: libpq caches the large object function OIDs per connection.

Two helpers find and repair objects whose roles have been dropped:

```sql
SELECT * FROM lolor.check_orphans();  -- objects referring to a dropped role
SELECT lolor.fix_orphans('some_role');  -- reassign them and drop dead ACL entries
```

When the spock extension is installed, both migration functions run under
`spock.repair_mode()`, so the row-shuffling migration DML is **not** replicated
to other nodes.  This is essential for `migrate_to_native()`: its deletes from
the lolor tables would otherwise replicate while the native re-creation stayed
local, destroying large objects on the other nodes.

Even with spock, migration is refused if a non-spock logical replication slot
(e.g. `pgoutput`, `wal2json`) exists, since repair mode only suppresses spock's
own output plugin and those consumers would still decode the migration DML:
`migrate_to_native()` raises an `ERROR`, while `migrate_from_native()` warns and
returns -1 without doing anything.  Drop the offending slots before migrating.

Without spock, the migration DML cannot be excluded from logical decoding, so
both functions refuse to migrate while logical replication slots exist in the
database: `migrate_from_native()` raises a `WARNING` and returns -1 without
doing anything (0 is reserved for "nothing to migrate"), while
`migrate_to_native()` raises an `ERROR`.  Drop all logical replication slots before
migrating; merely disabling a subscription is not sufficient, since its slot
retains the changes and delivers them when replication resumes.

### Migrating in a cluster that already has several nodes

Native large objects are never replicated, so before migration each node holds
only the objects that were created on that node. Migration moves those objects
into that node's lolor tables and does not replicate the rows. An object that
existed on one node is therefore still on only that node afterwards. lolor
replicates changes made from then on, so a later write to that object, or an
unlink of it, reaches the other nodes as a change to rows they do not have.

Before migrating, count the native objects on every node to see which nodes
hold any:

```sql
SELECT count(*) FROM lolor.native_lo_oids();
```

How to proceed depends on where the native objects are:

- If the database has a single node, install lolor and migrate first, and add
  the other nodes afterwards. The initial synchronization of a new node copies
  the lolor tables, because they are in the replication set.
- If every node holds the same native objects, for example because the nodes
  were restored from one backup, migrate on each node. The lolor tables then
  match without any copying.
- If one node holds every object, migrate on each node that holds native
  objects, then resynchronize the lolor tables on each other node from that
  node. The resynchronization replaces the other node's copy of each table:

    ```sql
    SELECT spock.sub_resync_table('mysub', 'lolor.pg_largeobject_metadata');
    SELECT spock.sub_resync_table('mysub', 'lolor.pg_largeobject');
    SELECT spock.sub_resync_table('mysub', 'lolor.pg_largeobject_description');
    ```

- If different nodes hold different objects, no node has the complete set and
  a resynchronization would discard objects. Migrate on each node, then bring
  the lolor tables into agreement with a table comparison and repair tool such
  as ACE.

In every case, stop large object activity until the nodes agree, and finish by
comparing `lolor.digest()` across the nodes.

## Dropping the extension

In a replicated cluster the lolor tables are published, subscribed, or both,
and the drop is refused while any of that is still true: the drop itself
would succeed, but the other side would keep sending or expecting rows for
tables this node no longer has. Unwind replication first, in this order:

1. Stop creating and changing large objects on every node, and let
   replication drain. Then confirm the nodes agree:

   ```sql
   SELECT * FROM lolor.digest();   -- run on every node; the output must match
   ```

2. Stop publishing the tables. With Spock, remove them from the replication
   set on every provider node that publishes them:

   ```sql
   SELECT spock.repset_remove_table('default', 'lolor.pg_largeobject');
   SELECT spock.repset_remove_table('default', 'lolor.pg_largeobject_metadata');
   ```

   With native logical replication, drop them from the publication instead:

   ```sql
   ALTER PUBLICATION mypub DROP TABLE lolor.pg_largeobject, lolor.pg_largeobject_metadata;
   ```

   A publication created `FOR TABLES IN SCHEMA lolor` drops them with
   `ALTER PUBLICATION mypub DROP TABLES IN SCHEMA lolor`. A `FOR ALL
   TABLES` publication publishes them for as long as it exists: drop it,
   or recreate it with an explicit table list.

3. Stop subscribing to them. A node that synchronized the tables when its
   spock subscription was created still counts them as replicated; refresh
   the subscription on that node so it forgets tables that are no longer in
   the provider's replication sets:

   ```sql
   SELECT spock.sub_alter_sync('mysub');
   ```

   A native subscription is refreshed with:

   ```sql
   ALTER SUBSCRIPTION mysub REFRESH PUBLICATION;
   ```

   From here no node publishes the tables and no subscription expects
   changes for them, so the order of the per-node steps below does not
   matter.

4. Migrate the data out on every node, connecting to each node directly;
   with spock the migration runs in repair mode and is not replicated:

   ```sql
   SELECT lolor.migrate_to_native();
   ```

   The migration refuses while a logical replication slot of any plugin
   other than spock's exists in the database, and a native subscription
   keeps its slot on the publisher even when refreshed or disabled. Drop
   the native subscriptions that point at the node, which removes their
   slots, before migrating there.

5. Drop the extension on each node, connecting to each node directly, with
   no other client session connected to the database:

   ```sql
   DROP EXTENSION lolor;
   ```

Without replication there is a single node: stop large object use, run
`lolor.migrate_to_native()`, and drop the extension, with the same
single-session requirement while lolor is enabled.

## Security

`lo_import()` and `lo_export()` read and write files on the server host. As in
core Postgres, `EXECUTE` on them is revoked from `PUBLIC`; grant it
deliberately if a non-superuser needs server-side file access.

Versions 1.0 through 1.2.3 left these two functions executable by every
database user. Upgrading to 2.0.0 revokes the privilege; see the
[release notes](lolor_release_notes.md).

## Limitations

- Native Postgres large object functionality cannot be used while you are using the lolor extension.
- lolor does not support the following statements against objects held in lolor storage: `ALTER LARGE OBJECT`, `GRANT ON LARGE OBJECT`, `COMMENT ON LARGE OBJECT`, and `REVOKE ON LARGE OBJECT`. Owners, ACLs and comments set while an object was in native storage are preserved across migration in both directions.
- `lolor.enable()`, `lolor.disable()`, the migration functions, `CREATE EXTENSION lolor`, and dropping the extension while lolor is enabled, refuse while any other session is connected to the database, the same rule as `ALTER DATABASE ... RENAME`: a renamed function keeps its OID, so a session that already resolved the `lo_*` functions keeps calling the previous implementation, and the row movement cannot be made atomic for other backends either. The calling session must reconnect after `enable()` or `disable()`. They also refuse to run from anything but a client session, so replicated DDL cannot drive them from an apply worker. Only client sessions count: background workers such as replication apply workers do not call the `lo_*` functions by name. To count reliably, each of these operations takes an exclusive lock on the database first, so a new connection to it waits until the operation's transaction ends. In single-user mode they run without the session check.
- The loaded library and the installed extension must be the same version for `lolor.enable()`, `lolor.disable()`, the migration functions, `lolor.check_orphans()`, `lolor.fix_orphans()` and dropping the extension. After installing new library files, run `ALTER EXTENSION lolor UPDATE` in each database before using them; until then they refuse and name both versions.
- Objects in lolor storage are rows in ordinary tables and so cannot participate in `pg_shdepend`. `DROP ROLE`, `DROP OWNED BY` and `REASSIGN OWNED BY` do not see them: a role that owns them or appears in their ACL can be dropped without a warning, and `REASSIGN OWNED` / `DROP OWNED` leave them untouched. Before dropping a role, run `REASSIGN OWNED BY` or `DROP OWNED BY` in each database that has lolor, then `DROP ROLE`. For the role that owns the extension use `REASSIGN OWNED BY`: `DROP OWNED BY` would remove the extension too, and is refused while any object remains in lolor storage. Afterwards run `lolor.check_orphans()` in each such database and repair anything it reports with `lolor.fix_orphans(new_owner)`; `lolor.migrate_to_native()` refuses while orphans exist.
- Dropping lolor is refused while `lolor.pg_largeobject` or `lolor.pg_largeobject_metadata` is in a spock replication set, a publication or a subscription on this node, or was synchronized to this node through a spock subscription, whichever way the drop is spelled. The drop itself would succeed; what breaks is replication afterwards, since the other side keeps sending rows for a table this node no longer has. Remove the tables from the replication set, publication or subscription first, then migrate the objects out and drop. The refusal is enforced when the tables are deleted, not only by the event trigger, so disabling event triggers does not get around it. A spock subscriber knows the tables as replicated only from their initial synchronization; a table added to a replication set later is not seen by the check on that node. The step-by-step order is in [Dropping the extension](#dropping-the-extension).
- Role OIDs come from a cluster-wide counter that wraps around, so a new role can receive a dropped role's OID and silently become the owner or grantee of that role's orphaned objects. This cannot be detected after the fact, which is another reason to run `lolor.check_orphans()` promptly after dropping roles.
- Large object migration is node-local. Native large objects live in `pg_catalog.pg_largeobject`, which is never replicated, so each node holds an independent set and `migrate_from_native()` migrates only the local node's objects; with spock installed, the migration DML runs in repair mode and is not replicated. Run the migration on every node that holds native large objects, connecting to each node directly. It refuses to run inside an apply worker, so sending it through DDL replication fails on every subscriber. Migrated objects keep their original native OIDs, which are not node-encoded: if different nodes hold different objects under the same OID, the nodes' lolor contents will diverge and later replicated changes to those objects can conflict. Newly created large objects are collision-free, since new OIDs are node-encoded via `lolor.node` and checked against existing rows. To make that hazard an error rather than silent divergence, collect the other nodes' OIDs with `lolor.native_lo_oids()` and pass them in: `SELECT lolor.migrate_from_native(peer_oids => ARRAY[...])` refuses when any of them collide. Migration does not copy objects between nodes: an object that existed natively on only one node is, after migration, in only that node's lolor tables, and a later replicated change to it finds no row on the other nodes. After migrating every node, compare `lolor.digest()` across nodes to confirm they converged.
- Install, update and remove lolor on each node separately. With Spock 5, automatic DDL replication (`spock.enable_ddl_replication`) sends `CREATE EXTENSION lolor`, `ALTER EXTENSION lolor UPDATE` and `DROP EXTENSION lolor` to the other nodes, where lolor refuses the create and the drop inside the apply worker; the other nodes record the failure in `spock.exception_log` while the node that ran the statement reports success. Turn the setting off in the session that runs these statements. Spock 6 keeps these statements on the node where they are issued.
