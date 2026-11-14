# lolor Release Notes

## lolor 2.0.0

lolor 2.0.0 adds supported migration of large objects into and out of lolor
storage, makes removal of the extension safe, and fixes two defects that
affect security and role management. This release changes how the lolor
library is loaded; read the upgrade steps before you install the new files.

The release is numbered 2.0.0, and not 1.3.0, because an existing
installation cannot take the new version without changes: the library must
be preloaded, the extension is no longer trusted, and a drop of the
extension no longer discards stored objects. There is no 1.3.0 release.

### Highlights

The following list summarizes the most important changes in this release:

- Two new functions, `lolor.migrate_from_native()` and
  `lolor.migrate_to_native()`, move large objects between native Postgres
  storage and lolor storage in either direction without loss.
- A drop of the extension no longer discards large objects. Earlier
  versions dropped the lolor tables together with their contents; the drop
  is now refused while lolor storage holds objects or while the lolor
  tables are replicated.
- lolor must now be listed in `shared_preload_libraries`. This change
  requires a configuration change and a restart during the upgrade.
- A security fix revokes `EXECUTE` on `lo_import()` and `lo_export()` from
  `PUBLIC`. Versions 1.0 through 1.2.3 left both functions open to every
  database user.
- `DROP ROLE` no longer fails with "unrecognized object class" for a role
  that created a large object.
- The extension is no longer marked `trusted`; only a superuser can install
  or update lolor.

### Upgrading to 2.0.0

The upgrade needs a restart and a superuser. Perform the following steps on
every node, and connect to each node directly for the SQL step:

1. Install the new lolor package or library files on the server and on each
   of its physical standbys.
2. Add `lolor` to `shared_preload_libraries` in `postgresql.conf` on the
   server and on each standby.
3. Restart the server and each standby.
4. Update the extension as a superuser in every database that has lolor:

    ```sql
    ALTER EXTENSION lolor UPDATE;
    ```
5. Add the new comment table to the replication set that holds the other
   lolor tables:

    ```sql
    SELECT spock.repset_add_table('default',
                                  'lolor.pg_largeobject_description');
    ```

Between step 1 and step 3, a new session that uses a large object fails
because the new library refuses to load on demand. A server that preloads
the old library does not have that window; new sessions keep using the
preloaded 1.2.3 library until the restart. To upgrade that way, perform
step 2 and a restart first, while the 1.2.3 files are still installed, and
then continue with steps 1, 3, 4 and 5. This order costs a second restart.

Review the following changes in behavior before you upgrade:

- lolor refuses to load on demand. `CREATE EXTENSION lolor`, `LOAD 'lolor'`
  and any call that reaches a lolor function fail with
  `lolor must be loaded via "shared_preload_libraries"` unless the library
  is preloaded. Between step 1 and step 3, a new session that uses a large
  object receives that error unless the old library is already preloaded.
  The native
  `pg_catalog.lo_*` functions are not affected while lolor is not installed
  or is disabled.
- A missing or broken library now fails at server start instead of at the
  first `lo_open()` call.
- The update script revokes `EXECUTE` on `lo_import()` and `lo_export()`
  from `PUBLIC`. Grant the privilege to each role that needs server-side
  file access.
- The update script removes stale `pg_shdepend` rows for the current
  database only. Until every database that has lolor is updated, `DROP
  ROLE` keeps failing for a role that created large objects in a database
  that is not yet updated.
- Until step 4 is complete in a database, a drop of the extension is
  refused in that database, and the new functions do not exist there yet.
  From 2.0.0 on, `lolor.enable()`, `lolor.disable()`, the migration
  functions, `lolor.check_orphans()`, `lolor.fix_orphans()` and the drop
  require the loaded library and the installed extension to be the same
  version.
- `CREATE EXTENSION lolor`, `lolor.enable()`, `lolor.disable()`, the
  migration functions and a drop of an enabled lolor require that no other
  client session is connected to the database. They also refuse to run
  from anything but a client session, so run them on each node directly
  and do not send them through DDL replication.
