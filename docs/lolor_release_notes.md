# lolor Release Notes

## lolor 1.4.0

* Rewrote large object migration between native and lolor storage as a direct relation-to-relation copy in C (`lolor.migrate_storage()`), replacing the previous reverse-migration loop that rewrote every object through the large object API. Fidelity and correctness fixes that follow from it:
  * **Ownership and ACLs are now recorded in `pg_shdepend`.** Through 1.3.0 the reverse migration set `lomowner` with a raw catalog `UPDATE`, which left no shared dependency: `DROP ROLE` would succeed on a role that still owned migrated large objects, `REASSIGN OWNED` skipped them, and `DROP OWNED BY` the migrating superuser could delete other users' objects.
  * **Comments are preserved.** `COMMENT ON LARGE OBJECT` text was silently discarded on migration. It is now parked in `lolor.pg_largeobject_description` while the object is in lolor storage and reinstated on the way back.
  * **Sparse large objects stay sparse.** Pages are copied verbatim instead of being rewritten through the write API, which previously zero-filled every gap — a sparse 10 MB object materialised as 10 MB of pages.
  * Native objects are now removed through `performMultipleDeletions()`, the same path `DROP` uses, so shared dependencies, comments and security labels are cleaned up rather than left behind.
  * Migration no longer routes through the renamed `_orig` functions, so `migrate_to_native()` (and `DROP EXTENSION`) works whether or not lolor is enabled. This resolves the previous "lolor must be enabled before migration to native" failure.
  * Storage layouts are verified against the running server's catalogs at migration time, so a future PostgreSQL catalog change produces a clear error instead of silent corruption.
  * `migrate_from_native()` refuses rather than discarding large object security labels, which lolor storage cannot represent.
  * OID conflicts are reported with the conflicting OIDs instead of only their existence.
* **Security fix: `lo_import()` and `lo_export()` were executable by any database user.** These functions read and write files on the server as the operating system account PostgreSQL runs under, and core revokes `EXECUTE` on them from `PUBLIC`. lolor replaces them by renaming the originals to `*_orig`; an ACL belongs to a function rather than to a name, so the restriction stayed behind on the parked original while each replacement was created with the default of `EXECUTE TO PUBLIC`. Any user could therefore read an arbitrary server file with `lo_import()` or overwrite one with `lo_export()`. The replacements are now locked down at install time, and the upgrade to 1.4.0 revokes the privilege on existing installations in either the enabled or the disabled state. All versions from 1.0 through 1.3.0 are affected.
* Fixed the `lolor.node` upper bound. The GUC accepted 0..16 while a generated OID reserves only four bits for the node id, so node 16 did not fit and was silently encoded as node 0. The bound is now derived from the encoding (`LOLOR_MAX_NODE_ID`), giving a valid range of 0..15; a configuration using node 16 will now be rejected rather than mis-encoding its OIDs.
* Migration now holds `ShareRowExclusiveLock` on both stores until the transaction commits. Ordinary large object reads and writes take `RowExclusiveLock`, which does not conflict with itself, so a concurrent `lo_write()` could previously commit between the point where the migration copied a page and the point where it emptied the source store — losing the write with no error. Two migrations running in opposite directions also now take their locks in a fixed order and cannot deadlock against each other.
* Cleanup now runs for every spelling of the drop. `DROP SCHEMA lolor CASCADE` and `DROP OWNED BY` reach the extension by dependency cascade rather than as `DROP EXTENSION`; the event trigger did not fire for them, so the large objects were destroyed along with the lolor tables and `pg_catalog` was left without a working `lo_open()`.
* `lolor.enable()`, `lolor.disable()` and `lolor.is_enabled()` now probe exact function signatures in `pg_catalog`. They previously matched on `proname` across every schema, so any user with `CREATE` on any schema could create a function named `lolor_lo_open` and permanently wedge lolor into an "inconsistent state" — which also blocked `DROP EXTENSION`. Both functions now also take an advisory lock so concurrent calls serialise.
* The extension is no longer marked `trusted`. Installing lolor renames functions in `pg_catalog` for the whole database, which is not an operation a non-superuser should be able to perform.
* New helpers: `lolor.digest()` for comparing lolor storage across nodes after a node-local migration, `lolor.check_orphans()` for finding objects whose owner has been dropped, and `lolor.native_lo_oids()` plus a `peer_oids` argument to `lolor.migrate_from_native()` that turns the documented cross-node OID collision hazard into a pre-flight refusal.
* `lolor.enable()` and `lolor.disable()` now emit a notice that client sessions must reconnect, since libpq caches the large object function OIDs per connection.
* Regression tests added for sparse objects, comment round trips, `pg_shdepend` restoration, `DROP SCHEMA CASCADE` cleanup, dropping the extension while disabled, and name-squatting resistance. The committed expected output was stale and has been regenerated.

## lolor 1.3.0

* Add bidirectional large object migration between native PostgreSQL and lolor storage:
  * `lolor.migrate_from_native()` migrates existing native large objects into lolor storage. This is a manual step (run after `CREATE EXTENSION lolor`) and requires superuser privileges.
  * `lolor.migrate_to_native()` migrates lolor large objects back to native storage.
  * Reverse migration runs automatically on `DROP EXTENSION lolor`, so large objects are never lost when the extension is removed.
  * With the spock extension installed, both migration functions run under `spock.repair_mode()` so migration is replication-safe. If a logical replication slot that spock cannot suppress is present — a non-spock slot, or any logical slot when spock is absent — the functions refuse to migrate rather than risk losing objects.
  * Migration is node-local: native large objects are never replicated, so each node holds an independent set and `migrate_from_native()` migrates only the local node's objects. Run it on every node that holds native large objects, for example via `spock.replicate_ddl('SELECT lolor.migrate_from_native()')`. Migrated objects keep their original native OIDs, which are not node-encoded and can collide across nodes if different nodes hold different objects under the same OID; newly created large objects are collision-free, since new OIDs are node-encoded via `lolor.node` and checked against existing rows.
* Expanded test coverage: TAP tests for dump/restore, streaming and logical replication, and standby promotion; regression tests for `lo_lseek`, `lo_tell`, and `lo_truncate`.
* Security hardening: addressed Codacy/Flawfinder warnings.

## lolor 1.2.2

* Fix lolor upgrades
* Fix issues with pg_upgrade. Note that this fixes upgrades with pg_upgrade going forward. `ALTER EXTENSION UPDATE` for upgrading the extension itself works, so if wanting to run pg_upgrade, first update your extension  to 1.2.2, then run pg_upgrade
* Address CVEs CVE-2022-26520, GHSA-673j-qm5f-xpv8
* PATH updated to match native Postgres packaging layout
* Make table OID caching safer
