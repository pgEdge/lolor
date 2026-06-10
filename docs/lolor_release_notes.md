# lolor Release Notes

## lolor 1.3.0

* Add bidirectional large object migration between native PostgreSQL and lolor storage:
  * `lolor.migrate_from_native()` migrates existing native large objects into lolor storage. This is a manual step (run after `CREATE EXTENSION lolor`) and requires superuser privileges.
  * `lolor.migrate_to_native()` migrates lolor large objects back to native storage.
  * Reverse migration runs automatically on `DROP EXTENSION lolor`, so large objects are never lost when the extension is removed.
  * When the spock extension is installed, both migration functions run under `spock.repair_mode()`, so the row-shuffling migration DML is not replicated to other nodes. Without spock, the functions refuse to migrate while logical replication slots exist in the database: `migrate_from_native()` warns and returns -1, `migrate_to_native()` (and therefore `DROP EXTENSION lolor`) raises an error.
  * Migration is node-local: native large objects are never replicated, so each node holds an independent set and `migrate_from_native()` migrates only the local node's objects. Run it on every node that holds native large objects, for example via `spock.replicate_ddl('SELECT lolor.migrate_from_native()')`. Migrated objects keep their original native OIDs, which are not node-encoded and can collide across nodes if different nodes hold different objects under the same OID; newly created large objects are collision-free, since new OIDs are node-encoded via `lolor.node` and checked against existing rows.
* Expanded test coverage: TAP tests for dump/restore, streaming and logical replication, and standby promotion; regression tests for `lo_lseek`, `lo_tell`, and `lo_truncate`.
* Security hardening: addressed Codacy/Flawfinder warnings.

## lolor 1.2.2

* Fix lolor upgrades
* Fix issues with pg_upgrade. Note that this fixes upgrades with pg_upgrade going forward. `ALTER EXTENSION UPDATE` for upgrading the extension itself works, so if wanting to run pg_upgrade, first update your extension  to 1.2.2, then run pg_upgrade
* Address CVEs CVE-2022-26520, GHSA-673j-qm5f-xpv8
* PATH updated to match native Postgres packaging layout
* Make table OID caching safer
