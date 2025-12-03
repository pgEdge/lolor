# Using pg_upgrade with lolor

The `pg_upgrade` utility is used for upgrading Postgres versions.

You can use `pg_upgrade` with the `lolor` extension installed provided that you are using at least version 1.2.2. If using an older version, you will need to upgrade the extension first.

Before running `pg_upgrade`, you must disable `lolor`. After executing, it can be enabled again.

Use `psql` or another client to disable:

```
db1_17=# SELECT lolor.disable();
```

Next, execute the upgrade. An example `pg_ugrade` command appears below:

```
# pg_upgrade --old-datadir=/data/db1_17 \
		--new-datadir=/data/db1_18 \
		--old-bindir=/usr/lib/postgresql/17/bin \
		--new-bindir=/usr/lib/postgresql/18/bin \
		--link
```

Finally, enable `lolor`:

```
db1_18=# SELECT lolor.enable();
```
