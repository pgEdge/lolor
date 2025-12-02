# lolor Release Notes

## lolor 1.2.2

* Fix lolor upgrades
* Fix issues with pg_upgrade. Note that this fixes upgrades with pg_upgrade going forward. `ALTER EXTENSION UPDATE` for upgrading the extension itself works, so if wanting to run pg_upgrade, first update your extension  to 1.2.2, then run pg_upgrade
* Address CVEs CVE-2022-26520, GHSA-673j-qm5f-xpv8
* PATH updated to match native Postgres packaging layout
* Make table OID caching safer
