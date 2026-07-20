# Installing and Configuring lolor

lolor is supported on Postgres versions 16 and later.

lolor ships with pgEdge Distributed Postgres and pgEdge Enterprise Postgres, so a pgEdge deployment provides the extension for you. The Control Plane installs the lolor package on each node as part of standard cluster setup.

If you manage Postgres yourself, you can compile and install the extension from the [source code](https://github.com/pgEdge/lolor), following the same guidelines as any other Postgres extension built with PGXS.  Make sure that your PATH environment variable includes the directory where `pg_config` (under your PostgreSQL installation) is located.

```
export PATH=/opt/pg16/bin:$PATH

# compile
make USE_PGXS=1
make USE_PGXS=1 install
```

After the lolor extension is installed, connect to your Postgres database and create the extension with the command:

```
CREATE EXTENSION lolor;
```

## Configuring lolor

You must set the `lolor.node` parameter on each node in your replication cluster before using the extension. The value can be from 1 to 2^28; the value is used to help in generation of new large object OID.

```
lolor.node = 1
```

You can also change the `search_path` to pick large object related tables from the `lolor` schema:

```
SET search_path=lolor,"$user",public,pg_catalog
```

lolor renames any existing methods in `pg_catalog.lo_*` to `pg_catalog.lo_*_orig`, and new versions of these methods are introduced.  If you remove the extension, the renamed `pg_catalog.lo_*_orig` functions are restored to their initial names.

When you replicate large objects with Spock, the `pg_largeobject` and `pg_largeobject_metadata` tables must belong to your replication set. Connect to the lolor database and add them with `spock.repset_add_table`:

```sql
SELECT spock.repset_add_table('spock_replication_set', 'lolor.pg_largeobject');
SELECT spock.repset_add_table('spock_replication_set', 'lolor.pg_largeobject_metadata');
```