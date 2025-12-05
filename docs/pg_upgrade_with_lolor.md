# Using pg_upgrade with lolor

The `pg_upgrade` utility is used for upgrading Postgres versions.

You can use `pg_upgrade` with the `lolor` extension installed provided that you are using lolor version 1.2.2 or later. If you are using an older version of lolor, you will need to upgrade the extension first.

Before running `pg_upgrade`, you must disable `lolor`. After executing pg_upgrade, you can enable lolor.  Use `psql` or another client to disable lolor:

```
db1_17=# SELECT lolor.disable();
```

Next, execute the upgrade. A sample `pg_ugrade` command appears below:

```
# pg_upgrade --old-datadir=/data/db1_17 \
		--new-datadir=/data/db1_18 \
		--old-bindir=/usr/lib/postgresql/17/bin \
		--new-bindir=/usr/lib/postgresql/18/bin \
		--link
```

Then, use psql to enable `lolor`:

```
db1_18=# SELECT lolor.enable();
```
