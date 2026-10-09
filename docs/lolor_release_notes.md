# lolor Release Notes

## lolor 1.3.0

* Add bidirectional large object migration between native PostgreSQL and lolor storage, implemented as a direct relation-to-relation copy in C (`lolor.migrate_storage()`) rather than a loop through the large object API:
  * `lolor.migrate_from_native(peer_oids oid[] DEFAULT NULL)` moves native large objects into lolor storage. It is a manual step after `CREATE EXTENSION lolor`, requires superuser, and returns the number of objects moved or -1 if the migration was refused.
  * `lolor.migrate_to_native()` moves them back, whether or not lolor is enabled. It also still runs automatically on `DROP EXTENSION lolor`.
  * Both directions preserve OIDs, owners, ACLs, comments and the exact page layout, so sparse objects stay sparse. Ownership and ACLs are recorded in `pg_shdepend` on the way back, so `DROP ROLE`, `REASSIGN OWNED` and `DROP OWNED` see the objects again. Comments are parked in `lolor.pg_largeobject_description` while an object is in lolor storage. Native objects are removed through `performMultipleDeletions()`, the path `DROP` uses, so their dependencies, comments and labels are cleaned up.
  * Storage layouts are verified against the running server at migration time. Security labels, which lolor storage cannot represent, cause `migrate_from_native()` to refuse. OID conflicts are reported with the conflicting OIDs.
  * Migration holds `ShareRowExclusiveLock` on both stores until commit. Ordinary large object access takes `RowExclusiveLock`, which does not conflict with itself, so a concurrent `lo_write()` could otherwise be lost silently. Opposing migrations take their locks in a fixed order and cannot deadlock.
  * Both migration functions refuse while any other session is connected to the database, and refuse to run from anything but a client session.
  * With spock installed, both functions run under `spock.repair_mode()`. If a logical slot spock cannot suppress exists, a non-spock slot or any slot when spock is absent, they refuse rather than let subscribers decode the migration as row changes.
  * Migration is node-local: native large objects are never replicated, so run the migration on each node by connecting to it directly. Do not send it through DDL replication, which would run it inside every subscriber's apply worker. Native OIDs are not node-encoded, so pass the other nodes' OIDs (from `lolor.native_lo_oids()`) as `peer_oids` to turn a cross-node collision into a refusal, and compare `lolor.digest()` across nodes afterwards.
  * `migrate_to_native()` refuses with a clear error while any object refers to a dropped role, instead of failing part-way with "role N was concurrently dropped"; remove those objects with `lo_unlink()` and retry.
* New helpers `lolor.digest()` and `lolor.native_lo_oids()` for cross-node checks after a node-local migration.
* **Security fix: `lo_import()` and `lo_export()` were executable by any database user.** These read and write files on the server as the account PostgreSQL runs under, so core revokes `EXECUTE` on them from `PUBLIC`. lolor replaces them by renaming the originals to `*_orig`; an ACL belongs to a function rather than a name, so the restriction stayed on the parked original while each replacement got the default `EXECUTE TO PUBLIC`. Any user could read an arbitrary server file with `lo_import()` or overwrite one with `lo_export()`. The replacements are now locked down at install time, and upgrading revokes the privilege on existing installations in either state. Versions 1.0 through 1.2.2 are affected.
* The extension is no longer marked `trusted`. Installing lolor renames functions in `pg_catalog` for the whole database, which a non-superuser should not be able to do.
* Fixed the `lolor.node` upper bound. The GUC accepted 0..16 while a generated OID reserves four bits for the node id, so node 16 did not fit: the node field of every OID it generated read back as 0. The bound is now derived from the encoding (`LOLOR_MAX_NODE_ID`), giving 0..15. **If you have `lolor.node = 16` configured**, the server still starts but logs `16 is outside the valid range for parameter "lolor.node" (0 .. 15)` and falls back to 0, which is the node id it was effectively using already. Set it to a value in 0..15, and check for OID collisions against whichever node is genuinely 0.
* Expanded test coverage: TAP tests for dump/restore, streaming and logical replication, standby promotion, migration fidelity and locking, and cross-node OID collisions; regression tests for `lo_lseek`, `lo_tell`, `lo_truncate`, sparse and multi-page objects, comment round trips and the migration helpers.
* Security hardening: addressed Codacy/Flawfinder warnings.

## lolor 1.2.2

* Fix lolor upgrades
* Fix issues with pg_upgrade. Note that this fixes upgrades with pg_upgrade going forward. `ALTER EXTENSION UPDATE` for upgrading the extension itself works, so if wanting to run pg_upgrade, first update your extension  to 1.2.2, then run pg_upgrade
* Address CVEs CVE-2022-26520, GHSA-673j-qm5f-xpv8
* PATH updated to match native Postgres packaging layout
* Make table OID caching safer