- Spock 5 automatic DDL replication sends `CREATE EXTENSION lolor`, `ALTER
  EXTENSION lolor UPDATE` and `DROP EXTENSION lolor` to the other nodes,
  where lolor refuses the create and the drop. Turn off
  `spock.enable_ddl_replication` in the session that runs these
  statements. Spock 6 keeps these statements on the node where they are
  issued.
- `lolor.node` no longer accepts 16; the valid node ids are 1 through 15,
  and 0 means unset. A server configured with `lolor.node = 16` still
  starts, but the setting is rejected and falls back to 0, and every call
  that creates a large object then fails with
  `value for lolor.node is not set`. `ALTER EXTENSION lolor UPDATE`
  refuses to run while a configuration file or a per-database or per-role
  setting names a value above 15, and reports where the value is set.
  Change the setting on such a node to an unused value in the range 1
  through 15.
- `pg_upgrade` requires `lolor` in `shared_preload_libraries` on both the
  old cluster and the new cluster.
- The update script raises a notice when streaming replicas are attached,
  as a reminder that each replica needs lolor installed.

A database that ran `DROP EXTENSION lolor` on an earlier version keeps its
stale `pg_shdepend` rows, and no update script runs there. As a superuser in
that database, use the following query to find the stale class OIDs:

```sql
SELECT DISTINCT classid
  FROM pg_shdepend
 WHERE dbid = (SELECT oid FROM pg_database
                WHERE datname = current_database())
   AND classid NOT IN (SELECT oid FROM pg_class);
```

Then use the following command to remove the rows, substituting the
database OID and the class OIDs that the query returned:

```sql
DELETE FROM pg_shdepend
 WHERE dbid = <dbid> AND classid IN (<class OIDs>);
```

### Migrating Large Objects

Migration is new in this release and is a manual, superuser-only step in
both directions. The following changes describe the migration functions:

- `lolor.migrate_from_native(peer_oids oid[] DEFAULT NULL)` moves native
  large objects into lolor storage. Run the function after `CREATE
  EXTENSION lolor`. The function returns the number of objects moved, or
  -1 with a warning when logical replication slots block the migration.
- `lolor.migrate_to_native()` moves the objects back to native storage,
  whether or not lolor is enabled. Run the function before you drop the
  extension. A blocked migration in this direction raises an error.
- Both directions preserve OIDs, owners, ACLs, comments and the exact page
  layout, so sparse objects stay sparse. The implementation is a direct
  relation-to-relation copy in C (`lolor.migrate_storage()`) instead of a
  loop through the large object API.
- A move back to native storage records ownership and ACLs in
  `pg_shdepend`, so `DROP ROLE`, `REASSIGN OWNED` and `DROP OWNED` see the
  objects again.
- The new table `lolor.pg_largeobject_description` holds the comment of
  each object while the object is in lolor storage. `lo_unlink()` removes
  the parked comment together with the object.
- Add `lolor.pg_largeobject_description` to the replication set that
  already holds the other two lolor tables, on every node, after the
  update. Without the table in the set, a `lo_unlink()` leaves the comment
  behind on the other nodes.
- Native objects are removed with the same bookkeeping as `DROP`
  (dependencies, comments and labels) but without the per-object locks. A
  database with more large objects than the lock table can hold migrates
  without a change to `max_locks_per_transaction`.
- `migrate_from_native()` does not check whether lolor is enabled. On a
  disabled lolor the objects still move into lolor storage and are not
  reachable through the native functions until `lolor.enable()` runs.
- Both functions verify the storage layouts against the running server
  before any row is copied.
- `migrate_from_native()` refuses when a large object carries a security
  label, because lolor storage cannot represent labels.
- Both functions refuse when an OID already exists in the destination
  storage, and the error names the first ten conflicting OIDs.
- `migrate_to_native()` refuses with a clear error while any object refers
  to a dropped role, instead of failing part-way with "role N was
  concurrently dropped". Repair those objects with `lolor.fix_orphans()`,
  or remove them with `lo_unlink()`, and retry.
