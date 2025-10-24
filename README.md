# lolor

lolor is an extension that makes Postgres' Large Objects compatible with Logical Replication.

## Table of Contents
- [lolor Overview](docs/index.md)
- [Building and Installing lolor](docs/install_configure.md)
- [Basic Configuration](README.md#configuring-lolor)
- [Using lolor](docs/using_lolor.md)
- [Limitations](README.md#limitations)

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

While using `pgedge` replication with large objects, you must have the tables `pg_largeobject` and `pg_largeobject_metadata` in your replication set; use 
the following commands to add the tables:

```
./pgedge spock repset-add-table spock_replication_set 'lolor.pg_largeobject' lolor_db
./pgedge spock repset-add-table spock_replication_set 'lolor.pg_largeobject_metadata' lolor_db
```

### Limitations

- Native large object functionality cannot be used while you are using the lolor extension.
- Native large object migration to the lolor feature is not available yet.
- lolor does not support the following statements: `ALTER LARGE OBJECT`, `GRANT ON LARGE OBJECT`, `COMMENT ON LARGE OBJECT`, and `REVOKE ON LARGE OBJECT`.