- Both functions hold `ShareRowExclusiveLock` on both stores until commit,
  so a concurrent `lo_write()` cannot be lost. Opposing migrations take
  the locks in a fixed order and cannot deadlock.
- Both functions refuse while any other client session is connected to
  the database, and refuse to run from anything but a client session.

Migration is local to one node. The following changes describe how
migration interacts with replication:

- With Spock installed, both functions run under `spock.repair_mode()`
  when a logical replication slot exists in the database, so the row
  movement is not replicated.
- Both functions refuse while the database has a logical replication slot
  that Spock cannot suppress; that is a slot of another output plugin, or
  any logical slot when Spock is absent. Subscribers would otherwise
  decode the migration as ordinary row changes.
- Native large objects are never replicated, so run the migration on each
  node that holds native large objects, and connect to that node directly.
  The functions refuse to run inside an apply worker.
- An object that is migrated on one node is not copied to the other nodes.
  In a cluster that already has several nodes, the lolor tables must be
  brought into agreement after the migration; the documentation describes
  the procedure for each starting point.
- Native OIDs are not node-encoded. Pass the OIDs of the other nodes (from
  the new function `lolor.native_lo_oids()`) as `peer_oids` to turn a
  cross-node collision into a refusal.
- The new function `lolor.digest()` returns a per-object checksum of lolor
  storage. Compare the output across nodes after a migration.

### Dropping the Extension

A drop of the extension is now guarded by an object access hook in addition
to the event trigger. The following changes apply to `DROP EXTENSION`,
`DROP SCHEMA lolor CASCADE`, `DROP OWNED BY` and any other path that reaches
the extension:

- The drop is refused while any object remains in lolor storage; run
  `lolor.migrate_to_native()` first. Earlier versions dropped the lolor
  tables and silently discarded every object in them.
- The event trigger restores the native `pg_catalog.lo_*` function names
  and does not move data. The trigger now also fires for `DROP SCHEMA` and
  `DROP OWNED`.
- The hook refuses the drop if lolor is still enabled when the extension is
  deleted, for example because event triggers are turned off. The check
  reads the catalog at the moment of deletion in the backend that performs
  the drop.
- The drop of an enabled lolor renames the native functions back, and
  therefore has the same requirements as `lolor.disable()`: no other
  client session connected to the database, and a client session.
- The drop is refused while the lolor tables are in a Spock replication
  set, a publication (including one created `FOR ALL TABLES` or `FOR
  TABLES IN SCHEMA lolor`) or a subscription on the node, or were
  synchronized to the node through a Spock subscription. The error names
  the memberships; remove the tables from them first. The hook enforces
  this check when the tables are deleted, so the check holds with event
  triggers disabled.
- The new superuser setting `lolor.allow_unsafe_drop` skips every check and
  discards the contents of lolor storage. With the setting on, the drop
  does not restore the native function names; run `lolor.disable()` first.

### Security

This release contains the following security changes:

- `lo_import()` and `lo_export()` were executable by any database user in
  versions 1.0 through 1.2.3. These functions read and write files on the
  server as the account that runs Postgres, so core Postgres revokes
  `EXECUTE` on them from `PUBLIC`. lolor replaces the functions by renaming
  the originals to `*_orig`; the restriction stayed on the renamed
  original, and each replacement received the default `EXECUTE TO PUBLIC`.
  Any user could read an arbitrary server file with `lo_import()` or
  overwrite one with `lo_export()`. A new installation now restricts the
  replacements, and the update revokes the privilege on an existing
  installation whether lolor is enabled or disabled.
- The extension is no longer marked `trusted`. An installation of lolor
  renames functions in `pg_catalog` for the whole database, which a
  non-superuser should not be able to do.
- `lolor.enable()`, `lolor.disable()` and `lolor.is_enabled()` now probe
  exact function signatures in `pg_catalog`. The functions previously
  matched on `proname` across every schema, so any user with `CREATE` on
  any schema could define a function named `lolor_lo_open` and leave lolor
  in a permanent "inconsistent state" that also blocked `DROP EXTENSION`.
- Source changes address Codacy and Flawfinder warnings, and updates to
  test dependencies address Dependabot alerts.

### Bug Fixes

This release fixes the following defects:

- `DROP ROLE` failed with "unrecognized object class" for any role that had
  created a large object. lolor recorded a `pg_shdepend` row whose
  `classId` was the OID of `lolor.pg_largeobject`, an ordinary table and
  not a catalog, and never removed the row. lolor no longer records these
  rows or invokes object access hooks for objects in lolor storage, and
  the update removes the rows that are already present.
- lolor closed large object descriptors after the commit record was
  written, where any error becomes a PANIC. The cleanup now runs on the
  pre-commit and pre-prepare events, as core Postgres does.
- The `lolor.node` setting accepted 16, which does not fit in the four bits
  that a generated OID reserves for the node id; the node field of every
  OID generated on such a node read back as 0. The upper bound is now
  derived from the encoding and is 15.

### Other Changes

This release also contains the following changes:

- New functions `lolor.check_orphans()` and `lolor.fix_orphans(new_owner
  regrole)` find and repair objects whose owner, grantee or grantor has been
  dropped. Objects in lolor storage cannot participate in `pg_shdepend`, so
  `DROP ROLE` does not notice them. `check_orphans()` lists each object and the
  dangling reference. `fix_orphans()` reassigns objects of dropped owners,
  replaces the old owner in the ACL as `REASSIGN OWNED` does so that grants
  made by the old owner survive, and drops entries that still name a missing
  role. `fix_orphans()` requires superuser and returns the number of objects
  changed.
- `lolor.enable()` and `lolor.disable()` refuse while any other client
  session is connected to the database, since a renamed function keeps its
  OID and other sessions cannot be made to see the switch. The check takes
  an exclusive lock on the database before counting, so a new connection
  waits until the transaction ends. Both functions emit a
  notice that client sessions must reconnect, because libpq caches the
  large object function OIDs for each connection.
- `lolor.enable()` and `lolor.disable()` refuse to run from anything but a
  client session, so replicated DDL cannot execute them inside an apply
  worker.
- `CREATE EXTENSION lolor` has the same requirements as `lolor.enable()`,
  since the install script renames the native functions the same way.
- Single-user mode is exempt from the session check.
- Test coverage is expanded. New TAP tests cover dump and restore,
  streaming and logical replication, standby promotion, file privileges,
  the drop paths, migration fidelity and locking, cross-node OID
  collisions and version skew. New regression tests cover `lo_lseek`,
  `lo_tell`, `lo_truncate`, the 64-bit interface, sparse objects, comment
  round trips, `pg_shdepend` restoration, permission enforcement, the
  orphan helpers and name squatting. The regression suite runs on a
  temporary instance that preloads lolor.
- A new installation runs one install script, `lolor--2.0.0.sql`, and no
  longer replays every update since 1.0. The update scripts from 1.0
  through 1.2.3 remain for existing installations, and the regression
  suite checks that both ways produce the same catalog contents.
- A new build workflow compiles lolor with warnings treated as errors.

## lolor 1.2.3

* Add support for PostgreSQL 19
* Add in-repo release workflow and RPM/DEB packaging
* Improve CI: build the test cluster from source, add PostgreSQL 19 to the test matrix, and bound test run time

## lolor 1.2.2

* Fix lolor upgrades
* Fix issues with pg_upgrade. Note that this fixes upgrades with pg_upgrade going forward. `ALTER EXTENSION UPDATE` for upgrading the extension itself works, so if wanting to run pg_upgrade, first update your extension  to 1.2.2, then run pg_upgrade
* Address CVEs CVE-2022-26520, GHSA-673j-qm5f-xpv8
* PATH updated to match native Postgres packaging layout
* Make table OID caching safer
